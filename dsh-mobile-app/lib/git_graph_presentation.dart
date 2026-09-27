import 'package:flutter/material.dart';

import 'git_models.dart';

class GitGraphLabel {
  final String text;
  final bool tag;
  final bool overflow;

  const GitGraphLabel(this.text, {this.tag = false, this.overflow = false});
}

const _lightBranchColors = <Color>[
  Color(0xff0057ff),
  Color(0xffff5a00),
  Color(0xffd5008f),
  Color(0xff00a83b),
  Color(0xff7a00ff),
  Color(0xff0096c7),
  Color(0xffe00000),
  Color(0xffc58a00),
];
const _darkBranchColors = <Color>[
  Color(0xff4f8cff),
  Color(0xffff7a1a),
  Color(0xffff3fac),
  Color(0xff21d164),
  Color(0xffa970ff),
  Color(0xff20c8f6),
  Color(0xffff4d4d),
  Color(0xffffd000),
];

List<Color> _graphPalette(Brightness brightness) =>
    brightness == Brightness.dark ? _darkBranchColors : _lightBranchColors;

int stableGitColorSlot(String ref) {
  var hash = 0;
  for (final unit in ref.codeUnits) {
    hash = ((hash * 31) + unit) & 0x7fffffff;
  }
  return hash % _lightBranchColors.length;
}

Color gitBranchColor(String ref, Brightness brightness) =>
    _graphPalette(brightness)[stableGitColorSlot(ref)];

Map<String, Color> _selectedBranchColors(
  List<GitBranch> selected,
  List<Color> palette,
) {
  final result = <String, Color>{};
  final usedSlots = <int>{};
  final ordered = [...selected]..sort((a, b) => a.name.compareTo(b.name));
  for (final branch in ordered.take(palette.length)) {
    if (result.containsKey(branch.name)) continue;
    var slot = stableGitColorSlot(branch.name);
    while (usedSlots.contains(slot)) {
      slot = (slot + 1) % palette.length;
    }
    usedSlots.add(slot);
    result[branch.name] = palette[slot];
  }
  return result;
}

List<Color> _laneColors(List<GitBranch> selected, Brightness brightness) {
  final palette = _graphPalette(brightness);
  final selectedColors = _selectedBranchColors(selected, palette);
  final result = <Color>[
    for (final branch in selected.take(palette.length))
      selectedColors[branch.name] ?? gitBranchColor(branch.name, brightness),
  ];
  for (final color in palette) {
    if (!result.contains(color)) result.add(color);
  }
  return result;
}

Color gitLaneColor(int slot, List<GitBranch> selected, Brightness brightness) {
  final colors = _laneColors(selected, brightness);
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
