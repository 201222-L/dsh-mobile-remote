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

  test('graph shows every ref and tag on one line in HEAD -> local -> remote -> tag order', () {
    const decoration = GitDecoration(
      refs: [
        GitRefDetail(
          kind: 'remoteBranch',
          name: 'refs/remotes/origin/main',
          shortName: 'origin/main',
        ),
        GitRefDetail(
          kind: 'localBranch',
          name: 'refs/heads/feature',
          shortName: 'feature',
        ),
        GitRefDetail(
          kind: 'head',
          name: 'refs/heads/main',
          shortName: 'main',
          current: true,
        ),
        GitRefDetail(
          kind: 'localBranch',
          name: 'refs/heads/release',
          shortName: 'release',
        ),
      ],
      tags: [
        GitTagDetail(name: 'refs/tags/v1', shortName: 'v1', annotated: true),
        GitTagDetail(name: 'refs/tags/v2', shortName: 'v2'),
      ],
    );

    final labels = gitGraphLabels(decoration);

    expect(labels.map((label) => label.text).toList(), [
      'main',
      'feature',
      'release',
      'origin/main',
      'v1',
      'v2',
    ]);
    // 全量展示：不再有 +N 折叠 pill。
    expect(
      labels.where(
        (label) =>
            label.text.startsWith('+') || label.text.contains('overflow'),
      ),
      isEmpty,
    );
    expect(labels.first.kind, GitGraphLabelKind.head);
    expect(labels.map((label) => label.kind).toList(), [
      GitGraphLabelKind.head,
      GitGraphLabelKind.localBranch,
      GitGraphLabelKind.localBranch,
      GitGraphLabelKind.remoteBranch,
      GitGraphLabelKind.tag,
      GitGraphLabelKind.tag,
    ]);
    expect(labels.first.annotated, isFalse);
    expect(labels[4].annotated, isTrue);
  });

  test(
    'graph labels dedupe by kind/shortName and hide stash and remote HEAD',
    () {
      const decoration = GitDecoration(
        refs: [
          GitRefDetail(
            kind: 'localBranch',
            name: 'refs/heads/main',
            shortName: 'main',
          ),
          GitRefDetail(
            kind: 'localBranch',
            name: 'refs/heads/main',
            shortName: 'main',
          ),
          GitRefDetail(kind: 'other', name: 'refs/stash', shortName: 'stash'),
          GitRefDetail(
            kind: 'remoteBranch',
            name: 'refs/remotes/origin/HEAD',
            shortName: 'origin/HEAD',
          ),
        ],
        tags: [
          GitTagDetail(name: 'refs/tags/v1', shortName: 'v1'),
          GitTagDetail(name: 'refs/tags/v1', shortName: 'v1'),
        ],
      );

      final labels = gitGraphLabels(decoration);

      // `refs/stash`、`refs/remotes/*/HEAD` 不展示；同 kind+shortName 只留一个。
      expect(labels.map((label) => label.text).toList(), ['main', 'v1']);
    },
  );

  test(
    'legacy ref strings fall back to ordered labels without annotated metadata',
    () {
      final decoration = GitDecoration.fromLegacy(
        refs: const [
          'refs/heads/feature',
          'HEAD -> refs/heads/main',
          'refs/remotes/origin/main',
          'tag: refs/tags/v1',
          'origin/other',
        ],
        tags: const ['v2'],
      );

      final labels = gitGraphLabels(decoration);
      // `HEAD -> refs/heads/main` 在旧宿主上投影为 head(HEAD) + current
      // localBranch(main)，与结构化宿主一致，不再出现重复的 main pill。
      expect(labels.map((label) => label.text).toList(), [
        'HEAD',
        'feature',
        'main',
        'origin/main',
        'origin/other',
        'v1',
        'v2',
      ]);
      expect(labels.first.kind, GitGraphLabelKind.head);
      expect(labels.first.text, 'HEAD');
      expect(labels[1].kind, GitGraphLabelKind.localBranch);
      expect(labels[2].kind, GitGraphLabelKind.localBranch);
      expect(labels[2].text, 'main');
      expect(
        labels.where((label) => label.tag).every((l) => !l.annotated),
        isTrue,
      );
      // 旧宿主的 tag 从 refs 字符串派生（`tag: refs/tags/v1`），不丢。
      expect(gitTagLabels(decoration).map((label) => label.text), ['v1', 'v2']);
      // refs 行不混入 tag。
      expect(gitRefLabels(decoration).where((label) => label.tag), isEmpty);
    },
  );

  test('label colors distinguish HEAD, local, remote and tag', () {
    const scheme = ColorScheme.light();
    const head = GitGraphLabel('main', kind: GitGraphLabelKind.head);
    const local = GitGraphLabel('feature', kind: GitGraphLabelKind.localBranch);
    const remote = GitGraphLabel(
      'origin/main',
      kind: GitGraphLabelKind.remoteBranch,
    );
    const tag = GitGraphLabel('v1', kind: GitGraphLabelKind.tag);

    final headColors = gitGraphLabelColors(
      head,
      scheme: scheme,
      brightness: Brightness.light,
    );
    final localColors = gitGraphLabelColors(
      local,
      scheme: scheme,
      brightness: Brightness.light,
    );
    final remoteColors = gitGraphLabelColors(
      remote,
      scheme: scheme,
      brightness: Brightness.light,
    );
    final tagColors = gitGraphLabelColors(
      tag,
      scheme: scheme,
      brightness: Brightness.light,
    );

    expect(headColors.background, isNot(localColors.background));
    expect(headColors.border, isNotNull);
    expect(localColors.foreground, isNot(remoteColors.foreground));
    expect(remoteColors.border, isNotNull);
    expect(tagColors.background, scheme.tertiaryContainer);
    expect(tagColors.foreground, scheme.onTertiaryContainer);
    expect(headColors.foreground, scheme.primary);
  });
}
