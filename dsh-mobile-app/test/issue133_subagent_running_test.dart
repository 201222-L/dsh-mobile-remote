// #124 / 实现跟踪 #133：主会话列表聚合递归子代理的运行指示。
//
// 需求：
//   - 根 agent idle、但任一（递归）子代理 running 时，主会话行显示现有旋转虚线；
//   - 子代理全部结束后指示消失；SSE agent/status 到达即时更新；
//   - 刷新列表 / 首页与列表页切换均保持正确；
//   - 子代理会话本身不进入列表；普通/归档/历史会话不误显示；
//   - 320 / 深色 / 1.5× 字号可见且不溢出；Semantics 含「运行中」。
//
// 数据源（不新增逐会话请求）：/api/sessions 已下发子代理会话的
// origin=subagent + parentSession；SSE agent/status 已按 sessionId 维护每会话状态。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue133_subagent_running_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/home_screen.dart';
import 'package:dsh_mobile_app/screens/sessions_screen.dart';
import 'package:dsh_mobile_app/session_list.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
import 'package:dsh_mobile_app/widgets/session_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late HttpServer _server;
List<Map<String, dynamic>> _sessionRows = const [];
late HttpServer _serverB;
List<Map<String, dynamic>> _sessionRowsB = const [];
Completer<void>? _sessionsGateB;

Map<String, dynamic> _row({
  required String id,
  String? title,
  int createdAt = 1000,
  int? lastMessageAt,
  String? origin,
  String? parentSession,
  bool archived = false,
  int? subagentsRunning,
}) => {
  'id': id,
  'title': title ?? id,
  'createdAt': createdAt,
  'lastMessageAt': lastMessageAt ?? createdAt,
  'origin': ?origin,
  'parentSession': ?parentSession,
  'archived': archived,
  'subagentsRunning': ?subagentsRunning,
};

Map<String, dynamic> _statusFrame(String sessionId, String status) => {
  'type': 'agent/status',
  'sessionId': sessionId,
  'agentId': 'agent-$sessionId',
  'status': status,
};

/// 新宿主 SSE 帧：rootSessionId + 递归 running 子代理数（0 也发）。
Map<String, dynamic> _rootStatusFrame({
  required String sessionId,
  required String rootSessionId,
  required int subagentsRunning,
  String status = 'running',
}) => {
  'type': 'agent/status',
  'sessionId': sessionId,
  'agentId': 'agent-$sessionId',
  'status': status,
  'rootSessionId': rootSessionId,
  'subagentsRunning': subagentsRunning,
};

Map<String, dynamic> _approvalFrame(String sessionId) => {
  'type': 'mobile/frame',
  'frame': {
    'type': 'approval/requested',
    'rpcId': 'rpc-1',
    'approvalId': 'ap-1',
    'sessionId': sessionId,
    'toolName': 'bash',
  },
};

Completer<void>? _sessionsGate;

/// 主会话 + 直接/递归子代理的典型树（子代理会话列表层不显示）。
List<Map<String, dynamic>> _treeRows() => [
  _row(id: 'main', createdAt: 3000),
  _row(id: 'child', createdAt: 2000, origin: 'subagent', parentSession: 'main'),
  _row(
    id: 'grandchild',
    createdAt: 1000,
    origin: 'subagent',
    parentSession: 'child',
  ),
  _row(id: 'other', createdAt: 500),
];

Future<void> _bootServer() async {
  _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _server.listen((req) async {
    if (req.uri.path == '/m/api/sessions' && _sessionsGate != null) {
      await _sessionsGate!.future;
    }
    final body = switch (req.uri.path) {
      '/m/api/sessions' => {'ok': true, 'sessions': _sessionRows},
      _ => {'ok': true},
    };
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  });
  api.baseUrl = 'http://127.0.0.1:${_server.port}';
  api.token = '';
  api.path = '/m';

  // 宿主 B：同一挂载路径/口令，仅地址不同（复现同 sessionId 换宿主）。
  _serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _serverB.listen((req) async {
    if (req.uri.path == '/m/api/sessions' && _sessionsGateB != null) {
      await _sessionsGateB!.future;
    }
    final body = switch (req.uri.path) {
      '/m/api/sessions' => {'ok': true, 'sessions': _sessionRowsB},
      _ => {'ok': true},
    };
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  });
}

