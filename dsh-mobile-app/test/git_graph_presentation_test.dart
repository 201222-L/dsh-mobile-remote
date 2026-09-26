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
