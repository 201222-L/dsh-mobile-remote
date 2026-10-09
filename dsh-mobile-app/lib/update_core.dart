// App 自动更新 — 纯决策模块（无 I/O，可单测）。
// 职责：版本解析/比较、更新判定（含防降级）、更新源候选构建（host manifest / GitHub release）。
// 下载、校验、签名、安装等有副作用的步骤在调用方（updater / UI）完成。
import 'package:flutter/foundation.dart';

/// 版本号：`major.minor.patch` + 可选 `+build`。
@immutable
class AppVersion {
  final int major;
  final int minor;
  final int patch;
  final int build; // 缺失视为 0
  final bool buildSet; // 原版本串是否显式带 +build（GitHub tag 无 build → false）

  const AppVersion(this.major, this.minor, this.patch,
      {this.build = 0, bool? buildSet})
      : buildSet = buildSet ?? build > 0;

  @override
  String toString() => buildSet ? '$major.$minor.$patch+$build' : '$major.$minor.$patch';
}

/// 解析版本串：容忍 `v` 前缀与 `+build` 后缀；非法返回 null。
/// 例：`v3.0.0` → 3.0.0（buildSet=false）；`3.0.0+8` → 3.0.0+8（buildSet=true）。
AppVersion? parseAppVersion(String input) {
  var s = input.trim();
  if (s.startsWith('v')) s = s.substring(1).trim();
  final plus = s.indexOf('+');
  var build = 0;
  if (plus != -1) {
    final b = s.substring(plus + 1).trim();
    if (b.isEmpty) return null; // 显式 `+` 但无 build → 非法（防畸形 manifest）
    final n = int.tryParse(b);
    if (n == null || n < 0) return null;
    build = n;
    s = s.substring(0, plus).trim();
  }
  final parts = s.split('.');
  if (parts.length != 3) return null;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0) return null;
    nums.add(n);
  }
  return AppVersion(nums[0], nums[1], nums[2], build: build, buildSet: plus != -1);
}

/// 版本比较：a < b → 负；相等 → 0；a > b → 正。先比 major/minor/patch，再比 build。
int compareAppVersion(AppVersion a, AppVersion b) {
  for (final pair in [
    (a.major, b.major),
    (a.minor, b.minor),
    (a.patch, b.patch),
    (a.build, b.build),
  ]) {
    if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
  }
  return 0;
}

/// 更新判定结果。
enum UpdateVerdict {
  upToDate, // 版本相等：不需要更新
  updateAvailable, // 远端更新：需要更新
  remoteOlder, // 远端低于本地：异常（防降级）
}

/// 比较 major/minor/patch 三段（不含 build）。
int compareMainVersion(AppVersion a, AppVersion b) {
  for (final pair in [
    (a.major, b.major),
    (a.minor, b.minor),
    (a.patch, b.patch),
  ]) {
    if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
  }
  return 0;
}

/// 判定本地是否需要按远端更新。
/// build 语义：仅当远端显式带 `+build`（buildSet）时才参与 build 比较；
/// 远端无 build（如 GitHub tag v3.0.0）时主版本相等即视为「不提示」——本地热修 build 不会误判为降级。
UpdateVerdict verdictFor({required AppVersion local, required AppVersion remote}) {
  final c = compareMainVersion(local, remote);
  if (c != 0) return c < 0 ? UpdateVerdict.updateAvailable : UpdateVerdict.remoteOlder;
  // 主版本相等：远端未显式带 build → 不提示；都带 build → 按 build 判
  if (!remote.buildSet) return UpdateVerdict.upToDate;
  if (remote.build > local.build) return UpdateVerdict.updateAvailable;
  if (remote.build < local.build) return UpdateVerdict.remoteOlder;
  return UpdateVerdict.upToDate;
}

/// 更新候选：App 展示与下载所需的最小集合。
@immutable
class UpdateCandidate {
  final String version; // 展示用版本串（含 build，如 3.0.0+8）
  final String downloadUrl;
  final int? sizeBytes;
  final String? sha256;
  final String? notes;
  final String source; // 展示用来源名：GitHub / 主机
  const UpdateCandidate({
    required this.version,
    required this.downloadUrl,
    this.sizeBytes,
    this.sha256,
    this.notes,
    required this.source,
  });
}

/// GitHub APK 资产名前缀（spec：取 assets 中第一个名形如 `DSH-Remote-*.apk` 的条目）。
const String githubApkPrefix = 'DSH-Remote-';

/// 主机源 API base：baseUrl + 插件挂载路径（与 api._uri 同规则：空/`/` 回退 `/m`，去尾斜杠）。
/// 检查与下载必须用同一 base——挂载路径非默认 `/m` 时硬编码会 404。
String hostApiBase({required String baseUrl, required String mountPath}) {
  var base = baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  var m = mountPath.trim();
  if (m.isEmpty || m == '/') m = '/m';
  while (m.length > 1 && m.endsWith('/')) {
    m = m.substring(0, m.length - 1);
  }
  return '$base$m';
}

/// GitHub release 资产里挑 APK：形如 `DSH-Remote-*.apk`。返回 null = 无 APK 资产。
Map<String, dynamic>? pickGithubApkAsset(List<dynamic>? assets) {
  if (assets == null) return null;
  for (final a in assets) {
    if (a is! Map) continue;
    final name = a['name'] as String? ?? '';
    if (name.startsWith(githubApkPrefix) && name.endsWith('.apk')) {
      return Map<String, dynamic>.from(a);
    }
  }
  return null;
}

/// 从 GitHub `releases/latest` 响应构建候选（tag 版本无 build；asset 无 sha256/notes）。
UpdateCandidate? candidateFromGithubRelease(Map<String, dynamic> release) {
  final tag = release['tag_name'] as String? ?? '';
  final version = parseAppVersion(tag);
  if (version == null) return null;
  final asset = pickGithubApkAsset(release['assets'] as List?);
  if (asset == null) return null;
  final url = asset['browser_download_url'] as String? ?? '';
  final parsedUrl = Uri.tryParse(url);
  if (parsedUrl == null || parsedUrl.scheme != 'https' || parsedUrl.host.isEmpty) return null;
  return UpdateCandidate(
    version: version.toString(),
    downloadUrl: url,
    sizeBytes: (asset['size'] as num?)?.toInt(),
    source: 'GitHub',
  );
}

/// 从主机源 manifest 构建候选（baseUrl 如 `http://<host>:3080/m`；下载走插件 /api/update/apk）。
UpdateCandidate? candidateFromHostManifest(Map<String, dynamic> manifest,
    {required String baseUrl}) {
  final version = manifest['version'] as String? ?? '';
  final apk = manifest['apk'] as String? ?? '';
  final digest = manifest['sha256'] as String? ?? '';
  if (parseAppVersion(version) == null || apk.isEmpty || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) return null;
  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return UpdateCandidate(
    version: version,
    downloadUrl: '$base/api/update/apk',
    sizeBytes: (manifest['size'] as num?)?.toInt(),
    sha256: digest,
    notes: manifest['notes'] as String?,
    source: '主机',
  );
}