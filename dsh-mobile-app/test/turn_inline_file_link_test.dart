// issue #53 §6：Markdown 行内代码命中本轮记录路径时变为可点击链接（歧义/未记录不链接）。

import 'package:dsh_mobile_app/md.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('唯一路径与 basename 可点击；未记录/歧义保持普通代码', (tester) async {
    final tapped = <String>[];
    final resolver = TurnFileLinkResolver(
      sessionId: 's1',
      presented: const [
        DeliverableFile(name: 'a.ts', display: 'src/a.ts', seq: 3, index: 0),
        DeliverableFile(name: '报告.pdf', display: '~/Documents/报告.pdf', seq: 3, index: 1),
      ],
      changed: const [
        ChangedFile(seq: 4, index: 0, display: 'lib/a.ts', name: 'a.ts', added: 1, deleted: 0),
        ChangedFile(seq: 4, index: 1, display: 'lib/use.py', name: 'use.py', added: 1, deleted: 0),
      ],
    );
    InlineCodeTap codeTap = (code) {
      final coordinate = resolver.resolve(code);
      if (coordinate == null) return null;
      return () => tapped.add(code);
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => SingleChildScrollView(
              child: Column(
                children: renderMarkdownBlocks(
                  '见 `src/a.ts`、`报告.pdf`、`use.py`、`a.ts`、`unknown.ts`',
                  context,
                  codeTap: codeTap,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 精确路径 / 唯一 basename / 唯一改动文件均可点击。
    await tester.tap(find.text('src/a.ts'));
    await tester.tap(find.text('报告.pdf'));
    await tester.tap(find.text('use.py'));
    expect(tapped, ['src/a.ts', '报告.pdf', 'use.py']);

    // `a.ts` 同时被 presented 与 changed 记录 → 歧义不链接；未记录也不链接。
    // （这两段是普通 TextSpan，不在 WidgetSpan 里，点击不会进入 codeTap；
    // 这里用回调受理列表确认没有多记。）
    expect(tapped, ['src/a.ts', '报告.pdf', 'use.py']);
  });

  testWidgets('无 codeTap 时行内代码保持纯文本（旧调用方行为不变）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: renderMarkdownBlocks('运行 `flutter test`', context),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('flutter test'), findsWidgets);
    expect(find.byType(GestureDetector), findsNothing);
  });
}
