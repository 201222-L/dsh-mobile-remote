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
import 'package:flutter/services.dart';

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
    this.initialRelativePath,
  }) : _api = apiClient ?? api;

  final AppStore store;

  /// 本页绑定的会话；浏览根由它的工作目录决定。
  final String sessionId;

  /// issue #67：从工具卡路径进入时的初始 cwd 相对路径（可空）。
  ///
  /// `open()` 在解析出会话工作目录后消费它：先过客户端词法校验与 `isWithinRoot`，
  /// 再把 `currentPath` 设为该文件的**父目录**并复用 [openFile] 的预览链路。
  /// 不构造任意绝对路径、不新增端点；非法值 fail-closed（零请求）。
  final String? initialRelativePath;

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
    return [(label: _rootLabel(), path: root), ...all.sublist(rootIdx + 1)];
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
    // issue #67：从工具卡深链进入时直接定位到文件预览，不先列 root（少一次请求）；
    // 非法 relative 由 _openResolvedRelative fail-closed（零请求）。
    final initial = initialRelativePath;
    if (initial != null && initial.isNotEmpty) {
      await _openResolvedRelative(initial);
      return;
    }
    await loadDir(cwd);
  }

  /// issue #67：按 **cwd 相对路径**直接打开文件预览（工具卡点击入口）。
  ///
  /// 这是 App 侧的唯一拼接点：路径必须通过 [resolveSessionRelativePath]（词法校验 +
  /// `isWithinRoot` 兜底）。非法值不发任何请求。
  ///
  /// reviewer P2：**显式传入的 [relative] 优先**。root 尚未解析时先走 [open] 补齐
  /// root（[open] 可能消费构造时的 [initialRelativePath]），完成后再用本次参数打开；
  /// 不能在 root 为空的分支里丢掉参数直接 `return`（那样会打开构造参数或什么都不开）。
  Future<void> openRelativeFile(String relative) async {
    // 先做纯词法校验：非法值在发任何请求（包括 open() 的根目录列举）之前 fail-closed。
    if (normalizeSessionRelativePath(relative) == null) {
      stage = BrowseStage.error;
      errorReason = '无法打开文件：路径不在会话工作目录内';
      notifyListeners();
      return;
    }
    if (root.isEmpty) {
      await open();
      // open() 失败（无 cwd）已置错误态；root 仍为空时无法拼接，直接返回。
      if (root.isEmpty) return;
    }
    await _openResolvedRelative(relative);
  }

  /// 已解析 root 后的相对路径预览：父目录 → `/files`（preview 路径的父目录必须成为
  /// `currentPath`，否则 [refresh] 用 `currentPath + basename` 重取会取错嵌套文件）。
  Future<void> _openResolvedRelative(String relative) async {
    final pathSep = _inferredSep();
    final path = resolveSessionRelativePath(root, relative, sep: pathSep);
    if (path == null) {
      stage = BrowseStage.error;
      errorReason = '无法打开文件：路径不在会话工作目录内';
      notifyListeners();
      return;
    }
    sep = pathSep;
    final parent = parentBrowsePath(path, sep);
    await loadDir(isWithinRoot(root, parent) ? parent : root);
    // 目录加载失败时不发 /files（避免在错误页上再做一次无意义的文件请求）。
    if (stage == BrowseStage.listing) {
      await openFile(_basename(path));
    }
  }

  /// 首列目录前 `sep` 还是默认 `/`；root 是 Windows 形状时按既有启发式推断（对齐 loadDir）。
  String _inferredSep() {
    if (sep == '/' && root.contains('\\') && !root.contains('/')) return '\\';
    return sep;
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
      // 设置只影响会话文件浏览；目录选择器仍用默认（不显示隐藏条目）。
      final listing = await _api.directories(
        path,
        includeHidden: store.showHiddenFiles,
      );
      // 服务端只在「根视图」响应里带 sep，普通目录响应没有这个字段，
      // 因此不能靠它判断分隔符（目录选择器的 dirSepOf 也是同样思路）。
      if (listing.sep != null && listing.sep!.isNotEmpty) {
        sep = listing.sep!;
      } else if (sep == '/' && path.contains('\\')) {
        sep = '\\';
      }
      // 即使宿主返回 `.git`（旧 host / 第三方实现），客户端也绝不展示。
      final limited = limitDirEntries(
        withoutGitEntries(listing.dirs),
        withoutGitEntries(listing.files),
      );
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
  Future<void> openDir(String name) =>
      loadDir(joinBrowsePath(currentPath, name, sep));

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
    // 先发布 previewPath：加载态也要能显示 in-content 返回按钮与历史入口。
    previewPath = path;
    notifyListeners();
    try {
      final prefix = await _api.downloadFilePrefix(path, kPreviewByteLimit);
      final bytes = prefix.bytes;
      final encoding = detectPreviewEncoding(bytes);
      if (encoding == PreviewEncoding.gb18030) {
        try {
          final text = await _filesChannel.invokeMethod<String>('decodeText', {
            'bytes': bytes,
            'charset': 'GB18030',
          });
          if (text == null) throw StateError('empty decode result');
          preview = PreviewText(
            text: text,
            truncated: prefix.truncated,
            bytesShown: bytes.length,
            encodingLabel: previewEncodingLabel(PreviewEncoding.gb18030),
          );
        } catch (_) {
          preview = const PreviewUnavailable('GB18030 文件：系统解码失败');
        }
      } else {
        preview = buildPreview(
          bytes,
          encoding: encoding,
          truncated: prefix.truncated,
        );
      }
      previewPath = path;
      lastLoadedAt = DateTime.now();
      stage = BrowseStage.preview;
    } catch (e) {
      stage = BrowseStage.error;
      errorReason = '无法读取文件：${_short(e)}';
    }
    notifyListeners();
  }

  static const MethodChannel _filesChannel = MethodChannel('dsh/files');

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
