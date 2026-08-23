// M1 自动更新服务：源检查（GitHub 默认 / 自定义 URL）+ 流式下载/校验/原子改名 + {sequence,payloadDigest} 持久化。
// 信任链：payloadDigest 与 sequence 判定 → parseAndVerifyManifest（验签+结构校验）→ 产物 sha256/size 校验。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trusted_keys.dart';
import 'update_manifest.dart';

const kDefaultGitOwner = '201222-L';
const kDefaultGitRepo = 'dsh-mobile-remote';
const kManifestAssetName = 'update.json';

/// 检查结果（App 侧判定已做好）
class UpdateCheckResult {
  final UpdateManifest? manifest;
  final String? verifiedKeyId;
  final bool appUpdate; // artifacts.app.versionCode > 当前
  final bool pluginUpdate; // artifacts.plugin.versionName > 当前插件版本
  final bool blocked; // 兼容闸门：目标 App 要求的最低插件版本 > 当前插件版本
  final String? blockReason; // blocked 的说明
  final String? error; // 失败原因（网络/manifest 不可信/sequence 拒绝）
  UpdateCheckResult({
    this.manifest,
    this.verifiedKeyId,
    this.appUpdate = false,
    this.pluginUpdate = false,
    this.blocked = false,
    this.blockReason,
    this.error,
  });
}

/// 全局单例；lastCheck 供各页面读取/监听（启动静默检查结果落在这里，不弹阻断窗）。
final Updater updater = Updater();
final ValueNotifier<UpdateCheckResult?> lastUpdateCheck = ValueNotifier(null);

/// 简单 semver 比较（x.y.z，忽略 pre-release：manifest 插件版本不含 pre）
bool semverGt(String a, String b) {
  final pa = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(a.trim());
  final pb = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(b.trim());
  if (pa == null || pb == null) return false;
  for (var i = 1; i <= 3; i++) {
    final x = int.parse(pa.group(i)!);
    final y = int.parse(pb.group(i)!);
    if (x != y) return x > y;
  }
  return false;
}

/// 用户取消下载
class UpdateCancelled implements Exception {
  @override
  String toString() => 'UpdateCancelled';
}

/// 捕获 chunked 哈希结果（crypto 未导出 DigestSink，自己的 5 行实现）
class _DigestCapture implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class Updater {
  static const _kSeq = 'update_seq';
  static const _kDigest = 'update_digest';
  static const _kSource = 'update_source'; // 'github' | 'custom'
  static const _kCustomUrl = 'update_custom_url';

  final http.Client _http = http.Client();

  // ── 更新源配置 ──
  Future<String> sourceKind() async =>
      (await SharedPreferences.getInstance()).getString(_kSource) ?? 'github';
  Future<void> setSource(String kind) async =>
      (await SharedPreferences.getInstance()).setString(_kSource, kind);
  Future<String?> customUrl() async =>
      (await SharedPreferences.getInstance()).getString(_kCustomUrl);
  Future<void> setCustomUrl(String? url) async {
    final p = await SharedPreferences.getInstance();
    if (url == null || url.trim().isEmpty) {
      await p.remove(_kCustomUrl);
    } else {
      await p.setString(_kCustomUrl, url.trim());
    }
  }

  // ── sequence 记录 ──
  Future<({int? sequence, String? digest})> loadSequenceRecord() async {
    final p = await SharedPreferences.getInstance();
    return (sequence: p.getInt(_kSeq), digest: p.getString(_kDigest));
  }

