import 'git_models.dart';

/// The renderer shows at most this many selected-tip colors in a commit node.
const maxNodeColorSegments = 3;

class GraphContinuation {
  final int from;
  final int to;
  final int colorSlot;

  const GraphContinuation(this.from, this.to, this.colorSlot);
}

class GraphRow {
  final int lane;
  final int incomingColorSlot;
  final int colorSlot;
  final List<int> parentLanes;
  final List<int> parentColorSlots;
  final List<int> tipColorSlots;
  final List<GraphContinuation> continuations;
  final bool merge;

  const GraphRow({
    required this.lane,
    required this.incomingColorSlot,
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
  for (var i = 0; i < selected.length && i < maxNodeColorSegments; i++)
    if (selected[i].oid == commit.oid) i,
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
  for (var i = 0; i < selected.length && i < maxNodeColorSegments; i++) {
    selectedSlots.putIfAbsent(selected[i].oid, () => i);
  }

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
      var parentLane = afterLanes.indexOf(parent);
      if (parentLane < 0) {
        parentLane = (lane + i).clamp(0, afterLanes.length);
        afterLanes.insert(parentLane, parent);
        afterColors.insert(parentLane, i == 0 ? outgoing : nextColor++);
      }
      parentLanes.add(parentLane);
      parentColors.add(afterColors[parentLane]);
    }

    final continuations = <GraphContinuation>[];
    for (var oldLane = 0; oldLane < lanes.length; oldLane++) {
      if (oldLane == lane) continue;
      final newLane = afterLanes.indexOf(lanes[oldLane]);
      if (newLane >= 0) {
        continuations.add(GraphContinuation(oldLane, newLane, colors[oldLane]));
      }
    }

    rows.add(
      GraphRow(
        lane: lane,
        incomingColorSlot: incoming,
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
