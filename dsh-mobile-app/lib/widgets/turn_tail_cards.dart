// issue #53（docs/03-api.md §6.20–§6.23）：轮末两张文件卡。
//
// 布局契约：过程(折叠) → 最终回答 → 改动卡 → 交付卡 → 轮次页脚。
// 两卡**不参与整轮折叠**，各自默认收起；无文件不占位；能力位缺失时由调用方不渲染。
//
// 卡片只做展示与手势回调，取数/缓存/坐标解析在 ChatScreen 与预览/差异页。

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme.dart';
import '../turn_tail.dart';

/// 组件稳定测试 Key（两卡默认折叠/展开、行点击、diff 入口）。
class TurnTailCardKeys {
  const TurnTailCardKeys._();

  static const changedCard = Key('turn-tail-changed');
  static const changedHeader = Key('turn-tail-changed-header');
  static const changedToggle = Key('turn-tail-changed-toggle');
  static const changedDiff = Key('turn-tail-changed-diff');
  static const deliveredCard = Key('turn-tail-delivered');
  static const deliveredHeader = Key('turn-tail-delivered-header');
  static const deliveredToggle = Key('turn-tail-delivered-toggle');

  static Key changedRow(int index) => Key('turn-tail-changed-row-$index');

  /// issue #60 R09：交付行/操作 Key 必须含**完整记录坐标**（seq+index）——同一轮多次
  /// present 时不同事件的 index 会重复，只用 index 会生成重复兄弟 Key。
  static Key deliveredRow({required int seq, required int index}) =>
      Key('turn-tail-delivered-row-$seq-$index');
  static Key deliveredActions({required int seq, required int index}) =>
      Key('turn-tail-delivered-actions-$seq-$index');
}

/// 折叠时最多显示的文件行数（issue #53 §3/§4）。
const int turnTailCollapsedRows = 4;

/// 本轮改动文件卡（§6.21）：header「本轮改动 N 个文件 +x −y」，默认收起。
class ChangedFilesCard extends StatefulWidget {
  const ChangedFilesCard({
    super.key,
    required this.turn,
    required this.summary,
    required this.onOpenFile,
    required this.onOpenDiff,
  });

  final int turn;
  final ChangesSummary summary;
  final ValueChanged<ChangedFile> onOpenFile;
  final ValueChanged<int> onOpenDiff;

  @override
  State<ChangedFilesCard> createState() => _ChangedFilesCardState();
}

