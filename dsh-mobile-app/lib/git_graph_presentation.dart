import 'package:flutter/material.dart';

import 'git_models.dart';

/// 图行标签种类：决定排序、配色与是否 tag。
enum GitGraphLabelKind { head, localBranch, remoteBranch, other, tag }

/// 图行/详情展示用的引用标签（已归一、排序、去重）。
class GitGraphLabel {
  final String text;
  final GitGraphLabelKind kind;

  /// tag 是否为 annotated（图行只保证这一位；详情可读完整元数据）。
  final bool annotated;

  /// 宿主提示：`nested-tag` / `non-commit-target`（仅 tag 相关时存在）。
  final String? hint;

  const GitGraphLabel(
    this.text, {
    required this.kind,
    this.annotated = false,
    this.hint,
  });

  bool get tag => kind == GitGraphLabelKind.tag;
  bool get isHead => kind == GitGraphLabelKind.head;
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

const _refOrder = <String>[
  GitRefKind.head,
  GitRefKind.localBranch,
  GitRefKind.remoteBranch,
  GitRefKind.other,
];

GitGraphLabelKind _labelKindOf(String kind) => switch (kind) {
  GitRefKind.head => GitGraphLabelKind.head,
  GitRefKind.localBranch => GitGraphLabelKind.localBranch,
  GitRefKind.remoteBranch => GitGraphLabelKind.remoteBranch,
  _ => GitGraphLabelKind.other,
};

/// 提交详情 / 图行共用的引用标签：HEAD → 本地分支 → 远程分支 → 其他。
///
/// 契约要求展示全量标签（不再 +N 折叠），排序与去重在这里统一做：
/// 按 (kind, shortName) 去重，`refs/stash` 不展示。
List<GitGraphLabel> gitRefLabels(GitDecoration decoration) {
  final seen = <String>{};
  final buckets = <String, List<GitGraphLabel>>{
    for (final kind in _refOrder) kind: <GitGraphLabel>[],
  };
  for (final ref in decoration.refs) {
    if (ref.isStash) continue;
    // `refs/remotes/*/HEAD` 是远程默认分支的符号引用，不是真实分支，不展示。
    if (ref.name.startsWith('refs/remotes/') && ref.name.endsWith('/HEAD')) {
      continue;
    }
    final text = ref.shortName.trim();
    if (text.isEmpty) continue;
    if (ref.kind == GitRefKind.remoteBranch && text.endsWith('/HEAD')) continue;
    final kind = _refOrder.contains(ref.kind) ? ref.kind : GitRefKind.other;
    if (!seen.add('$kind\u0000$text')) continue;
    buckets[kind]!.add(GitGraphLabel(text, kind: _labelKindOf(kind)));
  }
  return List.unmodifiable([for (final kind in _refOrder) ...buckets[kind]!]);
}

/// tag 标签：保持宿主返回顺序，按短名去重。
List<GitGraphLabel> gitTagLabels(GitDecoration decoration) {
  final seen = <String>{};
  final labels = <GitGraphLabel>[];
  for (final tag in decoration.tags) {
    final text = tag.shortName.trim();
    if (text.isEmpty || !seen.add(text)) continue;
    labels.add(
      GitGraphLabel(
        text,
        kind: GitGraphLabelKind.tag,
        annotated: tag.annotated,
        hint: tag.hint,
      ),
    );
  }
  return List.unmodifiable(labels);
}

/// 图行完整标签：引用（HEAD → 本地 → 远程）后接全部 tag，单行展示、不折叠。
List<GitGraphLabel> gitGraphLabels(GitDecoration decoration) =>
    List.unmodifiable([
      ...gitRefLabels(decoration),
      ...gitTagLabels(decoration),
    ]);

/// 按种类取标签配色：HEAD 高亮、本地/远程分支用稳定色、tag 用 tertiaryContainer。
({Color background, Color foreground, Color? border}) gitGraphLabelColors(
  GitGraphLabel label, {
  required ColorScheme scheme,
  required Brightness brightness,
}) {
  switch (label.kind) {
    case GitGraphLabelKind.head:
      return (
        background: scheme.primary.withValues(alpha: .16),
        foreground: scheme.primary,
        border: scheme.primary.withValues(alpha: .45),
      );
    case GitGraphLabelKind.localBranch:
      final color = gitBranchColor(label.text, brightness);
      return (
        background: color.withValues(alpha: .14),
        foreground: color,
        border: null,
      );
    case GitGraphLabelKind.remoteBranch:
      final color = gitBranchColor(label.text, brightness);
      return (
        background: color.withValues(alpha: .08),
        foreground: color,
        border: color.withValues(alpha: .35),
      );
    case GitGraphLabelKind.tag:
      return (
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        border: null,
      );
    case GitGraphLabelKind.other:
      return (
        background: scheme.surfaceContainerHighest,
        foreground: scheme.onSurfaceVariant,
        border: null,
      );
  }
}
