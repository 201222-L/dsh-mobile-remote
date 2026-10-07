// 会话文件浏览的页面状态机。
//
// 职责：把「当前会话的工作目录 + 当前目录 + 目录内容 / 文件预览」组织成 UI
// 可渲染的状态，并把所有外部交互（列目录、取文件）收在这里，便于用假 Api 做
// widget 测试。
//
// 作用域（见 ADR 0015）：浏览根 = **当前会话的工作目录**，与对话操作栏里的
// Git 导航同源。它不读也不写全局「当前选中工作区」——那是首页会话列表的筛选
// 状态，与本能力无关。
//
// 边界：只读；路径夹在会话工作目录内；不做写操作。

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'session_files_logic.dart';
import 'store.dart';

/// 页面阶段。
enum BrowseStage {
  /// 正在加载目录或文件。
  loading,

  /// 显示目录内容。
  listing,

  /// 显示文件内容预览。
  preview,

  /// 无法浏览（拿不到会话工作目录，或读取失败）。
  error,
}

class SessionFilesController extends ChangeNotifier {
  /// [apiClient] 只为测试注入；生产必须走全局 [api] 单例（与 chat_screen 的
  /// `_api` 同一约定）。
  ///
  /// 不能写 `apiClient ?? Api()`：`Api` 的 `baseUrl` 默认是空串，要由启动流程从
  /// SharedPreferences 载入。新建实例会得到没有 host 的 URL，请求直接抛
  /// 「no host specified in url」——真机上表现为「无法读取目录」。
  SessionFilesController({
    required this.store,
    required this.sessionId,
    Api? apiClient,
  }) : _api = apiClient ?? api;

  final AppStore store;

  /// 本页绑定的会话；浏览根由它的工作目录决定。
  final String sessionId;

  final Api _api;

  BrowseStage stage = BrowseStage.loading;

  /// 浏览根（会话工作目录），确定后不再变化。
  String root = '';

  /// 当前目录绝对路径；等于 root 时表示在根。
  String currentPath = '';

  /// 服务端路径分隔符，首次列举后确定。
  String sep = '/';

  /// 最近一次成功列举的目录内容（用于刷新失败时保留旧内容）。
  List<String> dirs = const [];
  List<String> files = const [];

  /// 因渲染上限被隐藏的条目数（0 表示全部展示）。
  int hiddenCount = 0;

  /// 目录条目总数。
  int totalEntries = 0;

  /// 预览中的文件。
  String previewPath = '';
  PreviewVerdict? preview;

  /// 错误原因；`stage == BrowseStage.error` 时有效。
  String errorReason = '';

  /// 最近一次成功取数的时间（刷新失败时 UI 用它标注陈旧）。
  DateTime? lastLoadedAt;

  /// 面包屑（从会话工作目录开始，不越出）。
  List<({String label, String path})> get breadcrumbs {
    final all = browseBreadcrumbs(currentPath, sep);
    // 裁掉根之前的部分：面包屑第一项固定是会话工作目录。
    final rootIdx = all.indexWhere((c) => _samePath(c.path, root));
    if (rootIdx < 0) {
      // 根路径与切分结果不完全一致时，退化为「根 + 相对段」
      final rel = _relativeToRoot(currentPath);
      final crumbs = <({String label, String path})>[
        (label: _rootLabel(), path: root),
      ];
      if (rel.isNotEmpty) {
        var acc = root;
        for (final part in rel.split(sep).where((e) => e.isNotEmpty)) {
          acc = joinBrowsePath(acc, part, sep);
          crumbs.add((label: part, path: acc));
        }
      }
      return crumbs;
    }
    return [
      (label: _rootLabel(), path: root),
      ...all.sublist(rootIdx + 1),
    ];
  }

  /// 是否位于浏览根（不允许再向上）。
  bool get atRoot => _samePath(currentPath, root);

  /// 打开页面：解析本会话的工作目录并加载。
  ///
  /// 拿不到工作目录就不浏览——不退回全局选中工作区，也不让用户在这里挑一个；
  /// 那会与「看当前会话的文件」这个语义分叉（见 ADR 0015）。
  Future<void> open() async {
    var cwd = _sessionCwd();
    if (cwd == null || cwd.isEmpty) {
      // 会话列表可能尚未拉取（冷启动直达会话页）：补拉一次再判断。
      await store.refreshSessions(notify: false);
      cwd = _sessionCwd();
    }
    if (cwd == null || cwd.isEmpty) {
      stage = BrowseStage.error;
      errorReason = '这个会话没有工作目录，无法浏览文件';
      notifyListeners();
      return;
    }
    root = cwd;
    currentPath = cwd;
    await loadDir(cwd);
  }

