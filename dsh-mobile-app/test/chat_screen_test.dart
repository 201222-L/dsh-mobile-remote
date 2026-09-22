import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  testWidgets('chat app bar keeps task tools without duplicate debug toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(store: AppStore(), onTitleChanged: () {}),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.assignment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.timeline_outlined), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
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

  testWidgets('ordinary mode keeps failed tool collapsed until user expands it', (
    tester,
  ) async {
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
  });
}
