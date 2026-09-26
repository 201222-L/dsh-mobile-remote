import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../git_browser_controller.dart';
import '../git_graph_logic.dart';
import '../git_models.dart';
import '../l10n.dart';

/// Read-only content for the host's DraggableScrollableSheet.
class GitBrowserSheet extends StatefulWidget {
  const GitBrowserSheet({
    super.key,
    required this.controller,
    required this.scrollController,
  });

  final GitBrowserController controller;
  final ScrollController scrollController;

  @override
  State<GitBrowserSheet> createState() => _GitBrowserSheetState();
}

enum _View { branches, graph, commit }

class _GitBrowserSheetState extends State<GitBrowserSheet> {
  _View _view = _View.branches;
  bool _choosingBranches = false;
  String _graphQuery = '';
  String? _openingOid;
  final ScrollController _horizontal = ScrollController();
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

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    widget.controller.addListener(_onState);
  }

  @override
  void didUpdateWidget(GitBrowserSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
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
    widget.scrollController.removeListener(_onScroll);
    widget.controller.removeListener(_onState);
    _horizontal.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    // A short first page may not generate a scroll event at all.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  void _onScroll() {
    if (!mounted || !widget.scrollController.hasClients) return;
    final position = widget.scrollController.position;
    if (position.extentAfter > 240) return;
    final state = widget.controller.state;
    if (state.stale || state.loading || state.error != null) return;
    if (_view == _View.graph &&
        state.graphNextCursor != null &&
        !state.loadingGraphPage) {
      widget.controller.loadNextGraphPage();
    } else if (_view == _View.commit &&
        state.commit?.filesNextCursor != null &&
        !state.loadingFilesPage) {
      widget.controller.loadNextFilesPage();
    }
  }

  void _showGraph(GitBranch branch) {
    setState(() {
      _view = _View.graph;
      _choosingBranches = false;
      _graphQuery = '';
    });
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

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                if (_view != _View.branches)
                  IconButton(
                    tooltip: L10n.t('返回', 'Back'),
                    onPressed: () => setState(() {
                      if (_view == _View.commit) {
                        _view = _View.graph;
                      } else {
                        _view = _View.branches;
                        _choosingBranches = false;
                      }
                    }),
                    icon: const Icon(Icons.arrow_back),
                  )
                else
                  const SizedBox(width: 8),
                const Icon(Icons.source_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.repository?.name ?? 'Git',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: L10n.t('刷新', 'Refresh'),
                  onPressed: state.loading ? null : widget.controller.refresh,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: L10n.t('关闭', 'Close'),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (state.stale)
            MaterialBanner(
              content: Text(
                L10n.t('提交图已过期，刷新以更新', 'Graph is stale. Refresh to update.'),
              ),
              actions: [
                TextButton(
                  onPressed: state.loading ? null : widget.controller.refresh,
                  child: Text(L10n.t('刷新', 'Refresh')),
                ),
              ],
            ),
          if (state.error != null &&
              !state.stale &&
              (state.branches.isNotEmpty || state.commit != null))
            MaterialBanner(
              content: Text(state.error!),
              actions: [
                TextButton(
                  onPressed: widget.controller.refresh,
                  child: Text(L10n.t('重试', 'Retry')),
                ),
              ],
            ),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  Widget _body(GitBrowserState state) {
    if (state.loading && state.capabilities == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.capabilities?.available == false && state.branches.isEmpty) {
      return _MessageState(
        message:
            state.capabilities?.reason ??
            L10n.t('此会话无法使用 Git', 'Git is unavailable for this session'),
        onRetry: widget.controller.refresh,
      );
    }
    if (state.error != null && state.branches.isEmpty && !state.stale) {
      return _MessageState(
        message: state.error!,
        onRetry: widget.controller.refresh,
      );
    }
    if (state.repository?.empty == true || state.branches.isEmpty) {
      return _MessageState(
        message: L10n.t('没有分支', 'No branches'),
        onRetry: widget.controller.refresh,
      );
    }
    switch (_view) {
      case _View.branches:
        return _branches(state);
      case _View.graph:
        return _graph(state);
      case _View.commit:
        return _detail(state);
    }
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
            controller: widget.scrollController,
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
    final labelWidth = state.commits.fold<double>(320.0, (width, commit) {
      final labels = [...commit.refs, ...commit.tags];
      return math.max(
        width,
        220.0 +
            labels.fold<int>(0, (sum, label) => sum + label.length * 8 + 24),
      );
    });
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
                label: Text(L10n.t('分支 (1–3)', 'Branches (1–3)')),
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
              children: [
                for (final branch in matches)
                  CheckboxListTile(
                    key: Key('git-filter-${branch.name}'),
                    dense: true,
                    title: Text(branch.displayName),
                    value: selected.any((item) => item.name == branch.name),
                    onChanged: (value) {
                      if ((value == true && selected.length >= 3) ||
                          (value == false && selected.length <= 1)) {
                        return;
                      }
                      widget.controller.toggleGraphBranch(branch);
                    },
                  ),
              ],
            ),
          ),
        ],
        if (state.loadingGraphPage) const LinearProgressIndicator(),
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
                            painter: _GraphRowPainter(row),
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
                                      for (final ref in commit.refs)
                                        _graphLabel(ref, false),
                                      for (final tag in commit.tags)
                                        _graphLabel(tag, true),
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

  Widget _graphLabel(String label, bool tag) => Container(
    margin: const EdgeInsets.only(right: 5, top: 3),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: tag
          ? Theme.of(context).colorScheme.tertiaryContainer
          : Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );

  Widget _detail(GitBrowserState state) {
    final commit = state.commit;
    if (commit == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      key: const Key('git-detail-list'),
      controller: widget.scrollController,
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
  const _GraphRowPainter(this.row);
  final GraphRow row;

  static const _colors = [
    Colors.blue,
    Colors.orange,
    Colors.green,
    Colors.purple,
    Colors.teal,
  ];
  Color _color(int slot) => _colors[slot % _colors.length];
  double _x(int lane) => 24.0 + lane * 30;

  @override
  void paint(Canvas canvas, Size size) {
    void line(double x1, double y1, double x2, double y2, int color) {
      canvas.drawLine(
        Offset(x1, y1),
        Offset(x2, y2),
        Paint()
          ..color = _color(color)
          ..strokeWidth = 2.5,
      );
    }

    for (final edge in row.continuations) {
      line(_x(edge.from), 0, _x(edge.to), size.height, edge.colorSlot);
    }
    line(_x(row.lane), 0, _x(row.lane), 32, row.incomingColorSlot);
    for (var i = 0; i < row.parentLanes.length; i++) {
      line(
        _x(row.lane),
        32,
        _x(row.parentLanes[i]),
        size.height,
        row.parentColorSlots[i],
      );
    }
    final slots = row.tipColorSlots.isEmpty
        ? [row.colorSlot]
        : row.tipColorSlots;
    for (var i = 0; i < slots.length; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(_x(row.lane), 32), radius: 6),
        -math.pi / 2 + i * 2 * math.pi / slots.length,
        2 * math.pi / slots.length,
        false,
        Paint()
          ..color = _color(slots[i])
          ..strokeWidth = 5
          ..style = PaintingStyle.stroke,
      );
    }
    canvas.drawCircle(
      Offset(_x(row.lane), 32),
      2,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_GraphRowPainter oldDelegate) => oldDelegate.row != row;
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