class _ChangedFilesCardState extends State<ChangedFilesCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant ChangedFilesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换到另一轮的摘要（同一卡片位置复用时）回到默认收起，避免把上一轮的手动展开带过去。
    if (oldWidget.turn != widget.turn ||
        oldWidget.summary.state != widget.summary.state) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final files = summary.files;
    if (files.isEmpty) return const SizedBox.shrink();
    final total = summary.total > 0 ? summary.total : files.length;
    final collapsed = !_expanded;
    final visible = collapsed && files.length > turnTailCollapsedRows
        ? files.take(turnTailCollapsedRows).toList(growable: false)
        : files;
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    // diff 入口始终指向本文件列表的第一个文件（truncated 只表示列表被截断，不影响已列文件）。
    final diffIndex = files.isEmpty ? -1 : 0;

    return Container(
      key: TurnTailCardKeys.changedCard,
      margin: const EdgeInsets.only(top: 4, bottom: 6),
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: TurnTailCardKeys.changedHeader,
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(Icons.edit_note, size: 16, color: ink2),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      L10n.t(
                        '本轮改动 $total 个文件',
                        '$total file${total == 1 ? '' : 's'} changed',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                  if (summary.added > 0 || summary.deleted > 0) ...[
                    Text(
                      '+${summary.added}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF188038),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '−${summary.deleted}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFD93025),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (summary.truncated)
                    Tooltip(
                      message: L10n.t('文件过多，仅显示前 200 个', 'Showing first 200 files'),
                      child: Icon(Icons.more_horiz, size: 16, color: ink2),
                    ),
                  IconButton(
                    key: TurnTailCardKeys.changedDiff,
                    tooltip: L10n.t('查看本轮改动', 'View turn changes'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.difference, size: 17, color: ink2),
                    onPressed: diffIndex >= 0
                        ? () => widget.onOpenDiff(diffIndex)
                        : null,
                  ),
                  if (files.length > turnTailCollapsedRows)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: ink2,
                    ),
                ],
              ),
            ),
          ),
          for (final entry in visible)
            _ChangedFileRow(
              key: TurnTailCardKeys.changedRow(entry.index),
              file: entry,
              onTap: () => widget.onOpenFile(entry),
            ),
          if (files.length > turnTailCollapsedRows)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: TurnTailCardKeys.changedToggle,
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? L10n.t('收起', 'Collapse')
                      : L10n.t('全部 ${files.length} 个', 'All ${files.length}'),
                  style: TextStyle(fontSize: 12, color: ink2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChangedFileRow extends StatelessWidget {
  const _ChangedFileRow({
    super.key,
    required this.file,
    required this.onTap,
  });

  final ChangedFile file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    final stat = file.binary
        ? L10n.t('二进制', 'Binary')
        : file.oversized
        ? L10n.t('文件过大', 'Too large')
        : '+${file.added} −${file.deleted}';
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                file.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: ink,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              stat,
              style: TextStyle(
                fontSize: 11.5,
                color: file.binary || file.oversized ? ink2 : ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 交付文件卡（§6.20）：单列文件行（类型图标 + 文件名 + 说明），>4 收起。
class DeliveredFilesCard extends StatefulWidget {
  const DeliveredFilesCard({
    super.key,
    required this.turn,
    required this.files,
    required this.onOpen,
    required this.onActions,
  });

  final int turn;
  final List<DeliverableFile> files;
  final ValueChanged<DeliverableFile> onOpen;
  final ValueChanged<DeliverableFile> onActions;

  @override
  State<DeliveredFilesCard> createState() => _DeliveredFilesCardState();
}

class _DeliveredFilesCardState extends State<DeliveredFilesCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant DeliveredFilesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turn != widget.turn) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.files;
    if (files.isEmpty) return const SizedBox.shrink();
    final collapsed = !_expanded;
    final visible = collapsed && files.length > turnTailCollapsedRows
        ? files.take(turnTailCollapsedRows).toList(growable: false)
        : files;
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);

    return Container(
      key: TurnTailCardKeys.deliveredCard,
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: TurnTailCardKeys.deliveredHeader,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(Icons.folder_open, size: 16, color: ink2),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      L10n.t(
                        '交付文件 ${files.length} 个',
                        '${files.length} delivered file${files.length == 1 ? '' : 's'}',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                  if (files.length > turnTailCollapsedRows)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: ink2,
                    ),
                ],
              ),
            ),
          ),
          for (var index = 0; index < visible.length; index += 1)
            _DeliveredFileRow(
              key: TurnTailCardKeys.deliveredRow(
                seq: visible[index].seq,
                index: visible[index].index,
              ),
              file: visible[index],
              onOpen: () => widget.onOpen(visible[index]),
              onActions: () => widget.onActions(visible[index]),
            ),
          if (files.length > turnTailCollapsedRows)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: TurnTailCardKeys.deliveredToggle,
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? L10n.t('收起', 'Collapse')
                      : L10n.t('全部 ${files.length} 个', 'All ${files.length}'),
                  style: TextStyle(fontSize: 12, color: ink2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeliveredFileRow extends StatelessWidget {
  const _DeliveredFileRow({
    super.key,
    required this.file,
    required this.onOpen,
    required this.onActions,
  });

  final DeliverableFile file;
  final VoidCallback onOpen;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    final description = file.description;
    return InkWell(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.only(left: 10, right: 2, top: 6, bottom: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        child: Row(
          children: [
            Icon(_iconOf(file.name), size: 18, color: ink2),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: ink),
                  ),
                  if (description != null)
                    Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: ink2),
                    ),
                ],
              ),
            ),
            IconButton(
              key: TurnTailCardKeys.deliveredActions(
                seq: file.seq,
                index: file.index,
              ),
              tooltip: L10n.t('更多操作', 'More actions'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.more_vert, size: 18, color: ink2),
              onPressed: onActions,
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconOf(String name) {
    if (isPreviewableImageName(name)) return Icons.image_outlined;
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.md') || lower.endsWith('.txt')) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
