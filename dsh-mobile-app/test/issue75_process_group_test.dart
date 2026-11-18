// issue #75：过程组「0 次工具调用」幽灵抬头 / 缺折叠箭头 / 不可点。
//
// 复现与验收（issue #75 正文 + note 2175）：
// - reasoning-only 组（有思考、无 tool/call）：抬头必须是「思考 N 字」等语义，带 chevron、可展开/收起；
// - **没有任何可见行**的组不渲染（不得出现「0 次工具调用」幽灵行）——分批把整组行挡在窗口外时尤其如此；
// - 每个可见组抬头都有明确 chevron 且点击生效（展开出现内容、再点收起）；
// - 运行中/已结束、普通模式「显示思考」开/关、50 行分批下一致。
//
// 用等价 fixture 复刻真机会话 22226918 的 turn 79/80 形状：
// `step1..N` 各一次工具调用，最后一个 `step` 只有 reasoning 与最终回答文本。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Backend {
  _Backend({required this.events, this.returnAllOnInitial = false});

  final List<Map<String, dynamic>> events;

  /// 初始窗口忽略 limit 返回全部事件（分批用例需要整轮 61 行都在窗口内）。
  final bool returnAllOnInitial;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue75.test'
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
    if (request.url.path == '/m/api/history') {
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else if (params.containsKey('before')) {
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final preceding = events.where((e) => (e['seq'] as int) < before).toList();
        final page =
            preceding.length > limit ? preceding.sublist(preceding.length - limit) : preceding;
        body = {'ok': true, 'events': page, 'hasMore': preceding.length > page.length};
      } else if (returnAllOnInitial) {
        body = {'ok': true, 'events': events, 'hasMore': false};
      } else {
        // 单轮 fixture 事件量小于 limit 的场景都走全量尾部。
        final tail = events.length > limit ? events.sublist(events.length - limit) : events;
        body = {'ok': true, 'events': tail, 'hasMore': events.length > tail.length};
      }
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

/// 复刻 turn 79/80 形状：若干「1 工具」step + 最后一个 reasoning-only step。
///
/// [ended] 为 false 表示轮次仍在运行（无 turn/end）。
List<Map<String, dynamic>> reasoningOnlyTurn({
  int turn = 1,
  int toolSteps = 2,
  bool ended = true,
  bool includeTime = true,
  bool reasoningOnToolSteps = false,
}) {
  const finalReasoning = 'FINAL-REASONING-只有思考没有工具\n第二行';
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  events.add({
    'seq': seq++,
    'type': 'turn/start',
    'data': {'turn': turn},
    if (includeTime) 'time': 1000,
  });
  events.add({
    'seq': seq++,
    'type': 'user/message',
    'data': {'messageId': 'u$turn', 'text': '问题 $turn', 'sourceKind': 'user'},
  });
  for (var step = 1; step <= toolSteps; step++) {
    if (reasoningOnToolSteps) {
      // 真机会话形状：每个工具 step 的 assistant/message 都带 reasoning（正文为空）。
      events.add({
        'seq': seq++,
        'type': 'assistant/message',
        'data': {
          'turn': turn,
          'step': step,
          'messageId': 'a$turn-$step',
          'text': '',
          'reasoning': 'STEP-$step-REASONING',
          'reasoningChars': 'STEP-$step-REASONING'.length,
        },
        if (includeTime) 'time': 1000 + step * 100 - 10,
      });
    }
    events.add({
      'seq': seq++,
      'type': 'tool/call',
      'data': {
        'turn': turn,
        'step': step,
        'callId': 'call-$turn-$step',
        'name': 'bash',
        'arguments': 'echo $step',
      },
      if (includeTime) 'time': 1000 + step * 100,
    });
    events.add({
      'seq': seq++,
      'type': 'tool/result',
      'data': {
        'turn': turn,
        'step': step,
        'callId': 'call-$turn-$step',
        'name': 'bash',
        'text': 'ok $step',
      },
      if (includeTime) 'time': 1000 + step * 100 + 50,
    });
  }
  final finalStep = toolSteps + 1;
  events.add({
    'seq': seq++,
    'type': 'assistant/message',
    'data': {
      'turn': turn,
      'step': finalStep,
      'messageId': 'a$turn-final',
      'text': '最终回答 $turn',
      'reasoning': finalReasoning,
      'reasoningChars': finalReasoning.length,
    },
    if (includeTime) 'time': 1500,
  });
  if (ended) {
    events.add({
      'seq': seq++,
      'type': 'turn/end',
      'data': {'turn': turn, 'reason': {'kind': 'completed'}},
      if (includeTime) 'time': 2000,
    });
  }
  return events;
}

/// 60 个工具行 + 最后一个 reasoning-only step：分批窗口只露出前 50 行，
/// 最后一个只有思考的组整体落在窗口外（幽灵抬头复现用例）。
List<Map<String, dynamic>> batchedWithReasoningTail() {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  events.add({'seq': seq++, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000});
  events.add({
    'seq': seq++,
    'type': 'user/message',
    'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
  });
  for (var i = 0; i < 60; i++) {
    events.add({
      'seq': seq++,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'bulk-$i',
        'name': 'bash',
        'arguments': 'echo $i',
      },
      'time': 1100 + i,
    });
    events.add({
      'seq': seq++,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'bulk-$i',
        'name': 'bash',
        'text': 'ok $i',
      },
      'time': 1101 + i,
    });
  }
  events.add({
    'seq': seq++,
    'type': 'assistant/message',
    'data': {
      'turn': 1,
      'step': 2,
      'messageId': 'a-tail',
      'text': '尾巴回答',
      'reasoning': 'TAIL-REASONING',
      'reasoningChars': 'TAIL-REASONING'.length,
    },
    'time': 2000,
  });
  events.add({
    'seq': seq++,
    'type': 'turn/end',
    'data': {'turn': 1, 'reason': {'kind': 'completed'}},
    'time': 2500,
  });
  return events;
}

