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

      final background = brightness == Brightness.light
          ? Colors.white
          : const Color(0xff161b22);
      final backgroundLuminance = background.computeLuminance();
      for (final ref in refsBySlot.values) {
        final color = gitBranchColor(ref, brightness);
        expect(HSLColor.fromColor(color).saturation, greaterThanOrEqualTo(.75));
        final foregroundLuminance = color.computeLuminance();
        final lighter = foregroundLuminance > backgroundLuminance
            ? foregroundLuminance
            : backgroundLuminance;
        final darker = foregroundLuminance > backgroundLuminance
            ? backgroundLuminance
            : foregroundLuminance;
        expect((lighter + .05) / (darker + .05), greaterThanOrEqualTo(3));
      }
    }
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