  Future<void> saveSequenceRecord(int sequence, String digest) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSeq, sequence);
    await p.setString(_kDigest, digest);
  }

  /// 检查更新：拉取 manifest → payloadDigest/sequence 判定 → 验签 → 两端版本比较。
  Future<UpdateCheckResult> check({
    required int currentVersionCode,
    required String currentPluginVersion,
    Map<String, String>? trustedKeys,
  }) async {
    try {
      final kind = await sourceKind();
      final String raw;
      final String manifestUrl;
      if (kind == 'custom') {
        final url = await customUrl();
        if (url == null || url.isEmpty) {
          return UpdateCheckResult(error: '未配置自定义更新源');
        }
        manifestUrl = url;
        raw = await _getText(url);
      } else {
        manifestUrl = await _fetchGitHubManifestUrl();
        raw = await _getText(manifestUrl);
      }
      final stored = await loadSequenceRecord();
      final digest = await payloadDigestOf(raw);
      final (manifest, keyId) =
          await parseAndVerifyManifest(raw, trustedKeys: trustedKeys ?? trustedReleaseKeys);
      final decision = decideSequence(
        storedSequence: stored.sequence,
        storedDigest: stored.digest,
        sequence: manifest.sequence,
        payloadDigest: digest,
      );
      switch (decision) {
        case SequenceDecision.rejectOlder:
          return UpdateCheckResult(error: '更新源返回旧版本（sequence 重放），已忽略');
        case SequenceDecision.sameConflict:
          return UpdateCheckResult(error: '同 sequence 但内容不一致，已忽略');
        case SequenceDecision.sameAllowed:
          break; // 同一 manifest：允许继续（重试/恢复）
        case SequenceDecision.acceptNew:
          await saveSequenceRecord(manifest.sequence, digest);
          break;
      }
      return UpdateCheckResult(
        manifest: manifest,
        verifiedKeyId: keyId,
        appUpdate: manifest.app.versionCode! > currentVersionCode,
        pluginUpdate: semverGt(manifest.plugin.versionName, currentPluginVersion),
        // 兼容闸门（PRD §4.1-G）：目标 App 所需最低插件版本 > 当前插件版本 → blocked
        blocked: semverGt(manifest.minPluginVersion, currentPluginVersion),
        blockReason: '电脑插件版本过低（目标 App 要求 ≥ ${manifest.minPluginVersion}，'
            '当前 ${currentPluginVersion.isEmpty ? '未知' : currentPluginVersion}）',
      );
    } catch (e) {
      return UpdateCheckResult(
        error: e is UpdateManifestException ? '[${e.code}] ${e.message}' : '$e',
      );
    }
  }

  /// 产物下载地址：自定义源按 manifest URL 目录 + fileName；GitHub 源按资产解析。
  Future<String> artifactUrl(String fileName) async {
    final kind = await sourceKind();
    if (kind == 'custom') {
      final url = await customUrl();
      if (url == null || url.isEmpty) throw Exception('未配置自定义更新源');
      final base = url.substring(0, url.lastIndexOf('/') + 1);
      return '$base$fileName';
    }
    return _githubAssetUrl(fileName);
  }

  Future<String> _fetchGitHubManifestUrl() async {
    final r = await _http
        .get(
          Uri.parse(
              'https://api.github.com/repos/$kDefaultGitOwner/$kDefaultGitRepo/releases/latest'),
          headers: const {'accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('GitHub Releases 请求失败 HTTP ${r.statusCode}');
    final doc = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final assets = (doc['assets'] as List? ?? const []);
    for (final a in assets) {
      final m = a as Map;
      if (m['name'] == kManifestAssetName) return m['browser_download_url'] as String;
    }
    throw Exception('最新 Release 未找到 $kManifestAssetName');
  }

  Future<String> _githubAssetUrl(String fileName) async {
    final r = await _http
        .get(
          Uri.parse(
              'https://api.github.com/repos/$kDefaultGitOwner/$kDefaultGitRepo/releases/latest'),
          headers: const {'accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('GitHub Releases 请求失败 HTTP ${r.statusCode}');
    final doc = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final assets = (doc['assets'] as List? ?? const []);
    for (final a in assets) {
      final m = a as Map;
      if (m['name'] == fileName) return m['browser_download_url'] as String;
    }
    throw Exception('Release 资产未找到 $fileName');
  }

  Future<String> _getText(String url) async {
    final r = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('下载 manifest 失败 HTTP ${r.statusCode}');
    return utf8.decode(r.bodyBytes);
  }

  /// 流式下载产物：手写消费循环（同一次遍历写文件+算 sha256，不用广播流——广播方案
  /// 在部分设备上会因订阅时序丢块/文件缺失）；校验 size/sha256 → 原子改名。
  /// [onProgress] 报告 (已收字节, 总字节)；[isCancelled] 每块检查，true 时清理并抛 [UpdateCancelled]。
  Future<File> downloadArtifact(
    UpdateArtifact art, {
    void Function(int received, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    final url = await artifactUrl(art.fileName);
    // M1 review(P1-5)：下载目录用 cacheDir——FileProvider 只暴露 cache-path，
    // 不以设备根作为可授予范围；校验通过前仅存 tmp。
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/updates');
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/${art.fileName}.tmp');
    final finalFile = File('${dir.path}/${art.fileName}');
    final req = await _http.send(http.Request('GET', Uri.parse(url)));
    if (req.statusCode != 200) throw Exception('下载失败 HTTP ${req.statusCode}');
    final sink = tmp.openWrite();
    final acc = _DigestCapture();
    final hashSink = sha256.startChunkedConversion(acc);
    var received = 0;
    try {
      await for (final chunk in req.stream) {
        if (isCancelled != null && await isCancelled()) {
          throw UpdateCancelled();
        }
        sink.add(chunk);
        hashSink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, art.sizeBytes);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      // 失败/取消：清理临时文件后上抛
      try { await sink.close(); } catch (_) {}
      try { if (tmp.existsSync()) await tmp.delete(); } catch (_) {}
      rethrow;
    }
    hashSink.close();
    final digest = acc.value.toString();
    if (digest != art.sha256) {
      await tmp.delete();
      throw Exception('校验失败：sha256 不符');
    }
    if (tmp.lengthSync() != art.sizeBytes) {
      await tmp.delete();
      throw Exception('校验失败：文件大小不符（${tmp.lengthSync()} ≠ ${art.sizeBytes}）');
    }
    if (finalFile.existsSync()) await finalFile.delete();
    await tmp.rename(finalFile.path);
    return finalFile;
  }
}
