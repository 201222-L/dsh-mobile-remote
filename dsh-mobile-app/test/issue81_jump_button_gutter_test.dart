// issue #81：320 大字下「回到底部」圆钮遮挡尾段正文。
//
// 修复口径：圆钮也是右侧 action gutter 的占用者——
// - 圆钮可见：列表右 padding 38dp，圆钮 right 0 / bottom 12 / 38dp；
// - 轨道可见（无圆钮）：36dp；都隐藏：16dp；同帧计算；
// - 轨道底部 62dp 预留保证与圆钮 ≥12dp 不重叠；圆钮动画/点击/语义不变。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/turn_navigator_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _longUserText = '这是一条足够长的用户消息，用来把气泡撑到可用宽度以验证右侧 action gutter ';

List<Map<String, dynamic>> _turnsEvents({int turns = 6}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  for (var turn = 1; turn <= turns; turn++) {
    events.add({
      'seq': seq++,
      'type': 'turn/start',
      'data': {'turn': turn},
    });
    events.add({
      'seq': seq++,
      'type': 'user/message',
      'data': {
        'messageId': 'user-$turn',
        'text': '$_longUserText（第 $turn 轮）',
        'sourceKind': 'user',
      },
    });
    events.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {
        'turn': turn,
        'messageId': 'assistant-$turn',
        // 单轮用例也要足够长（可上翻出圆钮）；多轮保持较轻量。
        'text': '第 $turn 轮的回答${'补充说明' * (turns <= 1 ? 320 : 60)}',
      },
    });
  }
  return events;
}

class _TurnBackend {
  _TurnBackend({this.turns = 6});

  final int turns;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue81.test'
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

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    if (request.url.path == '/m/api/history') {
      body = request.url.queryParameters.containsKey('before')
          ? {'ok': true, 'events': <Object>[], 'hasMore': false}
          : {
              'ok': true,
              'events': _turnsEvents(turns: turns),
              'hasMore': false,
            };
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (request.url.path == '/m/api/session-config') {
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

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _TurnBackend backend, {
  String sessionId = 'session-issue81',
  String keySuffix = '',
}) async {
  final store = AppStore()..sessionId = sessionId;
  store.sessions = [
    Session(id: sessionId, title: 'S', cwd: null, createdAt: 1),
  ];
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      key: ValueKey('issue81-$keySuffix'),
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

Future<void> _scrollUp(WidgetTester tester, {double by = 600}) async {
  await tester.drag(find.byType(CustomScrollView), Offset(0, by));
  await tester.pumpAndSettle();
}

double _screenWidth(WidgetTester tester) =>
    tester.view.physicalSize.width / tester.view.devicePixelRatio;

Finder get _rail => find.byType(TurnNavigatorRail);
Finder get _jumpButton => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_JumpToLatestButton',
    );

bool _jumpVisible(WidgetTester tester) {
  if (_jumpButton.evaluate().isEmpty) return false;
  final animated = find.descendant(
    of: _jumpButton,
    matching: find.byType(AnimatedOpacity),
  );
  return tester.widget<AnimatedOpacity>(animated.first).opacity > 0.5;
}

double _liveRightPadding(WidgetTester tester) {
  final paddings = tester
      .widgetList<SliverPadding>(find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(SliverPadding),
      ))
      .toList();
  return paddings.first.padding.resolve(TextDirection.ltr).right;
}

/// 消息流内所有可见 Text 的最大右缘（不依赖具体哪条消息可见）。
double? _maxContentTextRight(WidgetTester tester) {
  final screenW = _screenWidth(tester);
  final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  double? maxRight;
  for (final element in find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Text),
      )
      .evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    if (rect.top >= 0 && rect.bottom <= screenH && rect.left >= 0 && rect.right <= screenW) {
      if (maxRight == null || rect.right > maxRight) maxRight = rect.right;
    }
  }
  return maxRight;
}

/// 长用户气泡文本的可见右缘（用于精确断言气泡内缩 12dp）。
double? _visibleUserTextRight(WidgetTester tester) {
  final screenW = _screenWidth(tester);
  for (final element in find.textContaining('这是一条足够长的用户消息').evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    if (rect.top >= 0 && rect.bottom <= 1200 && rect.left >= 0) {
      if (rect.right <= screenW && rect.right > screenW - 140) return rect.right;
    }
  }
  return null;
}

