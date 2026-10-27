// issue #24：评审 5 项缺陷的**永久回归测试**（第一轮 #1054 / 复核 #1065）。
//
// 这些用例是把评审留在 /tmp 的临时反例转正而来，断言的是**用户可观察结果**：
//   1. 不等高会话里，已加载的中间轮次跳转后**真的进入视口**（不只是被构建）；
//   2. 超长刻度轨的边缘扫掠 / 初次可见见 `turn_navigator_rail_test.dart`；
//   3. 持续滚动时当前轮高亮跟随（含长回复导致边界被回收的情形）；
//   4. 非真人注入不抢占提示词预览、纯图片轮回退「第 N 轮」；
//   5. 同轮号不同 seq 的重复边界不再共用 GlobalKey（不再出现渲染断言）。
//
// 复用 `turn_navigation_chat_test.dart` 的假后端注入先例。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/turn_navigator_rail.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 按 turn 生成时间线事件；seq 由轮次号推导，保证多页拼接时全局一致。
List<Map<String, dynamic>> _turnEvents(
  int fromTurn,
  int toTurn, {
  int replyRepeat = 40,
  int? longTurn,
  int longRepeat = 2400,
  bool injected = false,
  bool duplicateFirstBoundary = false,
  bool imageOnlyFirstTurn = false,
}) {
  final out = <Map<String, dynamic>>[];
  final stride = injected ? 4 : 3;
  var seq = (fromTurn - 1) * stride + 1;
  for (var turn = fromTurn; turn <= toTurn; turn++) {
    out.add({'seq': seq++, 'type': 'turn/start', 'data': {'turn': turn}});
    if (duplicateFirstBoundary && turn == fromTurn) {
      out.add({'seq': seq++, 'type': 'turn/start', 'data': {'turn': turn}});
    }
    if (injected) {
      out.add({
        'seq': seq++,
        'type': 'user/message',
        'data': {
          'messageId': 'injected-$turn',
          'sourceKind': 'agent-instructions',
          'text': '注入指令 $turn',
        },
      });
    }
    final imageOnly = imageOnlyFirstTurn && turn == fromTurn;
    out.add({
      'seq': seq++,
      'type': 'user/message',
      'data': {
        'messageId': 'user-$turn',
        'sourceKind': 'user',
        'text': imageOnly ? '' : '问题 $turn',
      },
    });
    out.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {
        'messageId': 'assistant-$turn',
        'turn': turn,
        'text': '回答 $turn ' * (longTurn == turn ? longRepeat : replyRepeat),
      },
    });
  }
  return out;
}

class _Backend {
  _Backend({required this.initialEvents, this.olderEvents = const []});

  final List<Map<String, dynamic>> initialEvents;
  final List<Map<String, dynamic>> olderEvents;

