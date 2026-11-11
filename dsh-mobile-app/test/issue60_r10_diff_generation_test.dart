// issue #60 R10：diff 页切文件后，旧请求的成功/失败/loading 收尾不得覆盖新文件。
//
// 复现：打开 A 后立即切到 B；B 先返回、A 后返回时，旧实现把 A 的 diff 显示在 B 的
// 标题/索引下（用户会查看/复制错误文件的差异）。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/turn_changes_diff_screen.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _files = [
  ChangedFile(seq: 7, index: 0, display: 'src/a.ts', name: 'a.ts', added: 1, deleted: 0),
  ChangedFile(seq: 7, index: 1, display: 'src/b.ts', name: 'b.ts', added: 1, deleted: 0),
];

http.Response _diffResponse(String display, String body) => http.Response(
  jsonEncode({
    'ok': true,
    'state': 'available',
    'diff': {
      'kind': 'text',
      'display': display,
      'before': true,
      'after': true,
      'coarse': false,
      'diff': '--- a/$display\n+++ b/$display\n@@ -1,1 +1,1 @@\n-$body-old\n+$body-new\n',
      'truncated': false,
    },
  }),
  200,
  headers: {'content-type': 'application/json'},
);

Widget _wrap(Api api) => MaterialApp(
  home: TurnChangesDiffScreen(
    api: api,
    sessionId: 's1',
    turn: 2,
    files: _files,
  ),
);

void main() {
  testWidgets('乱序返回：B 先完成、A 后完成，不覆盖当前 B', (tester) async {
    final gates = <int, Completer<void>>{0: Completer<void>(), 1: Completer<void>()};
    final api = Api(
      client: MockClient((request) async {
        final index = int.parse(request.url.queryParameters['index']!);
        await gates[index]!.future;
        return index == 0
            ? _diffResponse('src/a.ts', 'A')
            : _diffResponse('src/b.ts', 'B');
      }),
    )
      ..baseUrl = 'http://r10.test'
      ..path = '/m'
      ..token = '';

    await tester.pumpWidget(_wrap(api));
    await tester.pump(); // 初始 A 请求在途

    // 立即切到 B（加载期间允许切换是现状）。
    await tester.tap(find.byKey(const Key('turn-diff-next')));
    await tester.pump();

    // B 先返回。
    gates[1]!.complete();
    await tester.pumpAndSettle();
    expect(find.text('src/b.ts'), findsWidgets);

    // A 的旧响应后到：不得覆盖 B 的 diff/标题。
    gates[0]!.complete();
    await tester.pumpAndSettle();

    expect(find.text('src/b.ts'), findsWidgets, reason: '标题必须是当前文件');
    expect(find.textContaining('B-new'), findsWidgets, reason: '当前应显示 B 的 diff');
    expect(find.textContaining('A-new'), findsNothing, reason: '旧 A 的响应不得污染 B');
  });

  testWidgets('失败回写也受代际保护：旧 A 的错误不得显示在 B 下', (tester) async {
    final gates = <int, Completer<void>>{0: Completer<void>(), 1: Completer<void>()};
    final api = Api(
      client: MockClient((request) async {
        final index = int.parse(request.url.queryParameters['index']!);
        await gates[index]!.future;
        if (index == 0) {
          return http.Response(
            jsonEncode({'error': 'diff-not-found'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        return _diffResponse('src/b.ts', 'B');
      }),
    )
      ..baseUrl = 'http://r10.test'
      ..path = '/m'
      ..token = '';

    await tester.pumpWidget(_wrap(api));
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-diff-next')));
    await tester.pump();

    gates[1]!.complete();
    await tester.pumpAndSettle();
    gates[0]!.complete(); // 旧请求失败
    await tester.pumpAndSettle();

    expect(find.textContaining('无法读取对比'), findsNothing, reason: '旧请求的错误不得覆盖当前文件');
    expect(find.textContaining('B-new'), findsWidgets);
  });
}