  /// 加载某个目录。
  Future<void> loadDir(String path) async {
    // 夹在浏览根内：越界的请求直接拒绝，不发给服务端。
    if (root.isNotEmpty && !isWithinRoot(root, path)) {
      stage = BrowseStage.error;
      errorReason = '已到达会话工作目录，无法向上浏览';
      notifyListeners();
      return;
    }
    stage = BrowseStage.loading;
    notifyListeners();
    try {
      final listing = await _api.directories(path);
      // 服务端只在「根视图」响应里带 sep，普通目录响应没有这个字段，
      // 因此不能靠它判断分隔符（目录选择器的 dirSepOf 也是同样思路）。
      if (listing.sep != null && listing.sep!.isNotEmpty) {
        sep = listing.sep!;
      } else if (sep == '/' && path.contains('\\')) {
        sep = '\\';
      }
      final limited = limitDirEntries(listing.dirs, listing.files);
      dirs = limited.dirs;
      files = limited.files;
      hiddenCount = limited.hiddenCount;
      totalEntries = limited.total;
      currentPath = path;
      preview = null;
      previewPath = '';
      lastLoadedAt = DateTime.now();
      stage = BrowseStage.listing;
    } catch (e) {
      // 保留旧内容：只改阶段与原因，不清空 dirs/files。
      stage = BrowseStage.error;
      errorReason = '无法读取目录：${_short(e)}';
    }
    notifyListeners();
  }

  /// 进入子目录。
  Future<void> openDir(String name) => loadDir(joinBrowsePath(currentPath, name, sep));

  /// 返回上一级；已在根则不动。
  Future<void> goUp() async {
    if (atRoot) return;
    final parent = parentBrowsePath(currentPath, sep);
    await loadDir(isWithinRoot(root, parent) ? parent : root);
  }

  /// 跳到面包屑上的某一级。
  Future<void> jumpTo(String path) => loadDir(path);

  /// 打开文件预览。
  Future<void> openFile(String name) async {
    final path = joinBrowsePath(currentPath, name, sep);
    stage = BrowseStage.loading;
    notifyListeners();
    try {
      final bytes = await _api.downloadFile(path);
      preview = buildPreview(bytes);
      previewPath = path;
      lastLoadedAt = DateTime.now();
      stage = BrowseStage.preview;
    } catch (e) {
      stage = BrowseStage.error;
      errorReason = '无法读取文件：${_short(e)}';
    }
    notifyListeners();
  }

  /// 从预览返回所在目录。
  Future<void> closePreview() async {
    preview = null;
    previewPath = '';
    await loadDir(currentPath);
  }

  /// 显式刷新当前视图（目录或预览）。
  Future<void> refresh() async {
    if (stage == BrowseStage.preview && previewPath.isNotEmpty) {
      final dir = currentPath;
      await openFile(_basename(previewPath));
      currentPath = dir;
      return;
    }
    await loadDir(currentPath);
  }

  /// 重试：清掉错误后重新解析根并加载。
  Future<void> retry() async {
    if (root.isEmpty) {
      await open();
      return;
    }
    await loadDir(currentPath.isEmpty ? root : currentPath);
  }

  /// 本会话的工作目录；会话不在列表里时为 null。
  String? _sessionCwd() {
    for (final Session s in store.sessions) {
      if (s.id == sessionId) return s.cwd;
    }
    return null;
  }

  bool _samePath(String a, String b) =>
      a == b || AppStore.normPath(a) == AppStore.normPath(b);

  String _relativeToRoot(String path) {
    if (!isWithinRoot(root, path) || _samePath(root, path)) return '';
    var rel = path.substring(root.length);
    while (rel.startsWith(sep)) {
      rel = rel.substring(sep.length);
    }
    return rel;
  }

  String _rootLabel() {
    final n = _basename(root);
    return n.isEmpty ? root : n;
  }

  String _basename(String path) {
    final parts = path.split(sep).where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }

  /// 错误信息只保留简短原因，不把服务端长文本铺到 UI 上。
  String _short(Object e) {
    final s = e.toString();
    return s.length <= 160 ? s : '${s.substring(0, 160)}…';
  }
}
