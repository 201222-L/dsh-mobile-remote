// Markdown 渲染 —— 完全对齐网页端 page.html 的 renderMarkdown：
// 段落/标题1-4/列表/引用/代码块/行内代码/表格/链接/分隔线，样式同 CSS。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'theme.dart';
import 'toast.dart';

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

// v3.0.0 review：块级判定正则提为顶层常量——渲染长消息时逐行构造会重复编译
final _mdTableSepRe = RegExp(r'^\s*\|?[\s:|-]+\|?\s*$');
final _mdHeadingRe = RegExp(r'^(#{1,4})\s+(.*)$');
final _mdHrRe = RegExp(r'^\s*(---|\*\*\*|___)\s*$');
final _mdBulletRe = RegExp(r'^\s*[-*+]\s+(.*)$');
final _mdNumberedRe = RegExp(r'^\s*(\d+)\.\s+(.*)$');
final _mdQuoteRe = RegExp(r'^\s*>\s?');

/// 合法代码围栏开启行 → 返回反引号数量 N；否则返回 null。
///
/// 规则：trim 后以 ≥3 个反引号开头，且其后的信息串（语言标注）不含反引号。
/// 缩进有意不做限制：CommonMark 只允许 ≤3 空格，但放宽可保住列表内缩进的代码块。
int? fenceOpenCount(String line) {
  final t = line.trim();
  if (!t.startsWith('```')) return null;
  var n = 0;
  while (n < t.length && t.codeUnitAt(n) == 0x60) {
    n++;
  }
  if (n < 3) return null;
  if (t.substring(n).contains('`')) return null; // 信息串含反引号 → 不是围栏
  return n;
}

