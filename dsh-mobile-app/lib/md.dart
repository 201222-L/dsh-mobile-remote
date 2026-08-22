// Markdown 渲染 —— 完全对齐网页端 page.html 的 renderMarkdown：
// 段落/标题1-4/列表/引用/代码块/行内代码/表格/链接/分隔线，样式同 CSS。
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'theme.dart';

/// 只放行 http/https 链接（v2.6.0 安全加固）：
/// 防止消息内容（或中间人篡改的回复）用 file:/intent:/tel: 等 scheme 拉起任意应用/Intent。
/// 解析失败或 scheme 不允许时返回 null（渲染为纯文本，不可点击）。
Uri? safeLinkUrl(String raw) {
  try {
    final uri = Uri.parse(raw.trim());
    if (uri.scheme == 'http' || uri.scheme == 'https') return uri;
  } catch (_) {}
  return null;
}

/// 行内 token：**加粗** *斜体* `代码` [链接](url)
final _inlineRe = RegExp(r'(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|`[^`]+`|\[[^\]]*\]\([^)\s]+\))');

/// 渲染完整 Markdown 文本 → 块级 Widget 列表（放置于 Column 中）。
List<Widget> renderMarkdownBlocks(String text, BuildContext context) {
  final ink = DshColors.ink(context);
  final ink2 = DshColors.ink2(context);
  final line = DshColors.line(context);
  final brandSoft = DshColors.brandSoft(context);
  final surface = DshColors.surface(context);
  final blocks = <Widget>[];
  final lines = text.split('\n');
  var i = 0;
  var inCode = false;
  final codeBuf = <String>[];
  var listEl = <String>[]; // 当前列表项内容
  var listOrdered = false;
  var para = <String>[];
  var tableBuf = <String>[];

  void flushPara() {
    if (para.isEmpty) return;
    blocks.add(Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _InlineText(para.join('\n'), style: TextStyle(fontSize: 15, height: 1.6, color: ink)),
    ));
    para = [];
  }

  void flushList() {
    if (listEl.isEmpty) return;
    blocks.add(Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var idx = 0; idx < listEl.length; idx++)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    child: Text(
                      listOrdered ? '${idx + 1}.' : '•',
                      style: TextStyle(fontSize: 14, color: ink2, height: 1.6),
                    ),
                  ),
                  Expanded(child: _InlineText(listEl[idx], style: TextStyle(fontSize: 15, height: 1.6, color: ink))),
                ],
              ),
            ),
        ],
      ),
    ));
    listEl = [];
  }

  void flushTable() {
    if (tableBuf.isEmpty) return;
    blocks.add(_buildTable(tableBuf, context, line, ink));
    tableBuf = [];
  }

  void pushCodeBlock() {
    if (codeBuf.isEmpty) return;
    final lineCount = codeBuf.length;
    final code = codeBuf.join('\n');
    codeBuf.clear();
    blocks.add(Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 长代码块限高（320px 内部滚动），避免单个消息撑出数千像素高度
          // （过高的列表总高度在部分设备上会触发绘制上限导致空白）。
          if (lineCount > 15)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '代码 · $lineCount 行 · 可滚动查看',
                style: TextStyle(fontSize: 10.5, color: ink2),
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  code,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.5, color: ink),
                ),
              ),
            ),
          ),
        ],
      ),
    ));
  }

  while (i < lines.length) {
    final raw = lines[i];
    final lineT = raw.trim();
    if (lineT.startsWith('```')) {
      flushPara();
      flushList();
      flushTable();
      if (!inCode) {
        inCode = true;
        codeBuf.clear();
      } else {
        pushCodeBlock();
        inCode = false;
      }
      i++;
      continue;
    }
    if (inCode) {
      codeBuf.add(raw);
      i++;
      continue;
    }
    // 表格：| a | b | 下一行是分隔行 |---|---|
    final tableStart = raw.startsWith('|') &&
        i + 1 < lines.length &&
        RegExp(r'^\s*\|?[\s:|-]+\|?\s*$').hasMatch(lines[i + 1]) &&
        lines[i + 1].contains('-');
    if (tableStart) {
      flushPara();
      flushList();
      tableBuf.add(raw);
      i++;
      while (i < lines.length && lines[i].startsWith('|')) {
        tableBuf.add(lines[i]);
        i++;
      }
      flushTable();
      continue;
    }
    // 标题
    final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(raw);
    if (heading != null) {
      flushPara();
      flushList();
      flushTable();
      final level = heading.group(1)!.length;
      final size = [18.0, 16.5, 15.5, 15.0][level - 1];
      blocks.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: _InlineText(heading.group(2)!, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, height: 1.4, color: ink)),
      ));
      i++;
      continue;
    }
    // 分隔线
    if (RegExp(r'^\s*(---|\*\*\*|___)\s*$').hasMatch(raw)) {
      flushPara();
      flushList();
      flushTable();
      blocks.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Divider(color: line, height: 1),
      ));
      i++;
      continue;
    }
    // 列表
    final bullet = RegExp(r'^\s*[-*+]\s+(.*)$').firstMatch(raw);
    final numbered = RegExp(r'^\s*(\d+)\.\s+(.*)$').firstMatch(raw);
    if (bullet != null || numbered != null) {
      flushPara();
      flushTable();
      if (listEl.isEmpty) listOrdered = numbered != null;
      listEl.add(bullet != null ? bullet.group(1)! : numbered!.group(2)!);
      i++;
      continue;
    }
    // 引用
    if (RegExp(r'^\s*>\s?').hasMatch(raw)) {
      flushPara();
      flushList();
      flushTable();
      blocks.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: brandSoft,
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, margin: const EdgeInsets.only(right: 10), color: DshColors.brand(context)),
              Expanded(
                child: _InlineText(raw.replaceFirst(RegExp(r'^\s*>\s?'), ''), style: TextStyle(fontSize: 14, height: 1.6, color: ink2)),
              ),
            ],
          ),
        ),
      ));
      i++;
      continue;
    }
    para.add(raw);
    i++;
  }
  flushPara();
  flushList();
  flushTable();
  if (inCode && codeBuf.isNotEmpty) pushCodeBlock();
  return blocks;
}

