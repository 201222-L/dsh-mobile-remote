import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/md.dart';

/// 代码围栏边界回归（issue #22 补充）：
/// 覆盖 md_fence_test.dart 未涉及的边界——闭合围栏长于开启、多层反引号嵌套、
/// 开启行信息串含反引号（CommonMark 下不是围栏）、围栏内出现更短的纯反引号行、
/// 连续围栏、围栏内 Markdown 语法不得被解析。
///
/// 全部只使用公开 API renderMarkdownBlocks，因此在 issue #22 修复前的代码上也能编译：
/// 其中「围栏内更短的纯反引号行」「5 反引号嵌 4 反引号」「信息串含反引号」三例在修复前
/// 会失败，修复后通过——作为该修复的红→绿对照证据。

Finder _codeCardText([String? contains]) => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.style?.fontFamily == 'monospace' &&
          (contains == null || (w.data ?? '').contains(contains)),
    );

Future<void> _pump(WidgetTester tester, String md) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
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
  group('围栏边界回归（issue #22）', () {
    testWidgets('闭合围栏长于开启（开 3 闭 4）仍正常闭合', (tester) async {
      await _pump(tester, '```js\nconst a = 1;\n````\n\n后续正文\n');
      expect(_codeCardText('const a = 1;'), findsOneWidget);
      expect(_codeCardText('后续正文'), findsNothing); // 正文不该被吞进代码卡片
      expect(find.textContaining('后续正文'), findsWidgets); // 但确实渲染出来了
    });

    testWidgets('围栏内出现更短的纯反引号行 → 仍是代码内容', (tester) async {
      await _pump(tester, '````text\n```\n还在代码里\n````\n');
      expect(_codeCardText('还在代码里'), findsOneWidget);
      expect(_codeCardText('```'), findsOneWidget);
    });

    testWidgets('五反引号围栏内含四反引号行 → 全部算代码', (tester) async {
      await _pump(tester, '`````\n````\nstill code\n`````\n');
      expect(_codeCardText('still code'), findsOneWidget);
      expect(_codeCardText('````'), findsOneWidget);
    });

    testWidgets('开启行信息串含反引号 → 不是围栏（CommonMark），不得进代码卡片', (tester) async {
      await _pump(tester, '```a`b\nhello world\n```\n');
      expect(_codeCardText('hello world'), findsNothing);
    });

    testWidgets('两个连续围栏互不串味', (tester) async {
      await _pump(tester, '```js\none\n```\n\n正文夹层\n\n```js\ntwo\n```\n');
      expect(_codeCardText('one'), findsOneWidget);
      expect(_codeCardText('two'), findsOneWidget);
      expect(_codeCardText('正文夹层'), findsNothing);
      expect(find.textContaining('正文夹层'), findsWidgets);
    });

    testWidgets('围栏内 Markdown 语法不得被解析（标题/列表保持字面）', (tester) async {
      await _pump(tester, '````markdown\n### 不是标题\n- 不是列表\n````\n');
      expect(_codeCardText('### 不是标题'), findsOneWidget);
      expect(_codeCardText('- 不是列表'), findsOneWidget);
    });
  });
}
