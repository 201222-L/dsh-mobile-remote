// issue #89：会话时间线可向上拖动超出内容范围并留下大块空白（alpha.14 真机）。
//
// 根因（诊断结论）：活动条显隐/展开改变消息视口高度时，底部占位 `_liveBottomGap` 只在
// ChatScreen.build 里实测；活动条由子 ListenableBuilder 单独重建时父 build 不跑，
// 旧占位（按更大/更小视口算出的高度）会保留到下一次无关 setState，期间短内容出现
// 下方大块空白（截图），且 stale max 让回底按钮/拖动跟随状态与真实位置不一致。
//
// 验收：任意拖动/活动条显隐/新内容到达后 pixels ∈ [min,max]；短内容底部对齐
// （空白 ≤ 输入区固定间距）；回底按钮只在真实离开底部时出现。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-89';
const _activityBarKey = ValueKey<String>('activity-bar');

class _Backend {
  _Backend({required this.events, this.hasOlder = false});
  final List<Map<String, dynamic>> events;
  final bool hasOlder;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue89.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: false,
      unknownEvents: true,
      callCorrelation: true,
    );

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    final path = request.url.path;
    if (path == '/m/api/history') {
      final params = request.url.queryParameters;
      if (params.containsKey('before')) {
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final page = events.where((e) => (e['seq'] as int) < before).toList();
        body = {'ok': true, 'events': page, 'hasMore': false};
      } else {
        body = {'ok': true, 'events': events, 'hasMore': hasOlder};
      }
    } else if (path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
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

List<Map<String, dynamic>> _short() => [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '你好', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {'turn': 1, 'messageId': 'a1', 'text': '收到'},
      },
    ];

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  bool showReasoning = false,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..showReasoning = showReasoning
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 120));
  return store;
}

void _injectRaw(AppStore store, Map<String, dynamic> event) {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': event,
  });
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ))
    .position;

/// 视口内最后一条文本/内容底部到视口底部的距离；短内容尾部固定内边距约 30–40。
double _blankBelow(WidgetTester tester) {
  final viewport = tester.renderObject<RenderBox>(find.byType(CustomScrollView));
  final top = viewport.localToGlobal(Offset.zero).dy;
  final bottom = top + viewport.size.height;
  var contentBottom = top;
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.top < top || rect.top > bottom) continue;
    if (rect.bottom > contentBottom) contentBottom = rect.bottom;
  }
  return bottom - contentBottom;
}


bool _jumpVisible(WidgetTester tester) => tester
    .widgetList(find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_JumpToLatestButton',
    ))
    .any((w) => (w as dynamic).visible == true);

double _liveRightPadding(WidgetTester tester) {
  for (final widget in tester.widgetList<SliverPadding>(find.byType(SliverPadding))) {
    final padding = widget.padding.resolve(TextDirection.ltr);
    if (padding.left == 16) return padding.right;
  }
  return -1;
}


void _expectWithinRange(WidgetTester tester) {
  final pos = _position(tester);
  expect(pos.pixels, lessThanOrEqualTo(pos.maxScrollExtent + 0.5));
  expect(pos.pixels, greaterThanOrEqualTo(pos.minScrollExtent - 0.5));
}

void _expectNoBigBlank(WidgetTester tester) {
  expect(
    _blankBelow(tester),
    lessThanOrEqualTo(48),
    reason: '短内容应贴输入框上方，不得留下大块空白',
  );
}

