// 文件提交历史（issue #42）的共享状态机。
//
// 一个实例服务两种 surface：
// - Git 管理里的「文件历史」tab；
// - 未启用该 tab 时从文件查看器深链打开的独立历史视图（同一 controller/body）。
//
// 职责：选文件、取分页历史、文件选择器的服务端搜索（250ms 防抖）与
// 最近使用文件（按仓库持久化，最多 5 个）、空态/错误态判定。
// 不持有任何 Widget；UI 只通过 [GitFileHistoryBody] 渲染。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'git_models.dart';

/// 文件历史控制器：历史分页 + 文件选择器。
class GitFileHistoryController extends ChangeNotifier {
  GitFileHistoryController({
    required this.api,
    required this.sessionId,
    required this.repositoryId,
    this.pageSize = 20,
    this.pickerLimit = 200,
    this.debounce = const Duration(milliseconds: 250),
    this.repositoryEmpty = false,
  });

  /// 最近使用文件的上限（按仓库持久化）。
  static const int recentFilesLimit = 5;

  /// 最近使用文件的 SharedPreferences 键（按 repositoryId 隔离）。
  static String recentFilesKey(String repositoryId) =>
      'dsh_mr_git_recent_files_$repositoryId';

  final GitReadApi api;
  final String sessionId;
  final String repositoryId;
  final int pageSize;
  final int pickerLimit;
  final Duration debounce;

  /// 仓库是否为空（无提交）：用于「仓库还没有提交」空态文案。
  final bool repositoryEmpty;

  // ── 历史 ──
  String? selectedPath;
  List<GitFileHistoryEntry> entries = const [];
  String? nextCursor;

  /// 宿主因 5000 条 / 20 秒软上限只返回了部分记录。
  bool truncated = false;

  /// 空/异常原因：not-tracked | no-history | path-invalid（宿主 200 响应）。
  String? reason;
  bool loadingHistory = false;
  bool loadingMore = false;
  String? historyError;

  // ── 文件选择器 ──
  bool pickerOpen = false;
  String pickerQuery = '';
  List<String> files = const [];
  List<String> recentFiles = const [];
  bool loadingFiles = false;
  String? filesError;
  bool filesTruncated = false;

  bool _initialized = false;
  bool _historyRequested = false;
  bool _autoOpenedPicker = false;
  bool _disposed = false;
  int _historyGeneration = 0;
  int _filesGeneration = 0;
  Timer? _pickerDebounce;
  SharedPreferences? _prefs;

  bool get hasFile => (selectedPath ?? '').isNotEmpty;
  bool get isUntracked => reason == 'not-tracked';
  bool get isPathInvalid => reason == 'path-invalid';
  bool get isEmptyRepository => repositoryEmpty;

  /// 首次挂载：恢复最近文件；无预填路径时自动打开一次选择器。
  Future<void> initialize({bool autoOpenPickerWhenEmpty = true}) async {
    if (_initialized || _disposed) return;
    _initialized = true;
    await _loadRecentFiles();
    if (_disposed) return;
    if (hasFile) {
      if (!_historyRequested) {
        _historyRequested = true;
        unawaited(_loadFirstPage());
      }
      return;
    }
    if (autoOpenPickerWhenEmpty && !_autoOpenedPicker) {
      _autoOpenedPicker = true;
      openPicker();
    }
    _notify();
  }