/// 是否为长度为 [openCount] 的开启围栏的合法闭合行。
///
/// 规则：trim 后仅由 ≥openCount 个反引号组成（允许尾随空白）。因此围栏内部带其它
/// 字符的反引号行（例如 4 反引号文档围栏里的内层 ```js）不会被误判为闭合。
bool isFenceClose(String line, int openCount) {
  final t = line.trim();
  if (t.isEmpty || !t.startsWith('`')) return false;
  var n = 0;
  while (n < t.length && t.codeUnitAt(n) == 0x60) {
    n++;
  }
  if (n < openCount) return false;
  return t.substring(n).trim().isEmpty;
}

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
  var fenceLen = 0; // 当前开启围栏的反引号数量（闭合需 ≥ 该值）
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
          // v3.1.2（csborbbnc 反馈）：代码块「复制」按钮 + 长块提示（与行数同行）
          Row(
            children: [
              if (lineCount > 15)
                Expanded(
                  child: Text(
                    '代码 · $lineCount 行 · 可滚动查看',
                    style: TextStyle(fontSize: 10.5, color: ink2),
                  ),
                )
              else
                const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  showToast(context, '已复制代码（$lineCount 行）');
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_all, size: 13, color: ink2),
                      const SizedBox(width: 3),
                      Text('复制', style: TextStyle(fontSize: 10.5, color: ink2)),
                    ],
                  ),
                ),
              ),
            ],
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
    // issue #22：围栏按「开启反引号数量」配对——开启行记录 N，闭合行必须
    // 仅由 ≥N 个反引号组成。修复此前 startsWith('```') 二元翻转导致 4 反引号文档围栏
    // 包裹 3 反引号代码块时「正文被吞成代码、代码被当作正文」的错位。
    if (!inCode) {
      final open = fenceOpenCount(raw);
      if (open != null) {
        flushPara();
        flushList();
        flushTable();
        inCode = true;
        fenceLen = open;
        codeBuf.clear();
        i++;
        continue;
      }
    } else if (isFenceClose(raw, fenceLen)) {
      pushCodeBlock();
      inCode = false;
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
        _mdTableSepRe.hasMatch(lines[i + 1]) &&
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
    final heading = _mdHeadingRe.firstMatch(raw);
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
    if (_mdHrRe.hasMatch(raw)) {
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
    final bullet = _mdBulletRe.firstMatch(raw);
    final numbered = _mdNumberedRe.firstMatch(raw);
    if (bullet != null || numbered != null) {
      flushPara();
      flushTable();
      if (listEl.isEmpty) listOrdered = numbered != null;
      listEl.add(bullet != null ? bullet.group(1)! : numbered!.group(2)!);
      i++;
      continue;
    }
    // 引用
    if (_mdQuoteRe.hasMatch(raw)) {
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
                child: _InlineText(raw.replaceFirst(_mdQuoteRe, ''), style: TextStyle(fontSize: 14, height: 1.6, color: ink2)),
              ),
            ],
          ),
        ),
      ));
      i++;
      continue;
    }
    // v3.0.0：列表/表格后的普通段落必须先落盘前一区块——此前 flushPara 在循环结束时恒在
    // flushList/flushTable 之前执行，“- a\n- b\nprose” 会把 prose 渲染到列表上方
    // （表格后跟段落同病）。同时空行/段落行也顺带结束当前列表，符合 Markdown 直觉。
    if (listEl.isNotEmpty) flushList();
    if (tableBuf.isNotEmpty) flushTable();
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
///
/// 缺陷修复（GitLab !3）：此前每行是独立 `Row`、单元格各取自然宽，导致同一列在不同行的
/// x 起点相差数百像素、边框呈阶梯状错位（观感像内容跑到表格外）；且单元格用裸 `Text`，
/// 行内 Markdown（`**加粗**`、`` `code` ``、链接）会把标记原样显示。现改为：
/// 1. **共享列宽**——先测量每列的最大自然宽（含表头），所有行共用同一组宽度；
/// 2. 单元格复用 [_InlineText]，与段落同一套行内解析；
/// 3. 边框改为「单一外框 + 行/列单线分隔」，同行单元格等高，不再出现双线与断框。
///
/// 列宽 = 内容自然宽、不换行、不设上限；整表超宽时仍横向滚动（行为与网页端 `.md-table`
/// 的 nowrap 一致）。
Widget _buildTable(List<String> rows, BuildContext context, Color line, Color ink) {
  List<String> parseRow(String l) =>
      l.trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((s) => s.trim()).toList();
  final head = parseRow(rows[0]);
  final body = <List<String>>[];
  for (var i = 2; i < rows.length; i++) {
    body.add(parseRow(rows[i]));
  }

  const hPad = 9.0; // 单元格左右内边距
  const vPad = 5.0; // 单元格上下内边距
  const fontSize = 13.0;

  TextStyle cellStyle({bool header = false}) => TextStyle(
        fontSize: fontSize,
        fontWeight: header ? FontWeight.w600 : FontWeight.w400,
        color: ink,
      );

  var colCount = head.length;
  for (final r in body) {
    if (r.length > colCount) colCount = r.length;
  }
  if (colCount == 0) return const SizedBox.shrink();

  // 用与渲染完全相同的 spans（含粗体/代码样式）测量，并按系统字号缩放；
  // 否则粗体或放大字号下测量偏小，单元格会意外换行。
  final textScaler = MediaQuery.textScalerOf(context);
  // 必须与渲染路径同源：`_InlineText` 的 Text.rich 会把样式并入 ambient DefaultTextStyle
  // （字体族/度量都参与），只按裸 style 测量会偏小 → 单元格意外换行。
  final ambient = DefaultTextStyle.of(context).style;
  double measure(String text, {required bool header}) {
    final style = ambient.merge(cellStyle(header: header));
    final tp = TextPainter(
      text: TextSpan(children: _inlineSpans(text, context), style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  final widths = List<double>.filled(colCount, 0);
  for (var c = 0; c < colCount; c++) {
    var w = c < head.length ? measure(head[c], header: true) : 0.0;
    for (final r in body) {
      if (c < r.length) {
        final m = measure(r[c], header: false);
        if (m > w) w = m;
      }
    }
    // +1 抵消亚像素取整，保证不换行
    widths[c] = w + hPad * 2 + 1;
  }

  Widget cell(String text, int c,
          {required bool header, required bool lastRow, required bool lastCol}) =>
      Container(
        width: widths[c],
        padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        decoration: BoxDecoration(
          color: header ? line : null,
          // 内部只画右/下分隔线，最后一行/列不画；外框由外层容器统一提供 → 单线不重叠
          border: Border(
            right: lastCol ? BorderSide.none : BorderSide(color: line),
            bottom: lastRow ? BorderSide.none : BorderSide(color: line),
          ),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _InlineText(text, style: cellStyle(header: header)),
        ),
      );

  Widget row(List<String> cells, {required bool header, required bool lastRow}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < colCount; c++)
            cell(c < cells.length ? cells[c] : '', c,
                header: header, lastRow: lastRow, lastCol: c == colCount - 1),
        ],
      );

  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Container(
      decoration: BoxDecoration(border: Border.all(color: line)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row(head, header: true, lastRow: body.isEmpty),
          for (var r = 0; r < body.length; r++)
            row(body[r], header: false, lastRow: r == body.length - 1),
        ],
      ),
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
