// issue #76：过程折叠/工具卡视觉方案 C「章节列表」+ A 导轨。
//
// 覆盖（ADR 0028 / note 2212/2213/2214）：
// - 48dp 组头（13/w600/ink、chevron、整行命中）；
// - A 导轨：展开组 2dp 低对比 line、内容左移 14dp、收起组无导轨、无组外框；
// - 工具/思考行平铺（无逐卡边框；工具名 13/w500/ink，摘要 12/ink2；思考正文常规字形）；
// - 已展开详情才用 surface+radius10 轻底；失败详情 danger@5%；
// - 图片 chip 数字 ink、独立命中；失败聚合 chip（danger@8% 底 + ink 文字）；
// - 「收起过程」右对齐 48dp 脚注（12/ink2 + 上分线）；
// - 窄屏/大字徽标折行、长文本、三位数图片、分批入口 48dp、四档×两时机冒烟。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-76';

class _Backend {
  _Backend({required this.events});

  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue76.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: false,
      unknownEvents: true,
      callCorrelation: true,
    )
    ..toolCardsCapabilities = const ToolCardsCapabilities(
      version: 1,
      tools: {'shell'},
    );

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    final path = request.url.path;
    if (path == '/m/api/history') {
      final params = request.url.queryParameters;
      if (params.containsKey('after') || params.containsKey('before')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else {
        // 初始窗口返回全部事件：单轮 fixture 可能超过默认窗口 limit，
        // 视觉/分批用例需要完整的一轮形状。
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

Map<String, dynamic> _image(String id) => {
      'attachmentId': id,
      'width': 12,
      'height': 8,
      'mimeType': 'image/png',
      'name': '$id.png',
    };

/// 运行中的一轮（无 turn/end：过程块/组强制展开，便于断言展开态视觉）。
List<Map<String, dynamic>> _runningEvents({
  int tools = 2,
  int failures = 0,
  int images = 0,
  bool reasoning = true,
  String toolName = 'shell',
  String arguments = '{"command":"ls -la"}',
}) {
  final events = <Map<String, dynamic>>[
    {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
    {
      'seq': 2,
      'type': 'user/message',
      'data': {'messageId': 'u1', 'text': '问题', 'sourceKind': 'user'},
      'time': 1100,
    },
  ];
  var seq = 3;
  if (reasoning) {
    events.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {
        'turn': 1,
        'step': 1,
        'messageId': 'a-reason',
        'text': '',
        'reasoning': 'ROW-REASONING 第一行',
        'reasoningChars': 18,
      },
      'time': 1150,
    });
  }
  for (var i = 0; i < tools; i++) {
    events.add({
      'seq': seq++,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-$i',
        'name': toolName,
        'arguments': arguments,
        if (toolName == 'shell')
          'summary': {
            'kind': 'command',
            'tool': toolName,
            'command': 'ls -la',
          },
      },
      'time': 1200 + i * 10,
    });
    events.add({
      'seq': seq++,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-$i',
        'name': toolName,
        'text': 'ok $i',
        'isError': i < failures,
        if (i == 0 && images > 0)
          'images': [for (var k = 0; k < images; k++) _image('att-$k')],
      },
      'time': 1201 + i * 10,
    });
  }
  return events;
}

/// 已完成的一轮（默认整轮摘要折叠；用于展开/收起、收起脚注、窄屏徽标）。
List<Map<String, dynamic>> _endedEvents({
  int tools = 2,
  int failures = 0,
  bool reasoning = true,
}) {
  final events = _runningEvents(
    tools: tools,
    failures: failures,
    images: failures > 0 ? 3 : 0,
    reasoning: reasoning,
  );
  var seq = events.length + 2;
  events.add({
    'seq': seq++,
    'type': 'assistant/message',
    'data': {'turn': 1, 'step': 2, 'messageId': 'a-final', 'text': '完成'},
    'time': 2000,
  });
  events.add({
    'seq': seq++,
    'type': 'turn/end',
    'data': {
      'turn': 1,
      'reason': {'kind': 'completed'},
    },
    'time': 2100,
  });
  return events;
}

