import 'git_models.dart';

/// 调色板槽位数（issue #86：16 色；超过 16 个已选分支按槽位循环复用）。
const maxGraphColorSlots = 16;

/// The renderer shows at most this many selected-tip colors in a commit node.
const maxNodeColorSegments = maxGraphColorSlots;

class GraphContinuation {
  final int from;
  final int to;
  final int colorSlot;

  const GraphContinuation(this.from, this.to, this.colorSlot);
}

class GraphRow {
  final int lane;
  final int incomingColorSlot;

  /// Whether a newer child commit connects into this row's lane.
  final bool hasIncomingEdge;
  final int colorSlot;
  final List<int> parentLanes;
  final List<int> parentColorSlots;
  final List<int> tipColorSlots;
  final List<GraphContinuation> continuations;
  final bool merge;

  const GraphRow({
    required this.lane,
    required this.incomingColorSlot,
    required this.hasIncomingEdge,
    required this.colorSlot,
    required this.parentLanes,
    required this.parentColorSlots,
    required this.tipColorSlots,
    this.continuations = const [],
    this.merge = false,
  });
}

/// One unresolved topology line at the end of a laid-out page.
class GraphLane {
  final String oid;
  final int colorSlot;

  const GraphLane(this.oid, this.colorSlot);
}

/// Immutable continuation data for laying out the next page.
///
/// Passing this back to [layoutGraph] makes pagination append-only: rows from
/// earlier pages never need to be laid out again.
class GraphLayoutState {
  final List<GraphLane> lanes;
  final int nextColorSlot;
  final int laneCount;

  GraphLayoutState({
    List<GraphLane> lanes = const [],
    this.nextColorSlot = maxNodeColorSegments,
    this.laneCount = 1,
  }) : lanes = List.unmodifiable(lanes);
}

class GraphLayout {
  final List<GraphRow> rows;
  final int laneCount;
  final GraphLayoutState continuation;

  const GraphLayout(this.rows, this.laneCount, this.continuation);
}

List<int> selectedTipColorSlots(
  GitCommitSummary commit,
  List<GitBranch> selected,
) => <int>[
  // issue #86 P2-4：槽位按选择顺序 i % 16 循环；同一 tip 的多个已选分支各占一个
  // 槽位（与既有渲染一致），但不产生超过 16 的额外槽位。
  for (var i = 0; i < selected.length; i++)
    if (selected[i].oid == commit.oid) i % maxNodeColorSegments,
];