/// 表格（对齐 .md-table：边框、表头灰底、nowrap）。
Widget _buildTable(List<String> rows, BuildContext context, Color line, Color ink) {  List<String> parseRow(String l) =>
      l.trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((s) => s.trim()).toList();
  final head = parseRow(rows[0]);
  final body = <List<String>>[];
  for (var i = 2; i < rows.length; i++) {
    body.add(parseRow(rows[i]));
  }
  Widget cell(String text, {bool header = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: line),
          color: header ? line : null,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: header ? FontWeight.w600 : FontWeight.w400,
            color: ink,
          ),
        ),
      );
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [for (final h in head) cell(h, header: true)]),
        for (final row in body) Row(children: [for (final c in row) cell(c)]),
      ],
    ),
  );
}

/// 段落文本（可选中复制），内部解析行内样式。
class _InlineText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _InlineText(this.text, {required this.style});

  @override
  Widget build(BuildContext context) {
    // v2.9.0 review(M3)：行内解析带 context——深色模式下链接用品牌深色（原静态浅色对比度差）
    final spans = _inlineSpans(text, context);
    // 用普通 Text 渲染（SelectableText 在部分 Android 设备上长文本换行/重叠渲染异常）
    return Text.rich(
      TextSpan(children: spans, style: style),
      style: style,
    );
  }
}

/// 行内解析：**加粗** / *斜体* / `代码` / [文字](链接)
List<InlineSpan> _inlineSpans(String text, BuildContext context) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inlineRe.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    final tok = m.group(0)!;
    if (tok.startsWith('**')) {
      spans.add(TextSpan(text: tok.substring(2, tok.length - 2), style: const TextStyle(fontWeight: FontWeight.w700)));
    } else if (tok.startsWith('`')) {
      spans.add(TextSpan(
        text: tok.substring(1, tok.length - 1),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          backgroundColor: DshTheme.line.withValues(alpha: 0.6),
        ),
      ));
    } else if (tok.startsWith('[')) {
      final mm = RegExp(r'^\[([^\]]*)\]\(([^)]*)\)$').firstMatch(tok);
      if (mm != null) {
        final target = safeLinkUrl(mm.group(2)!);
        if (target == null) {
          // 非 http/https 链接（或解析失败）：渲染为纯文本，不可点击（v2.6.0）
          spans.add(TextSpan(text: mm.group(1)!));
        } else {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () => launchUrl(target, mode: LaunchMode.externalApplication),
              child: Text(
                mm.group(1)!,
                style: TextStyle(color: DshColors.brand(context), decoration: TextDecoration.underline, decorationColor: DshColors.brand(context)),
              ),
            ),
          ));
        }
      } else {
        spans.add(TextSpan(text: tok));
      }
    } else {
      spans.add(TextSpan(text: tok.substring(1, tok.length - 1), style: const TextStyle(fontStyle: FontStyle.italic)));
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}