Future<AppStore> _pumpSessions(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool dark = false,
  double textScale = 1.0,
}) async {
  final store = AppStore();
  await store.loadPrefs();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? DshTheme.forSkin(DshSkin.dsh, Brightness.dark) : null,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: SessionsScreen(
                store: store,
                onOpenSession: () {},
                visible: true,
              ),
            ),
          ),
        ),
      ),
    );
    await store.refreshSessions();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return store;
}

SessionIcon _iconOf(WidgetTester tester, String sessionId) =>
    tester.widget<SessionIcon>(
      find.descendant(
        of: find.byKey(ValueKey('session-row-$sessionId')),
        matching: find.byType(SessionIcon),
      ),
    );

void main() {
  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    await _bootServer();
  });

  tearDown(() async {
    await _server.close(force: true);
    await _serverB.close(force: true);
  });

  group('递归聚合纯函数', () {
    final sessions = [
      Session(id: 'main', createdAt: 3, title: 'main'),
      Session(
        id: 'child',
        createdAt: 2,
        origin: 'subagent',
        parentSession: 'main',
      ),
      Session(
        id: 'grandchild',
        createdAt: 1,
        origin: 'subagent',
        parentSession: 'child',
      ),
      // 用户 fork：只有 parentSession、没有 origin → 不得当子代理聚合。
      Session(id: 'fork', createdAt: 1, parentSession: 'main'),
    ];

    test('直接子代理 running → 主会话 running；全部 idle → false', () {
      expect(
        hasRunningSubagentDescendant(
          sessionId: 'main',
          sessions: sessions,
          agentStatusOf: (id) => id == 'child' ? 'running' : 'idle',
        ),
        isTrue,
      );
      expect(
        hasRunningSubagentDescendant(
          sessionId: 'main',
          sessions: sessions,
          agentStatusOf: (_) => 'idle',
        ),
        isFalse,
      );
    });

    test('孙代理 running（直接子级 idle）也计入；子自身 running 不影响其它根', () {
      expect(
        hasRunningSubagentDescendant(
          sessionId: 'main',
          sessions: sessions,
          agentStatusOf: (id) => id == 'grandchild' ? 'running' : 'idle',
        ),
        isTrue,
      );
      expect(
        hasRunningSubagentDescendant(
          sessionId: 'other',
          sessions: sessions,
          agentStatusOf: (id) => id == 'grandchild' ? 'running' : 'idle',
        ),
        isFalse,
      );
    });

    test('用户 fork（无 origin）不参与聚合；无环安全', () {
      expect(
        hasRunningSubagentDescendant(
          sessionId: 'main',
          sessions: sessions,
          agentStatusOf: (id) => id == 'fork' ? 'running' : 'idle',
        ),
        isFalse,
      );
      final cyclic = [
        Session(id: 'a', createdAt: 1, origin: 'subagent', parentSession: 'b'),
        Session(id: 'b', createdAt: 1, origin: 'subagent', parentSession: 'a'),
      ];
      expect(
        hasRunningSubagentDescendant(
          sessionId: 'a',
          sessions: cyclic,
          agentStatusOf: (_) => 'idle',
        ),
        isFalse,
      );
    });

    test('等待态优先于子代理运行态', () {
      expect(
        sessionRowState(
          agentStatus: 'idle',
          hasRunningJobs: false,
          hasRunningSubagents: true,
          hasPendingQuestion: true,
          hasPendingApproval: false,
        ),
        SessionRowState.waiting,
      );
      expect(
        sessionRowState(
          agentStatus: 'idle',
          hasRunningJobs: false,
          hasRunningSubagents: true,
          hasPendingQuestion: false,
          hasPendingApproval: false,
        ),
        SessionRowState.running,
      );
    });
  });

  test('列表/首页面板计数同口径：根 idle + 子代理 running 计 1', () {
    final sessions = [
      Session(id: 'main', createdAt: 3, title: 'main'),
      Session(
        id: 'child',
        createdAt: 2,
        origin: 'subagent',
        parentSession: 'main',
      ),
      Session(id: 'idle', createdAt: 1),
    ];
    final count = runningSessionCountOf(
      sessions.where((s) => !s.isSubagent),
      (id) => sessionRowState(
        agentStatus: 'idle',
        hasRunningJobs: false,
        hasRunningSubagents: hasRunningSubagentDescendant(
          sessionId: id,
          sessions: sessions,
          agentStatusOf: (sid) => sid == 'child' ? 'running' : 'idle',
        ),
        hasPendingQuestion: false,
        hasPendingApproval: false,
      ),
    );
    expect(count, 1, reason: '根 idle 但子代理运行的面板计数必须与行一致，不能是 0');
  });

  testWidgets('根 idle + 直接子代理 running：主会话行旋转，子代理行不出现；子结束即消失', (tester) async {
    _sessionRows = _treeRows();
    final store = await _pumpSessions(tester);

    expect(find.byKey(const ValueKey('session-row-child')), findsNothing);
    expect(find.byKey(const ValueKey('session-row-grandchild')), findsNothing);
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
    expect(_iconOf(tester, 'other').state, SessionRowState.idle);

    store.injectFrame(_statusFrame('child', 'running'));
    await tester.pump();
    final running = _iconOf(tester, 'main');
    expect(running.state, SessionRowState.running);
    expect(
      running.effectiveAnimation,
      isNotNull,
      reason: '必须复用现有旋转/脉冲动效，不能只是静态色点',
    );
    expect(_iconOf(tester, 'other').state, SessionRowState.idle);

    store.injectFrame(_statusFrame('child', 'idle'));
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
    expect(_iconOf(tester, 'main').effectiveAnimation, isNull);
  });

  testWidgets('递归层级：直接子级 idle、孙代理 running 时主会话仍显示运行中', (tester) async {
    _sessionRows = _treeRows();
    final store = await _pumpSessions(tester);

    store.injectFrame(_statusFrame('child', 'idle'));
    store.injectFrame(_statusFrame('grandchild', 'running'));
    await tester.pump();

    expect(_iconOf(tester, 'main').state, SessionRowState.running);
    expect(_iconOf(tester, 'main').effectiveAnimation, isNotNull);
  });

  testWidgets('刷新后新增子代理 + 状态帧：主会话立即更新；首页同样生效', (tester) async {
    _sessionRows = [_row(id: 'main', createdAt: 3000)];
    final store = await _pumpSessions(tester);
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);

    // 刷新：子代理会话出现在 /sessions（仍不显示行）。
    _sessionRows = [
      _row(id: 'main', createdAt: 3000),
      _row(
        id: 'child',
        createdAt: 2000,
        origin: 'subagent',
        parentSession: 'main',
      ),
    ];
    await tester.runAsync(() async {
      await store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    store.injectFrame(_statusFrame('child', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);
    expect(find.byKey(const ValueKey('session-row-child')), findsNothing);

    // 切到首页：同一行状态同样聚合子代理（切页不丢）。
    final handle = tester.ensureSemantics();
    await pumpHomeFor(tester, store);
    expect(_homeIconState(tester, 'main'), SessionRowState.running);
    handle.dispose();
  });

  testWidgets('归档/普通/历史会话不误显示：无运行子代理时保持 idle；归档视图仍走 ADR 0013', (tester) async {
    _sessionRows = [
      _row(id: 'normal', createdAt: 5000),
      _row(id: 'archived-main', createdAt: 4000, archived: true),
      _row(
        id: 'archived-child',
        createdAt: 3000,
        archived: true,
        origin: 'subagent',
        parentSession: 'archived-main',
      ),
      _row(
        id: 'normal-child',
        createdAt: 2000,
        origin: 'subagent',
        parentSession: 'normal',
      ),
    ];
    final store = await _pumpSessions(tester);
    // 活跃视图：普通会话 + 运行中子代理 → running；归档主会话不在活跃视图。
    expect(_iconOf(tester, 'normal').state, SessionRowState.idle);
    expect(
      find.byKey(const ValueKey('session-row-archived-main')),
      findsNothing,
    );
    store.injectFrame(_statusFrame('normal-child', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'normal').state, SessionRowState.running);
    expect(
      find.byKey(const ValueKey('session-row-normal-child')),
      findsNothing,
    );

    // 归档视图：子代理行仍隐藏；无运行子代理的归档会话保持 idle（不误显示）。
    store.injectFrame(_statusFrame('normal-child', 'idle'));
    await tester.tap(find.textContaining('已归档'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('session-row-archived-child')),
      findsNothing,
    );
    expect(
      _iconOf(tester, 'archived-main').state,
      SessionRowState.idle,
      reason: '没有运行中的子代理时，归档会话不得出现运行指示',
    );
    // ADR 0013：归档只是分类，不代表会话停了——归档主会话自身 running 仍显示。
    store.injectFrame(_statusFrame('archived-main', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'archived-main').state, SessionRowState.running);
  });

  testWidgets('服务端聚合提示：子代理会话不在列表时主会话仍显示运行中；刷新清除后消失', (tester) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 1),
      _row(id: 'other', createdAt: 2000),
    ];
    final store = await _pumpSessions(tester);
    expect(_iconOf(tester, 'main').state, SessionRowState.running);
    expect(_iconOf(tester, 'main').effectiveAnimation, isNotNull);
    expect(_iconOf(tester, 'other').state, SessionRowState.idle);

    // 子代理结束后服务端聚合提示清除：刷新列表 → 指示消失。
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 0),
      _row(id: 'other', createdAt: 2000, subagentsRunning: 0),
    ];
    await tester.runAsync(() async {
      await store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
  });

  testWidgets('SSE rootSessionId 帧：子代理行缺失也能显示；idle/disposed 合成帧立即清除', (
    tester,
  ) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 0),
      _row(id: 'other', createdAt: 2000),
    ];
    final store = await _pumpSessions(tester);
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);

    // 子代理会话被 includeEmpty 过滤（列表里看不到行），仍靠 SSE 根字段显示。
    store.injectFrame(
      _rootStatusFrame(
        sessionId: 'hidden-child',
        rootSessionId: 'main',
        subagentsRunning: 1,
      ),
    );
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);
    expect(_iconOf(tester, 'main').effectiveAnimation, isNotNull);

    // 子代理 idle → 根计数 0 → 指示消失（无需等 /sessions 刷新）。
    store.injectFrame(
      _rootStatusFrame(
        sessionId: 'hidden-child',
        rootSessionId: 'main',
        subagentsRunning: 0,
        status: 'idle',
      ),
    );
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);

    // agent/disposed 的合成 idle 帧（同形状）也不得复活指示。
    store.injectFrame(
      _rootStatusFrame(
        sessionId: 'hidden-child-2',
        rootSessionId: 'main',
        subagentsRunning: 0,
        status: 'idle',
      ),
    );
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
  });

  testWidgets('旧 /sessions 慢快照不覆盖请求期间到达的新 SSE 帧', (tester) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 0),
      _row(id: 'other', createdAt: 2000),
    ];
    final store = await _pumpSessions(tester);
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);

    _sessionsGate = Completer<void>();
    addTearDown(() => _sessionsGate = null);
    late Future<void> refreshFuture;
    await tester.runAsync(() async {
      refreshFuture = store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    // 请求在途时子代理开始运行：新帧先落地（根计数 1）。
    store.injectFrame(
      _rootStatusFrame(
        sessionId: 'late-child',
        rootSessionId: 'main',
        subagentsRunning: 1,
      ),
    );
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);

    // 旧快照返回（subagentsRunning=0）不得清掉新帧。
    await tester.runAsync(() async {
      _sessionsGate!.complete();
      await refreshFuture;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.running,
      reason: '慢快照比 SSE 帧旧，不得覆盖新帧',
    );
  });

  testWidgets('连接代切换：A 的 running 不带到 B；B 慢快照不覆盖新帧；切回 A 不继承', (tester) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 1),
      _row(id: 'other', createdAt: 2000),
    ];
    final store = await _pumpSessions(tester);
    expect(_iconOf(tester, 'main').state, SessionRowState.running);

    // 切到宿主 B（同 sessionId）：B 快照慢响应，先到一帧 agent/status 改变 epoch。
    api.baseUrl = 'http://127.0.0.1:${_serverB.port}';
    _sessionRowsB = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 0),
      _row(id: 'other', createdAt: 2000),
    ];
    _sessionsGateB = Completer<void>();
    addTearDown(() => _sessionsGateB = null);
    late Future<void> refreshFuture;
    await tester.runAsync(() async {
      refreshFuture = store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    // 连接代切换当下即失效旧快照字段：不得沿用 A 的 count=1。
    await tester.pump();
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.idle,
      reason: '切宿主后 A 的 subagentsRunning 必须立即失效',
    );
    store.injectFrame(_statusFrame('main', 'idle'));
    await tester.pump();

    // B 的旧快照返回（0）——不得把 A 的 count 带进来，也不得被新帧覆盖成 running。
    await tester.runAsync(() async {
      _sessionsGateB!.complete();
      await refreshFuture;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
    store.injectFrame(
      _rootStatusFrame(
        sessionId: 'child',
        rootSessionId: 'main',
        subagentsRunning: 0,
        status: 'idle',
      ),
    );
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);

    // 切回 A：B 的缓存/字段不得被继承（A 快照 idle 就保持 idle）。
    api.baseUrl = 'http://127.0.0.1:${_server.port}';
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 0),
      _row(id: 'other', createdAt: 2000),
    ];
    await tester.runAsync(() async {
      await store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地树 fallback 连接代隔离：同 sessionId 子会话跨宿主不继承 running', (
    tester,
  ) async {
    // 宿主 A：主会话 + 子代理会话（旧宿主 SSE 无 root 字段 → 走本地树聚合）。
    _sessionRows = [
      _row(id: 'main', createdAt: 3000),
      _row(
        id: 'child',
        createdAt: 2000,
        origin: 'subagent',
        parentSession: 'main',
      ),
    ];
    final store = await _pumpSessions(tester);
    store.injectFrame(_statusFrame('child', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);

    // 切到宿主 B（同 sessionId，子会话不出现）：慢快照在途时旧本地树状态必须失效。
    api.baseUrl = 'http://127.0.0.1:${_serverB.port}';
    _sessionRowsB = [_row(id: 'main', createdAt: 3000)];
    _sessionsGateB = Completer<void>();
    addTearDown(() => _sessionsGateB = null);
    late Future<void> refreshFuture;
    await tester.runAsync(() async {
      refreshFuture = store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.idle,
      reason: '旧连接代的子代理 agent 状态不得作为本地 fallback',
    );
    await tester.runAsync(() async {
      _sessionsGateB!.complete();
      await refreshFuture;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);

    // 切回 A：旧 running 不继承；新帧到达才重新显示。
    api.baseUrl = 'http://127.0.0.1:${_server.port}';
    _sessionRows = [
      _row(id: 'main', createdAt: 3000),
      _row(
        id: 'child',
        createdAt: 2000,
        origin: 'subagent',
        parentSession: 'main',
      ),
    ];
    await tester.runAsync(() async {
      await store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.idle);
    store.injectFrame(_statusFrame('child', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实断链：旧 count=1 → offline 后行立即 idle（connect 失败路径）', (
    tester,
  ) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000, subagentsRunning: 1),
      _row(id: 'other', createdAt: 2000),
    ];
    final store = await _pumpSessions(tester);
    expect(_iconOf(tester, 'main').state, SessionRowState.running);

    // 指向不可达端口并走真实 connect：onError → _scheduleReconnect → offline。
    api.baseUrl = 'http://127.0.0.1:1';
    await tester.runAsync(() async {
      store.connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    expect(store.connState, 'offline');
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.idle,
      reason: '断链后必须清掉旧连接代的子代理运行计数/快照/本地状态',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('当前会话是子代理：child running 后断链，主行 idle（屏蔽 legacy 全局状态）', (
    tester,
  ) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000),
      _row(
        id: 'child',
        createdAt: 2000,
        origin: 'subagent',
        parentSession: 'main',
      ),
    ];
    final store = await _pumpSessions(tester);
    store.sessionId = 'child'; // 当前打开的是子代理会话
    store.injectFrame(_statusFrame('child', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);

    api.baseUrl = 'http://127.0.0.1:1';
    await tester.runAsync(() async {
      store.connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    expect(store.connState, 'offline');
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.idle,
      reason: '当前 session 是子代理时，断链后不得回退 legacy 全局 agentStatus',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('根会话 running 在断链后保留（不误清）', (tester) async {
    _sessionRows = [_row(id: 'main', createdAt: 3000)];
    final store = await _pumpSessions(tester);
    store.sessionId = 'main';
    store.injectFrame(_statusFrame('main', 'running'));
    await tester.pump();
    expect(_iconOf(tester, 'main').state, SessionRowState.running);

    api.baseUrl = 'http://127.0.0.1:1';
    await tester.runAsync(() async {
      store.connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    expect(store.connState, 'offline');
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.running,
      reason: '根会话自己的 running 状态不得被子代理清理误删（发送/停止键语义）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('被列表过滤的 child：先收到 running → 断链 → 之后可见也不复活旧状态', (tester) async {
    _sessionRows = [_row(id: 'main', createdAt: 3000)];
    final store = await _pumpSessions(tester);
    store.injectFrame(_statusFrame('filtered-child', 'running'));
    await tester.pump();

    api.baseUrl = 'http://127.0.0.1:1';
    await tester.runAsync(() async {
      store.connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    expect(store.connState, 'offline');

    // 断链后 child 才出现在刷新列表（被过滤 → 可见），且没有新的状态帧。
    api.baseUrl = 'http://127.0.0.1:${_server.port}';
    _sessionRows = [
      _row(id: 'main', createdAt: 3000),
      _row(
        id: 'filtered-child',
        createdAt: 2000,
        origin: 'subagent',
        parentSession: 'main',
      ),
    ];
    await tester.runAsync(() async {
      await store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(
      _iconOf(tester, 'main').state,
      SessionRowState.idle,
      reason: '断链前记录但当时不可见的 child 状态也必须失效，不能在列表可见后复活',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('状态切换不改变行几何；running/waiting 的 Semantics 正确', (tester) async {
    _sessionRows = [
      _row(id: 'main', createdAt: 3000),
      _row(id: 'other', createdAt: 2000),
    ];
    final handle = tester.ensureSemantics();
    final store = await _pumpSessions(tester);
    final row = find.byKey(const ValueKey('session-row-main'));
    final heightBefore = tester.getSize(row).height;

    store.injectFrame(
      _rootStatusFrame(
        sessionId: 'hidden-child',
        rootSessionId: 'main',
        subagentsRunning: 1,
      ),
    );
    await tester.pump();
    expect(tester.getSize(row).height, heightBefore, reason: '运行指示不得改变行高');
    expect(find.bySemanticsLabel('运行中'), findsWidgets);

    // 等待态优先于运行态：静态虚线 + “等待你处理”，不旋转。
    store.injectFrame(_approvalFrame('main'));
    await tester.pump();
    final waiting = _iconOf(tester, 'main');
    expect(waiting.state, SessionRowState.waiting);
    expect(waiting.effectiveAnimation, isNull);
    expect(find.bySemanticsLabel('等待你处理'), findsWidgets);
    expect(tester.getSize(row).height, heightBefore);
    handle.dispose();
  });

  testWidgets('320dp + 深色 + 1.5×：指示可见、不溢出、Semantics 含「运行中」', (tester) async {
    _sessionRows = _treeRows();
    final handle = tester.ensureSemantics();
    final store = await _pumpSessions(
      tester,
      size: const Size(320, 640),
      dark: true,
      textScale: 1.5,
    );
    store.injectFrame(_statusFrame('child', 'running'));
    await tester.pump();

    final icon = _iconOf(tester, 'main');
    expect(icon.state, SessionRowState.running);
    final rect = tester.getRect(find.byKey(const ValueKey('session-row-main')));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
    expect(
      find.bySemanticsLabel('运行中'),
      findsWidgets,
      reason: '运行中必须有无障碍语义，不能只靠动画/颜色',
    );
    expect(tester.takeException(), isNull);
    final theme = Theme.of(tester.element(find.byType(SessionsScreen)));
    expect(theme.brightness, Brightness.dark);
    handle.dispose();
  });
}

/// 在同一 store 上切到首页（模拟 IndexedStack 切页）。
Future<void> pumpHomeFor(WidgetTester tester, AppStore store) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(store: store, onOpenSession: () {}),
        ),
      ),
    );
    await store.refreshSessions();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

SessionRowState _homeIconState(WidgetTester tester, String sessionId) {
  final icon = tester.widget<SessionIcon>(
    find.descendant(
      of: find.byKey(ValueKey('home-session-row-$sessionId')),
      matching: find.byType(SessionIcon),
    ),
  );
  return icon.state;
}