  /// 选择文件并加载第一页历史（深链与手动选择共用）。
  Future<void> selectFile(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty || _disposed) return;
    selectedPath = normalized;
    pickerOpen = false;
    pickerQuery = '';
    _pickerDebounce?.cancel();
    _historyRequested = true;
    _historyGeneration++;
    entries = const [];
    nextCursor = null;
    truncated = false;
    reason = null;
    historyError = null;
    loadingHistory = true;
    loadingMore = false;
    _rememberRecent(normalized);
    _notify();
    await _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    final path = selectedPath;
    if (path == null || _disposed) return;
    final generation = ++_historyGeneration;
    loadingHistory = true;
    // 刷新/重选文件会作废 in-flight loadMore：先收起旧 footer spinner。
    loadingMore = false;
    historyError = null;
    _notify();
    try {
      final page = await api.fileHistory(
        sessionId,
        repositoryId,
        path: path,
        limit: pageSize,
      );
      if (generation != _historyGeneration || _disposed) return;
      entries = page.entries;
      nextCursor = page.nextCursor;
      truncated = page.truncated;
      reason = page.reason;
    } catch (error) {
      if (generation != _historyGeneration || _disposed) return;
      historyError = _short(error);
    }
    loadingHistory = false;
    _notify();
  }

  /// 下拉/触底加载下一页。
  Future<void> loadMore() async {
    final cursor = nextCursor;
    final path = selectedPath;
    if (cursor == null ||
        path == null ||
        loadingHistory ||
        loadingMore ||
        _disposed) {
      return;
    }
    final generation = _historyGeneration;
    loadingMore = true;
    _notify();
    try {
      final page = await api.fileHistory(
        sessionId,
        repositoryId,
        path: path,
        cursor: cursor,
        limit: pageSize,
      );
      if (generation != _historyGeneration) {
        loadingMore = false;
        return;
      }
      if (_disposed) return;
      final seen = entries.map((entry) => entry.oid).toSet();
      entries = List.unmodifiable([
        ...entries,
        for (final entry in page.entries)
          if (seen.add(entry.oid)) entry,
      ]);
      nextCursor = page.nextCursor;
      truncated = truncated || page.truncated;
    } catch (error) {
      if (generation != _historyGeneration) {
        loadingMore = false;
        return;
      }
      if (_disposed) return;
      historyError = _short(error);
    }
    loadingMore = false;
    _notify();
  }

  /// 显式刷新：已选文件则重取第一页，否则重取文件列表。
  Future<void> refresh() async {
    if (hasFile) {
      _historyGeneration++;
      await _loadFirstPage();
      return;
    }
    await _loadFiles(query: pickerQuery);
  }

  /// 错误态重试。
  Future<void> retry() async {
    if (historyError != null || hasFile) {
      await refresh();
      return;
    }
    await _loadFiles(query: pickerQuery);
  }

  /// 打开文件选择器（自动打开与用户点击共用；自动只发生一次）。
  ///
  /// 重新打开时清空上次搜索词：否则输入框已清空、结果却仍是旧过滤结果。
  void openPicker() {
    if (pickerOpen || _disposed) return;
    pickerOpen = true;
    pickerQuery = '';
    filesError = null;
    _notify();
    unawaited(_loadFiles(query: pickerQuery));
  }

  /// 关闭文件选择器（取消后本次 surface 不再自动打开）。
  void closePicker() {
    if (!pickerOpen) return;
    _pickerDebounce?.cancel();
    pickerOpen = false;
    _notify();
  }

  /// 服务端搜索输入（250ms 防抖）。
  void setPickerQuery(String value) {
    pickerQuery = value;
    _pickerDebounce?.cancel();
    _notify();
    if (!pickerOpen) return;
    _pickerDebounce = Timer(debounce, () {
      if (!_disposed && pickerOpen) unawaited(_loadFiles(query: pickerQuery));
    });
  }

  Future<void> _loadFiles({required String query}) async {
    final generation = ++_filesGeneration;
    loadingFiles = true;
    filesError = null;
    _notify();
    try {
      final trimmed = query.trim();
      final result = await api.files(
        sessionId,
        repositoryId,
        q: trimmed.isEmpty ? null : trimmed,
        limit: pickerLimit,
      );
      if (generation != _filesGeneration || _disposed) return;
      files = result.files;
      filesTruncated = result.truncated;
    } catch (error) {
      if (generation != _filesGeneration || _disposed) return;
      filesError = _short(error);
    }
    loadingFiles = false;
    _notify();
  }

  Future<void> _loadRecentFiles() async {
    List<String> saved = const [];
    try {
      _prefs = await SharedPreferences.getInstance();
      saved =
          _prefs?.getStringList(recentFilesKey(repositoryId)) ??
          const <String>[];
    } catch (_) {
      saved = const [];
    }
    // 深链可能在 initialize 之前就 selectFile，合并而不是覆盖。
    final merged = <String>[
      ...recentFiles,
      for (final path in saved)
        if (path.isNotEmpty && !recentFiles.contains(path)) path,
    ];
    if (merged.length > recentFilesLimit) {
      merged.removeRange(recentFilesLimit, merged.length);
    }
    recentFiles = List.unmodifiable(merged);
    // 预填文件可能先于 prefs 读取被记入内存：合并后回写，重建控制器仍能读到。
    final prefs = _prefs;
    if (prefs != null && !_samePaths(merged, saved)) {
      unawaited(prefs.setStringList(recentFilesKey(repositoryId), recentFiles));
    }
    _notify();
  }

  bool _samePaths(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _rememberRecent(String path) {
    final merged = <String>[
      path,
      for (final item in recentFiles)
        if (item != path) item,
    ];
    if (merged.length > recentFilesLimit) {
      merged.removeRange(recentFilesLimit, merged.length);
    }
    recentFiles = List.unmodifiable(merged);
    final prefs = _prefs;
    if (prefs != null) {
      unawaited(prefs.setStringList(recentFilesKey(repositoryId), recentFiles));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _short(Object error) {
    final text = error.toString();
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }

  @override
  void dispose() {
    _disposed = true;
    _historyGeneration++;
    _filesGeneration++;
    _pickerDebounce?.cancel();
    super.dispose();
  }
}
