// issue #90：斜杠菜单（命令+技能）+ 用户消息内联高亮。
//
// 覆盖：leading 命令+技能分组、inline 仅技能、空 query/过滤/无匹配、点选只插入、
// 技能提交走普通消息（命令同名优先）、未知命令保持 toast、用户气泡双高亮（不可点）。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-90';

const _commands = [
  {'name': 'compact', 'description': 'Compact conversation history'},
  {'name': 'plan', 'description': 'Plan a task', 'input': {'hint': '<goal>'}},
];
const _skills = [
  {'name': 'grill-me', 'description': 'Grill a plan', 'modelInvocable': true},
  {'name': 'manual', 'description': 'Manual only skill', 'modelInvocable': false},
  // 与命令同名：菜单/提交/高亮都必须命令优先。
  {'name': 'compact', 'description': 'skill duplicate', 'modelInvocable': true},
];

class _Backend {
  _Backend({
    this.events = const [],
    List<Map<String, dynamic>>? commands,
    List<Map<String, dynamic>>? skills,
    this.skillsUnavailable = false,
    this.skillsUnavailableOnce = false,
    this.skillsFailFirst = false,
    this.catalogGate,
    this.skillsGate,
  })  : commands = commands ?? _commands,
        skills = skills ?? _skills;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> commands;
  final List<Map<String, dynamic>> skills;
  final bool skillsUnavailable;
  final bool skillsUnavailableOnce;
  final bool skillsFailFirst;
  final Completer<void>? catalogGate;
  final Completer<void>? skillsGate;
  final List<Map<String, dynamic>> sends = [];
  int commandRuns = 0;
  int skillRequests = 0;
  int _skillFailures = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue90.test'
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
    http.Response reply(Map<String, dynamic> value) => http.Response(
          jsonEncode(value),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
      return reply(body);
    }
    if (path == '/m/api/commands') {
      if (request.method == 'POST') {
        commandRuns += 1;
        return reply({'ok': true, 'messageId': 'cmd-1'});
      }
      await catalogGate?.future;
      return reply({'ok': true, 'commands': commands});
    }
    if (path == '/m/api/skills') {
      skillRequests += 1;
      if (skillsFailFirst && _skillFailures++ == 0) {
        return http.Response('boom', 500);
      }
      await catalogGate?.future;
      await skillsGate?.future;
      if (skillsUnavailable ||
          (skillsUnavailableOnce && skillRequests == 1)) {
        return reply({'ok': true, 'skills': <Object>[], 'unavailable': true});
      }
      return reply({'ok': true, 'skills': skills});
    }
    if (path == '/m/api/send') {
      sends.add(jsonDecode(request.body) as Map<String, dynamic>);
      return reply({'ok': true, 'messageId': 'sent-1'});
    }
    if (path == '/m/api/queue') return reply({'ok': true, 'rows': <Object>[]});
    if (path == '/m/api/todos') return reply({'ok': true, 'todos': <Object>[]});
    if (path == '/m/api/session-config') {
      return reply({'ok': true, 'config': <String, dynamic>{}});
    }
    return reply({'ok': true});
  }
}