  /// 置上时，带 `before` 的上翻请求会挂起（用于让加载条保持可见）。
  Completer<http.Response>? olderGate;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://review.test'
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
      final older = request.url.queryParameters.containsKey('before');
      final gate = olderGate;
      if (older && gate != null) return gate.future;
      body = {
        'ok': true,
        'events': older ? olderEvents : initialEvents,
        'hasMore': false,
      };
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
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

/// 空的上翻页（放行挂起的请求用）。
http.Response _emptyPage() => http.Response(
      jsonEncode({'ok': true, 'events': <Object>[], 'hasMore': false}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<void> _pumpChat(
  WidgetTester tester, {
  required _Backend backend,
  String sessionId = 'review-session',
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      store: AppStore()..sessionId = sessionId,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

TurnNavigatorRail _rail(WidgetTester tester) =>
    tester.widget<TurnNavigatorRail>(find.byType(TurnNavigatorRail));

/// 该文本当前是否与消息流视口相交（"已构建"不等于"看得见"）。
bool _textInViewport(WidgetTester tester, String text) {
  final view = tester.getRect(find.byType(CustomScrollView));
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) return false;
  return finder.evaluate().any((e) => view.overlaps(tester.getRect(finder)));
}

/// 离开底部（>160px 阈值），让刻度轨出现——导航前的真实前置状态。
Future<void> _leaveBottom(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
  await tester.pumpAndSettle();
}

/// 点刻度轨上的某一轮，等定位流程（有界迭代 + 精调）走完，并记录滚动落点轨迹。
///
/// 轨迹只用于打印证据；断言一律看"目标文本是否与消息流视口相交"。
Future<List<double>> _navigateTo(WidgetTester tester, int turn) async {
  final position = _position(tester);
  final offsets = <double>[];
  void record() => offsets.add(position.pixels);
  position.addListener(record);
  final target = _rail(tester).anchors.firstWhere((a) => a.turn == turn);
  _rail(tester).onNavigate(target);
  await tester.pumpAndSettle();
  position.removeListener(record);
  // ignore: avoid_print
  print('TURNLOC turn=$turn offsets=$offsets '
      'pixels=${position.pixels} max=${position.maxScrollExtent}');
  return offsets;
}

void main() {
  group('缺陷 1：不等高已加载轮次必须真正进入视口', () {
    testWidgets('首轮超长回复 + prepend 之后再定位第 4 轮，目标在视口内', (tester) async {
      // 初始窗口只有第 3..8 轮；更早的第 1..2 轮等上翻时再 prepend。
      final backend = _Backend(
        initialEvents: _turnEvents(3, 8, longTurn: 4, longRepeat: 2400),
        olderEvents: _turnEvents(1, 2),
      );
      await _pumpChat(tester, backend: backend);

      // 滚到顶部触发无限上翻（prepend 更早的两轮），同时离开底部让刻度轨出现。
      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byType(TurnNavigatorRail), findsOneWidget);
      expect(_rail(tester).anchors.length, 8,
          reason: 'prepend 之后已加载窗口应包含 1..8 轮');

      final target = _rail(tester).anchors.firstWhere((a) => a.turn == 4);
      _rail(tester).onNavigate(target);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_textInViewport(tester, '问题 4'), isTrue,
          reason: '目标轮必须真的与视口相交，而不是只停留在已构建范围');
    });
  });

  group('缺陷 3：当前轮高亮跟随持续滚动', () {
    testWidgets('离开底部区间内跨多轮滚动，高亮跟随', (tester) async {
      final backend = _Backend(initialEvents: _turnEvents(1, 8));
      await _pumpChat(tester, backend: backend);

      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byType(TurnNavigatorRail), findsOneWidget);
      expect(_rail(tester).activeTurn, 1);

      final max = _position(tester).maxScrollExtent;
      _position(tester).jumpTo(max * 0.55);
      await tester.pumpAndSettle();
      expect(_rail(tester).activeTurn, isNot(1),
          reason: '始终在 160px 阈值外，滚动本身也必须触发几何校准');
    });

    testWidgets('长回复导致起始边界被回收时，用可见轮次推断而不跳到最新轮', (tester) async {
      // 第 3 轮回复极长：进入其中段后，第 3 轮起始边界会被懒构建回收。
      final backend =
          _Backend(initialEvents: _turnEvents(1, 6, longTurn: 3, longRepeat: 2600));
      await _pumpChat(tester, backend: backend);

      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byType(TurnNavigatorRail), findsOneWidget);

      final target = _rail(tester).anchors.firstWhere((a) => a.turn == 3);
      _rail(tester).onNavigate(target);
      await tester.pumpAndSettle();
      expect(_rail(tester).activeTurn, 3);

      // 深入长回复 1500px：起始边界被回收，但高亮应仍是第 3 轮（不是第 6 轮）。
      _position(tester).jumpTo(_position(tester).pixels + 1500);
      await tester.pumpAndSettle();
      expect(_rail(tester).activeTurn, 3,
          reason: '边界未构建时应按阅读线推断，不能无条件回退到最新轮');
    });
  });