Future<AppStore> _pumpChat(
  WidgetTester tester,
  List<Map<String, dynamic>> events, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  TurnFoldTiming timing = TurnFoldTiming.afterAnswer,
  String keySuffix = '',
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [
      Session(id: _session, title: 'S', cwd: null, createdAt: 1),
    ]
    ..stepDisplayMode = mode
    ..turnFoldTiming = timing;
  final backend = _Backend(events: events);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue76-$keySuffix-${mode.name}-${timing.name}'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  await tester.pump();
  return store;
}

Future<void> _inject(
  WidgetTester tester,
  AppStore store,
  Map<String, dynamic> event,
) async {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': event,
  });
  await tester.pump(const Duration(milliseconds: 90));
  await tester.pump();
}

Finder get _groupHeaders => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ProcessGroupHeader',
    );
Finder get _toolCards => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ToolActivityCard',
    );
Finder get _summaryRows => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ProcessSummaryRow',
    );
Finder get _imageChips => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ImageCountChip',
    );

/// 组边界导轨：仅 left 边 2dp、其它边为 0 的 Container（A 方案）。
Finder get _rails => find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final decoration = w.decoration;
      if (decoration is! BoxDecoration) return false;
      final border = decoration.border;
      if (border is! Border) return false;
      return border.left.width == 2 &&
          border.top.width == 0 &&
          border.right.width == 0 &&
          border.bottom.width == 0;
    });

Finder _borderedContainersIn(Finder scope) => find.descendant(
      of: scope,
      matching: find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final decoration = w.decoration;
        if (decoration is! BoxDecoration) return false;
        final border = decoration.border;
        if (border is! Border) return false;
        return border.top.width > 0 && border.left.width > 0;
      }),
    );