Future<void> _finishTimers(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('短内容 + 活动条展开→隐藏：立即无大块空白，pixels 不越界，回底按钮隐藏', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _short()), showReasoning: true);
    // 长思考出现 → 活动条；展开 → 视口明显变矮。
    _injectRaw(store, {
      'seq': 4,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': List.filled(20, '这是一段较长的思考内容。').join('\n'),
      },
    });
    await tester.pump(const Duration(milliseconds: 150));
    final thinking = find.byKey(const ValueKey<String>('activity-bar-thinking'));
    expect(thinking, findsOneWidget);
    await tester.tap(thinking);
    await tester.pump(const Duration(milliseconds: 150));
    _expectWithinRange(tester);

    // 思考结束 → 活动条消失、视口变高；短内容必须立刻重新贴底。
    _injectRaw(store, {
      'seq': 5,
      'type': 'assistant/message',
      'data': {'turn': 1, 'step': 2, 'messageId': 'a2', 'text': '思考完成'},
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    _expectWithinRange(tester);
    _expectNoBigBlank(tester);
    expect(_jumpVisible(tester), isFalse, reason: '仍在底部，回底按钮不得出现');
    await _finishTimers(tester);
  });

  testWidgets('活动条显隐 + 持握向上拖：pixels 始终 ≤ max，松手后贴底无空白', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _short()));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(CustomScrollView)));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump(const Duration(milliseconds: 16));
      _expectWithinRange(tester);
    }
    // 持握中：活动条出现（视口变矮）→ 隐藏（视口变高）。
    _injectRaw(store, {
      'seq': 4,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': List.filled(20, '思考。').join('\n'),
      },
    });
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(_activityBarKey), findsOneWidget);
    _expectWithinRange(tester);
    _injectRaw(store, {
      'seq': 5,
      'type': 'assistant/message',
      'data': {'turn': 1, 'step': 2, 'messageId': 'a2', 'text': '完成'},
    });
    // 活动条隐藏后的下一帧完成底部占位重测（父 build 不跑时由帧后校准补上）。
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    _expectWithinRange(tester);
    _expectNoBigBlank(tester);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));
    _expectWithinRange(tester);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    _expectWithinRange(tester);
    _expectNoBigBlank(tester);
    expect(_jumpVisible(tester), isFalse, reason: '全程未真实上翻，回底按钮不得出现');
    await _finishTimers(tester);
  });

  testWidgets('任意方向大幅拖动（含越界）：松手后 pixels 在 [min,max]、无大块空白', (tester) async {
    await _pumpChat(tester, _Backend(events: _short()));
    final scroll = find.byType(CustomScrollView);
    // 向上拖（朝底部）大幅越界。
    await tester.drag(scroll, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 400));
    _expectWithinRange(tester);
    _expectNoBigBlank(tester);
    // 向下拖（朝更早）大幅越界。
    await tester.drag(scroll, const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 400));
    _expectWithinRange(tester);
    await _finishTimers(tester);
  });

  testWidgets('历史分页 + 上翻后回底：pixels 不越界、回底按钮与位置一致', (tester) async {
    final backend = _Backend(events: _short(), hasOlder: true);
    await _pumpChat(tester, backend);
    // 加载更早消息（如果入口存在）。
    final older = find.textContaining('View earlier messages');
    if (older.evaluate().isNotEmpty) {
      await tester.tap(older.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    _expectWithinRange(tester);
    final scroll = find.byType(CustomScrollView);
    await tester.drag(scroll, const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 400));
    _expectWithinRange(tester);
    // 回底。
    await tester.drag(scroll, const Offset(0, 500));
    await tester.pump(const Duration(milliseconds: 400));
    _expectWithinRange(tester);
    final pos = _position(tester);
    final atBottom = pos.maxScrollExtent - pos.pixels <= 160;
    expect(
      _jumpVisible(tester),
      !atBottom,
      reason: '回底按钮显隐必须与真实贴底状态一致',
    );
    await _finishTimers(tester);
  });
  testWidgets('长换行内容：上翻出圆钮（padding38）→拖回底部（padding16）pixels 不越界、无大块空白', (tester) async {
    final events = <Map<String, dynamic>>[
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '长内容问题', 'sourceKind': 'user'},
      },
      for (var i = 0; i < 8; i++)
        {
          'seq': 3 + i,
          'type': 'assistant/message',
          'data': {
            'turn': 1,
            'step': 1,
            'messageId': 'a$i',
            'text': List.filled(12, '这是一段会随宽度变化换行的长文本$i。').join(' '),
          },
        },
    ];
    final store = await _pumpChat(tester, _Backend(events: events));
    final scroll = find.byType(CustomScrollView);
    // 上翻离开底部 → 回底圆钮出现，右 padding 变 38（#81 同帧契约）。
    await tester.drag(scroll, const Offset(0, 700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_jumpVisible(tester), isTrue);
    expect(_liveRightPadding(tester), 38);
    _expectWithinRange(tester);

    // 向上拖回底部（朝最新）：padding 38→16；途中插入运行中工具，模拟新内容竞态。
    final gesture = await tester.startGesture(tester.getCenter(scroll));
    for (var i = 0; i < 20; i++) {
      if (i == 6) {
        _injectRaw(store, {
          'seq': 30,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 2,
            'callId': 'run-89',
            'name': 'bash',
            'arguments': 'sleep 1',
          },
        });
      }
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 16));
      _expectWithinRange(tester);
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    _expectWithinRange(tester);
    expect(_liveRightPadding(tester), 16, reason: '回到底部后圆钮隐藏，padding 回到 16');
    expect(_jumpVisible(tester), isFalse);
    _expectNoBigBlank(tester);
    final pos = _position(tester);
    expect(
      pos.maxScrollExtent - pos.pixels,
      lessThanOrEqualTo(1.5),
      reason: '拖回底部后必须真正贴底（不留下可滚动余量）',
    );
    await _finishTimers(tester);
  });

}
