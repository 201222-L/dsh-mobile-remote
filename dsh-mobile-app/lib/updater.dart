// 自动更新编排：检查（按更新源取候选 + 版本判定）→ 下载（进度）→ sha256 校验（主机源）→
// 签名预检（自身 vs 下载 APK）→ 拉起系统安装器。均有副作用，按 spec 由 UI 层驱动。
import 'dart:convert';
import 'dart:io';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'logger.dart';
import 'native_update.dart';
import 'store.dart';
import 'update_core.dart';

/// 一次「检查更新」的结果。
class UpdateCheckOutcome {
  final UpdateVerdict verdict;
  final UpdateCandidate? candidate;
  final String? error; // 检查失败的人类可读提示（verdict 无意义时使用）
  const UpdateCheckOutcome({required this.verdict, this.candidate, this.error});
}

/// 下载取消令牌：UI 关闭进度弹窗时调用 [cancel] —— 中止 HTTP 流、
/// 停止后续校验/安装，并清理半成品文件（spec：取消即清理文件）。
class UpdateCancelToken {
  bool _cancelled = false;
  http.Client? _client;
  void cancel() {
    _cancelled = true;
    try {
      _client?.close(); // 中断进行中的下载流（抛 ClientException 由调用方收敛）
    } catch (_) {}
  }

  bool get cancelled => _cancelled;
}

/// 主机源检查错误 → 明确的中文提示（spec：错误码可读化，「主机源未配置更新」等）。
String hostCheckErrorMessage(ApiException e) {
  switch (e.code) {
    case 'update-not-configured':
      return '主机源未配置更新（需在插件配置 updateDir 并放入发布产物）';
    case 'update-dir-missing':
      return '主机更新目录不存在，请检查插件 updateDir 配置';
    case 'update-manifest-missing':
      return '主机更新目录缺少 manifest.json';
    case 'update-manifest-invalid':
      return '主机 manifest.json 格式无效';
    default:
      return '主机源检查失败：${e.message}';
  }
}

class Updater {
  static const _githubRepo = 'https://api.github.com/repos/201222-L/dsh-mobile-remote/releases/latest';

