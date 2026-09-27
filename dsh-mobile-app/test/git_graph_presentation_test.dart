import 'package:dsh_mobile_app/git_graph_presentation.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('branch color is stable by ref and adapts to the theme', () {
    expect(
      stableGitColorSlot('refs/heads/main'),
      stableGitColorSlot('refs/heads/main'),
    );
    expect(
      gitBranchColor('refs/heads/main', Brightness.light),
      isNot(gitBranchColor('refs/heads/main', Brightness.dark)),
    );
  });

  test('branch palette is vivid with readable contrast', () {
    for (final brightness in Brightness.values) {
      final refsBySlot = <int, String>{};
      for (var i = 0; i < 512 && refsBySlot.length < 8; i++) {
        final ref = 'refs/heads/color-check-$i';
        refsBySlot.putIfAbsent(stableGitColorSlot(ref), () => ref);
      }
      expect(refsBySlot, hasLength(8));
      expect(
        [
          for (var slot = 0; slot < 8; slot++)
            gitBranchColor(refsBySlot[slot]!, brightness),
        ],
        brightness == Brightness.dark
            ? const [
                Color(0xff4f8cff),
                Color(0xffff7a1a),
                Color(0xffff3fac),
                Color(0xff21d164),
                Color(0xffa970ff),
                Color(0xff20c8f6),
                Color(0xffff4d4d),
                Color(0xffffd000),
              ]
            : const [
                Color(0xff0057ff),
                Color(0xffff5a00),
                Color(0xffd5008f),
                Color(0xff00a83b),
                Color(0xff7a00ff),
                Color(0xff0096c7),
                Color(0xffe00000),
                Color(0xffc58a00),
              ],
      );

      final background = brightness == Brightness.light
          ? Colors.white
          : const Color(0xff161b22);
      final backgroundLuminance = background.computeLuminance();
      for (final ref in refsBySlot.values) {
        final color = gitBranchColor(ref, brightness);
        expect(HSLColor.fromColor(color).saturation, greaterThanOrEqualTo(.70));
        final foregroundLuminance = color.computeLuminance();
        final lighter = foregroundLuminance > backgroundLuminance
            ? foregroundLuminance
            : backgroundLuminance;
        final darker = foregroundLuminance > backgroundLuminance
            ? backgroundLuminance
            : foregroundLuminance;
        expect((lighter + .05) / (darker + .05), greaterThanOrEqualTo(2.99));
      }
    }
  });

  test('selected graph refs reuse archived colors without collisions', () {
    const selected = [
      GitBranch(
        name: 'refs/heads/develop',
        displayName: 'develop',
        oid: 'develop-tip',
        kind: 'local',
      ),
      GitBranch(
        name: 'refs/heads/main',
        displayName: 'main',
        oid: 'main-tip',
        kind: 'local',
      ),
      GitBranch(
        name: 'refs/heads/feature/app-git-management',
        displayName: 'feature/app-git-management',
        oid: 'feature-tip',
        kind: 'local',
      ),
    ];

    expect(
      [
        for (var slot = 0; slot < selected.length; slot++)
          gitLaneColor(slot, selected, Brightness.light),
      ],
      const [Color(0xffd5008f), Color(0xff7a00ff), Color(0xffe00000)],
    );
    expect(
      [
        for (var slot = 0; slot < selected.length; slot++)
          gitLaneColor(slot, selected, Brightness.dark),
      ],
      const [Color(0xffff3fac), Color(0xffa970ff), Color(0xffff4d4d)],
    );
  });

  test('graph decorations prioritize current ref and compact overflow', () {
    const current = GitBranch(
      name: 'refs/heads/main',
      displayName: 'main',
      oid: 'tip',
      kind: 'local',
      current: true,
    );
    final labels = compactGitGraphLabels(
      refs: const [
        'refs/heads/feature',
        'HEAD -> refs/heads/main',
        'origin/other',
      ],
      tags: const ['v1', 'v2'],
      selected: const [current],
      currentBranch: 'refs/heads/main',
    );

    expect(labels.map((label) => label.text).toList(), [
      'main',
      'feature',
      '+3',
    ]);
    expect(labels.last.overflow, isTrue);
  });
}
