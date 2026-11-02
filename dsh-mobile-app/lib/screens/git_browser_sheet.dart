import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../git_browser_controller.dart';
import '../git_file_history_controller.dart';
import '../git_graph_logic.dart';
import '../git_graph_presentation.dart';
import '../git_models.dart';
import '../l10n.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets/git_file_history_body.dart';
import '../widgets/git_file_viewer.dart';
import '../widgets/git_logo.dart';
import 'session_files_screen.dart';

/// Full-screen, read-only Git browser route.
class GitBrowserSheet extends StatefulWidget {
  const GitBrowserSheet({
    super.key,
    required this.controller,
    required this.scrollController,
    this.tabs = const ['branches', 'graph', 'worktree'],
    this.initialFileHistoryPath,
    this.store,
    this.fileBrowserPicker,
  });

  final GitBrowserController controller;
  final ScrollController scrollController;
  final List<String> tabs;

  /// 应用状态（会话工作目录等）：文件历史的「选择文件」需要它打开会话文件浏览器。
  final AppStore? store;

  /// 测试注入的浏览器选择器：返回选中的文件绝对路径（null = 取消）。
  ///
  /// 生产默认用 [SessionFilesScreen]（selectionMode）实现；注入后不创建路由，
  /// 便于 widget 测试验证“选择后回到原历史视图”。
  final Future<String?> Function(BuildContext context, String sessionId)?
  fileBrowserPicker;

  /// 打开即深链到该文件的提交历史（issue #42）。
  ///
  /// 若 history tab 已启用则切到该 tab；否则显示无 TabBar 的独立历史视图，
  /// 返回时恢复进入前的视图（从会话文件页进入时直接返回原页面）。
  final String? initialFileHistoryPath;

  @override
  State<GitBrowserSheet> createState() => _GitBrowserSheetState();
}

enum _View { tab, commit, preview, history }

/// 图行固定高度：标签全部单行展示，行高不再随标签数量变化。
const double kGitGraphRowHeight = 86;

