// M1/M2 自动更新服务：四源模式（自动=双源对照+本地记录/仅电脑/仅 GitHub/自定义）+ 流式下载/校验/原子改名
// + {sequence,payloadDigest} 持久化；电脑源 updateToken/HMAC 认证；plugin-update 编排（插件先行）。
// 信任链：payloadDigest 与 sequence 判定 → parseAndVerifyManifest（验签+结构校验）→ 产物 sha256/size 校验。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
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
  final String source; // 胜出源：'auto'|'pc'|'github'|'custom'
  UpdateCheckResult({
    this.manifest,
    this.verifiedKeyId,
    this.appUpdate = false,
    this.pluginUpdate = false,
    this.blocked = false,
    this.blockReason,
    this.error,
    this.source = 'auto',
  });
}

/// 单源候选（已验签合法）
class _Candidate {
  final String source;
  final UpdateManifest? manifest;
  final String? digest;
  final String? verifiedKeyId;
  final String? error; // 取源失败
  _Candidate.ok(this.source, UpdateManifest m, String d, String k)
      : manifest = m,
        digest = d,
        verifiedKeyId = k,
        error = null;
  _Candidate.err(this.source, this.error)
      : manifest = null,
        digest = null,
        verifiedKeyId = null;
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

/// 兼容闸门判定（review2 P1-2）：目标 App 声明了 minPluginVersion 时，
/// 当前插件版本**未知/格式非法**一律视为不满足硬闸门（blocked）——不得绕过。
bool isAppUpdateBlocked({
  required String minPluginVersion,
  required String currentPluginVersion,
}) {
  if (!RegExp(r'^\d+\.\d+\.\d+').hasMatch(minPluginVersion.trim())) return false; // 未有效声明 → 无闸门
  if (!RegExp(r'^\d+\.\d+\.\d+').hasMatch(currentPluginVersion.trim())) return true; // 未知/异常 → 不满足
  return semverGt(minPluginVersion, currentPluginVersion);
}

/// M2 双源判定纯函数（供单测）：本地记录核对（M1 四规则）→ 账本冲突 → 胜出选择。
/// 返回：'conflict'（同序异 content）/ 'none'（无可用：重放、同序异冲突或全量不可接受）/ 胜出源 source。
String resolveDualSourceSelection(
  List<({String source, int sequence, String digest})> candidates, {
  int? storedSequence,
  String? storedDigest,
}) {
  final ok = candidates.where((c) {
    final d = decideSequence(
      storedSequence: storedSequence,
      storedDigest: storedDigest,
      sequence: c.sequence,
      payloadDigest: c.digest,
    );
    return d == SequenceDecision.sameAllowed || d == SequenceDecision.acceptNew;
  }).toList();
  if (ok.isEmpty) return 'none';
  for (var i = 0; i < ok.length; i++) {
    for (var j = i + 1; j < ok.length; j++) {
      if (ok[i].sequence == ok[j].sequence && ok[i].digest != ok[j].digest) return 'conflict';
    }
  }
  ok.sort((a, b) {
    final s = b.sequence.compareTo(a.sequence);
    return s != 0 ? s : (a.source == 'pc' ? -1 : 1);
  });
  return ok.first.source;
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

  /// 检查更新（M2）：按模式取源 → 各源本地记录核对（M1 规则）→ 多源一致判定 → 两端版本比较。
  Future<UpdateCheckResult> check({
    required int currentVersionCode,
    required String currentPluginVersion,
    Map<String, String>? trustedKeys,
  }) async {
    try {
      final kind = await sourceKind();
      final stored = await loadSequenceRecord();
      final candidates = <_Candidate>[];
      // 1. 按模式取源
      if (kind == 'custom') {
        final url = await customUrl();
        if (url == null || url.isEmpty) {
          return UpdateCheckResult(error: '未配置自定义更新源', source: kind);
        }
        candidates.add(await _fetchCandidateCustom(url, trustedKeys));
      } else {
        if (kind == 'auto' || kind == 'github') {
          candidates.add(await _fetchCandidateGithub(trustedKeys));
        }
        if (kind == 'auto' || kind == 'pc') {
          if (api.updateToken.isEmpty) {
            if (kind == 'pc') {
              return UpdateCheckResult(
                  error: '未配置更新通道凭据（请到设置→重新配置连接→扫码配对）', source: kind);
            }
          } else if (api.baseUrl.isNotEmpty && api.path.isNotEmpty) {
            candidates.add(await _fetchCandidatePc(trustedKeys));
          }
        }
      }
      // 2/3/4. 本地记录核对 + 账本冲突 + 胜出（纯函数 resolveDualSourceSelection）
      final selection = resolveDualSourceSelection(
        candidates.where((c) => c.error == null).map((c) => (source: c.source, sequence: c.manifest!.sequence, digest: c.digest!)).toList(),
        storedSequence: stored.sequence,
        storedDigest: stored.digest,
      );
      if (selection == 'none' || selection == 'conflict') {
        if (selection == 'conflict') {
          return UpdateCheckResult(error: '发布账本冲突：两个源返回同 sequence 的不同内容，已拒绝', source: kind);
        }
        final errs = candidates.where((c) => c.error != null).map((c) => c.error).whereType<String>().toList();
        return UpdateCheckResult(
          error: errs.isNotEmpty
              ? '检查更新失败：${errs.first}'
              : '更新源均未返回可接受的版本（sequence 重放或同序异内容）',
          source: kind,
        );
      }
      // 5. 按胜出源定位完整候选（最高 sequence 中优先胜出源；同 seq 同 digest 两源等价）
      final bySeq = candidates.where((c) => c.error == null).toList()
        ..sort((a, b) => b.manifest!.sequence.compareTo(a.manifest!.sequence));
      final bestSeq = bySeq.first.manifest!.sequence;
      final winner = bySeq.firstWhere(
        (c) => c.source == selection && c.manifest!.sequence == bestSeq,
        orElse: () => bySeq.first,
      );
      if (winner.manifest!.sequence > (stored.sequence ?? 0)) {
        await saveSequenceRecord(winner.manifest!.sequence, winner.digest!);
      }
      return UpdateCheckResult(
        manifest: winner.manifest,
        verifiedKeyId: winner.verifiedKeyId,
        source: winner.source,
        appUpdate: winner.manifest!.app.versionCode! > currentVersionCode,
        pluginUpdate: semverGt(winner.manifest!.plugin.versionName, currentPluginVersion),
        // 兼容闸门（PRD §4.1-G / review2 P1-2）：插件版本未知/非法也视为不满足，不可绕过
        blocked: isAppUpdateBlocked(
          minPluginVersion: winner.manifest!.minPluginVersion,
          currentPluginVersion: currentPluginVersion,
        ),
        blockReason: '电脑插件版本过低（目标 App 要求 ≥ ${winner.manifest!.minPluginVersion}，'
            '当前 ${currentPluginVersion.isEmpty ? '未知' : currentPluginVersion}）',
      );
    } catch (e) {
      return UpdateCheckResult(
        error: e is UpdateManifestException ? '[${e.code}] ${e.message}' : '$e',
      );
    }
  }

  Future<_Candidate> _fetchCandidateGithub(Map<String, String>? trustedKeys) async {
    try {
      final url = await _fetchGitHubManifestUrl();
      final raw = await _getText(url);
      return await _parseCandidate('github', raw, trustedKeys);
    } catch (e) {
      return _Candidate.err('github', '$e');
    }
  }

  Future<_Candidate> _fetchCandidatePc(Map<String, String>? trustedKeys) async {
    try {
      final res = await _pcRequest('GET', '/api/update-check', null);
      if (res.statusCode == 404) return _Candidate.err('pc', '电脑更新缓存无已验签 manifest');
      if (res.statusCode == 401) {
        return _Candidate.err('pc', '更新通道凭据失效（请重新扫码配对）');
      }
      if (res.statusCode != 200) return _Candidate.err('pc', '电脑源 HTTP ${res.statusCode}');
      final raw = utf8.decode(res.bodyBytes);
      return await _parseCandidate('pc', raw, trustedKeys);
    } catch (e) {
      return _Candidate.err('pc', '$e');
    }
  }

  Future<_Candidate> _fetchCandidateCustom(String url, Map<String, String>? trustedKeys) async {
    try {
      final raw = await _getText(url);
      return await _parseCandidate('custom', raw, trustedKeys);
    } catch (e) {
      return _Candidate.err('custom', '$e');
    }
  }

  Future<_Candidate> _parseCandidate(
      String source, String raw, Map<String, String>? trustedKeys) async {
    final digest = await payloadDigestOf(raw);
    final (m, kid) = await parseAndVerifyManifest(raw, trustedKeys: trustedKeys ?? trustedReleaseKeys);
    return _Candidate.ok(source, m, digest, kid);
  }

  // ── 电脑源（updateToken/HMAC） ──
  /// PC 源完整 URL（桥/插件挂载路径 + 更新端点路径）
  Uri _pcUri(String apiPath) {
    var base = api.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    var mount = api.path.trim();
    if (mount.isEmpty) mount = '/m';
    if (mount.endsWith('/')) mount = mount.substring(0, mount.length - 1);
    return Uri.parse('$base$mount$apiPath');
  }

  /// HMAC 请求头（canonicalRequest 与插件端一致：method\npath\nquery\nbodySha\nts\nnonce）
  Future<Map<String, String>> _pcHeaders(String method, String path, String bodyShaHex) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = base64Url
        .encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final canonical = '$method\n$path\n\n$bodyShaHex\n$ts\n$nonce';
    final hmac = await cg.Hmac.sha256().calculateMac(
        utf8.encode(canonical),
        secretKey: cg.SecretKey(utf8.encode(api.updateToken)));
    final auth = base64Url.encode(hmac.bytes);
    return {'x-update-ts': '$ts', 'x-update-nonce': nonce, 'x-update-auth': auth};
  }