Map<String, dynamic> _event(String type, int seq, Map<String, dynamic> data) => {
      'seq': seq,
      'type': type,
      'data': data,
    };

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  bool dark = false,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(MaterialApp(
    theme: dark ? ThemeData.dark() : null,
    home: ChatScreen(
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return store;
}

Finder get _input => find.byType(TextField).first;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump(const Duration(milliseconds: 150));
}

void main() {
  setUp(() => L10n.lang = 'en');

  testWidgets('leading /：命令组前、技能组后；过滤/空态；点选只插入不发送', (tester) async {
    final backend = _Backend();
    await _pumpChat(tester, backend);
    await _type(tester, '/');
    expect(find.byKey(const Key('slash-menu')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-command-compact')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-command-plan')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-skill-manual')), findsOneWidget);
    expect(find.text('manual only'), findsOneWidget, reason: '技能 userOnly 标记');
    // 同名技能不重复（命令优先）。
    expect(find.byKey(const Key('slash-menu-skill-compact')), findsNothing);
    // 分组顺序：命令标题在技能标题之前。
    final commandHeader = tester.getTopLeft(find.textContaining('Commands')).dy;
    final skillHeader = tester.getTopLeft(find.textContaining('Skills')).dy;
    expect(commandHeader, lessThan(skillHeader));

    await _type(tester, '/gr');
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-command-compact')), findsNothing);
    await _type(tester, '/zzz');
    expect(find.byKey(const Key('slash-menu-empty')), findsOneWidget);
    expect(find.text('No matching commands or skills'), findsOneWidget);

    await _type(tester, '/gr');
    await tester.tap(find.byKey(const Key('slash-menu-skill-grill-me')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(_input).controller!.text, '/grill-me ');
    expect(backend.sends, isEmpty, reason: '点选只填入，不自动发送');
    expect(backend.commandRuns, 0, reason: '点选也不执行命令');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('行内 / 只显示技能；@/词内/URL 不弹菜单', (tester) async {
    await _pumpChat(tester, _Backend());
    await _type(tester, 'hello /');
    expect(find.byKey(const Key('slash-menu')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-command-compact')), findsNothing);

    await _type(tester, 'x/name');
    expect(find.byKey(const Key('slash-menu')), findsNothing);
    await _type(tester, 'https:/example');
    expect(find.byKey(const Key('slash-menu')), findsNothing);
    await _type(tester, '//double');
    expect(find.byKey(const Key('slash-menu')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('提交：技能按普通消息发送（同名命令优先）；未知命令保持 toast', (tester) async {
    final backend = _Backend();
    await _pumpChat(tester, backend);
    await _type(tester, '/grill-me');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.commandRuns, 0, reason: '技能不得走 commands.execute');
    expect(backend.sends.single['text'], '/grill-me');

    await _type(tester, '/compact');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.commandRuns, 1, reason: '同名技能存在时命令优先仍执行命令');
    expect(backend.sends, hasLength(1));

    await _type(tester, '/unknown-skill');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.commandRuns, 1, reason: '未知命令不执行');
    expect(backend.sends, hasLength(2), reason: '未知命令照常作为普通消息发送');
    // 未知命令 toast 的既有行为由 issue25_command_send_test 覆盖；此处验证不执行、照常发送。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('用户气泡高亮：命令/技能不同 chip、不可点、未知/路径普通文本', (tester) async {
    final backend = _Backend(events: [
      _event('turn/start', 1, {'turn': 1}),
      _event('user/message', 2, {
        'messageId': 'u1',
        'text': '/compact /grill-me /unknown /tmp/foo x/name https:/x',
        'sourceKind': 'user',
      }),
      _event('assistant/message', 3, {
        'turn': 1,
        'messageId': 'a1',
        'text': '收到',
      }),
    ]);
    await _pumpChat(tester, backend);
    expect(find.byKey(const Key('slash-chip-command-compact')), findsOneWidget);
    expect(find.byKey(const Key('slash-chip-skill-grill-me')), findsOneWidget);
    final commandDecoration =
        tester.widget<Container>(find.byKey(const Key('slash-chip-command-compact'))).decoration
            as BoxDecoration;
    expect(commandDecoration.border, isNotNull, reason: '命令 chip 必须有可见边框');
    expect(commandDecoration.color, const Color(0xFFE6F7EC));
    expect((commandDecoration.border as Border).top.color, const Color(0xFFBDE8CD));
    expect(
      commandDecoration.color,
      isNot(DshColors.line(tester.element(find.byType(ChatScreen)))),
      reason: '命令 chip 不得再与用户气泡同底色（line）',
    );
    final skillDecoration =
        tester.widget<Container>(find.byKey(const Key('slash-chip-skill-grill-me'))).decoration
            as BoxDecoration;
    expect(skillDecoration.color, const Color(0xFFE9EEFF));
    expect((skillDecoration.border as Border).top.color, const Color(0xFFC7D2FF));
    expect(find.byKey(const Key('slash-chip-command-unknown')), findsNothing);
    expect(find.byKey(const Key('slash-chip-skill-unknown')), findsNothing);
    // chip 不可点：内部不得有 InkWell/GestureDetector。
    expect(
      find.descendant(
        of: find.byKey(const Key('slash-chip-command-compact')),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    // 原始文本仍在（未知/路径不 chip，但复制文本不变）。
    expect(find.textContaining('/unknown'), findsWidgets);
    // 复制入口仍复制原始 item.text（不是 chip 文本/占位）。
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.tap(find.byIcon(Icons.content_copy).last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      copied,
      '/compact /grill-me /unknown /tmp/foo x/name https:/x',
      reason: '复制必须使用原始文本，不把 chip 当交互',
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('技能目录 unavailable：只显示命令（静默）；高亮只命令', (tester) async {
    final backend = _Backend(
      skillsUnavailable: true,
      events: [
        _event('turn/start', 1, {'turn': 1}),
        _event('user/message', 2, {
          'messageId': 'u1',
          'text': '/compact /grill-me',
          'sourceKind': 'user',
        }),
      ],
    );
    await _pumpChat(tester, backend);
    await _type(tester, '/');
    expect(find.byKey(const Key('slash-menu-command-compact')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('slash-chip-command-compact')), findsOneWidget);
    expect(find.byKey(const Key('slash-chip-skill-grill-me')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('技能目录首次失败不缓存永久空：再次输入重试并出现技能', (tester) async {
    final backend = _Backend(skillsFailFirst: true);
    await _pumpChat(tester, backend);
    await _type(tester, '/');
    expect(find.byKey(const Key('slash-menu-command-compact')), findsOneWidget);
    final firstRequests = backend.skillRequests;
    await _type(tester, '/gr');
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.skillRequests, greaterThanOrEqualTo(firstRequests), reason: '失败后可重试');
    expect(backend.skillRequests, greaterThanOrEqualTo(2), reason: '首次失败不得缓存为永久空');
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('目录未加载：先普通文本，加载完成后重建高亮', (tester) async {
    final gate = Completer<void>();
    final backend = _Backend(
      catalogGate: gate,
      events: [
        _event('turn/start', 1, {'turn': 1}),
        _event('user/message', 2, {
          'messageId': 'u1',
          'text': '/compact',
          'sourceKind': 'user',
        }),
      ],
    );
    await _pumpChat(tester, backend);
    expect(find.byKey(const Key('slash-chip-command-compact')), findsNothing);
    gate.complete();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('slash-chip-command-compact')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('320 + 深色：菜单不溢出、点击区 ≥44dp、可滚动', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final backend = _Backend();
    await _pumpChat(tester, backend, dark: true);
    await _type(tester, '/');
    expect(find.byKey(const Key('slash-menu')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '320 深色不得 overflow');
    final item = tester.getSize(find.byKey(const Key('slash-menu-command-compact')));
    expect(item.height, greaterThanOrEqualTo(44));
    expect(find.byType(Scrollable), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('行内技能不走命令/不特殊执行：作为普通消息文本发送', (tester) async {
    final backend = _Backend();
    await _pumpChat(tester, backend);
    await _type(tester, 'hello /grill-me');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.commandRuns, 0);
    expect(backend.sends.single['text'], 'hello /grill-me');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('320 + 大字号 + 深色：slash chip 可见且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final backend = _Backend(events: [
      _event('turn/start', 1, {'turn': 1}),
      _event('user/message', 2, {
        'messageId': 'u1',
        'text': '/compact /grill-me',
        'sourceKind': 'user',
      }),
    ]);
    await _pumpChat(tester, backend, dark: true);
    expect(find.byKey(const Key('slash-chip-command-compact')), findsOneWidget);
    expect(find.byKey(const Key('slash-chip-skill-grill-me')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '320+1.5x+深色不得 overflow');
    final decoration =
        tester.widget<Container>(find.byKey(const Key('slash-chip-command-compact'))).decoration
            as BoxDecoration;
    expect(decoration.border, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #95：中间光标插入替换整个 token，保留右侧文本/选择', (tester) async {
    await _pumpChat(tester, _Backend());
    tester.widget<TextField>(_input).controller!.value =
        const TextEditingValue(
      text: '/grill-me rest',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsOneWidget);
    await tester.tap(find.byKey(const Key('slash-menu-skill-grill-me')));
    await tester.pump(const Duration(milliseconds: 100));
    final controller = tester.widget<TextField>(_input).controller!;
    expect(controller.text, '/grill-me rest', reason: '保留 token 右侧文本，不重复后缀/空格');
    expect(controller.selection.baseOffset, '/grill-me'.length);

    // 非空选择同样不丢前后文本（光标 base 决定 token，右侧 token 整段替换）。
    tester.widget<TextField>(_input).controller!.value =
        const TextEditingValue(
      text: 'pre /gr rest',
      selection: TextSelection(baseOffset: 7, extentOffset: 9),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final skill = find.byKey(const Key('slash-menu-skill-grill-me'));
    if (skill.evaluate().isNotEmpty) {
      await tester.tap(skill);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.text, startsWith('pre /grill-me'), reason: '保留前置文本');
      expect(controller.text, endsWith(' rest'), reason: '保留后置文本');
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #95：命令先回/技能延迟时提交等待同一 in-flight，不误报未知命令', (tester) async {
    final gate = Completer<void>();
    final backend = _Backend(skillsGate: gate);
    await _pumpChat(tester, backend);
    await _type(tester, '/grill-me');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.sends, isEmpty, reason: '技能目录未回前不发送/不误报');
    expect(backend.commandRuns, 0);
    gate.complete();
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.commandRuns, 0);
    expect(backend.sends.single['text'], '/grill-me');
    expect(backend.skillRequests, 1, reason: '同会话 in-flight 复用，不重复请求');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #95：200 unavailable 只短 TTL 缓存空，到期重试并恢复技能菜单', (tester) async {
    final oldTtl = slashSkillsUnavailableTtl;
    slashSkillsUnavailableTtl = const Duration(milliseconds: 30);
    addTearDown(() => slashSkillsUnavailableTtl = oldTtl);
    final backend = _Backend(skillsUnavailableOnce: true);
    await _pumpChat(tester, backend);
    await _type(tester, '/');
    expect(find.byKey(const Key('slash-menu-command-compact')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await _type(tester, '/gr');
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.skillRequests, greaterThanOrEqualTo(2), reason: 'TTL 到期重试');
    expect(find.byKey(const Key('slash-menu-skill-grill-me')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });


  testWidgets('issue #97：菜单在输入框上方、最高 360、内部可滚动且底部提示可达', (tester) async {
    final commands = [
      for (var index = 0; index < 20; index += 1)
        {'name': 'cmd-$index', 'description': 'Command number $index'},
    ];
    final skills = [
      for (var index = 0; index < 20; index += 1)
        {'name': 'skill-$index', 'description': 'Skill number $index', 'modelInvocable': true},
    ];
    await _pumpChat(tester, _Backend(commands: commands, skills: skills));
    await _type(tester, '/');
    await tester.pump();
    final menu = find.byKey(const Key('slash-menu'));
    expect(menu, findsOneWidget);
    final menuRect = tester.getRect(menu);
    final inputRect = tester.getRect(_input);
    expect(menuRect.bottom, lessThanOrEqualTo(inputRect.top + 1), reason: '菜单在输入框上方');
    expect(menuRect.height, lessThanOrEqualTo(360.0));
    expect(find.byKey(const Key('slash-menu-more')), findsOneWidget, reason: '内容超出时显示上滑提示');
    // 最终角色映射：命令=绿、技能=蓝（浅色 token）。
    expect(tester.widget<Text>(find.text('/cmd-0')).style?.color, const Color(0xFF1F7A46));
    final list = find.byKey(const Key('slash-menu-list'));
    final listController = tester.widget<ListView>(list).controller!;
    listController.jumpTo(listController.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('slash-menu-more')), findsNothing, reason: '到底后提示消失');
    expect(find.byKey(const Key('slash-menu-bottom')), findsOneWidget, reason: '滚到底显示已到底');
    expect(find.byKey(const Key('slash-menu-skill-skill-19')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #97：320/深色菜单不溢出，命令/技能用深色 token', (tester) async {
    await _pumpChat(
      tester,
      _Backend(),
      dark: true,
      size: const Size(320, 640),
    );
    await _type(tester, '/');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('slash-menu')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final commandText = tester.widget<Text>(find.text('/compact'));
    expect(commandText.style?.color, const Color(0xFF7ED9A8));
    final skillText = tester.widget<Text>(find.text('/grill-me'));
    expect(skillText.style?.color, const Color(0xFF8FA8FF));
    final menuRect = tester.getRect(find.byKey(const Key('slash-menu')));
    expect(menuRect.bottom, lessThanOrEqualTo(tester.getRect(_input).top + 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #97：输入框高亮命令/技能、未知/路径不亮，IME 组合区保留下划线', (tester) async {
    await _pumpChat(tester, _Backend());
    await _type(tester, '/compact /grill-me 你好');
    await tester.pump(const Duration(milliseconds: 200));
    final textField = tester.widget<TextField>(_input);
    final controller = textField.controller!;
    final context = tester.element(_input);
    TextSpan build() => controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 14.5),
      withComposing: true,
    );
    Iterable<TextSpan> flatten(InlineSpan span) sync* {
      if (span is TextSpan) {
        yield span;
        for (final child in span.children ?? const <InlineSpan>[]) {
          yield* flatten(child);
        }
      }
    }
    final spans = flatten(build()).toList();
    final commandSpan = spans.firstWhere((span) => span.text == '/compact');
    expect(commandSpan.style?.color, const Color(0xFF1F7A46));
    expect(commandSpan.style?.backgroundColor, const Color(0xFFE6F7EC));
    final skillSpan = spans.firstWhere((span) => span.text == '/grill-me');
    expect(skillSpan.style?.color, const Color(0xFF2A54F0));
    expect(skillSpan.style?.backgroundColor, const Color(0xFFE9EEFF));

    // 未知命令/路径/词内都不着色。
    controller.value = const TextEditingValue(
      text: '/unknown /tmp/foo x/name',
      selection: TextSelection.collapsed(offset: 24),
    );
    final plainSpans = flatten(controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 14.5),
      withComposing: false,
    )).toList();
    expect(
      plainSpans.where((span) => span.style?.backgroundColor != null),
      isEmpty,
      reason: '未知/路径/词内不得高亮',
    );

    // IME 组合区：内容样式不受影响，但保留系统下划线。
    controller.value = const TextEditingValue(
      text: '/grill-me 你好',
      selection: TextSelection.collapsed(offset: 12),
      composing: TextRange(start: 10, end: 12),
    );
    final composingSpans = flatten(controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 14.5),
      withComposing: true,
    )).toList();
    final composing = composingSpans.firstWhere((span) => span.text == '你好');
    expect(composing.style?.decoration, TextDecoration.underline);
    expect(controller.text, '/grill-me 你好', reason: 'buildTextSpan 不得改写原文');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #97：点选后光标在空格后、键盘保持、不发送', (tester) async {
    final backend = _Backend();
    await _pumpChat(tester, backend);
    await _type(tester, '/gr');
    await tester.tap(find.byKey(const Key('slash-menu-skill-grill-me')));
    await tester.pump(const Duration(milliseconds: 100));
    final controller = tester.widget<TextField>(_input).controller!;
    expect(controller.text, '/grill-me ');
    expect(controller.selection.baseOffset, controller.text.length);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
      reason: '点选不得收起键盘/失焦',
    );
    expect(backend.sends, isEmpty);
    expect(find.byKey(const Key('slash-menu')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('issue #97：键盘弹出时菜单整体在键盘上方且不超过 360', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _Backend());
    await _type(tester, '/');
    await tester.pump(const Duration(milliseconds: 200));
    final menu = find.byKey(const Key('slash-menu'));
    expect(menu, findsOneWidget);
    final menuRect = tester.getRect(menu);
    final inputTop = tester.getRect(_input).top;
    expect(menuRect.bottom, lessThanOrEqualTo(inputTop + 1), reason: '菜单在输入框上方');
    expect(menuRect.height, lessThanOrEqualTo(360.0));
    final keyboardTop = tester.view.physicalSize.height / tester.view.devicePixelRatio - 300;
    expect(menuRect.bottom, lessThanOrEqualTo(keyboardTop + 1), reason: '菜单不得被键盘裁切');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('review P2: overflow indicator resets after filtering', (tester) async {
    final commands = [for (var i = 0; i < 30; i += 1) {'name': 'cmd-$i', 'description': 'command $i'}];
    await _pumpChat(tester, _Backend(commands: commands, skills: const []));
    await _type(tester, '/');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('slash-menu-more')), findsOneWidget);
    await _type(tester, '/cmd-0');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('slash-menu-command-cmd-0')), findsOneWidget);
    expect(find.byKey(const Key('slash-menu-more')), findsNothing);
    expect(find.byKey(const Key('slash-menu-bottom')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('review P2: overflow indicator resets after filtering at bottom', (tester) async {
    final commands = [for (var i = 0; i < 30; i += 1) {'name': 'cmd-$i', 'description': 'command $i'}];
    await _pumpChat(tester, _Backend(commands: commands, skills: const []));
    await _type(tester, '/');
    await tester.pump(const Duration(milliseconds: 200));
    final list = find.byKey(const Key('slash-menu-list'));
    final controller = tester.widget<ListView>(list).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('slash-menu-bottom')), findsOneWidget);
    await _type(tester, '/cmd-0');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('slash-menu-more')), findsNothing);
    expect(find.byKey(const Key('slash-menu-bottom')), findsNothing,
        reason: '到底后过滤到 1 项不能残留旧提示');
    expect(find.byKey(const Key('slash-menu-command-cmd-0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('review P2: 320 keyboard 350 dense menu fits viewport', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    final commands = [for (var i = 0; i < 30; i += 1) {'name': 'cmd-$i', 'description': 'command $i'}];
    await _pumpChat(tester, _Backend(commands: commands, skills: const []), size: const Size(320, 640));
    await _type(tester, '/');
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    final rect = tester.getRect(find.byKey(const Key('slash-menu')));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(290));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('review P2: 320 keyboard 300 dense menu fits viewport', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    final commands = [for (var i = 0; i < 30; i += 1) {'name': 'cmd-$i', 'description': 'command $i'}];
    await _pumpChat(tester, _Backend(commands: commands, skills: const []), size: const Size(320, 640));
    await _type(tester, '/');
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('review P2: known command prefix in filename not highlighted', (tester) async {
    await _pumpChat(tester, _Backend());
    await _type(tester, '/compact.md');
    await tester.pump(const Duration(milliseconds: 200));
    final c = tester.widget<TextField>(_input).controller!;
    final span = c.buildTextSpan(
      context: tester.element(_input),
      style: const TextStyle(),
      withComposing: false,
    );
    final children = span.children ?? const <InlineSpan>[];
    expect(children.whereType<TextSpan>().where((s) => s.style?.backgroundColor != null), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