void main() {
  test('listRightPaddingFor：四组合（仅圆钮/圆钮+轨道/仅轨道/都隐藏）', () {
    expect(
      listRightPaddingFor(jumpVisible: true, railVisible: true),
      38,
      reason: '圆钮+轨道取最大 38',
    );
    expect(
      listRightPaddingFor(jumpVisible: true, railVisible: false),
      38,
      reason: '仅圆钮 38',
    );
    expect(
      listRightPaddingFor(jumpVisible: false, railVisible: true),
      36,
      reason: '仅轨道 36',
    );
    expect(
      listRightPaddingFor(jumpVisible: false, railVisible: false),
      16,
      reason: '都隐藏 16（默认）',
    );
  });

  testWidgets('320 + textScale1.3：圆钮可见时正文右缘 ≤ 屏宽-38、不遮挡、可回底', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpChat(tester, _TurnBackend());
    await _scrollUp(tester);

    expect(_jumpVisible(tester), isTrue);
    expect(_liveRightPadding(tester), 38, reason: '圆钮可见 → 右 padding 38');
    final buttonRect = tester.getRect(_jumpButton);
    expect(buttonRect.height, 38);
    expect(buttonRect.right, closeTo(320, 0.5), reason: '圆钮 right 0（贴右缘）');
    final textRight = _maxContentTextRight(tester);
    expect(textRight, isNotNull);
    expect(textRight!, lessThanOrEqualTo(320 - 38 + 0.5),
        reason: '正文右缘不得进入圆钮占位（≤ 屏宽-38）');
    expect(tester.takeException(), isNull, reason: '320+1.3 无 overflow');

    // 点圆钮回底：轨道/圆钮消失、padding 同帧恢复 16，且确实到最新位置。
    await tester.tap(_jumpButton);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(_rail, findsNothing, reason: '回底后轨道隐藏');
    expect(_jumpVisible(tester), isFalse, reason: '回底后圆钮隐藏');
    expect(_liveRightPadding(tester), 16, reason: '都隐藏 → padding 16');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('320 + textScale1.5：圆钮可见时无 overflow、正文不进 gutter', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpChat(tester, _TurnBackend());
    await _scrollUp(tester);
    expect(_jumpVisible(tester), isTrue);
    expect(_liveRightPadding(tester), 38);
    final textRight = _maxContentTextRight(tester);
    expect(textRight, isNotNull);
    expect(textRight!, lessThanOrEqualTo(320 - 38 + 0.5),
        reason: '320+1.5 正文不得进入圆钮占位');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('圆钮+轨道：padding 38、圆钮 right0、与轨道不重叠且 ≥12dp', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _TurnBackend());
    await _scrollUp(tester);
    expect(_rail, findsOneWidget);
    expect(_jumpVisible(tester), isTrue);
    expect(_liveRightPadding(tester), 38, reason: '圆钮+轨道取 38');
    final railRect = tester.getRect(_rail);
    final buttonRect = tester.getRect(_jumpButton);
    expect(railRect.overlaps(buttonRect), isFalse, reason: '轨道与圆钮不重叠');
    expect(buttonRect.top - railRect.bottom, greaterThanOrEqualTo(12),
        reason: '轨道下界与圆钮至少 12dp 避让');
    expect(buttonRect.right, closeTo(390, 0.5), reason: '圆钮 right 0');
    expect(railRect.right, closeTo(390 - 8, 0.5), reason: '#80 轨道右留 8 不变');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('仅圆钮（<2 轮）：padding 38、无轨道；都隐藏时 padding 16', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _TurnBackend(turns: 1));
    // 都隐藏（底部）。
    expect(_liveRightPadding(tester), 16);
    expect(_rail, findsNothing);
    expect(_jumpVisible(tester), isFalse);
    // 上翻：只有圆钮（轮次不足 → 无轨道）。
    await _scrollUp(tester);
    expect(_jumpVisible(tester), isTrue);
    expect(_rail, findsNothing);
    expect(_liveRightPadding(tester), 38, reason: '仅圆钮 → 38');
    expect(tester.getRect(_jumpButton).right, closeTo(390, 0.5));
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('圆钮显隐与 padding 同帧（上翻一帧即 38；回底一帧即 16）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _TurnBackend());
    expect(_liveRightPadding(tester), 16);
    // 上翻一次 drag 后只 pump（不 settle），同帧检查圆钮+padding。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pump();
    expect(_jumpVisible(tester), isTrue);
    expect(_liveRightPadding(tester), 38);
    // 点圆钮回底，单帧后 padding 恢复。
    await tester.tap(_jumpButton, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_liveRightPadding(tester), 16, reason: 'padding 与圆钮显隐同帧');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('切换会话：从 38（上翻）切到新会话底部 → 16', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _TurnBackend(), keySuffix: 'multi');
    await _scrollUp(tester);
    expect(_liveRightPadding(tester), 38);
    await _pumpChat(
      tester,
      _TurnBackend(turns: 1),
      sessionId: 'session-issue81-single',
      keySuffix: 'single',
    );
    expect(_liveRightPadding(tester), 16);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('390：圆钮可见时 padding 38（优先于轨道 36）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _TurnBackend());
    await _scrollUp(tester);
    expect(_liveRightPadding(tester), 38);
    final textRight = _visibleUserTextRight(tester);
    expect(textRight, isNotNull);
    expect(textRight!, closeTo(390 - 38 - 12, 2),
        reason: '390 圆钮可见时正文右缘 = 屏宽-38-12');
    await tester.pump(const Duration(milliseconds: 900));
  });
}
