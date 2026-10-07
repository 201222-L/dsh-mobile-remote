import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TimelineBackend {
  _TimelineBackend() {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://timeline.test'
      ..path = '/m'
      ..token = ''
      ..timelineCapabilities = const TimelineCapabilities(
        version: 1,
        live: true,
        history: true,
        detail: true,
        unknownEvents: true,
        callCorrelation: true,
      );
  }

  late final Api api;
  int detailRequests = 0;

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    if (request.url.path == '/m/api/history') {
      body = request.url.queryParameters.containsKey('after')
          ? {'ok': true, 'events': <Object>[], 'hasMore': false}
          : {
              'ok': true,
              'events': [
                {
                  'seq': 1,
                  'type': 'tool/call',
                  'detail': {'available': true, 'seq': 1},
                  'data': {
                    'callId': 'call-failed',
                    'name': 'shell',
                    'arguments': '{"command":"false"}',
                  },
                },
                {
                  'seq': 2,
                  'type': 'tool/result',
                  'detail': {'available': true, 'seq': 2},
                  'data': {
                    'callId': 'call-failed',
                    'name': 'shell',
                    'isError': true,
                    'text': 'SUMMARY-FAIL',
                  },
                },
              ],
              'hasMore': false,
            };
    } else if (request.url.path == '/m/api/event-detail') {
      detailRequests++;
      body = {
        'ok': true,
        'event': {
          'seq': 2,
          'type': 'tool/result',
          'data': {
            'callId': 'call-failed',
            'name': 'shell',
            'isError': true,
            'text': 'FULL-FAIL',
          },
        },
        'degraded': true,
        'detailMode': 'current-surface',
      };
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (request.url.path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else if (request.url.path == '/m/api/usage') {
      body = {'ok': true};
    } else {
      body = {'ok': true};
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Future<void> _pumpChat(
  WidgetTester tester,
  AppStore store,
  _TimelineBackend backend,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: const ValueKey('timeline-chat'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('chat app bar opens one conversation action rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(store: AppStore(), onTitleChanged: () {}),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('对话操作'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byIcon(Icons.assignment_outlined), findsNothing);
    expect(find.byIcon(Icons.copy_all), findsNothing);

    await tester.tap(find.byTooltip('对话操作'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Git'), findsOneWidget);
    expect(find.byTooltip('文件'), findsOneWidget);
    expect(find.byTooltip('任务 / 子代理 / 目标'), findsOneWidget);
    expect(find.byTooltip('复制当前已加载的对话'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Git'), findsNothing);
    expect(find.byTooltip('对话操作'), findsOneWidget);
  });

  testWidgets('files action opens the session file browser', (tester) async {
    final backend = _TimelineBackend();
    final store = AppStore()
      ..sessionId = 'session-files'
      ..sessions = [
        Session(id: 'session-files', title: 'F', cwd: null, createdAt: 1),
      ];
    await _pumpChat(tester, store, backend);

    await tester.tap(find.byTooltip('对话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();

    // 打开的是会话文件浏览页；该会话无 cwd，因此页内说明原因而不是空白。
    expect(find.text('文件'), findsWidgets);
    expect(find.byKey(const Key('sf-error')), findsOneWidget);
    expect(find.textContaining('工作目录'), findsOneWidget);
    // 操作栏已关闭
    expect(find.byTooltip('Git'), findsNothing);
  });

  testWidgets('session tools remain in their existing bottom sheet', (
    tester,
  ) async {
    final backend = _TimelineBackend();
    final store = AppStore()..sessionId = 'session-tools';
    await _pumpChat(tester, store, backend);

    await tester.tap(find.byTooltip('对话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('任务 / 子代理 / 目标'));
    await tester.pumpAndSettle();

    expect(find.text('会话工具'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byTooltip('Git'), findsNothing);
  });

  testWidgets('no-session actions keep their existing behavior', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(store: AppStore(), onTitleChanged: () {}),
      ),
    );
    await tester.pump();

    Future<void> selectAction(String label) async {
      await tester.tap(find.byTooltip('对话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
    }

    await selectAction('Git');
    expect(find.byTooltip('对话操作'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);

    await selectAction('任务 / 子代理 / 目标');
    expect(find.byTooltip('对话操作'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);

    await selectAction('复制当前已加载的对话');
    expect(find.text('当前没有可复制的对话内容'), findsOneWidget);
  });

  testWidgets(
    'conversation action order can be dragged and persists across chats',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.loadPrefs();

      Future<void> pumpScreen(AppStore currentStore, String key) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ChatScreen(
              key: ValueKey(key),
              store: currentStore,
              onTitleChanged: () {},
            ),
          ),
        );
        await tester.pump();
      }

      Future<void> openRail() async {
        await tester.tap(find.byTooltip('对话操作'));
        await tester.pumpAndSettle();
      }

      double centerY(String label) =>
          tester.getCenter(find.byTooltip(label)).dy;

      await pumpScreen(store, 'first-chat');
      await openRail();
      expect(centerY('Git'), lessThan(centerY('任务 / 子代理 / 目标')));
      expect(centerY('任务 / 子代理 / 目标'), lessThan(centerY('复制当前已加载的对话')));

      final drag = await tester.startGesture(
        tester.getCenter(find.byTooltip('Git')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(
        tester.getCenter(find.byTooltip('复制当前已加载的对话')) + const Offset(0, 112),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await drag.up();
      await tester.pumpAndSettle();

      expect(centerY('任务 / 子代理 / 目标'), lessThan(centerY('复制当前已加载的对话')));
      expect(centerY('复制当前已加载的对话'), lessThan(centerY('Git')));

      await tester.tapAt(const Offset(20, 100));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      final restoredStore = AppStore();
      await restoredStore.loadPrefs();
      await pumpScreen(restoredStore, 'restored-chat');
      await openRail();

      expect(centerY('任务 / 子代理 / 目标'), lessThan(centerY('复制当前已加载的对话')));
      expect(centerY('复制当前已加载的对话'), lessThan(centerY('Git')));
    },
  );

  testWidgets('chat app bar keeps tools without duplicate debug toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(store: AppStore(), onTitleChanged: () {}),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('对话操作'), findsOneWidget);
    expect(find.byIcon(Icons.assignment_outlined), findsNothing);
    expect(find.byIcon(Icons.timeline_outlined), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);

    await tester.tap(find.byTooltip('对话操作'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.assignment_outlined), findsOneWidget);
  });

  testWidgets('debug mode auto-expands failed tool and loads detail', (
    tester,
  ) async {
    final backend = _TimelineBackend();
    final store = AppStore()
      ..sessionId = 'session-failed'
      ..timelineDebug = true;

    await _pumpChat(tester, store, backend);

    expect(backend.detailRequests, 1);
  });

  testWidgets(
    'ordinary mode keeps failed tool collapsed until user expands it',
    (tester) async {
      final backend = _TimelineBackend();
      final store = AppStore()
        ..sessionId = 'session-failed'
        ..timelineDebug = false;

      await _pumpChat(tester, store, backend);

      expect(find.text('shell'), findsOneWidget);
      expect(find.text('FULL-FAIL'), findsNothing);
      expect(backend.detailRequests, 0);

      await tester.ensureVisible(find.text('shell'));
      await tester.tap(find.text('shell'));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(backend.detailRequests, 1);
    },
  );
}
