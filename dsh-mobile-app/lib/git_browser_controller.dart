import 'dart:collection';

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
  final GitCommitDetails? commit;
  final bool loading;
  final bool loadingGraphPage;
  final bool loadingFilesPage;
  final bool stale;
  final String? error;

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
    this.commit,
    this.loading = false,
    this.loadingGraphPage = false,
    this.loadingFilesPage = false,
    this.stale = false,
    this.error,
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
    Object? commit = _keep,
    bool? loading,
    bool? loadingGraphPage,
    bool? loadingFilesPage,
    bool? stale,
    Object? error = _keep,
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
    commit: identical(commit, _keep)
        ? this.commit
        : commit as GitCommitDetails?,
    loading: loading ?? this.loading,
    loadingGraphPage: loadingGraphPage ?? this.loadingGraphPage,
    loadingFilesPage: loadingFilesPage ?? this.loadingFilesPage,
    stale: stale ?? this.stale,
    error: identical(error, _keep) ? this.error : error as String?,
  );
}

const _keep = Object();

class GitBrowserController extends ChangeNotifier {
  GitBrowserController(
    this._api, {
    this.graphPageSize = 100,
    this.filesPageSize = 100,
  });

  final GitReadApi _api;
  final int graphPageSize;
  final int filesPageSize;
  GitBrowserState _state = const GitBrowserState();
  int _generation = 0;
  int _graphGeneration = 0;
  int _commitGeneration = 0;
  Future<void>? _graphPageRequest;
  Future<void>? _filesPageRequest;
  bool _disposed = false;

  GitBrowserState get state => _state;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _graphGeneration++;
    _commitGeneration++;
    super.dispose();
  }

  void _emit(GitBrowserState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  Future<void> open(String sessionId) async {
    final generation = ++_generation;
    _graphGeneration++;
    _commitGeneration++;
    _graphPageRequest = null;
    _filesPageRequest = null;
    _emit(GitBrowserState(sessionId: sessionId, loading: true));
    await _loadSession(sessionId, generation, preserveSelection: false);
  }

  Future<void> refresh() async {
    final sessionId = _state.sessionId;
    if (sessionId == null) return;
    final generation = ++_generation;
    _graphGeneration++;
    _commitGeneration++;
    _graphPageRequest = null;
    _filesPageRequest = null;
    _emit(_state.copyWith(loading: true, loadingGraphPage: false, loadingFilesPage: false, error: null));
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
      _emit(
        _state.copyWith(
          capabilities: capabilities,
          repository: repository,
          branches: sorted,
          selectedBranches: selected,
          commits: selectionMissing ? const [] : null,
          snapshotId: selectionMissing ? null : _keep,
          graphNextCursor: selectionMissing ? null : _keep,
          commit: selectionMissing ? null : _keep,
          loading: false,
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
        commit: null,
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
      if (selected.length == 1) return false;
      selected.removeAt(index);
    } else {
      if (selected.length == 3) return false;
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
        commit: null,
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
    if (sessionId == null || repository == null || selected.isEmpty) return;
    try {
      final page = await _api.graph(
        sessionId,
        repository.repositoryId,
        selected
            .map((branch) => GitGraphTip(name: branch.name, tipOid: branch.oid))
            .toList(growable: false),
        snapshotId: snapshotId,
        cursor: cursor,
        limit: graphPageSize,
      );
      if (generation != _generation || graphGeneration != _graphGeneration) {
        return;
      }
      final commits = append
          ? _appendUnique(_state.commits, page.commits, (commit) => commit.oid)
          : page.commits;
      _emit(
        _state.copyWith(
          commits: commits,
          snapshotId: page.snapshotId,
          graphNextCursor: page.nextCursor,
          loadingGraphPage: false,
          stale: false,
          error: null,
        ),
      );
    } catch (error) {
      if (generation != _generation || graphGeneration != _graphGeneration) {
        return;
      }
      final graphStale = error is ApiException && error.code == 'graph-stale';
      _emit(
        _state.copyWith(
          loadingGraphPage: false,
          stale: graphStale ? true : _state.stale,
          error: graphStale ? 'graph-stale' : error.toString(),
        ),
      );
    }
  }

  Future<void> loadNextGraphPage() {
    if (_graphPageRequest != null) return _graphPageRequest!;
    if (_state.stale || _state.graphNextCursor == null || _state.loadingGraphPage) {
      return Future.value();
    }
    final generation = _generation;
    final graphGeneration = _graphGeneration;
    _emit(_state.copyWith(loadingGraphPage: true));
    late final Future<void> request;
    request = _loadGraph(
      generation: generation,
      graphGeneration: graphGeneration,
      append: true,
    ).whenComplete(() {
      if (identical(_graphPageRequest, request)) _graphPageRequest = null;
      if (generation == _generation && graphGeneration == _graphGeneration &&
          _state.loadingGraphPage) {
        _emit(_state.copyWith(loadingGraphPage: false));
      }
    });
    _graphPageRequest = request;
    return request;
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
    _emit(_state.copyWith(stale: true, loadingGraphPage: false));
  }
}