/// 过程组抬头内的 chevron 数量（箭头缺失/渲染异常的回归断言）。
int chevronCountInHeader(WidgetTester tester, String text) {
  final headerText = find.text(text);
  if (headerText.evaluate().isEmpty) return -1;
  final row = find.ancestor(of: headerText, matching: find.byType(Row)).first;
  return find
      .descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == Icons.keyboard_arrow_down ||
                  w.icon == Icons.keyboard_arrow_up),
        ),
      )
      .evaluate()
      .length;
}

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  bool showReasoning = false,
}) async {
  final store = AppStore()
    ..sessionId = 'session-75'
    ..sessions = [Session(id: 'session-75', title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode
    ..showReasoning = showReasoning;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue75-${mode.name}-$showReasoning-${backend.hashCode}'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

/// 展开整轮（标准档默认折叠成一行摘要）。
Future<void> _expandTurn(WidgetTester tester) async {
  await tester.tap(find.textContaining('组 · '));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('reasoning-only 组：抬头是「思考 N 字」、有 chevron、可展开看思考', (tester) async {
    await _pumpChat(tester, _Backend(events: reasoningOnlyTurn()));
    await _expandTurn(tester);

    // 工具有计数组；最后一个只有思考的组不得显示「0 次工具调用」。
    expect(find.text('1 次工具调用'), findsNWidgets(2));
    expect(find.text('0 次工具调用'), findsNothing);
    expect(
      find.textContaining('思考 '),
      findsWidgets,
      reason: 'reasoning-only 组抬头应显示思考字数语义',
    );

    // 找到 reasoning-only 组抬头并验证 chevron 存在（箭头缺失即本 issue 的核心症状）。
    final reasoningHeader = find.textContaining('思考 ').last;
    final row = find.ancestor(of: reasoningHeader, matching: find.byType(Row)).first;
    expect(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == Icons.keyboard_arrow_down ||
                  w.icon == Icons.keyboard_arrow_up),
        ),
      ),
      findsOneWidget,
      reason: '可见组抬头必须有明确 chevron',
    );

    // 点击可展开：出现思考正文。
    expect(find.textContaining('FINAL-REASONING'), findsNothing);
    await tester.tap(reasoningHeader);
    await tester.pumpAndSettle();
    expect(find.textContaining('FINAL-REASONING'), findsOneWidget);

    // 再点收起：思考正文消失（chevron 回落）。
    final headerRow = find.ancestor(
      of: find.textContaining('思考 ').last,
      matching: find.byType(Row),
    ).first;
    await tester.tap(headerRow);
    await tester.pumpAndSettle();
    expect(find.textContaining('FINAL-REASONING'), findsNothing);
  });

  testWidgets('分批把整组行挡在窗口外时，该组不渲染幽灵抬头', (tester) async {
    // 60 个工具行 + 末尾 reasoning-only：batch=50 时末尾组无任何可见行。
    // 用标准档（有过程组抬头），先把整轮展开。
    await _pumpChat(
      tester,
      _Backend(events: batchedWithReasoningTail(), returnAllOnInitial: true),
    );
    await _expandTurn(tester);

    Future<void> scrollUntil(Finder finder) async {
      for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 120));
      }
    }

    await scrollUntil(find.textContaining('显示更多（还有'));
    // 前面只显示 50 行工具（过程行），末尾「思考」组整体不可见 → 不应出现其抬头。
    expect(find.text('0 次工具调用'), findsNothing);
    expect(find.textContaining('思考 14 字'), findsNothing);
    expect(find.textContaining('显示更多（还有'), findsOneWidget);

    // 显示更多之后，末尾组有了可见行，抬头才出现且可展开。
    await tester.ensureVisible(find.textContaining('显示更多（还有'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('显示更多（还有'));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示更多'), findsNothing);
    expect(find.textContaining('TAIL-REASONING'), findsNothing,
        reason: '组仍折叠，思考正文不可见');
    await scrollUntil(find.textContaining('思考 14 字'));
    expect(find.textContaining('思考 14 字'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('思考 14 字'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('思考 14 字'));
    await tester.pumpAndSettle();
    expect(find.textContaining('TAIL-REASONING'), findsOneWidget);
  });

  testWidgets('真实会话形状（每个工具 step 都带 reasoning + 末尾纯思考 step）', (tester) async {
    // 复刻会话 22226918 turn 79：step1..5 各「reasoning + 1 工具」，step6 仅 reasoning + 回答。
    await _pumpChat(
      tester,
      _Backend(
        events: reasoningOnlyTurn(toolSteps: 5, reasoningOnToolSteps: true),
        returnAllOnInitial: true,
      ),
    );
    await _expandTurn(tester);

    expect(find.text('0 次工具调用'), findsNothing);
    // 5 个工具组各 1 次调用 + 1 个纯思考组。
    expect(find.text('1 次工具调用'), findsNWidgets(5));
    expect(find.textContaining('思考 '), findsOneWidget);
    // 每个可见组抬头都有 chevron。
    for (final label in ['1 次工具调用', ...List.filled(1, '思考 ')]) {
      final finder = label == '思考 ' ? find.textContaining(label).last : find.text(label).first;
      final row = find.ancestor(of: finder, matching: find.byType(Row)).first;
      expect(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Icon &&
                (w.icon == Icons.keyboard_arrow_down ||
                    w.icon == Icons.keyboard_arrow_up),
          ),
        ),
        findsOneWidget,
      );
    }
    // 纯思考组可展开看到思考全文（真机里正是它的「0 次工具调用」幽灵行）。
    await tester.tap(find.textContaining('思考 ').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('FINAL-REASONING'), findsOneWidget);
  });

  testWidgets('运行中 reasoning-only 组：有 chevron、可展开；不显示「0 次工具调用」', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: reasoningOnlyTurn(ended: false)),
      mode: WorkStepDisplayMode.expanded,
    );

    expect(find.text('0 次工具调用'), findsNothing);
    // 完全展开档运行中：过程行平铺、无组抬头；思考正文可直接读到。
    expect(find.textContaining('FINAL-REASONING'), findsOneWidget);
  });

  testWidgets('标准档运行中：按组强制展开，reasoning-only 组抬头语义正确且可收起', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: reasoningOnlyTurn(ended: false)),
      mode: WorkStepDisplayMode.standard,
    );

    // 运行中组强制展开：思考正文已在；
    expect(find.textContaining('FINAL-REASONING'), findsOneWidget);
    expect(find.text('0 次工具调用'), findsNothing);
    expect(find.textContaining('思考 '), findsWidgets);

    // 手动收起该组 → 思考正文消失，chevron 呈现收起态且仍可点。
    final header = find.textContaining('思考 ').last;
    expect(chevronCountInHeader(tester, (tester.widget<Text>(header)).data!), 1);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.textContaining('FINAL-REASONING'), findsNothing);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.textContaining('FINAL-REASONING'), findsOneWidget);
  });

  testWidgets('四档展示模式矩阵：reasoning-only 组不出现「0 次工具调用」，抬头语义正确', (tester) async {
    for (final mode in [
      WorkStepDisplayMode.concise,
      WorkStepDisplayMode.standard,
      WorkStepDisplayMode.detailed,
    ]) {
      await _pumpChat(
        tester,
        _Backend(events: reasoningOnlyTurn()),
        mode: mode,
      );
      await _expandTurn(tester);
      expect(find.text('0 次工具调用'), findsNothing, reason: mode.name);
      final reasoningHeader = find.textContaining('思考 ').last;
      expect(reasoningHeader, findsOneWidget, reason: mode.name);
      // 抬头内必须有 chevron，且点击可展开思考正文。
      final row = find.ancestor(of: reasoningHeader, matching: find.byType(Row)).first;
      expect(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Icon &&
                (w.icon == Icons.keyboard_arrow_down ||
                    w.icon == Icons.keyboard_arrow_up),
          ),
        ),
        findsOneWidget,
        reason: '${mode.name}：可见组抬头必须有 chevron',
      );
      // 展开组：标准/详细档折叠态仍保留思考首行预览；简洁档只给「思维链 N 字」标签。
      await tester.tap(reasoningHeader);
      await tester.pumpAndSettle();
      final rowLabel = mode == WorkStepDisplayMode.concise
          ? find.textContaining('思维链 ')
          : find.textContaining('FINAL-REASONING');
      expect(rowLabel, findsWidgets, reason: '${mode.name}：展开组后应出现思考行');
      // 点思考行才看到全文（简洁档无预览）。
      await tester.tap(rowLabel.last);
      await tester.pumpAndSettle();
      expect(find.textContaining('FINAL-REASONING'), findsOneWidget, reason: mode.name);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    // 完全展开档：过程行平铺、无组抬头，思考正文直接可见。
    await _pumpChat(
      tester,
      _Backend(events: reasoningOnlyTurn()),
      mode: WorkStepDisplayMode.expanded,
    );
    expect(find.text('0 次工具调用'), findsNothing);
    expect(find.textContaining('FINAL-REASONING'), findsOneWidget);
  });

  testWidgets('普通模式「显示思考」开/关：过程块 reasoning 行与抬头不受影响', (tester) async {
    for (final showReasoning in [false, true]) {
      await _pumpChat(
        tester,
        _Backend(events: reasoningOnlyTurn()),
        showReasoning: showReasoning,
      );
      await _expandTurn(tester);
      expect(find.text('0 次工具调用'), findsNothing);
      expect(find.textContaining('思考 '), findsWidgets, reason: 'showReasoning=$showReasoning');
      // 清理下一个用例：卸载本页状态。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
