// issue #77：活跃会话滚动贴底 / 短内容大片空白。
//
// 复现与验收：
// - 内容增长（流式正文、思考、工具插入、过程块）本身不得把“钉在底部”判成 false；
// - 内容短于视口时消息列表底部对齐视口底部（不顶对齐、下方不留大片空白）；
// - 用户主动上翻才停止跟随并出现「回到底部」，点击可回底；
// - 切换会话按新内容重新贴底。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-77';

class _Backend {
  _Backend({required this.events});

  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue77.test'
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
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else {
        body = {'ok': true, 'events': events, 'hasMore': false};
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

/// 很短的一段对话（只有 1 问 1 答）：center 布局下最容易暴露“顶对齐留白”。
List<Map<String, dynamic>> _shortHistory() => [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '你好', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {'turn': 1, 'messageId': 'a1', 'text': '收到'},
        'time': 1200,
      },
    ];

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  String sessionId = _session,
  String keySuffix = '',
}) async {
  final store = AppStore()
    ..sessionId = sessionId
    ..sessions = [
      Session(id: sessionId, title: 'S', cwd: null, createdAt: 1),
    ];
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue77-$sessionId-$keySuffix'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  // issue #77：短内容底部占位需要 1–2 帧收敛（帧后实测高度 → setState）。
  await tester.pumpAndSettle();
  return store;
}

void _injectRaw(AppStore store, Map<String, dynamic> event) {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': event,
  });
}

Future<void> _inject(WidgetTester tester, AppStore store, Map<String, dynamic> event) async {
  _injectRaw(store, event);
  await tester.pump(const Duration(milliseconds: 90));
}

ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Finder get _jumpButton => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_JumpToLatestButton',
    );

bool _jumpVisible(WidgetTester tester) {
  final finder = _jumpButton;
  if (finder.evaluate().isEmpty) return false;
  final animated = find.descendant(of: finder, matching: find.byType(AnimatedOpacity));
  if (animated.evaluate().isEmpty) return false;
  return tester.widget<AnimatedOpacity>(animated.first).opacity > 0.5;
}

/// 注入 [count] 组「工具调用 + 结果」，把内容推高到超过视口（过程块随轮次运行展开）。
Future<void> _injectTools(WidgetTester tester, AppStore store, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await _inject(tester, store, {
      'seq': 300 + i * 2,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 2 + i,
        'callId': 'call-$i',
        'name': 'bash',
        'arguments': 'echo $i',
      },
      'time': 3000 + i,
    });
    await _inject(tester, store, {
      'seq': 301 + i * 2,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 2 + i,
        'callId': 'call-$i',
        'name': 'bash',
        'text': 'ok $i ${'结果行 ' * 12}',
      },
      'time': 3001 + i,
    });
  }
}

