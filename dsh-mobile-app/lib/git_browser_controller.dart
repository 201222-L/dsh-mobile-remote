import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'git_models.dart';

class GitBrowserState {
  final String? sessionId;
  final GitReadCapabilities? capabilities;
  final GitRepository? repository;
  final List<GitBranch> branches;
  final String branchQuery;
  final List<GitBranch> selectedBranches;
  final List<GitCommitSummary> commits;
  final String? snapshotId;
  final String? graphNextCursor;

  /// issue #93：全部分支模式状态。prevCursor 指向更**新**一页；focus/pageStart 用于
  /// 首屏定位当前分支 HEAD 所在页；graphAll=true 表示当前图来自 all 快照。
  final String? graphPrevCursor;
  final String? graphFocusOid;
  final int? graphPageStart;
  final bool graphAll;
  final GitCommitDetails? commit;
  final GitWorktreeSnapshot? worktree;
  final bool loadingWorktree;
  final bool worktreeStale;
  final String? worktreeError;
  final GitFilePreview? preview;
  final bool loadingPreview;
  final String? previewError;
  final bool loading;
  final bool loadingGraph;
  final bool loadingGraphPage;
  final bool loadingFilesPage;
  final bool stale;
  final String? error;

  /// issue #86：当前生效的分支图选中上限（5/10/不限）。
  final GitGraphBranchLimit branchLimit;

  /// issue #86：仅「不限」档的 30s 超时态（不自动降档，等待用户三选一）。
  final bool graphTimedOut;

  /// re-review P1-3：**分页** append 超时——保留已加载 commits，页级重试，不替换整图。
  final bool graphPageTimedOut;

  /// issue #95：分页超时方向（true=更新页/顶部；false=更旧页/底部），供 UI 单侧重试。
  final bool graphPageTimedOutNewer;

  const GitBrowserState({
    this.sessionId,
    this.capabilities,
    this.repository,
    this.branches = const [],
    this.branchQuery = '',
    this.selectedBranches = const [],
    this.commits = const [],
    this.snapshotId,
    this.graphNextCursor,
    this.graphPrevCursor,
    this.graphFocusOid,
    this.graphPageStart,
    this.graphAll = false,
    this.commit,
    this.worktree,
    this.loadingWorktree = false,
    this.worktreeStale = false,
    this.worktreeError,
    this.preview,
    this.loadingPreview = false,
    this.previewError,
    this.loading = false,
    this.loadingGraph = false,
    this.loadingGraphPage = false,
    this.loadingFilesPage = false,
    this.stale = false,
    this.error,
    this.branchLimit = GitGraphBranchLimit.fallback,
    this.graphTimedOut = false,
    this.graphPageTimedOut = false,
    this.graphPageTimedOutNewer = false,
  });

  List<GitBranch> get filteredBranches {
    final query = branchQuery.trim().toLowerCase();
    if (query.isEmpty) return branches;
    return UnmodifiableListView(
      branches.where(
        (branch) => branch.displayName.toLowerCase().contains(query),
      ),
    );
  }

  GitBrowserState copyWith({
    Object? sessionId = _keep,
    Object? capabilities = _keep,
    Object? repository = _keep,
    List<GitBranch>? branches,
    String? branchQuery,
    List<GitBranch>? selectedBranches,
    List<GitCommitSummary>? commits,
    Object? snapshotId = _keep,
    Object? graphNextCursor = _keep,
    Object? graphPrevCursor = _keep,
    Object? graphFocusOid = _keep,
    Object? graphPageStart = _keep,
    bool? graphAll,
    Object? commit = _keep,
    Object? worktree = _keep,
    bool? loadingWorktree,
    bool? worktreeStale,
    Object? worktreeError = _keep,
    Object? preview = _keep,
    bool? loadingPreview,
    Object? previewError = _keep,
    bool? loading,
    bool? loadingGraph,
    bool? loadingGraphPage,
    bool? loadingFilesPage,
    bool? stale,
    Object? error = _keep,
    GitGraphBranchLimit? branchLimit,
    bool? graphTimedOut,
    bool? graphPageTimedOut,
    bool? graphPageTimedOutNewer,
  }) => GitBrowserState(
    sessionId: identical(sessionId, _keep)
        ? this.sessionId
        : sessionId as String?,
    capabilities: identical(capabilities, _keep)
        ? this.capabilities
        : capabilities as GitReadCapabilities?,
    repository: identical(repository, _keep)
        ? this.repository
        : repository as GitRepository?,
    branches: branches == null ? this.branches : UnmodifiableListView(branches),
    branchQuery: branchQuery ?? this.branchQuery,
    selectedBranches: selectedBranches == null
        ? this.selectedBranches
        : UnmodifiableListView(selectedBranches),
    commits: commits == null ? this.commits : UnmodifiableListView(commits),
    snapshotId: identical(snapshotId, _keep)
        ? this.snapshotId
        : snapshotId as String?,
    graphNextCursor: identical(graphNextCursor, _keep)
        ? this.graphNextCursor
        : graphNextCursor as String?,
    graphPrevCursor: identical(graphPrevCursor, _keep)
        ? this.graphPrevCursor
        : graphPrevCursor as String?,
    graphFocusOid: identical(graphFocusOid, _keep)
        ? this.graphFocusOid
        : graphFocusOid as String?,
    graphPageStart: identical(graphPageStart, _keep)
        ? this.graphPageStart
        : graphPageStart as int?,
    graphAll: graphAll ?? this.graphAll,
    commit: identical(commit, _keep)
        ? this.commit
        : commit as GitCommitDetails?,
    worktree: identical(worktree, _keep)
        ? this.worktree
        : worktree as GitWorktreeSnapshot?,
    loadingWorktree: loadingWorktree ?? this.loadingWorktree,
    worktreeStale: worktreeStale ?? this.worktreeStale,
    worktreeError: identical(worktreeError, _keep)
        ? this.worktreeError
        : worktreeError as String?,
    preview: identical(preview, _keep)
        ? this.preview
        : preview as GitFilePreview?,
    loadingPreview: loadingPreview ?? this.loadingPreview,
    previewError: identical(previewError, _keep)
        ? this.previewError
        : previewError as String?,
    loading: loading ?? this.loading,
    loadingGraph: loadingGraph ?? this.loadingGraph,
    loadingGraphPage: loadingGraphPage ?? this.loadingGraphPage,
    loadingFilesPage: loadingFilesPage ?? this.loadingFilesPage,
    stale: stale ?? this.stale,
    error: identical(error, _keep) ? this.error : error as String?,
    branchLimit: branchLimit ?? this.branchLimit,
    graphTimedOut: graphTimedOut ?? this.graphTimedOut,
    graphPageTimedOut: graphPageTimedOut ?? this.graphPageTimedOut,
    graphPageTimedOutNewer:
        graphPageTimedOutNewer ?? this.graphPageTimedOutNewer,
  );
}