void main() {
  testWidgets('组头：48dp 整行命中、13/w600/ink、有 chevron', (tester) async {
    await _pumpChat(tester, _runningEvents());
    final header = _groupHeaders;
    expect(header, findsOneWidget);
    expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
    final ctx = tester.element(header);
    final title = find.descendant(
      of: header,
      matching: find.textContaining('工具调用'),
    );
    expect(title, findsOneWidget);
    final style = tester.widget<Text>(title).style!;
    expect(style.fontSize, 13);
    expect(style.fontWeight, FontWeight.w600);
    expect(style.color, DshColors.ink(ctx));
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.keyboard_arrow_up)),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('A 导轨：展开组 2dp line + 内容左移 14dp；无组外框', (tester) async {
    await _pumpChat(tester, _runningEvents());
    expect(_rails, findsOneWidget);
    final headerLeft = tester.getTopLeft(_groupHeaders).dx;
    final railRect = tester.getRect(_rails);
    expect(railRect.left - headerLeft, closeTo(6, 0.5), reason: '导轨在左 6dp');
    final border =
        (tester.widget<Container>(_rails).decoration as BoxDecoration).border
            as Border;
    expect(border.left.width, 2, reason: '导轨 2dp');
    expect(border.left.color, DshColors.line(tester.element(_rails)),
        reason: '导轨用低对比 line');
    expect(
      tester.getTopLeft(_toolCards.first).dx - headerLeft,
      closeTo(14, 0.5),
      reason: '组内容左移 14dp',
    );
    // 组没有外框：工具卡自身也没有整卡边框（平铺）。
    expect(_borderedContainersIn(_toolCards), findsNothing);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('组收起：不留导轨；展开后重新出现', (tester) async {
    await _pumpChat(tester, _endedEvents());
    // 整轮摘要默认折叠 → 点摘要展开过程块（组默认收起）。
    expect(_summaryRows, findsOneWidget);
    await tester.tap(_summaryRows);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_groupHeaders, findsOneWidget);
    expect(_rails, findsNothing, reason: '收起组不留导轨/空白');
    await tester.tap(_groupHeaders);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_rails, findsOneWidget, reason: '展开组出现导轨');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('工具行平铺：标题 13/w500/ink、摘要 12/ink2、无整卡边框', (tester) async {
    await _pumpChat(tester, _runningEvents());
    final ctx = tester.element(_toolCards.first);
    final title = find.descendant(
      of: _toolCards.first,
      matching: find.text('shell'),
    );
    final titleStyle = tester.widget<Text>(title.first).style!;
    expect(titleStyle.fontSize, 13);
    expect(titleStyle.fontWeight, FontWeight.w500);
    expect(titleStyle.color, DshColors.ink(ctx));
    final fold = find.descendant(
      of: _toolCards.first,
      matching: find.textContaining('ls -la'),
    );
    final foldStyle = tester.widget<Text>(fold.first).style!;
    expect(foldStyle.fontSize, 12);
    expect(foldStyle.color, DshColors.ink2(ctx));
    expect(_borderedContainersIn(_toolCards), findsNothing);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('展开详情：surface + radius10 轻底；失败详情 danger@5%', (tester) async {
    await _pumpChat(tester, _runningEvents(tools: 2, failures: 1));
    final danger = DshColors.danger(tester.element(_toolCards.first));
    final failedCard = _toolCards.first;
    // 失败工具默认收起（普通模式），点开详情。
    await tester.tap(failedCard);
    await tester.pump(const Duration(milliseconds: 200));
    final detailContainers = find.descendant(
      of: failedCard,
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          ((w.decoration as BoxDecoration).borderRadius ==
              BorderRadius.circular(DshTheme.radiusSm))),
    );
    expect(detailContainers, findsWidgets, reason: '详情区使用 radius10 轻底');
    final failureBg = tester
        .widgetList<Container>(detailContainers)
        .map((c) => (c.decoration as BoxDecoration).color)
        .whereType<Color>()
        .toList();
    expect(
      failureBg.any((c) => c.a > 0 && c.r == danger.r && c.g == danger.g),
      isTrue,
      reason: '失败详情 danger@5% 轻底',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('图片 chip 数字 ink + 独立 32 命中；失败聚合 chip danger 底/ink 字', (tester) async {
    await _pumpChat(tester, _runningEvents(tools: 2, failures: 2, images: 100));
    final ctx = tester.element(_toolCards.first);
    expect(_imageChips, findsWidgets);
    final chip = _imageChips.first;
    final count = tester.widget<Text>(
      find.descendant(of: chip, matching: find.text('100')),
    );
    expect(count.style?.color, DshColors.ink(ctx), reason: '数字用 ink（不用 ink2）');
    expect(tester.getSize(chip).height, 32, reason: '#74 独立 32 命中区');
    final failChip = find.text('失败 2');
    expect(failChip, findsOneWidget, reason: '组头聚合失败工具数（只计 failed）');
    final failStyle = tester.widget<Text>(failChip).style!;
    expect(failStyle.fontSize, 11);
    expect(failStyle.color, DshColors.ink(ctx));
    final failContainer = find.ancestor(
      of: failChip,
      matching: find.byWidgetPredicate((w) =>
          w is Container && w.decoration is BoxDecoration),
    );
    final bg = (tester.widget<Container>(failContainer.first).decoration
            as BoxDecoration)
        .color!;
    final danger = DshColors.danger(ctx);
    expect(bg.r, closeTo(danger.r, 0.02), reason: '失败 chip danger 底');
    expect(bg.a, closeTo(0.08, 0.02), reason: 'danger@8%');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('思考行落定平铺、正文 12/1.6 常规字形（中文不斜体）', (tester) async {
    await _pumpChat(tester, _runningEvents(tools: 1));
    final ctx = tester.element(_groupHeaders);
    final preview = find.text('ROW-REASONING 第一行');
    expect(preview, findsOneWidget);
    final previewStyle = tester.widget<Text>(preview).style!;
    expect(previewStyle.fontSize, 12);
    expect(previewStyle.color, DshColors.ink2(ctx));
    // 落定行没有 brandSoft 卡片底。
    expect(
      find.ancestor(
        of: preview,
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                DshColors.brandSoft(ctx)),
      ),
      findsNothing,
      reason: '落定思考行平铺，不挂轻底卡',
    );
    await tester.tap(preview);
    await tester.pump(const Duration(milliseconds: 200));
    final body = find.byWidgetPredicate(
      (w) => w is SelectableText && (w.data ?? '').contains('ROW-REASONING'),
    );
    expect(body, findsOneWidget);
    final bodyStyle = tester.widget<SelectableText>(body).style!;
    expect(bodyStyle.fontSize, 12);
    expect(bodyStyle.height, 1.6);
    expect(bodyStyle.fontStyle, isNot(FontStyle.italic),
        reason: '中文小字不用斜体');
    expect(bodyStyle.color, DshColors.ink2(ctx));
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('provisional 思考行保留 brandSoft 轻底（与落定行区分）', (tester) async {
    final store = await _pumpChat(
      tester,
      _runningEvents(tools: 1, reasoning: false),
    );
    await _inject(tester, store, {
      'seq': 50,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'provisional 思考',
      },
      'time': 3000,
    });
    final prov = find.byKey(const ValueKey('provisional-reasoning-row:1:1'));
    expect(prov, findsOneWidget);
    final ctx = tester.element(prov);
    final provBox = tester.widget<Container>(prov);
    expect(
      (provBox.decoration as BoxDecoration).color,
      DshColors.brandSoft(ctx),
      reason: 'provisional 行用 brandSoft 轻底',
    );
    expect(
      (provBox.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(DshTheme.radiusSm),
      reason: 'provisional 行 radiusSm',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('收起过程：右对齐 48dp、12/ink2、上方 1dp 分线', (tester) async {
    await _pumpChat(tester, _endedEvents());
    await tester.tap(_summaryRows);
    await tester.pump(const Duration(milliseconds: 200));
    final ctx = tester.element(find.text('收起过程'));
    final text = tester.widget<Text>(find.text('收起过程'));
    expect(text.style?.fontSize, 12);
    expect(text.style?.color, DshColors.ink2(ctx));
    final hit = find.ancestor(
      of: find.text('收起过程'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(hit.first).height, greaterThanOrEqualTo(48));
    final rect = tester.getRect(find.text('收起过程'));
    final screenWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(rect.right, closeTo(screenWidth - 24, 2),
        reason: '右对齐脚注（页边距 16 + 内边距 8）');
    expect(
      find.byWidgetPredicate((w) =>
          w is Icon && w.icon == Icons.unfold_less),
      findsOneWidget,
    );
    // 上方 1dp 分线：收起行上方存在 1dp 高 line 色 Container。
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.constraints?.maxHeight == 1 &&
          w.color == DshColors.line(ctx)),
      findsWidgets,
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('320 窄屏 + textScale1.5：组头徽标折到文案下一行，无 overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpChat(tester, _endedEvents(tools: 2, failures: 2));
    await tester.tap(find.textContaining('次工具调用').first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_groupHeaders, findsOneWidget);
    final ctx = tester.element(_groupHeaders);
    final titleRect = tester.getRect(
      find.descendant(
        of: _groupHeaders,
        matching: find.textContaining('工具调用'),
      ),
    );
    final chipRect = tester.getRect(
      find.descendant(of: _groupHeaders, matching: find.text('失败 2')),
    );
    expect(chipRect.top, greaterThan(titleRect.bottom - 1),
        reason: '窄屏/大字下徽标在文案下一行');
    expect(find.descendant(of: _groupHeaders, matching: _imageChips), findsWidgets,
        reason: '窄屏不丢图片入口');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 900));
    // 宽屏（390）下徽标应回到右栏（同一行）。
    tester.view.physicalSize = const Size(390, 800);
    tester.platformDispatcher.textScaleFactorTestValue = 1.0;
    await tester.pump(const Duration(milliseconds: 200));
    final wideTitle = tester.getRect(
      find.descendant(
        of: _groupHeaders,
        matching: find.textContaining('工具调用'),
      ),
    );
    final wideChip = tester.getRect(
      find.descendant(of: _groupHeaders, matching: find.text('失败 2')),
    );
    expect(wideChip.top, lessThan(wideTitle.bottom + 20));
    await tester.pump(const Duration(milliseconds: 900));
    // ignore: unused_local_variable
    final _ = ctx;
  });

  testWidgets('长工具名/命令/路径不裁切关键信息、无 overflow', (tester) async {
    final longName = 'very_long_tool_name_${'x' * 80}';
    final longArg = '{"command":"cat /very/long/path/${'y' * 120}/file.txt"}';
    await _pumpChat(
      tester,
      _runningEvents(tools: 1, toolName: longName, arguments: longArg),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('very_long_tool_name'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('分批入口：min48 平铺、12/500/ink2、无卡、图片 chip 独立', (tester) async {
    // 60 行过程块在默认视口下位于 live 列表顶部（懒构建不渲染）；拉高视口让整块可见。
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _runningEvents(tools: 60, images: 2));
    final more = find.textContaining('显示更多');
    expect(more, findsOneWidget);
    final style = tester.widget<Text>(more).style!;
    expect(style.fontSize, 12);
    expect(style.fontWeight, FontWeight.w500);
    expect(style.color, DshColors.ink2(tester.element(more)));
    final hit = find.ancestor(of: more, matching: find.byType(InkWell));
    expect(tester.getSize(hit.first).height, greaterThanOrEqualTo(48));
    expect(
      find.descendant(
        of: hit.first,
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border is Border),
      ),
      findsNothing,
      reason: '批次入口透明无卡',
    );
    expect(_imageChips, findsWidgets, reason: '分批隐藏行的图片入口仍可达');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('四档 × 两时机：渲染无异常，展开组有导轨、收起组无导轨', (tester) async {
    for (final mode in WorkStepDisplayMode.values) {
      for (final timing in TurnFoldTiming.values) {
        await _pumpChat(
          tester,
          _endedEvents(tools: 2),
          mode: mode,
          timing: timing,
          keySuffix: 'matrix',
        );
        expect(tester.takeException(), isNull,
            reason: '${mode.name}/${timing.name} 渲染无异常');
        if (_summaryRows.evaluate().isNotEmpty) {
          await tester.tap(_summaryRows);
          await tester.pump(const Duration(milliseconds: 200));
        }
        if (_groupHeaders.evaluate().isNotEmpty) {
          final before = _rails.evaluate().length;
          await tester.tap(_groupHeaders.first);
          await tester.pump(const Duration(milliseconds: 200));
          final after = _rails.evaluate().length;
          expect(after, isNot(before),
              reason: '${mode.name}/${timing.name} 组展开/收起切换导轨');
        }
        await tester.pump(const Duration(milliseconds: 900));
      }
    }
  });

  testWidgets('仅思考组：显示「思考 N 字」+ chevron，不出现工具语义', (tester) async {
    final events = <Map<String, dynamic>>[
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '问题', 'sourceKind': 'user'},
        'time': 1100,
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 1,
          'messageId': 'a1',
          'text': '答案',
          'reasoning': '只有思考',
          'reasoningChars': 5,
        },
        'time': 1200,
      },
      {
        'seq': 4,
        'type': 'turn/end',
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
        'time': 1300,
      },
    ];
    await _pumpChat(tester, events);
    if (_summaryRows.evaluate().isNotEmpty) {
      await tester.tap(_summaryRows);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('思考 5 字'), findsOneWidget);
    expect(
      find.descendant(
        of: _groupHeaders,
        matching: find.byIcon(Icons.keyboard_arrow_down),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 900));
  });
}