  /// 读取本机 App 版本（package_info_plus）。失败返回 null。
  static Future<AppVersion?> _localVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return parseAppVersion('${info.version}+${info.buildNumber}');
    } catch (e) {
      AppLog.instance.log('Update: 读取本地版本失败 $e');
      return null;
    }
  }

  /// 检查更新：按 store.updateSource 取候选并判定。不抛（失败收敛为 error 结果）。
  static Future<UpdateCheckOutcome> check(AppStore store) async {
    final local = await _localVersion();
    if (local == null) {
      return const UpdateCheckOutcome(verdict: UpdateVerdict.upToDate, error: '无法读取本地版本');
    }
    UpdateCandidate? candidate;
    try {
      if (store.updateSource == 'host') {
        candidate = await _candidateFromHost();
      } else {
        candidate = await _candidateFromGithub();
      }
    } catch (e) {
      AppLog.instance.log('Update: 检查失败 $e');
      return UpdateCheckOutcome(verdict: UpdateVerdict.upToDate, error: _checkErrorMessage(store.updateSource, e));
    }
    if (candidate == null) {
      // 源可用但无候选（主机未配置更新 / release 无 APK 资产）
      final msg = store.updateSource == 'host'
          ? '主机源没有可用的更新配置'
          : 'GitHub 最新 release 中没有 APK 资产';
      return UpdateCheckOutcome(verdict: UpdateVerdict.upToDate, error: msg);
    }
    final remote = parseAppVersion(candidate.version);
    if (remote == null) {
      return UpdateCheckOutcome(verdict: UpdateVerdict.upToDate, error: '更新源版本号格式异常：${candidate.version}');
    }
    return UpdateCheckOutcome(
      verdict: verdictFor(local: local, remote: remote),
      candidate: candidate,
    );
  }

  /// 检查失败的提示：主机源按错误码映射；GitHub 失败给「可切主机源」引导（spec）。
  static String _checkErrorMessage(String source, Object e) {
    if (source == 'host') {
      if (e is ApiException) return hostCheckErrorMessage(e);
      return '主机源检查失败：$e';
    }
    return 'GitHub 源检查失败：$e（网络不可达？可在「更新源」切换为主机源）';
  }

  static Future<UpdateCandidate?> _candidateFromHost() async {
    final d = await api.updateManifest();
    // 检查与下载同 base：挂载路径来自 bootstrap 权威校正，不可硬编码 /m
    return candidateFromHostManifest(d, baseUrl: hostApiBase(baseUrl: api.baseUrl, mountPath: api.path));
  }

  static Future<UpdateCandidate?> _candidateFromGithub() async {
    // GitHub API 强制要求 User-Agent
    final resp = await http
        .get(Uri.parse(_githubRepo), headers: {'User-Agent': 'dsh-mobile-remote-app'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException('GitHub API HTTP ${resp.statusCode}');
    }
    final release = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return candidateFromGithubRelease(release);
  }

  /// 启动静默自动检查（spec：默认开）：仅把命中的候选写入 store（不弹窗），
  /// 由首页横幅 / 设置页「有新版本」提示驱动用户操作；失败静默跳过。
  static Future<void> autoCheckSilent(AppStore store) async {
    if (store.updateChecking) return;
    store.updateChecking = true;
    final o = await check(store);
    store.updateChecking = false;
    if (o.verdict == UpdateVerdict.updateAvailable && o.candidate != null) {
      store.setUpdateCandidate(o.candidate);
    }
  }

  /// 下载 + 校验 + 签名预检 + 安装。成功返回 null；失败返回人类可读错误；
  /// 用户取消（经 [cancel]）返回 'cancelled' 并清理半成品文件，不进入安装。
  /// [onProgress]：(已下载字节, 总字节或 null)；[onStage]：阶段提示（用于 UI）。
  static Future<String?> downloadAndInstall(
    UpdateCandidate candidate, {
    void Function(int received, int? total)? onProgress,
    void Function(String stage)? onStage,
    UpdateCancelToken? cancel,
  }) async {
    // ── 下载 ──
    final dir = await getTemporaryDirectory();
    final updateDir = Directory('${dir.path}/dsh-update');
    await updateDir.create(recursive: true);
    final target = File('${updateDir.path}/dsh-update-${DateTime.now().millisecondsSinceEpoch}.apk');

    // 取消即清理：删除半成品并收敛为 'cancelled'（UI 已自行展示取消态）
    Future<String> abortCancelled() async {
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      return 'cancelled';
    }

    http.Client? client;
    IOSink? sink;
    try {
      onStage?.call('download');
      final req = http.Request('GET', Uri.parse(candidate.downloadUrl));
      if (candidate.source == '主机' && api.token.isNotEmpty) {
        req.headers['x-mobile-token'] = api.token;
      }
      client = http.Client();
      if (cancel != null) cancel._client = client;
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        return '下载失败：HTTP ${resp.statusCode}';
      }
      final total = resp.contentLength ?? candidate.sizeBytes;
      sink = target.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        if (cancel?.cancelled == true) break;
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancel?.cancelled == true) return await abortCancelled();
      if (!await target.exists() || await target.length() == 0) {
        return '下载失败：文件为空';
      }
      bool wasCancelled() => cancel?.cancelled == true;

      // ── sha256 校验（主机源 manifest 提供；GitHub 无 -> 跳过） ──
      if (candidate.sha256 != null && candidate.sha256!.isNotEmpty) {
        onStage?.call('checksum');
        if (wasCancelled()) return await abortCancelled();
        final acc = AccumulatorSink<Digest>();
        await sha256.bind(target.openRead()).fold<AccumulatorSink<Digest>>(acc, (a, d) {
          a.add(d);
          return a;
        });
        final digest = acc.events.single.toString();
        if (digest != candidate.sha256!.toLowerCase()) {
          await target.delete();
          return '校验失败：文件与发布清单不一致，已取消';
        }
      }
      if (wasCancelled()) return await abortCancelled();

      // ── 签名预检（自身 vs 下载 APK；任一读取失败 → 保守取消） ──
      onStage?.call('signature');
      final own = await NativeUpdate.ownSignatureSha256();
      final apk = await NativeUpdate.apkSignatureSha256(target.path);
      if (wasCancelled()) return await abortCancelled();
      if (own == null || apk == null) {
        await target.delete();
        return '无法读取签名信息，已取消更新';
      }
      if (own.toLowerCase() != apk.toLowerCase()) {
        await target.delete();
        return '签名不一致，已取消更新（请先卸载旧版，或使用同签名版本）';
      }

      // ── 安装（拉起系统安装器；最终核对交给系统） ──
      onStage?.call('install');
      await NativeUpdate.installApk(target.path);
      return null;
    } catch (e) {
      AppLog.instance.log('Update: 下载/安装失败 $e');
      // 用户取消触发的中断（close 流）不算失败——收敛为 cancelled
      if (cancel?.cancelled == true) return await abortCancelled();
      final err = '$e';
      try {
        if (sink != null) {
          await sink.close();
        }
      } catch (_) {}
      sink = null;
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      return '更新失败：$err';
    } finally {
      try {
        client?.close();
      } catch (_) {}
    }
  }
}