/// Lays out commits ordered child-before-parent.
///
/// Lanes model unresolved parent edges only. Branch selection affects initial
/// anchoring and colors, but it does not assign ownership of ancestry to a
/// branch. Supply [state] when appending a page.
GraphLayout layoutGraph(
  List<GitCommitSummary> commits,
  List<GitBranch> selected, {
  GraphLayoutState? state,
}) {
  final selectedSlots = <String, int>{};
  for (var i = 0; i < selected.length; i++) {
    selectedSlots.putIfAbsent(selected[i].oid, () => i % maxNodeColorSegments);
  }
  final incomingEdges = state == null
      ? <String>{}
      : state.lanes.map((lane) => lane.oid).toSet();

  late final List<String> lanes;
  late final List<int> colors;
  late int nextColor;
  var peakLaneCount = state?.laneCount ?? 1;

  if (state != null) {
    lanes = [for (final lane in state.lanes) lane.oid];
    colors = [for (final lane in state.lanes) lane.colorSlot];
    nextColor = state.nextColorSlot;
  } else {
    lanes = <String>[];
    colors = <int>[];
    nextColor = maxNodeColorSegments;

    final byOid = {for (final commit in commits) commit.oid: commit};
    bool reaches(String start, String target) {
      final pending = <String>[start];
      final seen = <String>{};
      while (pending.isNotEmpty) {
        final oid = pending.removeLast();
        if (!seen.add(oid)) continue;
        if (oid == target) return true;
        pending.addAll(byOid[oid]?.parents ?? const <String>[]);
      }
      return false;
    }

    final selectedOids = selectedSlots.keys.where(byOid.containsKey).toSet();
    // Do not reserve a second lane for a selected tip that is already an
    // ancestor of another selected tip. That would manufacture a branch where
    // the commit graph contains only a chain.
    final anchors = selectedOids.where(
      (oid) =>
          !selectedOids.any((other) => other != oid && reaches(other, oid)),
    );
    for (final branch in selected.take(maxNodeColorSegments)) {
      if (anchors.contains(branch.oid) && !lanes.contains(branch.oid)) {
        lanes.add(branch.oid);
        colors.add(selectedSlots[branch.oid]!);
      }
    }
    if (lanes.length > peakLaneCount) peakLaneCount = lanes.length;
  }

  final rows = <GraphRow>[];
  for (final commit in commits) {
    final hasIncomingEdge = incomingEdges.remove(commit.oid);
    final lanesConnectedBeforeRow = {...incomingEdges};
    var lane = lanes.indexOf(commit.oid);
    if (lane < 0) {
      // A commit not reached by an active parent edge starts a disconnected
      // component. Append it; never steal an existing topology lane.
      lane = lanes.length;
      lanes.add(commit.oid);
      colors.add(selectedSlots[commit.oid] ?? nextColor++);
    }
    if (lanes.length > peakLaneCount) peakLaneCount = lanes.length;

    final incoming = colors[lane];
    final outgoing = selectedSlots[commit.oid] ?? incoming;

    final afterLanes = <String>[...lanes]..removeAt(lane);
    final afterColors = <int>[...colors]..removeAt(lane);
    final parentLanes = <int>[];
    final parentColors = <int>[];

    for (var i = 0; i < commit.parents.length; i++) {
      final parent = commit.parents[i];
      if (!afterLanes.contains(parent)) {
        final parentLane = (lane + i).clamp(0, afterLanes.length);
        afterLanes.insert(parentLane, parent);
        afterColors.insert(parentLane, i == 0 ? outgoing : nextColor++);
      }
      incomingEdges.add(parent);
    }
    // Resolve indices only after every insertion: a later parent inserted
    // before an existing lane shifts its index in afterLanes.
    for (final parent in commit.parents) {
      final parentLane = afterLanes.indexOf(parent);
      parentLanes.add(parentLane);
      parentColors.add(afterColors[parentLane]);
    }

    final continuations = <GraphContinuation>[];
    for (var oldLane = 0; oldLane < lanes.length; oldLane++) {
      if (oldLane == lane) continue;
      final oldOid = lanes[oldLane];
      if (!lanesConnectedBeforeRow.contains(oldOid)) continue;
      final newLane = afterLanes.indexOf(oldOid);
      if (newLane >= 0) {
        continuations.add(GraphContinuation(oldLane, newLane, colors[oldLane]));
      }
    }

    rows.add(
      GraphRow(
        lane: lane,
        incomingColorSlot: incoming,
        hasIncomingEdge: hasIncomingEdge,
        colorSlot: outgoing,
        parentLanes: List.unmodifiable(parentLanes),
        parentColorSlots: List.unmodifiable(parentColors),
        tipColorSlots: List.unmodifiable(
          selectedTipColorSlots(commit, selected),
        ),
        continuations: List.unmodifiable(continuations),
        merge: commit.parents.toSet().length > 1,
      ),
    );

    lanes
      ..clear()
      ..addAll(afterLanes);
    colors
      ..clear()
      ..addAll(afterColors);
    if (lanes.length > peakLaneCount) peakLaneCount = lanes.length;
  }

  final continuation = GraphLayoutState(
    lanes: [
      for (var i = 0; i < lanes.length; i++) GraphLane(lanes[i], colors[i]),
    ],
    nextColorSlot: nextColor,
    laneCount: peakLaneCount,
  );
  return GraphLayout(List.unmodifiable(rows), peakLaneCount, continuation);
}

/// issue #102：视口可见行的 lane 占用范围（纯函数，供动态左边距使用）。
///
/// 返回闭区间 `(start, end)`；`offset` 为纵向滚动偏移，`viewportExtent` 为视口高度。
/// 会做 ±overscan 行扩展（默认 1），并在行数边界内 clamp。
({int start, int end}) graphVisibleRowRange({
  required int rowCount,
  required double offset,
  required double rowHeight,
  required double viewportExtent,
  int overscan = 1,
}) {
  if (rowCount <= 0 || rowHeight <= 0) return (start: 0, end: -1);
  final first = (offset / rowHeight).floor() - overscan;
  final last = ((offset + viewportExtent) / rowHeight).floor() + overscan;
  final start = first.clamp(0, rowCount - 1);
  final end = last.clamp(start, rowCount - 1);
  return (start: start, end: end);
}

/// issue #102：可见行最大占用 lane 数（lane / parentLanes / continuation from/to）。
///
/// 返回 `0` 表示没有可见行；调用方据此得到空图最小宽度 80。
int graphVisibleLaneCount(
  List<GraphRow> rows, {
  required int start,
  required int end,
}) {
  if (rows.isEmpty || end < start) return 0;
  var maxLane = -1;
  void take(int lane) {
    if (lane > maxLane) maxLane = lane;
  }

  for (var index = start; index <= end && index < rows.length; index++) {
    final row = rows[index];
    take(row.lane);
    for (final lane in row.parentLanes) {
      take(lane);
    }
    for (final continuation in row.continuations) {
      take(continuation.from);
      take(continuation.to);
    }
  }
  return maxLane + 1;
}