  Future<http.Response> _pcRequest(String method, String apiPath, String? body) async {
    final bodyBytes = utf8.encode(body ?? '');
    final bodyShaHex = sha256.convert(bodyBytes).toString();
    final headers = await _pcHeaders(method, apiPath, bodyShaHex);
    headers['content-type'] = 'application/json';
    final req = http.Request(method, _pcUri(apiPath));
    req.headers.addAll(headers);
    if (body != null) req.body = body;
    return _http.send(req).then((r) async => (await http.Response.fromStream(r)));
  }

  /// 触发电脑插件暂存（plugin-update）；返回插件端 { staged } 或抛错。
  Future<Map<String, dynamic>> pluginUpdate(
    UpdateManifest m, {
    String source = 'github',
    required int declaredAppVersionCode,
  }) async {
    if (!api.hasPluginUpdateCapability) {
      throw Exception('电脑插件不支持联动更新（能力字段缺失），请按 docs/06 人工升级');
    }
    if (api.updateToken.isEmpty) throw Exception('未配置更新通道凭据（请重新扫码配对）');
    final body = jsonEncode({
      'manifest': m.rawSigned,
      'source': source,
      'declaredAppVersionCode': declaredAppVersionCode,
    });
    final res = await _pcRequest('POST', '/api/plugin-update', body);
    if (res.statusCode == 409) {
      throw Exception('插件端校验：当前 App 版本过低（${res.body}）');
    }
    if (res.statusCode == 401) throw Exception('更新通道凭据失效（请重新扫码配对）');
    if (res.statusCode != 200) throw Exception('插件暂存失败 HTTP ${res.statusCode}: ${res.body}');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// 产物下载请求解析：按胜出源决定 URL 与请求头（PC 源带 HMAC；GitHub/自定义无附加认证）。
  Future<({String url, Map<String, String> headers})> artifactRequest(
    UpdateManifest m,
    UpdateArtifact art, {
    required String source,
  }) async {
    if (source == 'pc') {
      if (api.updateToken.isEmpty) throw Exception('未配置更新通道凭据（请重新扫码配对）');
      final path = '/api/update-file/${art.artifactId}';
      final headers = await _pcHeaders('GET', path, _emptyBodySha);
      return (url: _pcUri(path).toString(), headers: headers);
    }
    if (source == 'custom') {
      final url = await customUrl();
      if (url == null || url.isEmpty) throw Exception('未配置自定义更新源');
      final base = url.substring(0, url.lastIndexOf('/') + 1);
      return (url: '$base${art.fileName}', headers: const <String, String>{});
    }
    final url = await _githubAssetUrl(art.fileName);
    return (url: url, headers: const <String, String>{});
  }

  static const _emptyBodySha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

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
    UpdateManifest m,
    UpdateArtifact art, {
    required String source,
    void Function(int received, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    final rq = await artifactRequest(m, art, source: source);
    // M1 review(P1-5)：下载目录用 cacheDir——FileProvider 只暴露 cache-path，
    // 不以设备根作为可授予范围；校验通过前仅存 tmp。
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/updates');
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/${art.fileName}.tmp');
    final finalFile = File('${dir.path}/${art.fileName}');
    final httpReq = http.Request('GET', Uri.parse(rq.url));
    httpReq.headers.addAll(rq.headers);
    final req = await _http.send(httpReq);
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
