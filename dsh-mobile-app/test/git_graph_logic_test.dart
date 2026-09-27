import 'dart:math';

import 'package:dsh_mobile_app/git_graph_logic.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter_test/flutter_test.dart';

GitCommitSummary commit(String oid, [List<String> parents = const []]) =>
    GitCommitSummary(oid: oid, parents: parents);

void main() {
  test('ordinary chain stays in one topology lane', () {
    final layout = layoutGraph([
      commit('tip', ['middle']),
      commit('middle', ['root']),
      commit('root'),
    ], const []);

    expect(layout.rows.map((row) => row.lane), [0, 0, 0]);
    expect(layout.rows.map((row) => row.parentLanes), [
      [0],
      [0],
      <int>[],
    ]);
    expect(layout.rows.every((row) => !row.merge), isTrue);
    expect(layout.laneCount, 1);
  });

  test('lane topology origins omit only their incoming stems', () {
    const selected = [
      GitBranch(
        name: 'refs/heads/main',
        displayName: 'main',
        oid: 'main-tip',
        kind: 'local',
        current: true,
      ),
      GitBranch(
        name: 'refs/heads/feature',
        displayName: 'feature',
        oid: 'feature-tip',
        kind: 'local',
      ),
    ];
    final layout = layoutGraph([
      commit('main-tip', ['shared']),
      commit('feature-tip', ['shared']),
      commit('shared', ['root']),
      commit('root'),
    ], selected);

    expect(layout.rows.map((row) => row.hasIncomingEdge), [
      false,
      false,
      true,
      true,
    ]);
  });

  test('selected ancestor tip keeps a real incoming child edge', () {
    const selected = [
      GitBranch(
        name: 'refs/heads/child',
        displayName: 'child',
        oid: 'child-tip',
        kind: 'local',
      ),
      GitBranch(
        name: 'refs/heads/parent',
        displayName: 'parent',
        oid: 'parent-tip',
        kind: 'local',
      ),
    ];
    final layout = layoutGraph([
      commit('child-tip', ['parent-tip']),
      commit('parent-tip', ['root']),
      commit('root'),
    ], selected);

    expect(layout.rows.map((row) => row.hasIncomingEdge), [false, true, true]);
    expect(layout.rows.first.parentLanes, [0]);
  });

  test('incoming edge continues across an appended graph page', () {
    final first = layoutGraph([
      commit('tip', ['parent']),
    ], const []);
    final second = layoutGraph(
      [
        commit('parent', ['root']),
      ],
      const [],
      state: first.continuation,
    );

    expect(first.rows.single.hasIncomingEdge, isFalse);
    expect(second.rows.first.hasIncomingEdge, isTrue);
  });

  test('fork and shared ancestor use parent topology without false merge', () {
    final layout = layoutGraph([
      commit('tip', ['left', 'right']),
      commit('left', ['root']),
      commit('right', ['root']),
      commit('root'),
    ], const []);

    expect(layout.rows.map((row) => row.lane), [0, 0, 1, 0]);
    expect(layout.rows.first.parentLanes, [0, 1]);
    expect(layout.rows[2].parentLanes, [0]);
    expect(layout.rows.map((row) => row.merge), [true, false, false, false]);
    expect(layout.laneCount, 2);
  });

  test('side parent may be listed before first parent without re-laning', () {
    final layout = layoutGraph([
      commit('merge', ['first', 'side']),
      commit('side', ['root']),
      commit('first', ['root']),
      commit('root'),
    ], const []);

    expect(layout.rows.map((row) => row.lane), [0, 1, 0, 0]);
    expect(layout.rows.first.parentLanes, [0, 1]);
    expect(layout.rows[1].parentLanes, [1]);
    expect(layout.rows[2].parentLanes, [0]);
  });

  test('octopus merge preserves every parent in declared order', () {
    final layout = layoutGraph([
      commit('octopus', ['one', 'two', 'three']),
      commit('two'),
      commit('one'),
      commit('three'),
    ], const []);

    expect(layout.rows.first.parentLanes, [0, 1, 2]);
    expect(layout.rows.first.parentColorSlots, hasLength(3));
    expect(layout.rows.first.merge, isTrue);
    expect(layout.laneCount, 3);
  });

  test(
    'inserting later parents preserves distinct lanes for active parents',
    () {
      final layout = layoutGraph([
        commit('c0', ['c2']),
        commit('c1', ['c3', 'c4']),
        commit('c2', ['c4', 'c5']),
        commit('c3'),
        commit('c4'),
        commit('c5'),
      ], const []);

      expect(layout.rows[2].parentLanes, [2, 1]);
      expect(layout.rows[2].parentLanes.toSet(), hasLength(2));
      expect(layout.rows[2].parentColorSlots, hasLength(2));
    },
  );

  test('criss-crossing active lines retain their continuations', () {
    final layout = layoutGraph([
      commit('merge', ['left', 'right']),
      commit('left', ['base-left']),
      commit('right', ['base-right']),
      commit('base-left', ['root']),
      commit('base-right', ['root']),
      commit('root'),
    ], const []);

    expect(layout.rows.map((row) => row.lane), [0, 0, 1, 0, 1, 0]);
    expect(layout.rows[2].continuations, isNotEmpty);
    expect(layout.rows[4].continuations, isNotEmpty);
  });

  test('disconnected roots never borrow an active parent lane', () {
    final layout = layoutGraph([
      commit('first', ['root']),
      commit('other', ['other-root']),
      commit('root'),
      commit('other-root'),
    ], const []);

    expect(layout.rows.map((row) => row.lane), [0, 1, 0, 0]);
    expect(layout.rows[2].continuations, isNotEmpty);
    expect(layout.laneCount, 2);
  });

  test('selected order anchors colors even when opposite topology order', () {
    const selected = [
      GitBranch(kind: 'local', name: 'b', displayName: 'b', oid: 'b'),
      GitBranch(kind: 'local', name: 'a', displayName: 'a', oid: 'a'),
    ];
    final layout = layoutGraph([
      commit('a', ['root']),
      commit('b', ['root']),
      commit('root'),
    ], selected);

    expect(layout.rows.map((row) => row.lane), [1, 0, 0]);
    expect(layout.rows[0].colorSlot, 1);
    expect(layout.rows[1].colorSlot, 0);
    expect(layout.rows[0].tipColorSlots, [1]);
    expect(layout.rows[1].tipColorSlots, [0]);
  });

  test(
    'selected ancestor changes color at its node without a false branch',
    () {
      const selected = [
        GitBranch(kind: 'local', name: 'tip', displayName: 'tip', oid: 'tip'),
        GitBranch(
          kind: 'local',
          name: 'ancestor',
          displayName: 'ancestor',
          oid: 'ancestor',
        ),
      ];
      final layout = layoutGraph([
        commit('tip', ['ancestor']),
        commit('ancestor', ['root']),
        commit('root'),
      ], selected);

      expect(layout.rows.map((row) => row.lane), [0, 0, 0]);
      expect(layout.rows[1].incomingColorSlot, 0);
      expect(layout.rows[1].colorSlot, 1);
      expect(layout.rows.every((row) => !row.merge), isTrue);
    },
  );

  test(
    'only five selected tips influence node segments and initial anchors',
    () {
      expect(maxNodeColorSegments, 5);
      const selected = [
        GitBranch(kind: 'local', name: 'a', displayName: 'a', oid: 'a'),
        GitBranch(kind: 'local', name: 'b', displayName: 'b', oid: 'b'),
        GitBranch(kind: 'local', name: 'c', displayName: 'c', oid: 'c'),
        GitBranch(kind: 'local', name: 'd', displayName: 'd', oid: 'd'),
        GitBranch(kind: 'local', name: 'e', displayName: 'e', oid: 'e'),
        GitBranch(kind: 'local', name: 'f', displayName: 'f', oid: 'f'),
      ];
      final shared = layoutGraph(
        [commit('a')],
        const [
          GitBranch(kind: 'local', name: 'a1', displayName: 'a1', oid: 'a'),
          GitBranch(kind: 'local', name: 'a2', displayName: 'a2', oid: 'a'),
          GitBranch(kind: 'local', name: 'a3', displayName: 'a3', oid: 'a'),
          GitBranch(kind: 'local', name: 'a4', displayName: 'a4', oid: 'a'),
          GitBranch(kind: 'local', name: 'a5', displayName: 'a5', oid: 'a'),
          GitBranch(kind: 'local', name: 'a6', displayName: 'a6', oid: 'a'),
        ],
      );
      final separate = layoutGraph([
        commit('a'),
        commit('b'),
        commit('c'),
        commit('d'),
        commit('e'),
        commit('f'),
      ], selected);

      expect(shared.rows.single.tipColorSlots, [0, 1, 2, 3, 4]);
      expect(separate.rows.take(5).map((row) => row.colorSlot), [
        0,
        1,
        2,
        3,
        4,
      ]);
      expect(separate.rows[5].colorSlot, greaterThanOrEqualTo(5));
    },
  );

  test('selected tip absent from the page does not create a ghost lane', () {
    const selected = [
      GitBranch(
        kind: 'local',
        name: 'not-loaded',
        displayName: 'not-loaded',
        oid: 'not-loaded',
      ),
    ];

    final layout = layoutGraph([
      commit('tip', ['root']),
      commit('root'),
    ], selected);

    expect(layout.rows.map((row) => row.lane), [0, 0]);
    expect(layout.laneCount, 1);
    expect(layout.continuation.lanes, isEmpty);
  });

  test(
    'page continuation leaves prior rows unchanged and connects parent lines',
    () {
      final first = layoutGraph([
        commit('merge', ['left', 'right']),
        commit('left', ['left-base']),
      ], const []);
      final before = first.rows.map(rowSignature).toList();
      final second = layoutGraph(
        [
          commit('right', ['right-base']),
          commit('left-base', ['root']),
          commit('right-base', ['root']),
          commit('root'),
        ],
        const [],
        state: first.continuation,
      );
      final whole = layoutGraph([
        commit('merge', ['left', 'right']),
        commit('left', ['left-base']),
        commit('right', ['right-base']),
        commit('left-base', ['root']),
        commit('right-base', ['root']),
        commit('root'),
      ], const []);

      expect(first.rows.map(rowSignature), before);
      expect(
        [...first.rows, ...second.rows].map(rowSignature),
        whole.rows.map(rowSignature),
      );
      expect(
        second.rows.first.incomingColorSlot,
        first.continuation.lanes
            .firstWhere((lane) => lane.oid == 'right')
            .colorSlot,
      );
      expect(second.laneCount, whole.laneCount);
    },
  );

  test(
    'deterministic randomized DAGs preserve topology across page splits',
    () {
      final random = Random(73021);
      for (var sample = 0; sample < 40; sample++) {
        final count = 8 + random.nextInt(20);
        final commits = <GitCommitSummary>[];
        for (var i = 0; i < count; i++) {
          final candidates = [for (var p = i + 1; p < count; p++) 'c$p'];
          final parentCount = candidates.isEmpty
              ? 0
              : random.nextInt(min(3, candidates.length) + 1);
          candidates.shuffle(random);
          commits.add(commit('c$i', candidates.take(parentCount).toList()));
        }
        final split = 1 + random.nextInt(count - 1);
        final whole = layoutGraph(commits, const []);
        final first = layoutGraph(commits.take(split).toList(), const []);
        final second = layoutGraph(
          commits.skip(split).toList(),
          const [],
          state: first.continuation,
        );
        final paged = [...first.rows, ...second.rows];

        expect(
          paged.map(rowSignature),
          whole.rows.map(rowSignature),
          reason: 'sample $sample split $split',
        );
        for (var i = 0; i < commits.length; i++) {
          expect(paged[i].parentLanes, hasLength(commits[i].parents.length));
          expect(
            paged[i].parentLanes.toSet().length,
            commits[i].parents.toSet().length,
            reason: 'sample $sample row $i must use distinct parent lanes',
          );
          expect(
            paged[i].parentColorSlots,
            hasLength(commits[i].parents.length),
          );
          expect(paged[i].merge, commits[i].parents.toSet().length > 1);
          expect(paged[i].lane, greaterThanOrEqualTo(0));
          expect(paged[i].parentLanes.every((lane) => lane >= 0), isTrue);
        }
      }
    },
  );
}

List<Object> rowSignature(GraphRow row) => [
  row.lane,
  row.incomingColorSlot,
  row.colorSlot,
  row.parentLanes,
  row.parentColorSlots,
  row.tipColorSlots,
  row.merge,
  [
    for (final line in row.continuations) [line.from, line.to, line.colorSlot],
  ],
];
