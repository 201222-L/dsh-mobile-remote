// issue #53：本轮改动 diff 页（文本 / binary / 文件切换 / 失败重试）。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/turn_changes_diff_screen.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _files = [
  ChangedFile(seq: 7, index: 0, display: 'src/a.ts', name: 'a.ts', added: 2, deleted: 1),
  ChangedFile(seq: 7, index: 1, display: 'src/b.ts', name: 'b.ts', added: 1, deleted: 0),
];

Api _api(MockClient client) => Api(client: client)
  ..baseUrl = 'http://diff.test'
  ..path = '/m'
  ..token = '';

http.Response _textDiff(int index) => http.Response(
  jsonEncode({
    'ok': true,
    'state': 'available',
    'diff': {
      'kind': 'text',
      'display': 'src/a.ts',
      'before': true,
      'after': true,
      'coarse': index == 1,
      'diff': '--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,1 +1,1 @@\n-old line\n+new line\n',
      'truncated': false,
    },
  }),
  200,
  headers: {'content-type': 'application/json'},
);

Widget _wrap(Api api, {int initialIndex = 0}) => MaterialApp(
  home: TurnChangesDiffScreen(
    api: api,
    sessionId: 's1',
    turn: 2,
    files: _files,
    initialIndex: initialIndex,
  ),
);

void main() {
  testWidgets('文本 diff 渲染统一文本，切换文件重新取数并提示 coarse', (tester) async {
    final requested = <String?>[];
    final api = _api(
      MockClient((request) async {
        requested.add(request.url.queryParameters['index']);
        final index = int.tryParse(
          request.url.queryParameters['index'] ?? '0',
        );
        return _textDiff(index ?? 0);
      }),
    );
    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();
    expect(requested, ['0']);
    expect(find.byKey(const Key('turn-diff-viewer')), findsOneWidget);
    expect(find.textContaining('old line'), findsWidgets);
    expect(find.textContaining('new line'), findsWidgets);
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('turn-diff-next')));
    await tester.pumpAndSettle();
    expect(requested, ['0', '1']);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.textContaining('逐行对比超时'), findsWidgets);
  });

  testWidgets('binary 文件显示不可比对提示', (tester) async {
    final api = _api(
      MockClient((request) async {
        return http.Response(
          jsonEncode({
            'ok': true,
            'state': 'available',
            'diff': {'kind': 'binary', 'display': 'bin.dat'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();
    expect(find.textContaining('二进制文件'), findsWidgets);
  });

  testWidgets('读取失败可重试，成功后渲染', (tester) async {
    var calls = 0;
    final api = _api(
      MockClient((request) async {
        calls += 1;
        if (calls == 1) {
          return http.Response(
            jsonEncode({'error': 'diff-not-found'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        return _textDiff(0);
      }),
    );
    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取对比'), findsWidgets);
    await tester.tap(find.byKey(const Key('turn-diff-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('old line'), findsWidgets);
  });
}