void main() {
  testWidgets('内容短于视口：消息列表底部对齐输入框上方（不顶对齐留大片空白）', (tester) async {
    await _pumpChat(tester, _Backend(events: _shortHistory()));
    final view = tester.getRect(find.byType(CustomScrollView));
    final last = tester.getRect(find.text('收到'));
    final pos = _pos(tester);
    expect(pos.maxScrollExtent, 0, reason: '短内容不应产生可滚动距离');
    expect(
      view.bottom - last.bottom,
      lessThanOrEqualTo(80),
      reason: '最后一条消息应贴近视口底部（含气泡/列表底部间距），实际 ${view.bottom - last.bottom}',
    );
    expect(
      last.bottom,
      greaterThan(view.top + view.height / 2),
      reason: '内容应整体下移，而不是顶对齐',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('工具/过程块增长：始终贴底，不被内容高度增长误判为上翻', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _shortHistory()));
    for (var i = 0; i < 12; i++) {
      await _inject(tester, store, {
        'seq': 300 + i * 2,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 2 + i,
          'callId': 'call-$i',
          'name': 'bash',
          'arguments': 'echo $i',
        },
        'time': 3000 + i,
      });
      await _inject(tester, store, {
        'seq': 301 + i * 2,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 2 + i,
          'callId': 'call-$i',
          'name': 'bash',
          'text': 'ok $i ${'结果行 ' * 12}',
        },
        'time': 3001 + i,
      });
      final pos = _pos(tester);
      expect(
        pos.extentAfter,
        lessThanOrEqualTo(160),
        reason: '第 $i 次工具插入后应仍贴底（extentAfter=${pos.extentAfter}）',
      );
    }
    final pos = _pos(tester);
    expect((pos.maxScrollExtent - pos.pixels).abs(), lessThanOrEqualTo(1));
    expect(_jumpVisible(tester), isFalse, reason: '贴底时不应出现回到底部浮钮');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('长思考/流式正文增长：钉在底部时持续跟随', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _shortHistory()));
    // 大量 reasoning delta：provisional 过程行 / 活动条随文本增长。
    for (var i = 0; i < 80; i++) {
      await _inject(tester, store, {
        'seq': 100 + i,
        'type': 'assistant/live-chunk',
        'data': {
          'turn': 1,
          'step': 1,
          'reasoning': true,
          'text': '思考第 $i 行：分析滚动逻辑与布局。\n',
        },
        'time': 1500 + i,
      });
    }
    // 再注入正文 delta（草稿气泡增长）。
    for (var i = 0; i < 30; i++) {
      await _inject(tester, store, {
        'seq': 500 + i,
        'type': 'assistant/live-chunk',
        'data': {
          'turn': 1,
          'step': 1,
          'text': '正文第 $i 段，逐字增长。\n',
        },
        'time': 5000 + i,
      });
    }
    final pos = _pos(tester);
    expect(pos.maxScrollExtent, greaterThan(0), reason: '注入后内容应超过视口');
    expect(
      pos.extentAfter,
      lessThanOrEqualTo(160),
      reason: '长思考/流式正文增长仍应贴底（extentAfter=${pos.extentAfter}）',
    );
    expect(_jumpVisible(tester), isFalse);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('用户主动上翻：停止跟随并出现回到底部；点击可回底', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _shortHistory()));
    await _injectTools(tester, store);
    expect(_pos(tester).extentAfter, lessThanOrEqualTo(160));

    // 手指向下拖 = 查看更早内容（离开底部）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 200));
    final afterDrag = _pos(tester);
    expect(afterDrag.extentAfter, greaterThan(160), reason: '上翻后应离开底部');
    expect(_jumpVisible(tester), isTrue, reason: '上翻后应出现回到底部浮钮');

    // 用户不在底部时，新内容到达不得把视图拉回底部。
    final pinnedPixels = afterDrag.pixels;
    await _inject(tester, store, {
      'seq': 900,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 40,
        'callId': 'call-late',
        'name': 'bash',
        'arguments': 'echo late',
      },
      'time': 9000,
    });
    await _inject(tester, store, {
      'seq': 901,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 40,
        'callId': 'call-late',
        'name': 'bash',
        'text': 'late ok',
      },
      'time': 9001,
    });
    final afterGrowth = _pos(tester);
    expect(
      afterGrowth.pixels,
      closeTo(pinnedPixels, 40),
      reason: '用户上翻后不得因内容增长被拉回底部',
    );

    // 点「回到底部」→ 贴底、浮钮消失。
    await tester.tap(_jumpButton);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    final afterJump = _pos(tester);
    expect((afterJump.maxScrollExtent - afterJump.pixels).abs(), lessThanOrEqualTo(1));
    expect(_jumpVisible(tester), isFalse);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('切换会话：新会话内容短时同样底部对齐', (tester) async {
    await _pumpChat(tester, _Backend(events: _shortHistory()));
    // 换成另一个更短的会话（新页面状态）。
    final backend2 = _Backend(events: [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '新会话', 'sourceKind': 'user'},
      },
    ]);
    await _pumpChat(
      tester,
      backend2,
      sessionId: 'session-77b',
      keySuffix: 'b',
    );
    final view = tester.getRect(find.byType(CustomScrollView));
    final last = tester.getRect(find.text('新会话'));
    // 用户消息尾部还带「复制」操作行与气泡间距，文本底部距视口底约 60px 仍算贴底。
    expect(view.bottom - last.bottom, lessThanOrEqualTo(80));
    expect(_pos(tester).maxScrollExtent, 0);
    await tester.pump(const Duration(milliseconds: 900));
  });
}