const _keep = Object();

class GitBrowserController extends ChangeNotifier {
  GitBrowserController(
    this._api, {
    this.graphPageSize = 16,
    this.filesPageSize = 100,
    GitGraphBranchLimit branchLimit = GitGraphBranchLimit.fallback,
    this.graphLoadTimeout = const Duration(seconds: 30),
  }) : _branchLimit = branchLimit; // ignore: prefer_initializing_formals

  final GitReadApi _api;
  final int graphPageSize;
  final int filesPageSize;

  /// issue #86：仅「不限」档生效的初始 graph 加载超时（测试可注入更短值）。
  final Duration graphLoadTimeout;

  GitGraphBranchLimit _branchLimit;
  Timer? _graphTimeoutTimer;
  GitBrowserState _state = const GitBrowserState();
  int _generation = 0;
  int _graphGeneration = 0;
  int _commitGeneration = 0;
  int _worktreeGeneration = 0;
  int _worktreeCheckGeneration = 0;
  int _previewGeneration = 0;
  Future<void>? _graphPageRequest;
  bool _graphPageWantedNewer = false;
  // issue #100：prev 预取先缓存，不立即前插；用户真实到顶才应用。
  GitGraphPage? _pendingPrevPage;
  String? _pendingPrevSnapshotId;
  String? _pendingPrevCursor;
  int _pendingPrevGeneration = -1;
  bool _prevPrefetchInFlight = false;
  Future<void>? _filesPageRequest;
  bool _disposed = false;

  GitBrowserState get state => _state;

  GitGraphBranchLimit get branchLimit => _branchLimit;

  /// task-28：可选 POST 能力（旧宿主/旧 fake 不实现 → GET）。
  GitGraphPostApi? get _postApi => _api is GitGraphPostApi ? _api as GitGraphPostApi : null;

  /// issue #93：可选全部分支能力（旧宿主/旧 fake 不实现 → 回退选择档）。
  GitGraphAllApi? get _allApi => _api is GitGraphAllApi ? _api as GitGraphAllApi : null;

  /// issue #93：不限档 + 宿主声明 graphAll → 真正的全部分支模式。
  bool get graphAllMode =>
      _branchLimit.isUnlimited &&
      (_state.capabilities?.graphAll ?? false) &&
      _allApi != null;

  int get graphAllPageSize =>
      _state.capabilities?.graphAllPageSize ?? graphPageSize;

  /// 宿主声明的 GET/POST tips 上限；capability 缺失按旧宿主 5/5。
  int get _graphGetMax =>
      _state.capabilities?.effectiveGraphTipsGetMax ?? 5;
  int get _graphMaxTips => _state.capabilities?.effectiveGraphTipsMax ?? 5;

  /// re-review P2-6：实际可选上限 = min(档位, host max)；不限 = host max。
  int get _effectiveTierCap => _branchLimit.isUnlimited
      ? _graphMaxTips
      : math.min(_branchLimit.max ?? _graphMaxTips, _graphMaxTips);

  /// 供 UI 使用的实际上限（状态文案/达上限 chip/点击拦截必须与 controller 一致）。
  int get effectiveSelectionCap => _effectiveTierCap;
  bool get _supportsGraphPost =>
      _state.capabilities?.supportsGraphPost == true;

  /// GET URL 预算：编码后的 tips JSON 超过 ~8KB 直接走 POST（避免 431/16KB URL 上限）。
  int _encodedTipsBytes(List<GitGraphTip> tips) =>
      Uri.encodeQueryComponent(
        jsonEncode([for (final tip in tips) tip.toJson()]),
      ).length;

  int get selectedGraphBranchCount => _state.selectedBranches.length;

  /// 只读 Git API：sheet 里的文件历史等附加视图复用同一注入实现（测试可替换）。
  GitReadApi get readApi => _api;

  @override
  void dispose() {
    _disposed = true;
    _graphTimeoutTimer?.cancel();
    _graphTimeoutTimer = null;
    _generation++;
    _graphGeneration++;
    _commitGeneration++;
    _worktreeGeneration++;
    _worktreeCheckGeneration++;
    _previewGeneration++;
    super.dispose();
  }

