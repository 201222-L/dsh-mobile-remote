// issue #98：工作区外图首次 403 consent-required 自动弹授权；仅此次/本会话目录/取消；
// 取消后卡片“授权读取”再弹；授权后带 consentId 重试成功。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAF9Z2ZkAAAAASUVORK5CYII=',
);

class _Backend {
  _Backend({
    this.assistantText = '说明\n\n![worktree](worktree/pics/a.png)',
  });

  final String assistantText;
  final List<Map<String, dynamic>> consentBodies = [];
  final List<String?> imageConsentIds = [];
  bool rejectConsent = false;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://host.test'
    ..path = '/m'
    ..token = 'tkn';

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/history') {
      body = {
        'ok': true,
        'events': [
          {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
          {'seq': 2, 'type': 'user/message', 'data': {'messageId': 'u1', 'text': '看图', 'sourceKind': 'user'}},
          {'seq': 3, 'type': 'assistant/message', 'data': {'turn': 1, 'messageId': 'a1', 'text': assistantText}},
        ],
      };
    } else if (path == '/m/api/workspace-image/consent') {
      final parsed = jsonDecode(request.body) as Map<String, dynamic>;
      consentBodies.add(parsed);
      if (rejectConsent) {
        return http.Response(jsonEncode({'ok': false, 'error': 'consent-root-not-allowed'}), 403,
            headers: {'content-type': 'application/json'});
      }
      body = {
        'ok': true,
        'consentId': 'consent-1',
        'scope': parsed['scope'],
        'expiresAt': '2099-01-01T00:00:00Z',
      };
    } else if (path == '/m/api/workspace-image') {
      imageConsentIds.add(request.url.queryParameters['consentId']);
      if (request.url.queryParameters['consentId'] != 'consent-1') {
        return http.Response(jsonEncode({'ok': false, 'error': 'consent-required'}), 403,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
    } else if (path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else if (path == '/m/api/commands' || path == '/m/api/skills') {
      body = {'ok': true, 'commands': <Object>[], 'skills': <Object>[]};
    } else {
      body = {'ok': true};
    }
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
  }
}

Future<void> _pump(WidgetTester tester, _Backend backend) async {
  L10n.lang = 'en';
  final store = AppStore()
    ..sessionId = 's1'
    ..sessions = [Session(id: 's1', title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(store: store, apiClient: backend.api, onTitleChanged: () {}),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('首次 consent-required 自动弹窗；仅此次授权后带 consentId 重试显示', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend);
    expect(find.byKey(const Key('image-consent-dialog')), findsOneWidget);
    expect(backend.imageConsentIds, [null]);
    await tester.tap(find.byKey(const Key('image-consent-once')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.consentBodies.single['scope'], 'once');
    expect(backend.consentBodies.single['path'], 'worktree/pics/a.png');
    expect(backend.imageConsentIds, [null, 'consent-1']);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('取消后卡片显示“授权读取”，不自动重复弹；点击再弹并可选目录', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend);
    await tester.tap(find.byKey(const Key('image-consent-cancel')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('image-consent-dialog')), findsNothing);
    expect(find.byKey(const Key('markdown-image-retry')), findsOneWidget);
    expect(find.text('Authorize'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('image-consent-dialog')), findsNothing,
        reason: '取消后不得自动反复弹窗');

    await tester.tap(find.byKey(const Key('markdown-image-retry')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('image-consent-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('image-consent-directory')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.consentBodies.single['scope'], 'session-directory');
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('取消后滚动离屏/重建不自动弹，点「授权读取」才弹', (tester) async {
    final backend = _Backend(
      assistantText: '${[for (var i = 0; i < 80; i++) '行 $i'].join('\n')}\n\n![worktree](worktree/pics/a.png)',
    );
    await _pump(tester, backend);
    expect(find.byKey(const Key('image-consent-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('image-consent-cancel')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('image-consent-dialog')), findsNothing);

    final scrollable = find.byType(Scrollable).first;
    // 滚离图 → 再滚回；Sliver 回收/重建不得再次自动弹。
    await tester.drag(scrollable, const Offset(0, 1200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.drag(scrollable, const Offset(0, -1200));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('image-consent-dialog')), findsNothing,
        reason: '取消后重建不得自动弹窗');
    expect(find.byKey(const Key('markdown-image-retry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('markdown-image-retry')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('image-consent-dialog')), findsOneWidget,
        reason: '只有用户点授权读取才重新弹');
    await tester.tap(find.byKey(const Key('image-consent-once')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

}
