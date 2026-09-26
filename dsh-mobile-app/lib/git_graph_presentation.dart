import 'package:flutter/material.dart';

import 'git_models.dart';

class GitGraphLabel {
  final String text;
  final bool tag;
  final bool overflow;

  const GitGraphLabel(this.text, {this.tag = false, this.overflow = false});
}

const _lightBranchColors = <Color>[
  Color(0xffcf3b2e),
  Color(0xff147d64),
  Color(0xff235db4),
  Color(0xff9a5d00),
  Color(0xff7543a5),
  Color(0xff087e9b),
  Color(0xffb02e70),
  Color(0xff596b18),
];
const _darkBranchColors = <Color>[
  Color(0xffff806e),
  Color(0xff57d6a2),
  Color(0xff82b4ff),
  Color(0xffffc266),
  Color(0xffc79aff),
  Color(0xff55d6ef),
  Color(0xffff8cc7),
  Color(0xffc6df68),
];

int stableGitColorSlot(String ref) {
  var hash = 0x811c9dc5;
  for (final unit in ref.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash % _lightBranchColors.length;
}

Color gitBranchColor(String ref, Brightness brightness) =>
    (brightness == Brightness.dark
    ? _darkBranchColors
    : _lightBranchColors)[stableGitColorSlot(ref)];

Color gitLaneColor(int slot, List<GitBranch> selected, Brightness brightness) {
  if (slot >= 0 && slot < selected.length) {
    return gitBranchColor(selected[slot].name, brightness);
  }
  final colors = brightness == Brightness.dark
      ? _darkBranchColors
      : _lightBranchColors;
  return colors[slot.abs() % colors.length];
}

List<GitGraphLabel> compactGitGraphLabels({
  required List<String> refs,
  required List<String> tags,
  required List<GitBranch> selected,
  String? currentBranch,
  int maxVisible = 2,
}) {
  final values = <GitGraphLabel>[
    for (final ref in refs) GitGraphLabel(_cleanRef(ref)),
    for (final tag in tags) GitGraphLabel(tag, tag: true),
  ];
  final unique = <GitGraphLabel>[];
  final seen = <String>{};
  for (final value in values) {
    final key = '${value.tag ? 'tag' : 'ref'}:${value.text}';
    if (value.text.isNotEmpty && seen.add(key)) unique.add(value);
  }
  if (unique.length <= maxVisible) return unique;

  final currentName = currentBranch == null
      ? null
      : _cleanRef(currentBranch.replaceFirst('refs/heads/', ''));
  var currentIndex = -1;
  if (currentName != null) {
    currentIndex = unique.indexWhere(
      (label) =>
          !label.tag &&
          (label.text == currentName || label.text.endsWith('->$currentName')),
    );
  }
  if (currentIndex < 0) {
    currentIndex = unique.indexWhere(
      (label) => !label.tag && label.text.startsWith('HEAD ->'),
    );
  }
  if (currentIndex < 0 && selected.isNotEmpty) {
    final selectedNames = selected
        .map((branch) => _cleanRef(branch.displayName))
        .toSet();
    currentIndex = unique.indexWhere(
      (label) => !label.tag && selectedNames.contains(label.text),
    );
  }
  final prioritized = <GitGraphLabel>[
    if (currentIndex >= 0) unique[currentIndex],
    for (var i = 0; i < unique.length; i++)
      if (i != currentIndex) unique[i],
  ];
  final visibleCount = maxVisible.clamp(1, 8).toInt();
  final visible = prioritized.take(visibleCount).toList();
  final hidden = prioritized.length - visible.length;
  if (hidden > 0) visible.add(GitGraphLabel('+$hidden', overflow: true));
  return List.unmodifiable(visible);
}

String _cleanRef(String ref) => ref
    .replaceFirst('HEAD -> ', '')
    .replaceFirst('refs/heads/', '')
    .replaceFirst('refs/remotes/', '');
