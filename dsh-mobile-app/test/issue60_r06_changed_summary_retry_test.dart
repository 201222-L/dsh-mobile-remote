// issue #60 R06：改动摘要懒加载门闩只表示 in-flight；TTL 到期/会话重建后能重新拉取。
//
// 复现原缺陷：`_changedSummaryRequested` 只 add 不移除 → 负缓存/正缓存 TTL 到期后
// 卡片永久消失，只能重进会话恢复。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:dsh_mobile_app/widgets/turn_tail_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RetryBackend {
  _RetryBackend({required this.summaryPayloads, this.summaryGate});

  /// 第 N 次 summary 请求返回的 state 序列（超出取最后一项）。
  final List<Map<String, dynamic>> summaryPayloads;
  final Completer<void>? summaryGate;
  int summaryRequests = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://r06.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
    )
    ..turnTailCapabilities = const TurnTailCapabilities(
      version: 1,
      presented: true,
      changed: true,
      changesDiff: true,
    );

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      return _json({
        'ok': true,
        'hasMore': false,
        'turnTails': {
          '1': {'changes': true, 'presented': false},
        },
        'events': [
          {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
          {
            'seq': 2,
            'type': 'user/message',
            'data': {'messageId': 'u1', 'text': '改点东西', 'sourceKind': 'user'},
          },
          {
            'seq': 3,
            'type': 'assistant/message',
            'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '好了'},
          },
          {
            'seq': 4,
            'type': 'turn/end',
            'data': {
              'turn': 1,
              'reason': {'kind': 'completed'},
              'tail': {'changes': true, 'presented': false},
            },
          },
        ],
      });
    }
    if (request.url.path == '/m/api/changes/summary') {
      summaryRequests += 1;
      if (summaryGate != null && summaryRequests == 1) await summaryGate!.future;
      final payload = summaryPayloads[
          (summaryRequests - 1).clamp(0, summaryPayloads.length - 1)];
      return _json({'ok': true, 'turn': 1, ...payload});
    }
    if (request.url.path == '/m/api/notifications') {
      return _json({'ok': true, 'items': <Object>[]});
    }
    if (request.url.path == '/m/api/queue') {
      return _json({'ok': true, 'rows': <Object>[]});
    }
    if (request.url.path == '/m/api/todos') {
      return _json({'ok': true, 'todos': <Object>[]});
    }
    return _json({'ok': true});
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> _availableSummary() => {
  'state': 'available',
  'files': [
    {
      'seq': 5,
      'index': 0,
      'display': 'src/a.ts',
      'name': 'a.ts',
      'added': 1,
      'deleted': 0,
    },
  ],
  'total': 1,
  'added': 1,
  'deleted': 0,
  'truncated': false,
};

/// 触发 ChatScreen 重建（store 只在展示模式/收起时机变化时 setState）。
void _forceRebuild(AppStore store) {
  store.setTurnFoldTiming(
    store.turnFoldTiming == TurnFoldTiming.afterAnswer
        ? TurnFoldTiming.onNewMessage
        : TurnFoldTiming.afterAnswer,
  );
}

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _RetryBackend backend,
  TurnTailSummaryCache cache,
) async {
  final store = AppStore()..sessionId = 'session-r06';
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        store: store,
        apiClient: backend.api,
        changedSummaryCache: cache,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('负结果 TTL 到期后重建能重新拉取（门闩不滞留）', (tester) async {
    final backend = _RetryBackend(
      summaryPayloads: [
        {'state': 'unavailable', 'files': <Object>[]},
        _availableSummary(),
      ],
    );
    var now = DateTime(2026, 1, 1);
    final cache = TurnTailSummaryCache(
      negativeTtl: const Duration(milliseconds: 50),
      clock: () => now,
    );
    final store = await _pumpChat(tester, backend, cache);
    expect(backend.summaryRequests, 1);
    expect(find.byKey(TurnTailCardKeys.changedCard), findsNothing);

    // 等待负缓存 TTL 过期，然后触发一次页面重建（通知设置变化最接近真实场景）。
    now = now.add(const Duration(milliseconds: 80));
    _forceRebuild(store);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      backend.summaryRequests,
      2,
      reason: 'TTL 到期后必须能重新拉取，而不是被 forever in-flight 门闩挡住',
    );
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);
  });

  testWidgets('正结果 TTL 到期后重建也能刷新', (tester) async {
    final backend = _RetryBackend(
      summaryPayloads: [_availableSummary(), _availableSummary()],
    );
    var now = DateTime(2026, 1, 1);
    final cache = TurnTailSummaryCache(
      availableTtl: const Duration(milliseconds: 50),
      clock: () => now,
    );
    final store = await _pumpChat(tester, backend, cache);
    expect(backend.summaryRequests, 1);
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);

    now = now.add(const Duration(milliseconds: 80));
    _forceRebuild(store);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(backend.summaryRequests, 2);
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);
  });

  testWidgets('请求进行中重建不会重复发起（门闩仍承担 in-flight 去重）', (tester) async {
    final gate = Completer<void>();
    final backend = _RetryBackend(
      summaryPayloads: [_availableSummary()],
      summaryGate: gate,
    );
    final cache = TurnTailSummaryCache();
    final store = AppStore()..sessionId = 'session-r06';
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          store: store,
          apiClient: backend.api,
          changedSummaryCache: cache,
          onTitleChanged: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.summaryRequests, 1);
    _forceRebuild(store);
    await tester.pump();
    expect(backend.summaryRequests, 1, reason: 'in-flight 期间不得重复请求');
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);
  });

  testWidgets('recheck-11：reset 后旧请求完成不得回填缓存/移除新门闩', (tester) async {
    final gate = Completer<void>();
    final backend = _RetryBackend(
      summaryPayloads: [
        {'state': 'unavailable', 'files': <Object>[]},
        _availableSummary(),
      ],
      summaryGate: gate,
    );
    final cache = TurnTailSummaryCache();
    final store = await _pumpChat(tester, backend, cache);
    expect(backend.summaryRequests, 1);
    expect(find.byKey(TurnTailCardKeys.changedCard), findsNothing);

    // 触发会话重同步（reset）：清空门闩/缓存并重新拉历史 → 新请求应立即发起并成功。
    store.injectFrame({
      'type': 'session/event',
      'sessionId': 'session-r06',
      'event': {'seq': 99, 'type': 'compaction/end', 'data': <String, dynamic>{}},
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(backend.summaryRequests, 2, reason: 'reset 后新请求不得被旧 in-flight 门闩挡住');
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);

    // 旧请求此时才完成（unavailable）：不得回填缓存让卡片消失，也不得移除新门闩。
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget, reason: '旧代际结果必须丢弃');
    expect(backend.summaryRequests, 2);
    // 收尾：停掉 SSE/去抖计时器，避免 dispose 后仍有 pending timer 断言。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