  void _emit(GitBrowserState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  void _cancelGraphTimeout() {
    _graphTimeoutTimer?.cancel();
    _graphTimeoutTimer = null;
  }

  /// issue #86：仅「不限」档为初始 graph 请求装 30s 超时；超时即作废本次 generation，
  /// 迟到响应由 `_loadGraph` 的 generation 检查丢弃。
  void _armGraphTimeout(int generation, int graphGeneration) {
    _cancelGraphTimeout();
    if (!_branchLimit.isUnlimited) return;
    _graphTimeoutTimer = Timer(graphLoadTimeout, () {
      _graphTimeoutTimer = null;
      if (_disposed ||
          generation != _generation ||
          graphGeneration != _graphGeneration) {
        return;
      }
      _graphGeneration++; // 丢弃本请求的迟到响应
      _emit(
        _state.copyWith(
          loadingGraph: false,
          loadingGraphPage: false,
          graphTimedOut: true,
          error: null,
        ),
      );
    });
  }

  /// issue #86：切换三档上限——升档保留选择，降档保留前 N 个；返回被裁剪的数量。
  ///
  /// P2-2：选择集与上限**同步原子更新**，graph 加载异步发起（不等待网络）；
  /// 旧请求由 `_graphGeneration` 作废，迟到响应不回写。
  int setBranchLimit(GitGraphBranchLimit limit) {
    // task-28：旧宿主（capability 已解析且无 POST graphTips）不允许升到 10/不限。
    // capability 还没加载时不做判断——由 `_loadSession` 在解析后 clamp。
    final caps = _state.capabilities;
    if (caps != null && !caps.supportsGraphPost &&
        limit != GitGraphBranchLimit.five) {
      limit = GitGraphBranchLimit.five;
    }
    if (limit == _branchLimit) return 0;
    _branchLimit = limit;
    final hostMax = _graphMaxTips;
    final cap = limit.isUnlimited
        ? hostMax
        : math.min(limit.max ?? hostMax, hostMax);
    final selected = [..._state.selectedBranches];
    final trimmed =
        selected.length <= cap ? 0 : selected.length - cap;
    if (trimmed > 0) selected.removeRange(cap, selected.length);
    _graphGeneration++; // 旧请求/旧超时作废
    _cancelGraphTimeout();
    _graphPageRequest = null;
    _emit(
      _state.copyWith(
        branchLimit: limit,
        selectedBranches: selected,
        commits: const [],
        snapshotId: null,
        graphNextCursor: null,
        graphPrevCursor: null,
        graphFocusOid: null,
        graphPageStart: null,
        graphAll: false,
        loadingGraph: selected.isNotEmpty,
        loadingGraphPage: false,
        graphTimedOut: false,
        stale: false,
        error: null,
      ),
    );
    if (selected.isNotEmpty && _state.repository != null) {
      unawaited(_reloadGraphAfterSelectionChange());
    }
    return trimmed;
  }

  /// issue #86：重试一次 graph（超时面板「重试」）。
  Future<void> retryGraphLoad() async {
    if (_state.sessionId == null || _state.repository == null) return;
    // issue #95：all 模式重试必须回到 all=true + focus 当前分支，绝不回退选择集。
    if (graphAllMode) {
      await openAllGraph(focus: _state.repository?.currentBranch);
      return;
    }
    if (_state.selectedBranches.isEmpty) return;
    final graphGeneration = ++_graphGeneration;
    _cancelGraphTimeout();
    _emit(
      _state.copyWith(
        commits: const [],
        snapshotId: null,
        graphNextCursor: null,
        graphPrevCursor: null,
        graphFocusOid: null,
        graphPageStart: null,
        graphAll: false,
        loadingGraph: true,
        graphTimedOut: false,
        graphPageTimedOut: false,
        stale: false,
        error: null,
      ),
    );
    await _loadGraph(
      generation: _generation,
      graphGeneration: graphGeneration,
      append: false,
    );
  }

  Future<void> _reloadGraphAfterSelectionChange() async {
    final graphGeneration = ++_graphGeneration;
    _cancelGraphTimeout();
    _emit(
      _state.copyWith(
        loadingGraph: true,
        graphTimedOut: false,
        graphPageTimedOut: false,
        stale: false,
        error: null,
      ),
    );
    await _loadGraph(
      generation: _generation,
      graphGeneration: graphGeneration,
      append: false,
    );
  }

  /// issue #86：「不限」档全选（**union**）——把当前搜索结果中未选的分支加入现有选择，
  /// 搜索范围外已选分支保留；max 截断。
  ///
  /// re-review P2-5：选择与 toast 数据**同步**返回并立即生效，graph 加载异步发起
  /// （慢网络不阻塞反馈）。返回 `added`（已加入）与 `skipped`（超上限/未纳入）。
  ({int added, int skipped}) selectGraphBranches(List<GitBranch> branches) {
    if (!_branchLimit.isUnlimited || _state.repository == null) {
      return (added: 0, skipped: 0);
    }
    final known = {for (final branch in _state.selectedBranches) branch.name};
    final candidates = <GitBranch>[
      for (final branch in branches)
        if (known.add(branch.name)) branch,
    ];
    final room = _effectiveTierCap - _state.selectedBranches.length;
    final added = room <= 0
        ? const <GitBranch>[]
        : candidates.take(room).toList(growable: false);
    final skipped = candidates.length - added.length;
    if (added.isEmpty) return (added: 0, skipped: skipped);
    final selected = [..._state.selectedBranches, ...added];
    _graphGeneration++;
    _cancelGraphTimeout();
    _graphPageRequest = null;
    _commitGeneration++;
    _emit(
      _state.copyWith(
        selectedBranches: selected,
        commits: const [],
        snapshotId: null,
        graphNextCursor: null,
        graphPrevCursor: null,
        graphFocusOid: null,
        graphPageStart: null,
        graphAll: false,
        commit: null,
        loadingGraph: true,
        graphTimedOut: false,
        graphPageTimedOut: false,
        stale: false,
        error: null,
      ),
    );
    unawaited(_loadGraph(
      generation: _generation,
      graphGeneration: _graphGeneration,
      append: false,
    ));
    return (added: added.length, skipped: skipped);
  }

  /// issue #86：「不限」档清空选择（graph 区域显示「请选择分支」占位）。
  void clearGraphBranches() {
    if (!_branchLimit.isUnlimited) return;
    _graphGeneration++;
    _commitGeneration++;
    _cancelGraphTimeout();
    _graphPageRequest = null;
    _emit(
      _state.copyWith(
        selectedBranches: const [],
        commits: const [],
        snapshotId: null,
        graphNextCursor: null,
        graphPrevCursor: null,
        graphFocusOid: null,
        graphPageStart: null,
        graphAll: false,
        commit: null,
        loadingGraph: false,
        loadingGraphPage: false,
        graphTimedOut: false,
        graphPageTimedOut: false,
        stale: false,
        error: null,
      ),
    );
  }

  Future<void> open(String sessionId) async {
    final generation = ++_generation;
    _graphGeneration++;
    _commitGeneration++;
    _worktreeGeneration++;
    _worktreeCheckGeneration++;
    _previewGeneration++;
    _graphPageRequest = null;
    _filesPageRequest = null;
    _cancelGraphTimeout();
    _emit(
      GitBrowserState(
        sessionId: sessionId,
        loading: true,
        branchLimit: _branchLimit,
      ),
    );
    await _loadSession(sessionId, generation, preserveSelection: false);
  }

  Future<void> refresh() async {
    final sessionId = _state.sessionId;
    if (sessionId == null) return;
    final generation = ++_generation;
    _graphGeneration++;
    _commitGeneration++;
    _worktreeGeneration++;
    _worktreeCheckGeneration++;
    _previewGeneration++;
    _graphPageRequest = null;
    _filesPageRequest = null;
    _cancelGraphTimeout();
    _emit(
      _state.copyWith(
        loading: true,
        loadingGraph: false,
        loadingGraphPage: false,
        loadingFilesPage: false,
        loadingWorktree: false,
        loadingPreview: false,
        graphTimedOut: false,
        error: null,
      ),
    );
    await _loadSession(sessionId, generation, preserveSelection: true);
  }

  Future<void> _loadSession(
    String sessionId,
    int generation, {
    required bool preserveSelection,
  }) async {
    try {
      final capabilities = await _api.capabilities(sessionId);
      if (generation != _generation) return;
      if (!capabilities.available) {
        _emit(
          preserveSelection
              ? _state.copyWith(
                  capabilities: capabilities,
                  loading: false,
                  error: capabilities.reason,
                )
              : _state.copyWith(
                  capabilities: capabilities,
                  repository: null,
                  branches: const [],
                  selectedBranches: const [],
                  loading: false,
                  error: capabilities.reason,
                ),
        );
        return;
      }
      final repository = await _api.repository(sessionId);
      if (generation != _generation) return;
      final incoming = await _api.branches(sessionId, repository.repositoryId);
      if (generation != _generation) return;
      final sorted = _sortBranches(incoming);
      final oldNames = _state.selectedBranches
          .map((branch) => branch.name)
          .toList();
      List<GitBranch> selected;
      var selectionMissing = false;
      if (preserveSelection && oldNames.isNotEmpty) {
        selected = [
          for (final name in oldNames)
            ...sorted.where((branch) => branch.name == name),
        ];
        selectionMissing = selected.length != oldNames.length;
        if (selectionMissing) selected = const [];
      } else {
        final fallback = _defaultBranch(repository, sorted);
        selected = fallback == null ? const [] : [fallback];
      }
      // task-28：旧宿主无 graphTips（不支持 POST）→ 10/不限回退 5（一次性 clamp）。
      if (!capabilities.supportsGraphPost &&
          _branchLimit != GitGraphBranchLimit.five) {
        _branchLimit = GitGraphBranchLimit.five;
      }
      // re-review P2-6：实际上限 = min(档位, host max)；不限 = host max。
      final hostMax = capabilities.effectiveGraphTipsMax;
      final limit = _branchLimit.isUnlimited
          ? hostMax
          : math.min(_branchLimit.max ?? hostMax, hostMax);
      if (selected.length > limit) {
        selected = selected.sublist(0, limit);
      }
      _emit(
        _state.copyWith(
          capabilities: capabilities,
          repository: repository,
          branches: sorted,
          branchLimit: _branchLimit,
          selectedBranches: selected,
          commits: selectionMissing ? const [] : null,
          snapshotId: selectionMissing ? null : _keep,
          graphNextCursor: selectionMissing ? null : _keep,
          commit: selectionMissing ? null : _keep,
          loading: false,
          loadingGraph: preserveSelection && selected.isNotEmpty,
          stale: selectionMissing ? false : _state.stale,
          error: selectionMissing ? 'git-ref-not-found' : null,
        ),
      );
      if (preserveSelection && selected.isNotEmpty) {
        final graphGeneration = ++_graphGeneration;
        await _loadGraph(
          generation: generation,
          graphGeneration: graphGeneration,
          append: false,
        );
      }
    } catch (error) {
      if (generation != _generation) return;
      _emit(_state.copyWith(loading: false, error: error.toString()));
    }
  }

  List<GitBranch> _sortBranches(List<GitBranch> branches) {
    final current = branches.where(
      (branch) => branch.isLocal && branch.current,
    );
    final locals = branches.where(
      (branch) => branch.isLocal && !branch.current,
    );
    final remotes = branches.where((branch) => branch.isRemote);
    final other = branches.where(
      (branch) => !branch.isLocal && !branch.isRemote,
    );
    return List.unmodifiable([...current, ...locals, ...remotes, ...other]);
  }

  GitBranch? _defaultBranch(
    GitRepository repository,
    List<GitBranch> branches,
  ) {
    for (final branch in branches) {
      if (branch.isLocal && branch.current) return branch;
    }
    for (final branch in branches) {
      if (branch.isLocal && branch.oid == repository.headOid) return branch;
    }
    for (final branch in branches) {
      if (branch.isLocal) return branch;
    }
    for (final branch in branches) {
      if (branch.isRemote) return branch;
    }
    return null;
  }

  void setBranchQuery(String value) {
    if (value == _state.branchQuery) return;
    _emit(_state.copyWith(branchQuery: value));
  }

  Future<void> openBranch(GitBranch branch) async {
    if (_state.repository == null || _state.sessionId == null) return;
    final graphGeneration = ++_graphGeneration;
    _graphPageRequest = null;
    _commitGeneration++;
    _filesPageRequest = null;
    _emit(
      _state.copyWith(
        selectedBranches: [branch],
        commits: const [],
        snapshotId: null,
        graphNextCursor: null,
        graphPrevCursor: null,
        graphFocusOid: null,
        graphPageStart: null,
        graphAll: false,
        commit: null,
        loadingGraph: true,
        graphTimedOut: false,
        graphPageTimedOut: false,
        stale: false,
        error: null,
      ),
    );
    await _loadGraph(
      generation: _generation,
      graphGeneration: graphGeneration,
      append: false,
    );
  }

  Future<bool> toggleGraphBranch(GitBranch branch) async {
    final selected = [..._state.selectedBranches];
    final index = selected.indexWhere((item) => item.name == branch.name);
    if (index >= 0) {
      // issue #86 P2-3：5/10 至少保留 1 个；不限档允许取消最后一项 → 0 选择空态。
      if (selected.length == 1) {
        if (!_branchLimit.isUnlimited) return false;
        _graphGeneration++;
        _commitGeneration++;
        _cancelGraphTimeout();
        _graphPageRequest = null;
        _emit(
          _state.copyWith(
            selectedBranches: const [],
            commits: const [],
            snapshotId: null,
            graphNextCursor: null,
            graphPrevCursor: null,
            graphFocusOid: null,
            graphPageStart: null,
            graphAll: false,
            commit: null,
            loadingGraph: false,
            loadingGraphPage: false,
            graphTimedOut: false,
            graphPageTimedOut: false,
            stale: false,
            error: null,
          ),
        );
        return true;
      }
      selected.removeAt(index);
    } else {
      if (selected.length >= _effectiveTierCap) return false;
      selected.add(branch);
    }
    final graphGeneration = ++_graphGeneration;
    _graphPageRequest = null;
    _commitGeneration++;
    _filesPageRequest = null;
    _emit(
      _state.copyWith(
        selectedBranches: selected,
        commits: const [],
        snapshotId: null,
        graphNextCursor: null,
        graphPrevCursor: null,
        graphFocusOid: null,
        graphPageStart: null,
        graphAll: false,
        commit: null,
        loadingGraph: true,
        graphTimedOut: false,
        graphPageTimedOut: false,
        stale: false,
        error: null,
      ),
    );
    await _loadGraph(
      generation: _generation,
      graphGeneration: graphGeneration,
      append: false,
    );
    return true;
  }

  Future<void> _loadGraph({
    required int generation,
    required int graphGeneration,
    required bool append,
  }) async {
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    final selected = _state.selectedBranches;
    final snapshotId = append ? _state.snapshotId : null;
    final cursor = append ? _state.graphNextCursor : null;
    if (sessionId == null || repository == null) return;
    if (selected.isEmpty && !append) return;
    _cancelGraphTimeout();
    final tips = selected
        .map((branch) => GitGraphTip(name: branch.name, tipOid: branch.oid))
        .toList(growable: false);
    // task-28：>服务端 max 的事前阻止（UI 已阻止；controller 兜底不发请求）。
    if (!append && tips.length > _graphMaxTips) {
      _emit(
        _state.copyWith(
          loadingGraph: false,
          loadingGraphPage: false,
          error: 'graph-too-many-tips',
        ),
      );
      return;
    }
    if (!append) {
      // issue #86：仅「不限」档启用 30s 超时；5/10 沿用普通加载/失败处理。
      _armGraphTimeout(generation, graphGeneration);
    }
    final timeout = _branchLimit.isUnlimited
        ? const Duration(seconds: 35)
        : const Duration(seconds: 15);
    final postApi = _postApi;
    final supportsPost = _supportsGraphPost && postApi != null;
    // 续页只带 snapshotId/cursor（服务端忽略 tips）；初始按 GET/POST 阈值与 URL 预算选择。
    final requestTips = append ? const <GitGraphTip>[] : tips;
    final usePost = supportsPost &&
        (append
            ? selected.length > _graphGetMax
            : tips.length > _graphGetMax || _encodedTipsBytes(tips) > 8192);
    Future<GitGraphPage> fetch({required bool post}) {
      if (post) {
        return postApi!.graphPost(
          sessionId,
          repository.repositoryId,
          requestTips,
          snapshotId: snapshotId,
          cursor: cursor,
          limit: graphPageSize,
          timeout: timeout,
        );
      }
      return _api.graph(
        sessionId,
        repository.repositoryId,
        requestTips,
        snapshotId: snapshotId,
        cursor: cursor,
        limit: graphPageSize,
        timeout: timeout,
      );
    }

    try {
      GitGraphPage page;
      try {
        page = await fetch(post: usePost);
      } catch (error) {
        // GET URL 超长（Node 431）/ 网关 414：一次性回退 POST（task-28）。
        final urlTooLarge = error is ApiException &&
            (error.status == 431 ||
                error.status == 414 ||
                error.code == 'payload-too-large');
        if (!usePost && supportsPost && urlTooLarge) {
          page = await fetch(post: true);
        } else {
          rethrow;
        }
      }
      if (generation != _generation || graphGeneration != _graphGeneration) {
        return;
      }
      _cancelGraphTimeout();
      final commits = append
          ? _appendUnique(_state.commits, page.commits, (commit) => commit.oid)
          : page.commits;
      _emit(
        _state.copyWith(
          commits: commits,
          snapshotId: page.snapshotId,
          graphNextCursor: page.nextCursor,
          loadingGraph: false,
          loadingGraphPage: false,
          graphTimedOut: false,
          graphPageTimedOut: false,
          graphPageTimedOutNewer: false,
          stale: false,
          error: null,
        ),
      );
    } catch (error) {
      if (generation != _generation || graphGeneration != _graphGeneration) {
        return;
      }
      _cancelGraphTimeout();
      final apiError = error is ApiException ? error : null;
      final code = apiError?.code;
      final graphStale = code == 'graph-stale';
      final timedOut = apiError?.status == 504 || code == 'graph-timeout';
      // re-review P1-3：分页 append 超时——保留已加载 commits，页级错误/重试，
      // 不置 global graphTimedOut、不替换整图。
      if (append && timedOut) {
        _emit(
          _state.copyWith(
            loadingGraph: false,
            loadingGraphPage: false,
            graphPageTimedOut: true,
            graphPageTimedOutNewer: false,
            loading: false,
            stale: _state.stale,
            error: null,
          ),
        );
        return;
      }
      if (timedOut && _branchLimit.isUnlimited) {
        // 服务端 25s deadline（504）与客户端 30s 兜底同一超时三动作面板。
        _emit(
          _state.copyWith(
            loadingGraph: false,
            loadingGraphPage: false,
            graphTimedOut: true,
            error: null,
          ),
        );
        return;
      }
      _emit(
        _state.copyWith(
          loadingGraph: false,
          loadingGraphPage: false,
          graphPageTimedOut: false,
          graphPageTimedOutNewer: false,
          stale: graphStale ? true : _state.stale,
          error: graphStale ? 'graph-stale' : (code ?? error.toString()),
        ),
      );
    }
  }

  /// re-review P1-3：分页超时后的页级重试（不重载整图）。
  Future<void> retryGraphPage() async {
    if (graphAllMode) {
      if (_graphPageWantedNewer ? _state.graphPrevCursor == null : _state.graphNextCursor == null) return;
      _graphPageRequest = null;
      _emit(_state.copyWith(
        graphPageTimedOut: false,
        graphPageTimedOutNewer: false,
        error: null,
      ));
      await (_graphPageWantedNewer ? loadPrevGraphPage() : loadNextGraphPage());
      return;
    }
    if (_state.graphNextCursor == null) return;
    _graphPageRequest = null;
    _emit(_state.copyWith(
      graphPageTimedOut: false,
      graphPageTimedOutNewer: false,
      error: null,
    ));
    await loadNextGraphPage();
  }

  /// issue #93：加载更**新**一页（全部分支模式向左/上拖）。
  Future<void> loadPrevGraphPage() {
    if (_pendingPrevPage != null) return applyPendingPrevGraphPage();
    if (_graphPageRequest != null) return _graphPageRequest!;
    if (!graphAllMode ||
        _state.stale ||
        _state.graphPrevCursor == null ||
        _state.loadingGraphPage ||
        _state.graphPageTimedOut) {
      return Future.value();
    }
    return _requestAllGraphPage(newer: true);
  }

  Future<void> loadNextGraphPage() {
    if (_graphPageRequest != null) return _graphPageRequest!;
    if (graphAllMode) {
      if (_state.stale ||
          _state.graphNextCursor == null ||
          _state.loadingGraphPage ||
          _state.graphPageTimedOut) {
        return Future.value();
      }
      return _requestAllGraphPage(newer: false);
    }
    if (_state.stale ||
        _state.graphNextCursor == null ||
        _state.loadingGraphPage ||
        // 页级超时后等用户点重试，不因滚动自动反复重试。
        _state.graphPageTimedOut) {
      return Future.value();
    }
    final generation = _generation;
    final graphGeneration = _graphGeneration;
    _emit(_state.copyWith(
      loadingGraphPage: true,
      graphPageTimedOut: false,
      error: null,
    ));
    late final Future<void> request;
    request =
        _loadGraph(
          generation: generation,
          graphGeneration: graphGeneration,
          append: true,
        ).whenComplete(() {
          if (identical(_graphPageRequest, request)) _graphPageRequest = null;
          if (generation == _generation &&
              graphGeneration == _graphGeneration &&
              _state.loadingGraphPage) {
            _emit(_state.copyWith(loadingGraphPage: false));
          }
        });
    _graphPageRequest = request;
    return request;
  }

  void _resetPendingPrev() {
    _pendingPrevPage = null;
    _pendingPrevSnapshotId = null;
    _pendingPrevCursor = null;
    _pendingPrevGeneration = -1;
    _prevPrefetchInFlight = false;
  }

  /// issue #100：是否有已缓存、等待用户主动到顶再应用的更新页。
  bool get hasPendingPrevGraphPage => _pendingPrevPage != null;

  /// issue #100：后台预取更新页——只缓存，不 emit commits/不改滚动锚点。
  Future<void> prefetchPrevGraphPage() async {
    final api = _allApi;
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    final cursor = _state.graphPrevCursor;
    final snapshotId = _state.snapshotId;
    if (api == null ||
        sessionId == null ||
        repository == null ||
        cursor == null ||
        snapshotId == null ||
        !graphAllMode ||
        _state.stale ||
        _state.loadingGraphPage ||
        _state.graphPageTimedOut ||
        _prevPrefetchInFlight ||
        _pendingPrevPage != null) {
      return;
    }
    final generation = _generation;
    final graphGeneration = _graphGeneration;
    _prevPrefetchInFlight = true;
    try {
      final page = await api.graphAll(
        sessionId,
        repository.repositoryId,
        all: true,
        snapshotId: snapshotId,
        cursor: cursor,
        limit: graphAllPageSize,
        timeout: const Duration(seconds: 35),
      );
      if (generation != _generation ||
          graphGeneration != _graphGeneration ||
          _state.snapshotId != snapshotId ||
          _state.graphPrevCursor != cursor) {
        return;
      }
      _pendingPrevPage = page;
      _pendingPrevSnapshotId = snapshotId;
      _pendingPrevCursor = cursor;
      _pendingPrevGeneration = graphGeneration;
    } catch (_) {
      // 后台预取失败静默；用户真正到顶时会重新尝试。
    } finally {
      _prevPrefetchInFlight = false;
    }
  }

  /// issue #100：应用缓存页；只由用户真实到顶触发（UI 负责时机）。
  Future<void> applyPendingPrevGraphPage() async {
    final page = _pendingPrevPage;
    if (page == null) return;
    final valid = _pendingPrevGeneration == _graphGeneration &&
        _pendingPrevSnapshotId == _state.snapshotId &&
        _pendingPrevCursor == _state.graphPrevCursor &&
        !_state.stale &&
        !_state.loadingGraphPage;
    _pendingPrevPage = null;
    _pendingPrevSnapshotId = null;
    _pendingPrevCursor = null;
    _pendingPrevGeneration = -1;
    if (!valid) return;
    _applyAllGraphPage(page, initial: false, newer: true);
  }

  /// issue #93：打开全部分支图（首页或 focus 页）。
  Future<void> openAllGraph({String? focus}) async {
    _resetPendingPrev();
    if (!graphAllMode) return;
    final generation = _generation;
    final graphGeneration = ++_graphGeneration;
    _graphPageRequest = null;
    _commitGeneration++;
    _filesPageRequest = null;
    _emit(_state.copyWith(
      commits: const [],
      snapshotId: null,
      graphNextCursor: null,
      graphPrevCursor: null,
      graphFocusOid: null,
      graphPageStart: null,
      graphAll: true,
      commit: null,
      loadingGraph: true,
      loadingGraphPage: false,
      graphTimedOut: false,
      graphPageTimedOut: false,
      graphPageTimedOutNewer: false,
      stale: false,
      error: null,
    ));
    _armGraphTimeout(generation, graphGeneration);
    await _loadAllGraphPage(
      generation: generation,
      graphGeneration: graphGeneration,
      initial: true,
      newer: false,
      focus: focus ?? _state.repository?.currentBranch,
    );
  }

  Future<void> _requestAllGraphPage({required bool newer}) {
    final generation = _generation;
    final graphGeneration = _graphGeneration;
    _graphPageWantedNewer = newer;
    _emit(_state.copyWith(
      loadingGraphPage: true,
      graphPageTimedOut: false,
      error: null,
    ));
    late final Future<void> request;
    request = _loadAllGraphPage(
      generation: generation,
      graphGeneration: graphGeneration,
      initial: false,
      newer: newer,
    ).whenComplete(() {
      if (identical(_graphPageRequest, request)) _graphPageRequest = null;
      if (generation == _generation &&
          graphGeneration == _graphGeneration &&
          _state.loadingGraphPage) {
        _emit(_state.copyWith(loadingGraphPage: false));
      }
    });
    _graphPageRequest = request;
    return request;
  }

  void _applyAllGraphPage(
    GitGraphPage page, {
    required bool initial,
    required bool newer,
  }) {
    if (initial) _resetPendingPrev();
    final existing = _state.commits;
    final List<GitCommitSummary> commits;
    if (initial) {
      commits = page.commits;
    } else if (newer) {
      final seen = {for (final commit in existing) commit.oid};
      commits = [
        ...page.commits.where((commit) => seen.add(commit.oid)),
        ...existing,
      ];
    } else {
      final seen = {for (final commit in existing) commit.oid};
      commits = [
        ...existing,
        ...page.commits.where((commit) => seen.add(commit.oid)),
      ];
    }
    _emit(_state.copyWith(
      commits: commits,
      snapshotId: page.snapshotId,
      // issue #95（#93 review）：older 页只更新 next、newer 页只更新 prev；
      // 不能用响应里的另一侧 cursor 覆盖当前浏览方向已加载页的锚点。
      graphNextCursor: initial
          ? page.nextCursor
          : (newer ? _state.graphNextCursor : page.nextCursor),
      graphPrevCursor: initial
          ? page.prevCursor
          : (newer ? page.prevCursor : _state.graphPrevCursor),
      graphFocusOid: initial ? page.focusOid : _state.graphFocusOid,
      graphPageStart: initial ? page.pageStart : _state.graphPageStart,
      graphAll: true,
      loadingGraph: false,
      loadingGraphPage: false,
      graphTimedOut: false,
      graphPageTimedOut: false,
      graphPageTimedOutNewer: false,
      stale: false,
      error: null,
    ));
  }

  Future<void> _loadAllGraphPage({
    required int generation,
    required int graphGeneration,
    required bool initial,
    required bool newer,
    String? focus,
  }) async {
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    final api = _allApi;
    if (sessionId == null || repository == null || api == null) return;
    final cursor = initial
        ? null
        : (newer ? _state.graphPrevCursor : _state.graphNextCursor);
    final snapshotId = initial ? null : _state.snapshotId;
    try {
      final page = await api.graphAll(
        sessionId,
        repository.repositoryId,
        all: true,
        focus: initial ? focus : null,
        snapshotId: snapshotId,
        cursor: cursor,
        limit: graphAllPageSize,
        timeout: const Duration(seconds: 35),
      );
      if (generation != _generation || graphGeneration != _graphGeneration) {
        return;
      }
      _cancelGraphTimeout();
      _applyAllGraphPage(page, initial: initial, newer: newer);
    } catch (error) {
      if (generation != _generation || graphGeneration != _graphGeneration) {
        return;
      }
      _cancelGraphTimeout();
      final apiError = error is ApiException ? error : null;
      final code = apiError?.code;
      final timedOut = apiError?.status == 504 || code == 'graph-timeout';
      if (!initial && timedOut) {
        _emit(_state.copyWith(
          loadingGraph: false,
          loadingGraphPage: false,
          graphPageTimedOut: true,
          graphPageTimedOutNewer: newer,
          error: null,
        ));
        return;
      }
      _emit(_state.copyWith(
        loadingGraph: false,
        loadingGraphPage: false,
        graphTimedOut: initial && timedOut,
        graphPageTimedOut: false,
        graphPageTimedOutNewer: false,
        stale: code == 'graph-stale' ? true : _state.stale,
        error: code == 'graph-stale' ? 'graph-stale' : (code ?? error.toString()),
      ));
    }
  }

  Future<void> openCommit(String oid) async {
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    if (sessionId == null || repository == null) return;
    final generation = _generation;
    final commitGeneration = ++_commitGeneration;
    _filesPageRequest = null;
    try {
      final commit = await _api.commitDetails(
        sessionId,
        repository.repositoryId,
        oid,
        filesLimit: filesPageSize,
      );
      if (generation != _generation || commitGeneration != _commitGeneration) {
        return;
      }
      _emit(_state.copyWith(commit: commit, error: null));
    } catch (error) {
      if (generation != _generation || commitGeneration != _commitGeneration) {
        return;
      }
      _emit(_state.copyWith(error: error.toString()));
    }
  }

  Future<void> loadWorktree({bool refresh = false}) async {
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    if (sessionId == null || repository == null || _state.loadingWorktree) {
      return;
    }
    if (!refresh && _state.worktree != null) return;
    if (refresh) {
      _worktreeCheckGeneration++;
      _previewGeneration++;
    }
    final generation = ++_worktreeGeneration;
    _emit(
      _state.copyWith(
        loadingWorktree: true,
        worktreeError: null,
        loadingPreview: refresh ? false : null,
        previewError: refresh ? null : _keep,
      ),
    );
    try {
      final snapshot = await _api.worktree(sessionId, repository.repositoryId);
      if (generation != _worktreeGeneration ||
          _state.repository?.repositoryId != snapshot.repositoryId) {
        return;
      }
      _emit(
        _state.copyWith(
          worktree: snapshot,
          loadingWorktree: false,
          worktreeStale: false,
          worktreeError: null,
        ),
      );
    } catch (error) {
      if (generation != _worktreeGeneration) return;
      final isStale = error is ApiException && error.code == 'graph-stale';
      _emit(
        _state.copyWith(
          loadingWorktree: false,
          worktreeStale: isStale ? true : _state.worktreeStale,
          worktreeError: error.toString(),
        ),
      );
    }
  }

  Future<void> checkWorktreeFreshness() async {
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    final current = _state.worktree;
    if (sessionId == null ||
        repository == null ||
        current == null ||
        _state.worktreeStale) {
      return;
    }
    final generation = ++_worktreeCheckGeneration;
    try {
      final latest = await _api.worktree(sessionId, repository.repositoryId);
      if (generation != _worktreeCheckGeneration ||
          _state.repository?.repositoryId != latest.repositoryId) {
        return;
      }
      if (latest.snapshotId != current.snapshotId) markWorktreeStale();
    } catch (error) {
      if (generation == _worktreeCheckGeneration) {
        _emit(_state.copyWith(worktreeError: error.toString()));
      }
    }
  }

  Future<void> openPreview({
    required String kind,
    required String path,
    String? oid,
  }) async {
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    if (sessionId == null || repository == null) return;
    final worktreeKind = kind != 'commit';
    final snapshot = _state.worktree;
    if (worktreeKind && (snapshot == null || _state.worktreeStale)) return;
    final generation = ++_previewGeneration;
    _emit(
      _state.copyWith(loadingPreview: true, preview: null, previewError: null),
    );
    try {
      final preview = await _api.preview(
        sessionId,
        repository.repositoryId,
        kind: kind,
        path: path,
        snapshotId: worktreeKind ? snapshot!.snapshotId : null,
        oid: oid,
      );
      if (generation != _previewGeneration) return;
      _emit(
        _state.copyWith(
          preview: preview,
          loadingPreview: false,
          previewError: null,
        ),
      );
    } catch (error) {
      if (generation != _previewGeneration) return;
      final isStale = error is ApiException && error.code == 'graph-stale';
      _emit(
        _state.copyWith(
          loadingPreview: false,
          previewError: error.toString(),
          worktreeStale: worktreeKind && isStale ? true : _state.worktreeStale,
        ),
      );
    }
  }

  void closePreview() {
    _previewGeneration++;
    _emit(
      _state.copyWith(preview: null, loadingPreview: false, previewError: null),
    );
  }

  void markWorktreeStale() {
    // A change can arrive while a worktree load (including a refresh of an
    // already-stale snapshot) is pending. Its result predates the change.
    _worktreeGeneration++;
    _worktreeCheckGeneration++;
    if (_state.loadingPreview) _previewGeneration++;
    _emit(
      _state.copyWith(
        worktreeStale: true,
        loadingWorktree: false,
        loadingPreview: _state.loadingPreview ? false : null,
        previewError: _state.loadingPreview ? 'graph-stale' : null,
      ),
    );
  }

  Future<void> loadNextFilesPage() {
    if (_filesPageRequest != null) return _filesPageRequest!;
    final current = _state.commit;
    final sessionId = _state.sessionId;
    final repository = _state.repository;
    if (current == null ||
        current.filesNextCursor == null ||
        sessionId == null ||
        repository == null) {
      return Future.value();
    }
    final generation = _generation;
    final commitGeneration = _commitGeneration;
    _emit(_state.copyWith(loadingFilesPage: true));
    final request = _api
        .commitDetails(
          sessionId,
          repository.repositoryId,
          current.oid,
          filesCursor: current.filesNextCursor,
          filesLimit: filesPageSize,
        )
        .then((page) {
          if (generation != _generation ||
              commitGeneration != _commitGeneration ||
              _state.commit?.oid != current.oid) {
            return;
          }
          final files = _appendUnique(current.files, page.files, _fileKey);
          _emit(
            _state.copyWith(
              commit: current.withFiles(files, page.filesNextCursor),
              loadingFilesPage: false,
              error: null,
            ),
          );
        })
        .catchError((Object error) {
          if (generation == _generation &&
              commitGeneration == _commitGeneration) {
            _emit(
              _state.copyWith(loadingFilesPage: false, error: error.toString()),
            );
          }
        })
        .whenComplete(() {
          _filesPageRequest = null;
          if (_state.loadingFilesPage) {
            _emit(_state.copyWith(loadingFilesPage: false));
          }
        });
    _filesPageRequest = request;
    return request;
  }

  String _fileKey(GitCommitFile file) =>
      '${file.status}\u0000${file.oldPath}\u0000${file.path}';

  List<T> _appendUnique<T>(
    List<T> first,
    List<T> second,
    Object Function(T) key,
  ) {
    final seen = first.map(key).toSet();
    return List.unmodifiable([
      ...first,
      for (final item in second)
        if (seen.add(key(item))) item,
    ]);
  }

  void markStale() {
    if (_state.stale) return;
    // A response already in flight belongs to the old tip-bound snapshot.
    _graphGeneration++;
    _emit(
      _state.copyWith(
        stale: true,
        loadingGraph: false,
        loadingGraphPage: false,
      ),
    );
  }
}
