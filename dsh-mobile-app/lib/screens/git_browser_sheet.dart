import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../git_browser_controller.dart';
import '../git_graph_logic.dart';
import '../git_graph_presentation.dart';
import '../git_models.dart';
import '../l10n.dart';
import '../theme.dart';
import '../widgets/git_logo.dart';

/// Full-screen, read-only Git browser route.
class GitBrowserSheet extends StatefulWidget {
  const GitBrowserSheet({
    super.key,
    required this.controller,
    required this.scrollController,
    this.tabs = const ['branches', 'graph', 'worktree'],
  });

  final GitBrowserController controller;
  final ScrollController scrollController;
  final List<String> tabs;

  @override
  State<GitBrowserSheet> createState() => _GitBrowserSheetState();
}

enum _View { tab, commit, preview }

class _GitBrowserSheetState extends State<GitBrowserSheet>
    with TickerProviderStateMixin {
  _View _view = _View.tab;
  bool _temporaryGraph = false;
  bool _previewFromCommit = false;
  String _previewKind = 'unstaged';
  String _previewPath = '';
  String? _previewOid;
  bool _choosingBranches = false;
  String _graphQuery = '';
  String? _openingOid;
  late final TabController _tabs;
  final ScrollController _branchScroll = ScrollController();
  final ScrollController _worktreeScroll = ScrollController();
  final ScrollController _commitScroll = ScrollController();
  final ScrollController _previewScroll = ScrollController();
  final ScrollController _horizontal = ScrollController();
  Timer? _freshnessTimer;
  final Set<int> _expandedContextRuns = {};
  bool _defaultGraphRequested = false;
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

  List<String> get _tabIds => widget.tabs.isEmpty
      ? const ['branches', 'graph', 'worktree']
      : widget.tabs;

  String get _activeTab => _temporaryGraph ? 'graph' : _tabIds[_tabs.index];

  int get _graphTabIndex => _tabIds.indexOf('graph');

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabIds.length, vsync: this);
    widget.scrollController.addListener(_onGraphScroll);
    _commitScroll.addListener(_onCommitScroll);
    widget.controller.addListener(_onState);
    _freshnessTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      widget.controller.checkWorktreeFreshness();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    }
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    widget.scrollController.removeListener(_onGraphScroll);
    _commitScroll.removeListener(_onCommitScroll);
    widget.controller.removeListener(_onState);
    _tabs.dispose();
    _branchScroll.dispose();
    _worktreeScroll.dispose();
    _commitScroll.dispose();
    _previewScroll.dispose();
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
    required bool fromCommit,
  }) async {
    setState(() {
      _previewFromCommit = fromCommit;
      _previewKind = kind;
      _previewPath = path;
      _previewOid = oid;
      _expandedContextRuns.clear();
      _view = _View.preview;
    });
    await widget.controller.openPreview(kind: kind, path: path, oid: oid);
  }

  void _back() {
    if (_view == _View.preview) {
      widget.controller.closePreview();
      setState(() => _view = _previewFromCommit ? _View.commit : _View.tab);
    } else if (_view == _View.commit) {
      setState(() => _view = _View.tab);
    } else if (_temporaryGraph) {
      setState(() => _temporaryGraph = false);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _refresh() async {
    final activeTab = _activeTab;
    if (activeTab == 'worktree' ||
        (_view == _View.preview && !_previewFromCommit)) {
      final reloadingPreview = _view == _View.preview && !_previewFromCommit;
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
                    (_view == _View.preview && !_previewFromCommit)))
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
                  if (_view == _View.commit) _detail(state),
                  if (_view == _View.preview) _preview(state),
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
                  fromCommit: false,
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

  Widget _preview(GitBrowserState state) {
    final preview = state.preview;
    if (state.loadingPreview) {
      return const Center(child: CircularProgressIndicator());
    }
    if (preview == null) {
      final error = state.previewError;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error ?? L10n.t('无法读取文件差异', 'Could not load file changes')),
              const SizedBox(height: 12),
              if (error != null && !state.worktreeStale)
                FilledButton.tonalIcon(
                  onPressed: () => widget.controller.openPreview(
                    kind: _previewKind,
                    path: _previewPath,
                    oid: _previewOid,
                  ),
                  icon: const Icon(Icons.refresh),
                  label: Text(L10n.t('重试', 'Retry')),
                ),
            ],
          ),
        ),
      );
    }
    if (preview.binary || preview.notice != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            preview.notice ??
                L10n.t('二进制文件不提供行级预览', 'Binary files have no line preview'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      key: const Key('git-file-preview'),
      controller: _previewScroll,
      children: [
        if (preview.truncated)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Text(
              L10n.t(
                '差异已截断，仅显示安全上限内的内容',
                'Diff truncated at the safety limit.',
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${preview.oldPath == null ? '' : '${preview.oldPath} → '}${preview.path}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        ..._diffWidgets(preview),
        if (preview.diff.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(L10n.t('没有可显示的行级差异', 'No line changes to display')),
          ),
      ],
    );
  }

  List<Widget> _diffWidgets(GitFilePreview preview) {
    if (preview.diff.isEmpty) return const [];
    final rawLines = preview.diff.split('\n');
    final lines = <({String marker, String text})>[];
    var inHunk = false;
    for (var rawIndex = 0; rawIndex < rawLines.length; rawIndex++) {
      final line = rawLines[rawIndex];
      if (preview.kind == 'untracked') {
        // This endpoint returns file bytes, not a unified patch: keep blank lines
        // and source text that happens to resemble diff metadata. Ignore only
        // the terminal split sentinel after a final newline.
        if (rawIndex == rawLines.length - 1 &&
            line.isEmpty &&
            preview.diff.endsWith('\n')) {
          continue;
        }
        lines.add((marker: '+', text: line));
        continue;
      }
      if (line.isEmpty ||
          line.startsWith('diff --git ') ||
          line.startsWith('index ') ||
          line.startsWith('Binary files ')) {
        continue;
      }
      if (line.startsWith('@@')) {
        inHunk = true;
        lines.add((marker: '@', text: line));
        continue;
      }
      if (line.startsWith('\\')) continue;
      if (!inHunk && (line.startsWith('--- ') || line.startsWith('+++ '))) {
        continue;
      }
      if (line.startsWith('+') || line.startsWith('-')) {
        lines.add((marker: line[0], text: line.substring(1)));
      } else if (line.startsWith(' ')) {
        lines.add((marker: ' ', text: line.substring(1)));
      }
    }
    final result = <Widget>[];
    var index = 0;
    var runId = 0;
    while (index < lines.length) {
      if (lines[index].marker != ' ') {
        result.add(_diffLine(lines[index], lineIndex: index));
        index++;
        continue;
      }
      final start = index;
      while (index < lines.length && lines[index].marker == ' ') {
        index++;
      }
      final length = index - start;
      if (length <= 6) {
        for (var i = start; i < index; i++) {
          result.add(_diffLine(lines[i], lineIndex: i));
        }
        continue;
      }
      final id = runId++;
      final expanded = _expandedContextRuns.contains(id);
      final visible = expanded
          ? List.generate(length, (offset) => start + offset)
          : [
              ...List.generate(3, (offset) => start + offset),
              ...List.generate(3, (offset) => index - 3 + offset),
            ];
      for (final lineIndex in visible.where((lineIndex) => lineIndex < index)) {
        result.add(_diffLine(lines[lineIndex], lineIndex: lineIndex));
      }
      result.add(
        TextButton.icon(
          key: Key('git-context-fold-$id'),
          onPressed: () => setState(() {
            if (expanded) {
              _expandedContextRuns.remove(id);
            } else {
              _expandedContextRuns.add(id);
            }
          }),
          icon: Icon(
            expanded ? Icons.unfold_less : Icons.unfold_more,
            size: 18,
          ),
          label: Text(
            expanded
                ? L10n.t('折叠未改动行', 'Fold unchanged lines')
                : L10n.t(
                    '展开 ${length - 6} 行未改动',
                    'Expand ${length - 6} unchanged lines',
                  ),
          ),
        ),
      );
    }
    return result;
  }

  Widget _diffLine(({String marker, String text}) line, {int? lineIndex}) {
    final color = switch (line.marker) {
      '+' => DshColors.ok(context),
      '-' => DshColors.danger(context),
      '@' => DshColors.ink3(context),
      _ => DshColors.ink(context),
    };
    final background = switch (line.marker) {
      '+' => DshColors.ok(context).withValues(alpha: .10),
      '-' => DshColors.danger(context).withValues(alpha: .10),
      _ => Colors.transparent,
    };
    return Container(
      key: lineIndex == null ? null : Key('git-diff-line-$lineIndex'),
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              line.marker == ' ' ? ' ' : line.marker,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                line.text,
                softWrap: false,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
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
    // Compact decorations keep long ref/tag lists from expanding the graph lane viewport.
    const labelWidth = 560.0;
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
              width: math.max(
                MediaQuery.sizeOf(context).width,
                graphWidth + labelWidth,
              ),
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
                  return SizedBox(
                    height: 86,
                    child: InkWell(
                      key: Key('git-commit-${commit.oid}'),
                      onTap: () => _showCommit(commit.oid),
                      child: Row(
                        children: [
                          CustomPaint(
                            size: Size(graphWidth, 86),
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
                                if (commit.refs.isNotEmpty ||
                                    commit.tags.isNotEmpty)
                                  Row(
                                    children: [
                                      for (final label in compactGitGraphLabels(
                                        refs: commit.refs,
                                        tags: commit.tags,
                                        selected: selected,
                                        currentBranch:
                                            state.repository?.currentBranch,
                                      ))
                                        _graphLabel(
                                          label.text,
                                          label.tag,
                                          overflow: label.overflow,
                                        ),
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

  Widget _graphLabel(String label, bool tag, {bool overflow = false}) =>
      Container(
        constraints: const BoxConstraints(maxWidth: 112),
        margin: const EdgeInsets.only(right: 5, top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: overflow
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : tag
              ? Theme.of(context).colorScheme.tertiaryContainer
              : gitBranchColor(
                  label,
                  Theme.of(context).brightness,
                ).withValues(alpha: .15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );

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
              _metadata('Refs', commit.refs.join(', ')),
              _metadata('Tags', commit.tags.join(', ')),
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
              fromCommit: true,
            ),
          ),
        if (state.loadingFilesPage)
          const Center(child: CircularProgressIndicator()),
        if (commit.filesNextCursor != null && !state.loadingFilesPage)
          Center(child: Text(L10n.t('加载更多…', 'Loading more…'))),
      ],
    );
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
    edge(_x(row.lane), 0, _x(row.lane), nodeY, row.incomingColorSlot);
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