class _GitBrowserSheetState extends State<GitBrowserSheet>
    with TickerProviderStateMixin {
  _View _view = _View.tab;
  bool _temporaryGraph = false;

  /// 预览返回目标：worktree 预览→tab，提交详情文件→commit，历史行→历史 surface。
  _View _previewReturnView = _View.tab;
  String _previewKind = 'unstaged';
  String _previewPath = '';
  String? _previewOid;
  bool _choosingBranches = false;
  String _graphQuery = '';
  String? _openingOid;

  /// 文件提交历史：tab 与独立历史视图共用同一个 controller/body。
  GitFileHistoryController? _history;
  String? _historySessionId;
  String? _historyRepositoryId;
  String? _pendingHistoryPath;
  bool _historyLinkHandled = false;
  int _lastTabIndex = 0;
  late final TabController _tabs;
  final ScrollController _branchScroll = ScrollController();
  final ScrollController _worktreeScroll = ScrollController();
  final ScrollController _commitScroll = ScrollController();
  final ScrollController _horizontal = ScrollController();
  Timer? _freshnessTimer;
  bool _defaultGraphRequested = false;

  /// 图行标签缓存：标签只在图数据变化时计算/测量一次（TextPainter 是 O(标签数)）。
  final Map<String, List<GitGraphLabel>> _rowLabels = {};
  List<String> _labelOids = const [];
  double _labelLineWidth = 0;
  String? _labelSnapshot;
  String? _labelTips;
  TextStyle? _labelStyle;
  TextScaler? _labelTextScaler;
  GraphLayout? _layout;
  String? _layoutSnapshot;
  String? _layoutTips;
  List<String> _laidOutOids = const [];

  GraphLayout _graphLayout(GitBrowserState state) {
    final tips = state.selectedBranches
        .map((branch) => '${branch.name}\u0000${branch.oid}')
        .join('\u0001');
    final commits = state.commits;
    final append =
        _layout != null &&
        _layoutSnapshot == state.snapshotId &&
        _layoutTips == tips &&
        commits.length >= _laidOutOids.length &&
        List.generate(
          _laidOutOids.length,
          (index) => commits[index].oid == _laidOutOids[index],
        ).every((same) => same);
    _syncGraphLabels(state, rebuild: !append);
    if (!append) {
      _layout = layoutGraph(commits, state.selectedBranches);
    } else if (commits.length > _laidOutOids.length) {
      final tail = layoutGraph(
        commits.sublist(_laidOutOids.length),
        state.selectedBranches,
        state: _layout!.continuation,
      );
      _layout = GraphLayout(
        List.unmodifiable([..._layout!.rows, ...tail.rows]),
        tail.laneCount,
        tail.continuation,
      );
    }
    _layoutSnapshot = state.snapshotId;
    _layoutTips = tips;
    _laidOutOids = [for (final commit in commits) commit.oid];
    return _layout!;
  }

  /// 依据图数据增量刷新标签缓存（[rebuild] 为 true 时整体重算）。
  ///
  /// 排序/归一/去重全部由 [gitGraphLabels] 统一处理；这里只做缓存与宽度测量：
  /// 每行标签共用图的横向滚动轴，需要提前知道"最宽一行"才能确定滚动范围。
  void _syncGraphLabels(GitBrowserState state, {required bool rebuild}) {
    final style = Theme.of(context).textTheme.labelSmall;
    final textScaler = MediaQuery.textScalerOf(context);
    final tips = state.selectedBranches
        .map((branch) => '${branch.name}\u0000${branch.oid}')
        .join('\u0001');
    // 字号或系统文字缩放变化都会改变标签宽度，必须重算横向滚动范围。
    if (style != _labelStyle || textScaler != _labelTextScaler) {
      _labelStyle = style;
      _labelTextScaler = textScaler;
      rebuild = true;
    }
    if (rebuild ||
        state.snapshotId != _labelSnapshot ||
        tips != _labelTips ||
        _labelOids.length > state.commits.length) {
      _rowLabels.clear();
      _labelOids = const [];
      _labelLineWidth = 0;
      _labelSnapshot = state.snapshotId;
      _labelTips = tips;
    }
    if (_labelOids.length == state.commits.length) return;
    for (final commit in state.commits.skip(_labelOids.length)) {
      final labels = gitGraphLabels(commit.resolvedDecoration);
      _rowLabels[commit.oid] = labels;
      final width = _measureLabelLine(labels, style, textScaler);
      if (width > _labelLineWidth) _labelLineWidth = width;
    }
    _labelOids = [for (final commit in state.commits) commit.oid];
  }

  /// 一行全部标签的像素宽度（pill 内边距 6*2 + 右边距 5 + 边框 1*2）。
  ///
  /// 宽度宁大勿小：这里算出的滚动范围要保证全部标签单行、不被裁切。
  double _measureLabelLine(
    List<GitGraphLabel> labels,
    TextStyle? style,
    TextScaler textScaler,
  ) {
    var width = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label.text, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      width += painter.width + 19;
    }
    return width;
  }

  List<String> get _tabIds => widget.tabs.isEmpty
      ? const ['branches', 'graph', 'worktree']
      : widget.tabs;

  String get _activeTab => _temporaryGraph ? 'graph' : _tabIds[_tabs.index];

  int get _graphTabIndex => _tabIds.indexOf('graph');

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabIds.length, vsync: this);
    _lastTabIndex = _tabs.index;
    _tabs.addListener(_onTabControllerChanged);
    _pendingHistoryPath = widget.initialFileHistoryPath;
    widget.scrollController.addListener(_onGraphScroll);
    _commitScroll.addListener(_onCommitScroll);
    widget.controller.addListener(_onState);
    _freshnessTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      widget.controller.checkWorktreeFreshness();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeHandleHistoryDeepLink();
      _maybeOpenDefaultGraph();
      if (mounted && _tabIds.first == 'worktree') {
        widget.controller.loadWorktree();
      }
    });
  }

  @override
  void didUpdateWidget(GitBrowserSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onGraphScroll);
      widget.scrollController.addListener(_onGraphScroll);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onState);
      widget.controller.addListener(_onState);
      _layout = null;
      _laidOutOids = const [];
      _history?.dispose();
      _history = null;
      _historySessionId = null;
      _historyRepositoryId = null;
    }
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    widget.scrollController.removeListener(_onGraphScroll);
    _commitScroll.removeListener(_onCommitScroll);
    widget.controller.removeListener(_onState);
    _tabs.removeListener(_onTabControllerChanged);
    _tabs.dispose();
    _history?.dispose();
    _branchScroll.dispose();
    _worktreeScroll.dispose();
    _commitScroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    final state = widget.controller.state;
    if (_activeTab == 'worktree' &&
        state.repository != null &&
        state.worktree == null &&
        !state.loadingWorktree &&
        state.worktreeError == null) {
      widget.controller.loadWorktree();
    }
    setState(() {});
    _maybeHandleHistoryDeepLink();
    _maybeOpenDefaultGraph();
    // A short first page may not generate a scroll event at all.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onScroll(
        widget.controller.state.commit != null && _view == _View.commit
            ? _commitScroll
            : widget.scrollController,
      );
    });
  }

  void _onTabControllerChanged() {
    // TabController 在切换动画期间会多次通知；只在 index 真正变化时重建。
    if (!mounted || _tabs.index == _lastTabIndex) return;
    _lastTabIndex = _tabs.index;
    setState(() {});
  }

  void _onGraphScroll() => _onScroll(widget.scrollController);
  void _onCommitScroll() => _onScroll(_commitScroll);

  void _onScroll(ScrollController source) {
    if (!mounted || !source.hasClients) return;
    final state = widget.controller.state;
    if (state.stale || state.loading || state.error != null) return;
    if ((_view == _View.tab && _activeTab == 'graph' || _temporaryGraph) &&
        identical(source, widget.scrollController) &&
        state.graphNextCursor != null &&
        !state.loadingGraphPage &&
        source.position.extentAfter <= 240) {
      widget.controller.loadNextGraphPage();
    } else if (_view == _View.commit &&
        identical(source, _commitScroll) &&
        state.commit?.filesNextCursor != null &&
        !state.loadingFilesPage &&
        source.position.extentAfter <= 240) {
      widget.controller.loadNextFilesPage();
    }
  }

  void _maybeOpenDefaultGraph() {
    if (!mounted || _defaultGraphRequested || _activeTab != 'graph') return;
    // 带文件历史深链打开时不要抢先打开默认分支图；深链处理完后
    // 用户再切到图谱 tab 仍应正常打开默认分支。
    if (_pendingHistoryPath != null && !_historyLinkHandled) return;
    if (_view == _View.history || _activeTab == 'fileHistory') return;
    final state = widget.controller.state;
    if (state.loading ||
        state.loadingGraph ||
        state.repository == null ||
        state.selectedBranches.isEmpty ||
        state.snapshotId != null ||
        state.capabilities?.available != true) {
      return;
    }
    _defaultGraphRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.openBranch(state.selectedBranches.first);
    });
  }

  void _selectTab(int index) {
    if (index < 0 || index >= _tabIds.length) return;
    setState(() => _temporaryGraph = false);
    final id = _tabIds[index];
    if (id == 'graph') _maybeOpenDefaultGraph();
    if (id == 'worktree') {
      if (widget.controller.state.worktree == null) {
        widget.controller.loadWorktree();
      } else if (!widget.controller.state.worktreeStale) {
        widget.controller.checkWorktreeFreshness();
      }
    }
  }

  void _showGraph(GitBranch branch) {
    setState(() {
      _view = _View.tab;
      _temporaryGraph = _graphTabIndex < 0;
      _choosingBranches = false;
      _graphQuery = '';
      if (_graphTabIndex >= 0) _tabs.animateTo(_graphTabIndex);
    });
    _defaultGraphRequested = true;
    widget.controller.openBranch(branch);
  }

  Future<void> _showCommit(String oid) async {
    setState(() => _openingOid = oid);
    await widget.controller.openCommit(oid);
    if (!mounted || _openingOid != oid) return;
    setState(() {
      _openingOid = null;
      if (widget.controller.state.commit?.oid == oid) _view = _View.commit;
    });
  }

  Future<void> _showPreview({
    required String kind,
    required String path,
    String? oid,
    required _View returnTo,
  }) async {
    setState(() {
      _previewReturnView = returnTo;
      _previewKind = kind;
      _previewPath = path;
      _previewOid = oid;
      _view = _View.preview;
    });
    await widget.controller.openPreview(kind: kind, path: path, oid: oid);
  }

  bool _historyEnabled(GitBrowserState state) =>
      state.capabilities?.fileHistory == true &&
      state.repository != null &&
      state.sessionId != null;

  GitFileHistoryController _ensureHistoryController(GitBrowserState state) {
    final sessionId = state.sessionId!;
    final repositoryId = state.repository!.repositoryId;
    final existing = _history;
    if (existing != null &&
        _historySessionId == sessionId &&
        _historyRepositoryId == repositoryId) {
      return existing;
    }
    existing?.dispose();
    final created = GitFileHistoryController(
      api: widget.controller.readApi,
      sessionId: sessionId,
      repositoryId: repositoryId,
      repositoryEmpty: state.repository?.empty == true,
    );
    _history = created;
    _historySessionId = sessionId;
    _historyRepositoryId = repositoryId;
    return created;
  }

  /// 打开即深链（来自会话文件页，或构造参数 [GitBrowserSheet.initialFileHistoryPath]）。
  void _maybeHandleHistoryDeepLink() {
    final path = _pendingHistoryPath;
    if (path == null || _historyLinkHandled) return;
    final state = widget.controller.state;
    if (state.loading || state.repository == null) return;
    _historyLinkHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openFileHistory(path);
    });
  }

  /// 深链到某文件的提交历史：已启用 history tab 则切 tab，否则显示独立历史视图。
  ///
  /// 独立历史视图的返回键直接退出 Git 浏览器（不恢复进入前的预览/提交详情），
  /// 避免“历史 → 预览 → 历史”的循环；tab 模式返回键在 tab 根退出。
  void _openFileHistory(String path) {
    final state = widget.controller.state;
    if (!_historyEnabled(state)) {
      // 查看器入口在能力缺失时隐藏，因此这里只可能是初始深链：仍进入历史
      // 视图，由 body 显示不可用提示，而不是静默丢掉深链。
      setState(() => _view = _View.history);
      return;
    }
    final history = _ensureHistoryController(state);
    unawaited(history.selectFile(path));
    final tabIndex = _tabIds.indexOf('fileHistory');
    if (tabIndex >= 0) {
      // 设计决策（US11）：history tab 已启用时深链切换过去，不叠加独立历史视图。
      // 返回键行为与手动切到该 tab 一致——在 tab 根退出 Git 浏览器。
      setState(() {
        _temporaryGraph = false;
        _view = _View.tab;
      });
      _tabs.animateTo(tabIndex);
      return;
    }
    if (_view == _View.preview) widget.controller.closePreview();
    setState(() => _view = _View.history);
  }

  /// 历史行点按：直接打开该文件在此提交上的 diff（不经过通用提交详情）。
  Future<void> _openHistoryEntryDiff(String oid) async {
    final path = _history?.selectedPath;
    if (path == null || path.isEmpty) return;
    final returnTo = _view == _View.history ? _View.history : _View.tab;
    await _showPreview(
      kind: 'commit',
      path: path,
      oid: oid,
      returnTo: returnTo,
    );
  }

  /// 文件历史的主「选择文件」入口：打开会话文件浏览器选中文件后，回到本历史
  /// 视图直接加载该文件的历史（不叠加第二个 GitBrowserSheet）。
  Future<void> _browseFilesForHistory() async {
    final sessionId = widget.controller.state.sessionId;
    final history = _history;
    if (history == null || sessionId == null) return;
    final picker = widget.fileBrowserPicker;
    final path = picker != null
        ? await picker(context, sessionId)
        : await _pushSessionFileBrowser(sessionId, history);
    if (!mounted) return;
    final selected = path?.trim() ?? '';
    if (selected.isEmpty) return;
    await history.selectFile(selected);
  }

  Future<String?> _pushSessionFileBrowser(
    String sessionId,
    GitFileHistoryController history,
  ) async {
    final store = widget.store;
    if (store == null) return null;
    return Navigator.of(context).push<String?>(
      MaterialPageRoute<String?>(
        builder: (_) => SessionFilesScreen(
          store: store,
          sessionId: sessionId,
          gitReadApi: history.api,
          selectionMode: true,
        ),
      ),
    );
  }

  /// 文件查看器顶部的「提交历史」入口（capability 缺失时隐藏）。
  List<Widget> _historyActions(GitBrowserState state, String path) {
    if (state.capabilities?.fileHistory != true || state.repository == null) {
      return const [];
    }
    return [
      IconButton(
        key: const Key('git-file-history'),
        tooltip: L10n.t('提交历史', 'Commit history'),
        icon: const Icon(Icons.history),
        onPressed: () => _openFileHistory(path),
      ),
    ];
  }

  /// tab 与独立历史视图共用的 body。
  Widget _historySurface(GitBrowserState state) {
    if (state.repository == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_historyEnabled(state)) {
      return _MessageState(
        message: L10n.t(
          '此宿主不支持文件提交历史',
          'File history is not supported by this host',
        ),
        onRetry: _refresh,
      );
    }
    final history = _ensureHistoryController(state);
    final canBrowse =
        widget.store != null || widget.fileBrowserPicker != null;
    return GitFileHistoryBody(
      controller: history,
      onOpenCommitDiff: _openHistoryEntryDiff,
      onBrowseFiles: canBrowse ? _browseFilesForHistory : null,
    );
  }

  void _back() {
    if (_view == _View.history) {
      // 独立历史视图：返回直接退出 Git 浏览器到调用方（不恢复预览/提交详情），
      // 这样重复“历史 → diff → 历史”也不会形成导航回环。
      Navigator.of(context).pop();
    } else if (_view == _View.preview) {
      widget.controller.closePreview();
      setState(() => _view = _previewReturnView);
    } else if (_view == _View.commit) {
      setState(() => _view = _View.tab);
    } else if (_temporaryGraph) {
      setState(() => _temporaryGraph = false);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _refresh() async {
    if (_view == _View.history ||
        (_view == _View.tab && _activeTab == 'fileHistory')) {
      await _history?.refresh();
      return;
    }
    final activeTab = _activeTab;
    final worktreePreview = _view == _View.preview && _previewKind != 'commit';
    if (activeTab == 'worktree' || worktreePreview) {
      final reloadingPreview = worktreePreview;
      await widget.controller.loadWorktree(refresh: true);
      if (reloadingPreview &&
          mounted &&
          !widget.controller.state.worktreeStale) {
        await widget.controller.openPreview(
          kind: _previewKind,
          path: _previewPath,
        );
      }
    } else {
      await widget.controller.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final baseView = _view == _View.tab && !_temporaryGraph;
    return PopScope(
      canPop: baseView,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: _view == _View.tab && !_temporaryGraph
                ? L10n.t('返回聊天', 'Back to chat')
                : L10n.t('返回', 'Back'),
            onPressed: _back,
            icon: const Icon(Icons.arrow_back),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              const GitLogo(size: 23),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _view == _View.preview
                      ? (state.preview?.path ?? L10n.t('文件预览', 'File preview'))
                      : _view == _View.commit
                      ? L10n.t('提交详情', 'Commit details')
                      : _view == _View.history
                      ? L10n.t('文件历史', 'File history')
                      : _temporaryGraph
                      ? L10n.t('分支图', 'Branch graph')
                      : state.repository?.name ?? 'Git',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: L10n.t('刷新', 'Refresh'),
              onPressed: state.loading || state.loadingWorktree
                  ? null
                  : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: baseView
              ? TabBar(
                  controller: _tabs,
                  onTap: _selectTab,
                  tabs: [for (final id in _tabIds) Tab(text: _tabLabel(id))],
                )
              : null,
        ),
        body: Column(
          children: [
            if (state.stale && (_activeTab == 'graph' || _view == _View.commit))
              MaterialBanner(
                content: Text(
                  L10n.t('提交图已过期，刷新以更新', 'Graph is stale. Refresh to update.'),
                ),
                actions: [
                  TextButton(
                    onPressed: _refresh,
                    child: Text(L10n.t('刷新', 'Refresh')),
                  ),
                ],
              ),
            if (state.worktreeStale &&
                (_activeTab == 'worktree' ||
                    (_view == _View.preview && _previewKind != 'commit')))
              MaterialBanner(
                content: Text(
                  L10n.t(
                    '工作区已变化，当前内容保持不变',
                    'Worktree changed; keeping the current view.',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: _refresh,
                    child: Text(L10n.t('刷新', 'Refresh')),
                  ),
                ],
              ),
            if (state.error != null &&
                !state.stale &&
                state.branches.isNotEmpty &&
                _view == _View.tab)
              MaterialBanner(
                content: Text(state.error!),
                actions: [
                  TextButton(
                    onPressed: _refresh,
                    child: Text(L10n.t('重试', 'Retry')),
                  ),
                ],
              ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: !baseView,
                    child: IndexedStack(
                      index: _tabs.index,
                      children: [for (final id in _tabIds) _tabBody(id, state)],
                    ),
                  ),
                  if (_temporaryGraph && _view == _View.tab)
                    _tabBody('graph', state),
                  if (_view == _View.preview) _preview(state),
                  if (_view == _View.commit) _detail(state),
                  if (_view == _View.history) _historySurface(state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tabLabel(String id) => switch (id) {
    'branches' => L10n.t('分支列表', 'Branches'),
    'graph' => L10n.t('分支图', 'Graph'),
    'worktree' => L10n.t('工作区', 'Worktree'),
    'fileHistory' => L10n.t('文件历史', 'History'),
    _ => id,
  };

  Widget _tabBody(String id, GitBrowserState state) {
    if (state.loading && state.capabilities == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.capabilities?.available == false) {
      return _MessageState(
        message:
            state.capabilities?.reason ??
            L10n.t('此会话无法使用 Git', 'Git is unavailable for this session'),
        onRetry: _refresh,
      );
    }
    if (id == 'fileHistory') {
      if (state.repository == null) {
        return const Center(child: CircularProgressIndicator());
      }
      if (state.capabilities?.fileHistory != true) {
        return _MessageState(
          message: L10n.t(
            '此宿主不支持文件提交历史',
            'File history is not supported by this host',
          ),
          onRetry: _refresh,
        );
      }
      // 只在当前激活该 tab 时挂载 body：避免未打开就自动弹文件选择器。
      if (_activeTab != 'fileHistory') return const SizedBox.shrink();
      return _historySurface(state);
    }
    if (id == 'worktree') return _worktree(state);
    if (state.error != null && state.branches.isEmpty && !state.stale) {
      return _MessageState(message: state.error!, onRetry: _refresh);
    }
    if (state.repository?.empty == true || state.branches.isEmpty) {
      return _MessageState(
        message: L10n.t('没有分支', 'No branches'),
        onRetry: _refresh,
      );
    }
    return id == 'graph' ? _graph(state) : _branches(state);
  }

  Widget _branches(GitBrowserState state) {
    final branches = state.filteredBranches;
    final locals = branches.where((branch) => branch.isLocal).toList();
    final remotes = branches.where((branch) => branch.isRemote).toList();
    final other = branches
        .where((branch) => !branch.isLocal && !branch.isRemote)
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextFormField(
            key: const Key('git-branch-search'),
            initialValue: state.branchQuery,
            onChanged: widget.controller.setBranchQuery,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: L10n.t('搜索分支', 'Search branches'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            controller: _branchScroll,
            children: [
              _branchGroup(L10n.t('本地分支', 'Local branches'), locals),
              _branchGroup(L10n.t('远程分支', 'Remote branches'), remotes),
              if (other.isNotEmpty) _branchGroup(L10n.t('其他', 'Other'), other),
              if (branches.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(L10n.t('没有匹配的分支', 'No matching branches')),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _worktree(GitBrowserState state) {
    final snapshot = state.worktree;
    if (snapshot == null && state.loadingWorktree) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot == null) {
      return _MessageState(
        message:
            state.worktreeError ?? L10n.t('无法读取工作区', 'Could not read worktree'),
        onRetry: () => widget.controller.loadWorktree(refresh: true),
      );
    }
    final total =
        snapshot.staged.length +
        snapshot.unstaged.length +
        snapshot.untracked.length;
    return ListView(
      key: const Key('git-worktree-list'),
      controller: _worktreeScroll,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            L10n.t('当前工作区 · $total 个改动项', 'Current worktree · $total changes'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        _worktreeGroup(L10n.t('已暂存', 'Staged'), 'staged', snapshot.staged),
        _worktreeGroup(
          L10n.t('未暂存', 'Unstaged'),
          'unstaged',
          snapshot.unstaged,
        ),
        _worktreeGroup(
          L10n.t('未跟踪', 'Untracked'),
          'untracked',
          snapshot.untracked,
        ),
        if (snapshot.truncated)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              L10n.t(
                '文件清单过多，已截取显示',
                'File list is large; entries are truncated.',
              ),
            ),
          ),
        if (total == 0)
          Padding(
            padding: const EdgeInsets.all(28),
            child: Center(child: Text(L10n.t('工作区干净', 'Working tree clean'))),
          ),
        if (state.worktreeError != null)
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(state.worktreeError!),
            trailing: TextButton(
              onPressed: () => widget.controller.loadWorktree(refresh: true),
              child: Text(L10n.t('重试', 'Retry')),
            ),
          ),
      ],
    );
  }

  Widget _worktreeGroup(
    String title,
    String kind,
    List<GitWorktreeFile> files,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          '$title (${files.length})',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      if (files.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            L10n.t('无', 'None'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      for (final file in files)
        ListTile(
          key: Key('git-worktree-$kind-${file.path}'),
          dense: true,
          title: Text(file.path, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: file.oldPath == null
              ? null
              : Text('${file.oldPath} → ${file.path}'),
          leading: file.conflicted
              ? Icon(
                  Icons.warning_amber_rounded,
                  color: DshColors.danger(context),
                )
              : const Icon(Icons.insert_drive_file_outlined),
          trailing: Text(
            file.conflicted
                ? L10n.t('冲突', 'Conflict')
                : _statusLabel(file.status),
          ),
          onTap: file.conflicted || widget.controller.state.worktreeStale
              ? null
              : () => _showPreview(
                  kind: kind,
                  path: file.path,
                  returnTo: _View.tab,
                ),
        ),
    ],
  );

  String _statusLabel(String status) => switch (status) {
    'added' => L10n.t('新增', 'Added'),
    'deleted' => L10n.t('删除', 'Deleted'),
    'renamed' => L10n.t('重命名', 'Renamed'),
    'untracked' => L10n.t('未跟踪', 'Untracked'),
    'conflicted' => L10n.t('冲突', 'Conflict'),
    _ => L10n.t('修改', 'Modified'),
  };

  /// 工作区/提交 diff 预览：只做数据适配，渲染交给统一的 GitFileViewer。
  Widget _preview(GitBrowserState state) {
    final preview = state.preview;
    if (state.loadingPreview) {
      return GitFileViewer(
        key: const Key('git-file-preview'),
        mode: GitFileViewerMode.diff,
        path: _previewPath,
        loading: true,
        topActions: _historyActions(state, _previewPath),
        keys: const GitFileViewerKeys(prefix: 'git'),
      );
    }
    if (preview == null) {
      final error = state.previewError;
      return GitFileViewer(
        key: const Key('git-file-preview'),
        mode: GitFileViewerMode.diff,
        path: _previewPath,
        error: error ?? L10n.t('无法读取文件差异', 'Could not load file changes'),
        onRetry: error != null && !state.worktreeStale
            ? () => widget.controller.openPreview(
                kind: _previewKind,
                path: _previewPath,
                oid: _previewOid,
              )
            : null,
        topActions: _historyActions(state, _previewPath),
        keys: const GitFileViewerKeys(prefix: 'git'),
      );
    }
    return GitFileViewer(
      key: const Key('git-file-preview'),
      mode: GitFileViewerMode.diff,
      path: preview.path,
      oldPath: preview.oldPath,
      diff: preview.diff,
      truncated: preview.truncated,
      truncatedMessage: L10n.t(
        '差异已截断，仅显示安全上限内的内容',
        'Diff truncated at the safety limit.',
      ),
      binary: preview.binary,
      notice: preview.notice,
      rawAddedContent: preview.kind == 'untracked',
      topActions: _historyActions(state, preview.path),
      keys: const GitFileViewerKeys(prefix: 'git'),
    );
  }

  Widget _branchGroup(String title, List<GitBranch> branches) {
    if (branches.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final branch in branches)
          ListTile(
            key: Key('git-branch-${branch.name}'),
            leading: Icon(
              branch.current
                  ? Icons.check_circle_outline
                  : Icons.account_tree_outlined,
            ),
            title: Text(branch.displayName),
            subtitle:
                branch.tracking == null &&
                    branch.ahead == 0 &&
                    branch.behind == 0
                ? null
                : Text(
                    [
                      if (branch.tracking != null) branch.tracking!,
                      if (branch.ahead != 0) '↑${branch.ahead}',
                      if (branch.behind != 0) '↓${branch.behind}',
                    ].join('  '),
                  ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showGraph(branch),
          ),
      ],
    );
  }

  Widget _graph(GitBrowserState state) {
    final selected = state.selectedBranches;
    final query = _graphQuery.trim().toLowerCase();
    final matches = state.branches.where(
      (branch) => branch.displayName.toLowerCase().contains(query),
    );
    final layout = _graphLayout(state);
    final graphWidth = math.max(80.0, layout.laneCount * 30.0 + 32);
    // 全部标签单行展示、与图共用同一条横向滚动轴：滚动范围按最宽一行标签计算。
    final horizontalWidth = math.max(
      MediaQuery.sizeOf(context).width,
      graphWidth + _labelLineWidth + 56,
    );
    // 正常字号下保持设计稿固定 86；系统文字缩放时按文本高度放大行高，
    // 避免主题/无障碍字号下标签行被纵向裁切。
    final textScaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(
      kGitGraphRowHeight,
      textScaler.scale(kGitGraphRowHeight - 22) + 22,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selected.map((branch) => branch.displayName).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                key: const Key('git-graph-filter'),
                onPressed: () =>
                    setState(() => _choosingBranches = !_choosingBranches),
                icon: const Icon(Icons.filter_alt_outlined),
                label: Text(L10n.t('分支 (1–5)', 'Branches (1–5)')),
              ),
            ],
          ),
        ),
        if (_choosingBranches) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('git-graph-search'),
              onChanged: (value) => setState(() => _graphQuery = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: L10n.t('搜索分支', 'Search branches'),
              ),
            ),
          ),
          SizedBox(
            height: 176,
            child: ListView(
              key: const Key('git-graph-branch-list'),
              children: [
                for (final branch in matches)
                  CheckboxListTile(
                    key: Key('git-filter-${branch.name}'),
                    dense: true,
                    title: Text(branch.displayName),
                    value: selected.any((item) => item.name == branch.name),
                    onChanged: (value) {
                      if (value == true &&
                          selected.length >= maxSelectedGraphBranches) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              L10n.t(
                                '最多选择 $maxSelectedGraphBranches 个分支',
                                'Select up to $maxSelectedGraphBranches branches',
                              ),
                            ),
                          ),
                        );
                        return;
                      }
                      if (value == false && selected.length <= 1) return;
                      widget.controller.toggleGraphBranch(branch);
                    },
                  ),
              ],
            ),
          ),
        ],
        if (state.loadingGraph || state.loadingGraphPage)
          const LinearProgressIndicator(),
        Expanded(
          child: SingleChildScrollView(
            key: const Key('git-graph-horizontal'),
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: horizontalWidth,
              child: ListView.builder(
                key: const Key('git-graph-vertical'),
                controller: widget.scrollController,
                itemCount:
                    state.commits.length +
                    (state.graphNextCursor != null ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == state.commits.length) {
                    return Center(
                      child: state.loadingGraphPage
                          ? const CircularProgressIndicator()
                          : Text(L10n.t('加载更多…', 'Loading more…')),
                    );
                  }
                  final commit = state.commits[index];
                  final row = layout.rows[index];
                  final labels =
                      _rowLabels[commit.oid] ?? const <GitGraphLabel>[];
                  return SizedBox(
                    height: rowHeight,
                    child: InkWell(
                      key: Key('git-commit-${commit.oid}'),
                      onTap: () => _showCommit(commit.oid),
                      child: Row(
                        children: [
                          CustomPaint(
                            size: Size(graphWidth, rowHeight),
                            painter: _GraphRowPainter(
                              row,
                              selected,
                              isHead: commit.oid == state.repository?.headOid,
                              brightness: Theme.of(context).brightness,
                              surface: Theme.of(context).colorScheme.surface,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  commit.subject,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${commit.author} · ${_time(commit.timestamp)} · ${_short(commit.oid)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (labels.isNotEmpty)
                                  Row(
                                    children: [
                                      for (final label in labels)
                                        _graphLabel(label),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                          if (_openingOid == commit.oid)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(),
                            ),
                          const SizedBox(width: 12),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 图行单个标签 pill：全量展示、不截断（滚动由外层共享横向轴负责）。
  Widget _graphLabel(GitGraphLabel label) {
    final theme = Theme.of(context);
    final colors = gitGraphLabelColors(
      label,
      scheme: theme.colorScheme,
      brightness: theme.brightness,
    );
    final pill = Container(
      margin: const EdgeInsets.only(right: 5, top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(4),
        border: colors.border == null
            ? null
            : Border.all(color: colors.border!, width: 1),
      ),
      child: Text(
        label.text,
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.labelSmall?.copyWith(color: colors.foreground),
      ),
    );
    final hint = label.hint;
    if (hint == null) return pill;
    return Tooltip(message: _tagHintLabel(hint), child: pill);
  }

  String _tagHintLabel(String hint) => switch (hint) {
    'nested-tag' => L10n.t(
      '嵌套 tag：目标不是该提交',
      'Nested tag: does not target this commit',
    ),
    'non-commit-target' => L10n.t(
      'tag 指向非 commit 对象',
      'Tag targets a non-commit object',
    ),
    _ => hint,
  };

  Widget _detail(GitBrowserState state) {
    final commit = state.commit;
    if (commit == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      key: const Key('git-detail-list'),
      controller: _commitScroll,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                commit.message,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _metadata(L10n.t('作者', 'Author'), commit.author),
              _metadata(L10n.t('时间', 'Time'), _time(commit.timestamp)),
              _metadata('OID', commit.oid),
              _metadata(L10n.t('父提交', 'Parents'), commit.parents.join(', ')),
              _metadata('Refs', _refsText(commit.resolvedDecoration)),
              _metadata('Tags', _tagsText(commit.resolvedDecoration)),
              ..._annotatedTagWidgets(commit.resolvedDecoration),
              _metadata(
                L10n.t('统计', 'Stats'),
                '${commit.stats.files} files · +${commit.stats.additions} −${commit.stats.deletions}',
              ),
              const SizedBox(height: 12),
              Text(
                '${L10n.t('变更文件', 'Changed files')} (${commit.files.length}/${commit.filesTotal})',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
        ),
        for (final file in commit.files)
          ListTile(
            key: Key('git-file-${file.path}'),
            title: Text(file.path),
            subtitle: file.oldPath == null ? null : Text(file.oldPath!),
            trailing: Text(
              '+${file.additions} −${file.deletions}${file.binary ? ' · binary' : ''}',
            ),
            onTap: () => _showPreview(
              kind: 'commit',
              path: file.path,
              oid: commit.oid,
              returnTo: _View.commit,
            ),
          ),
        if (state.loadingFilesPage)
          const Center(child: CircularProgressIndicator()),
        if (commit.filesNextCursor != null && !state.loadingFilesPage)
          Center(child: Text(L10n.t('加载更多…', 'Loading more…'))),
      ],
    );
  }

  /// 详情 Refs：结构化 refsDetail 优先（HEAD → 本地 → 远程），旧宿主由原始
  /// 装饰字符串解析兜底；空态显示 `none`（与图行一致）。
  String _refsText(GitDecoration decoration) {
    final labels = gitRefLabels(decoration);
    return labels.isEmpty
        ? 'none'
        : labels.map((label) => label.text).join(', ');
  }

  /// 详情 Tags：结构化 tagsDetail 优先；旧宿主的 Tags 从 refs 装饰派生。
  /// tag 目标非 commit / 嵌套 tag 时附加宿主 hint。
  String _tagsText(GitDecoration decoration) {
    final labels = gitTagLabels(decoration);
    if (labels.isEmpty) return 'none';
    return labels
        .map(
          (label) => label.hint == null
              ? label.text
              : '${label.text} (${_tagHintLabel(label.hint!)})',
        )
        .join(', ');
  }

  /// annotated tag 元数据（tagger / 日期 / 说明）；无元数据时不占位。
  List<Widget> _annotatedTagWidgets(GitDecoration decoration) {
    final tags = decoration.tags
        .where((tag) => tag.annotated && tag.hasMetadata)
        .toList();
    if (tags.isEmpty) return const [];
    return [
      const SizedBox(height: 4),
      Text(
        L10n.t('Tag 详情', 'Tag details'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      for (final tag in tags)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                tag.shortName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if ((tag.tagger ?? '').isNotEmpty)
                _metadata(L10n.t('Tagger', 'Tagger'), tag.tagger!),
              if (tag.timestamp != null)
                _metadata(L10n.t('日期', 'Date'), _time(tag.timestamp!)),
              if ((tag.subject ?? '').isNotEmpty)
                SelectableText(tag.subject!),
            ],
          ),
        ),
    ];
  }

  Widget _metadata(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: SelectableText('$label: $value'),
  );

  String _short(String oid) => oid.length <= 8 ? oid : oid.substring(0, 8);

  String _time(int seconds) => DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).toLocal().toString().split('.').first;
}

class _GraphRowPainter extends CustomPainter {
  const _GraphRowPainter(
    this.row,
    this.selected, {
    required this.isHead,
    required this.brightness,
    required this.surface,
  });

  final GraphRow row;
  final List<GitBranch> selected;
  final bool isHead;
  final Brightness brightness;
  final Color surface;

  Color _color(int slot) => gitLaneColor(slot, selected, brightness);
  double _x(int lane) => 24.0 + lane * 30;

  @override
  void paint(Canvas canvas, Size size) {
    final nodeY = size.height / 2;
    final linePaint = Paint()
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void edge(double x1, double y1, double x2, double y2, int color) {
      linePaint.color = _color(color);
      final path = Path()..moveTo(x1, y1);
      if (x1 == x2) {
        path.lineTo(x2, y2);
      } else {
        final dy = y2 - y1;
        path.cubicTo(x1, y1 + dy * .38, x2, y2 - dy * .38, x2, y2);
      }
      canvas.drawPath(path, linePaint);
    }

    for (final continuation in row.continuations) {
      edge(
        _x(continuation.from),
        0,
        _x(continuation.to),
        size.height,
        continuation.colorSlot,
      );
    }
    if (row.hasIncomingEdge) {
      edge(_x(row.lane), 0, _x(row.lane), nodeY, row.incomingColorSlot);
    }
    for (var i = 0; i < row.parentLanes.length; i++) {
      edge(
        _x(row.lane),
        nodeY,
        _x(row.parentLanes[i]),
        size.height,
        row.parentColorSlots[i],
      );
    }

    final center = Offset(_x(row.lane), nodeY);
    if (row.tipColorSlots.length > 1) {
      for (var i = 0; i < row.tipColorSlots.length; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: 6),
          -math.pi / 2 + i * 2 * math.pi / row.tipColorSlots.length,
          2 * math.pi / row.tipColorSlots.length,
          false,
          Paint()
            ..color = _color(row.tipColorSlots[i])
            ..strokeWidth = 5
            ..style = PaintingStyle.stroke,
        );
      }
    } else {
      final slot = row.tipColorSlots.isEmpty
          ? row.colorSlot
          : row.tipColorSlots.single;
      canvas.drawCircle(center, 5, Paint()..color = _color(slot));
    }
    canvas.drawCircle(center, 2, Paint()..color = surface);
    if (row.merge || isHead) {
      canvas.drawCircle(
        center,
        isHead ? 9 : 7.5,
        Paint()
          ..color = isHead
              ? gitBranchColor('HEAD', brightness)
              : _color(row.colorSlot)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isHead ? 1.8 : 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_GraphRowPainter oldDelegate) =>
      oldDelegate.row != row ||
      oldDelegate.selected != selected ||
      oldDelegate.isHead != isHead ||
      oldDelegate.brightness != brightness ||
      oldDelegate.surface != surface;
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.account_tree_outlined, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(L10n.t('重试', 'Retry')),
          ),
        ],
      ),
    ),
  );
}