  group('缺陷 4：注入消息不抢占真人提示词预览', () {
    testWidgets('agent-instructions 先于真人问题时，预览是真人那句', (tester) async {
      final backend = _Backend(initialEvents: _turnEvents(1, 6, injected: true));
      await _pumpChat(tester, backend: backend);

      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      final anchors = _rail(tester).anchors;
      expect(anchors.first.prompt, '问题 1');
    });

    testWidgets('纯图片轮（无文本）预览回退为「第 N 轮」', (tester) async {
      final backend = _Backend(initialEvents: _turnEvents(1, 3, imageOnlyFirstTurn: true));
      await _pumpChat(tester, backend: backend);

      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(_rail(tester).anchors.first.prompt, isEmpty);

      // 长按第一个刻度：气泡回退为「第 1 轮」。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('turn-tick-1'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(TurnNavigatorRail),
          matching: find.text('第 1 轮'),
        ),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pump();
    });
  });

  group('缺陷 5：同号重试边界不共用 GlobalKey', () {
    testWidgets('同一轮号两个相邻 turn/start 不触发渲染断言', (tester) async {
      final backend = _Backend(
        initialEvents: _turnEvents(1, 6, duplicateFirstBoundary: true),
      );
      await _pumpChat(tester, backend: backend);
      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: '两个同轮号、不同 seq 的边界不得共用同一个 GlobalKey');
      // 折叠去重：同号边界只产生一个刻度。
      expect(find.byKey(const ValueKey('turn-tick-1')), findsOneWidget);
    });
  });

  group('缺陷 6（第二轮 P1）：长回复夹在目标与当前视口之间时仍要能定位', () {
    // 评审 #1072 的复现口径：8 轮 / 24 个已加载事件，普通回复各 900 字
    // （`'回答 N ' * 180`），长回复 14,400 字（`* 2880`），定位前先离开底部。
    const normalRepeat = 180; // 5 字 × 180 = 900 字
    const longRepeat = 2880; // 5 字 × 2880 = 14,400 字

    testWidgets('评审新反例：长回复在目标之后（第 6 轮 14,400 字，选第 4 轮）', (tester) async {
      final backend = _Backend(
        initialEvents:
            _turnEvents(1, 8, replyRepeat: normalRepeat, longTurn: 6, longRepeat: longRepeat),
      );
      await _pumpChat(tester, backend: backend);
      await _leaveBottom(tester);
      expect(find.byType(TurnNavigatorRail), findsOneWidget);

      await _navigateTo(tester, 4);

      expect(tester.takeException(), isNull);
      expect(_textInViewport(tester, '问题 4'), isTrue,
          reason: '目标已在轮次索引里，长回复只是位于它与当前视口之间——必须真的进入视口');
    });

    testWidgets('长回复在首轮（目标在它之后），第 4 轮仍能进入视口', (tester) async {
      final backend = _Backend(
        initialEvents:
            _turnEvents(1, 8, replyRepeat: normalRepeat, longTurn: 1, longRepeat: longRepeat),
      );
      await _pumpChat(tester, backend: backend);
      await _leaveBottom(tester);

      await _navigateTo(tester, 4);

      expect(tester.takeException(), isNull);
      expect(_textInViewport(tester, '问题 4'), isTrue,
          reason: '目标在超长首轮回复之后，比例估算会失准，必须用实测索引收窄区间');
    });

    testWidgets('长回复就在目标轮（第 4 轮 14,400 字），目标边界仍进入视口', (tester) async {
      final backend = _Backend(
        initialEvents:
            _turnEvents(1, 8, replyRepeat: normalRepeat, longTurn: 4, longRepeat: longRepeat),
      );
      await _pumpChat(tester, backend: backend);
      await _leaveBottom(tester);

      await _navigateTo(tester, 4);

      expect(tester.takeException(), isNull);
      expect(_textInViewport(tester, '问题 4'), isTrue,
          reason: '长回复属于目标轮本身时，落点常落在回复中段，仍需回到该轮起点');
    });

    testWidgets('prepend 之后最早的已加载轮次（长回复在其后）也能进入视口', (tester) async {
      // 初始只有第 5..10 轮，第 8 轮超长；上翻 prepend 第 1..4 轮后定位**第 1 轮**
      // ——它是最早的已加载轮次，位于 center 之前那条列表的最远处；center 锚点下
      // 该列表的"子项序号"与内容顺序相反，正是第二轮复现出的反向 bug 的落点。
      final backend = _Backend(
        initialEvents:
            _turnEvents(5, 10, replyRepeat: normalRepeat, longTurn: 8, longRepeat: longRepeat),
        olderEvents: _turnEvents(1, 4, replyRepeat: normalRepeat),
      );
      await _pumpChat(tester, backend: backend);

      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(_rail(tester).anchors.length, 10,
          reason: 'prepend 之后已加载窗口应包含 1..10 轮');

      await _navigateTo(tester, 1);

      expect(tester.takeException(), isNull);
      expect(_textInViewport(tester, '问题 1'), isTrue,
          reason: 'prepend 后最早的已加载轮次必须真的进入视口');
    });
  });

  // ── 第二轮评审 note 1080：加载条让实测索引比目标坐标系多 1 ──
  group('缺陷 6：加载条不得让实测索引与目标错位', () {
    for (final pending in [false, true]) {
      testWidgets('上翻在途（pending=$pending）时，已加载目标仍进入视口', (tester) async {
        final gate = Completer<http.Response>();
        final backend = _Backend(
          initialEvents: _turnEvents(1, 8, longTurn: 3, longRepeat: 2400),
          olderEvents: _turnEvents(1, 2),
        )..olderGate = gate;
        await _pumpChat(tester, backend: backend);

        // 滑到顶部触发上翻：请求挂起时 live sliver 首项就是加载条。
        final position = _position(tester);
        position.jumpTo(0);
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (!pending) {
          // 对照：让上翻先完成，加载条消失。
          gate.complete(_emptyPage());
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(gate.isCompleted, isTrue);
        } else {
          expect(gate.isCompleted, isFalse, reason: '加载条应保持可见');
        }

        // 定位期间用有界 pump（加载条的动画会让 pumpAndSettle 永不收敛）。
        final target = _rail(tester).anchors.firstWhere((a) => a.turn == 4);
        _rail(tester).onNavigate(target);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }

        // ignore: avoid_print
        print('TURNLOC pending=$pending turn=4 pixels=${position.pixels} '
            'max=${position.maxScrollExtent}');

        expect(_textInViewport(tester, '问题 4'), isTrue,
            reason: pending
                ? '加载条显示时测量索引必须与目标同一坐标系（此前多算一项，跳成前一条消息）'
                : '对照：加载条消失后同样必须进入视口（防止过度纠正）');

        if (!gate.isCompleted) {
          gate.complete(_emptyPage());
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  // ── issue #31：真机缺陷「长会话里跳不到早期轮次」──
  // 真机会话只有 10 轮却有 ~2967 个条目（每轮含大量工具调用与长回复），第 2 轮在最上方；
  // 旧的 6 次尝试预算 + 盲二分在 3000 条目下跳不到。
  group('缺陷 7（issue #31）：长会话里跳早期轮次', () {
    testWidgets('3000 条目从底部跳第 2 轮：进入视口且探针次数很少', (tester) async {
      final backend = _Backend(initialEvents: _turnEvents(1, 1000, replyRepeat: 2));
      await _pumpChat(tester, backend: backend);
      await _leaveBottom(tester);

      final offsets = await _navigateTo(tester, 2);

      expect(_textInViewport(tester, '问题 2'), isTrue,
          reason: '长会话里第 2 轮必须真的进入视口（真机报「多次尝试后仍未进入视图」）');
      expect(offsets.length, lessThanOrEqualTo(6),
          reason: '尺寸缓存 + 索引估算应让长跳在少数几步内收敛，而不是靠 24 次硬试');
      expect(tester.takeException(), isNull);
    });

    testWidgets('同一会话第二次跳转更快（尺寸缓存已热；先离开再重跳同一目标）', (tester) async {
      final backend = _Backend(initialEvents: _turnEvents(1, 1000, replyRepeat: 2));
      await _pumpChat(tester, backend: backend);
      await _leaveBottom(tester);

      final cold = await _navigateTo(tester, 2);
      expect(_textInViewport(tester, '问题 2'), isTrue);

      // 复审指出上一版直接跳**相邻**的第 3 轮、且目标已可见 → 0 次滚动也能绿，证明不了
      // 缓存起作用。改成：先回到列表另一端并断言目标已离开视口，再重跳**同一**目标。
      final position = _position(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_textInViewport(tester, '问题 2'), isFalse,
          reason: '重跳前目标必须不在视口，否则测不到热缓存');
      await _leaveBottom(tester);

      final hot = await _navigateTo(tester, 2);

      expect(_textInViewport(tester, '问题 2'), isTrue, reason: '热跳同样必须落到目标');
      expect(hot.length, lessThanOrEqualTo(cold.length),
          reason: '热缓存不应比冷跳更慢（冷 ${cold.length} 步 / 热 ${hot.length} 步）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('条目高度极不均匀（长回复按块穿插）时也收敛', (tester) async {
      final events = <Map<String, dynamic>>[];
      for (var block = 0; block < 10; block++) {
        final from = block * 60 + 1;
        events.addAll(_turnEvents(
          from,
          from + 59,
          replyRepeat: 2,
          longTurn: from + 30,
          longRepeat: 400,
        ));
      }
      final backend = _Backend(initialEvents: events);
      await _pumpChat(tester, backend: backend);
      await _leaveBottom(tester);

      await _navigateTo(tester, 2);

      expect(_textInViewport(tester, '问题 2'), isTrue,
          reason: '全局平均高度完全不可用时也要收敛（靠实测几何校正）');
      expect(tester.takeException(), isNull);
    });
  });
}
