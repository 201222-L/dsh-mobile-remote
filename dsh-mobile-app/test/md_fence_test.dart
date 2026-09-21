import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/md.dart';

/// 代码围栏解析回归（issue #9）：
/// 此前围栏判定是「以三反引号开头」的二元翻转、不记录开启长度——4 反引号文档围栏
/// 包裹 3 反引号代码块时，内层开启行被当成闭合行，导致 Markdown 正文被吞成代码卡片、
/// 真正的代码被渲染成正文。修复后按「开启反引号数量 N」配对：闭合行必须仅由 ≥N 个
/// 反引号组成（允许尾随空白），围栏内带其它字符的反引号行一律算内容。

/// issue 原样本（4 反引号外层 + 3 反引号内层）。
/// 按 CommonMark：4 反引号围栏内的**全部内容**（含 `### 标题` 与内层 ```js 行）都是代码。
const _issueSample = '''
````markdown
### 标题

- 列表项 A

```js
const x = 1;
final y = 2;
```
````
''';

/// issue 截图场景：4 反引号围栏内含 23 行正文（无内层代码块）。
/// 按 CommonMark 整段是一个代码块 → 代码卡片 23 行（>15 触发「可滚动查看」文案）。
final _longProseSample =
    '````markdown\n${List.generate(23, (i) => '- 第 $i 行正文').join('\n')}\n````\n';

/// 代码卡片内的文本（代码块以 monospace Text 呈现；用于区分「代码卡片」与行内富文本）。
Finder _codeCardText([String? contains]) => find.byWidgetPredicate(
      (w) => w is Text && w.style?.fontFamily == 'monospace' && (contains == null || (w.data ?? '').contains(contains)),
    );

/// 普通三反引号 + 17 行代码（触发「代码 · N 行 · 可滚动查看」文案）。
final _longCode = '```text\n${List.generate(17, (i) => 'line$i').join('\n')}\n```';

Future<void> _pump(WidgetTester tester, String md, {double width = 360}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: Builder(
            builder: (context) => SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: renderMarkdownBlocks(md, context),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  group('围栏开启判定 fenceOpenCount', () {
    test('3/4/5 个反引号均可作为开启围栏', () {
      expect(fenceOpenCount('```js'), 3);
      expect(fenceOpenCount('````markdown'), 4);
      expect(fenceOpenCount('`````'), 5);
    });

    test('不足 3 个反引号 → 不是围栏', () {
      expect(fenceOpenCount('``'), isNull);
      expect(fenceOpenCount('`` js'), isNull);
    });

    test('信息串含反引号 → 不是围栏（CommonMark）', () {
      expect(fenceOpenCount('```a`b'), isNull);
    });

    test('缩进不限（保住列表内缩进的代码块）', () {
      expect(fenceOpenCount('    ```js'), 3);
      expect(fenceOpenCount('  ````'), 4);
    });

    test('普通行 → 不是围栏', () {
      expect(fenceOpenCount('### 标题'), isNull);
      expect(fenceOpenCount(''), isNull);
    });
  });

  group('围栏闭合判定 isFenceClose', () {
    test('闭合长度必须 ≥ 开启长度', () {
      expect(isFenceClose('```', 3), isTrue);
      expect(isFenceClose('````', 3), isTrue);
      expect(isFenceClose('```', 4), isFalse);
    });

    test('允许尾随空白与缩进', () {
      expect(isFenceClose('```   ', 3), isTrue);
      expect(isFenceClose('  ````  ', 4), isTrue);
    });

    test('带其它字符的反引号行不是闭合（内层 ```js 不会被误判）', () {
      expect(isFenceClose('```js', 3), isFalse);
      expect(isFenceClose('````markdown', 4), isFalse);
    });

    test('空行不是闭合', () {
      expect(isFenceClose('', 3), isFalse);
    });
  });

  group('围栏渲染回归（issue #9）', () {
    testWidgets('4 反引号围栏内全部内容统一在一个代码卡片中（不再半卡半正文）', (tester) async {
      await _pump(tester, _issueSample);
      // 整段（含 Markdown 正文行与内层代码行）都在同一个 monospace 代码卡片内
      expect(_codeCardText(), findsOneWidget);
      expect(_codeCardText('### 标题'), findsOneWidget);
      expect(_codeCardText('列表项 A'), findsOneWidget);
      expect(_codeCardText('const x = 1;'), findsOneWidget);
      expect(_codeCardText('final y = 2;'), findsOneWidget);
    });

    testWidgets('长正文围栏（23 行）整段为代码卡片且行数正确', (tester) async {
      await _pump(tester, _longProseSample);
      // 整段是代码块 → 23 行（修复前错位后卡片只有前半段，行数与内容都不对）
      expect(find.textContaining('代码 · 23 行'), findsOneWidget);
      expect(_codeCardText('第 0 行正文'), findsOneWidget);
      expect(_codeCardText('第 22 行正文'), findsOneWidget);
    });

    testWidgets('普通三反引号长代码块：行数等于真实行数', (tester) async {
      await _pump(tester, _longCode);
      expect(find.textContaining('代码 · 17 行'), findsOneWidget);
    });

    testWidgets('未闭合围栏：内容仍按代码渲染到结尾', (tester) async {
      await _pump(tester, '```js\nconst open = true;\n');
      expect(_codeCardText('const open = true;'), findsOneWidget);
    });

    testWidgets('列表内缩进围栏仍被识别为代码块', (tester) async {
      await _pump(tester, '- 步骤：\n\n    ```js\n    const nested = 1;\n    ```\n');
      expect(_codeCardText('const nested = 1;'), findsOneWidget);
    });
  });
}
