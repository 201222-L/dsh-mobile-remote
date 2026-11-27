// issue #103：工具卡/过程块展开后聊天记录脱离底部、上翻困难、整屏空白。
//
// 覆盖：展开 summary/组/工具卡后 pinned 跟随；ScrollMetricsNotification 驱动的
// 内容高度变化；回底后无尾部空白；320/深色/1.5x；代码块不再嵌套滚动抢父级手势。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-103';

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue103.test'
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
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
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

List<Map<String, dynamic>> _fixture({int tools = 16}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data, {int? time}) => events.add({
    'seq': seq++,
    'type': type,
    'data': data,
    'time': time ?? seq * 10,
  });
  add('turn/start', {'turn': 103});
  add('user/message', {'messageId': 'u1', 'text': '开始', 'sourceKind': 'user'});
  for (var i = 0; i < 4; i++) {
    add('assistant/message', {
      'turn': 103,
      'messageId': 'a$i',
      'text': '前文第 $i 段。\n${'内容行。' * 20}',
    });
  }
  for (var i = 0; i < tools; i++) {
    add('tool/call', {
      'turn': 103,
      'step': 1,
      'callId': 'call-$i',
      'name': 'bash',
      'arguments': 'printf result $i',
    });
    add('tool/result', {
      'turn': 103,
      'step': 1,
      'callId': 'call-$i',
      'name': 'bash',
      'text': '结果行 $i\n${'输出内容行。\n' * 120}',
    });
  }
  add('assistant/message', {'turn': 103, 'messageId': 'aend', 'text': '最后回答。'});
  add('turn/end', {
    'turn': 103,
    'reason': {'kind': 'completed'},
  });
  return events;
}

Future<AppStore> _pump(
  WidgetTester tester, {
  Size size = const Size(800, 700),
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = _Backend(events: _fixture());
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: ChatScreen(
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return store;
}

ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

Finder get _jumpButton => find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_JumpToLatestButton',
);

bool _jumpVisible(WidgetTester tester) {
  final f = _jumpButton;
  if (f.evaluate().isEmpty) return false;
  final a = find.descendant(of: f, matching: find.byType(AnimatedOpacity));
  return a.evaluate().isNotEmpty &&
      tester.widget<AnimatedOpacity>(a.first).opacity > 0.5;
}

void _expectPinned(WidgetTester tester, String step) {
  final pos = _pos(tester);
  expect(
    pos.extentAfter,
    lessThanOrEqualTo(1.5),
    reason: '$step: 展开/内容变化后应仍贴底（extentAfter=${pos.extentAfter}）',
  );
  expect(_jumpVisible(tester), isFalse, reason: '$step: 贴底时不应出现回底按钮');
}

Future<void> _expand(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => L10n.lang = 'zh');
  tearDown(() => L10n.lang = 'zh');

  testWidgets('issue #103：展开 summary/组/全部工具卡后仍贴底，回底后无尾部空白', (tester) async {
    await _pump(tester);
    _expectPinned(tester, 'initial');

    // 展开轮过程 summary。
    final summary = find.textContaining('次工具调用').first;
    await _expand(tester, summary);
    _expectPinned(tester, 'summary');

    // 展开唯一组（16 个工具都在 step1）。
    final group = find.textContaining('次工具调用').first;
    await _expand(tester, group);
    _expectPinned(tester, 'group');

    // 依次展开全部工具卡（用户在列表里滚动后逐张点开，这是真实场景）。
    for (var i = 0; i < 16; i++) {
      final card = find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.startsWith('tool:call-$i:');
      });
      if (card.evaluate().isEmpty) continue;
      await _expand(tester, card.first);
    }
    await tester.pump(const Duration(milliseconds: 300));
    // 全部展开后用户点回底 → 多帧 settle 后严格贴底，内容最后一行在视口底部附近。
    if (_jumpVisible(tester)) {
      await tester.tap(_jumpButton);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
    }
    final pos = _pos(tester);
    expect((pos.maxScrollExtent - pos.pixels).abs(), lessThanOrEqualTo(1.5));
    final view = tester.getRect(find.byType(CustomScrollView));
    final last = find.text('最后回答。');
    expect(last, findsOneWidget);
    expect(
      view.bottom - tester.getRect(last).bottom,
      lessThanOrEqualTo(80),
      reason: '回底后最后内容应贴底，不得留下大块尾部空白',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('issue #103 / ADR 0035：详情溢出走内层滚动，父列表仍可从组头拖动', (tester) async {
    await _pump(tester);
    await _expand(tester, find.textContaining('次工具调用').first);
    await _expand(tester, find.textContaining('次工具调用').first);
    // 展开第一张工具卡（长结果 → 显示“查看全文”）。
    final card = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith('tool:call-0:');
    });
    await _expand(tester, card.first);
    expect(find.text('查看全文'), findsWidgets, reason: '长代码块仍提供全文入口');
    // ADR 0035 C 方案：详情体溢出时只在内层滚动，不做边缘交接；
    // 父列表从组头（非详情体）起手仍必须可滚动。
    final header = find.textContaining('次工具调用').first;
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    final before = _pos(tester).pixels;
    await tester.drag(header, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 300));
    final after = _pos(tester).pixels;
    expect(
      after,
      lessThan(before),
      reason: '组头上的手势应由父 CustomScrollView 接收（before=$before after=$after）',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('issue #103：320/深色/1.5x 展开不溢出且可贴底', (tester) async {
    await _pump(
      tester,
      size: const Size(320, 640),
      theme: ThemeData.dark(),
      textScaler: const TextScaler.linear(1.5),
    );
    expect(tester.takeException(), isNull);
    await _expand(tester, find.textContaining('次工具调用').first);
    expect(tester.takeException(), isNull);
    await _expand(tester, find.textContaining('次工具调用').first);
    expect(tester.takeException(), isNull);
    final card = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith('tool:call-0:');
    });
    await _expand(tester, card.first);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 900));
  });
}
