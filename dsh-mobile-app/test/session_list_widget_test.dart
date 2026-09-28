// issue #14 / ADR 0013：会话列表页与首页「最近会话」的 widget 契约测试。
//
// Seam 选择（见 issue 的 Testing Decisions）：这是本次改动能触及的**最高层客户端 seam**——
// 用一个真实的假 HTTP 服务端喂受控的 /api/sessions 响应，构建真实页面，再投递真实的
// SSE 帧（agent/status、mobile/frame），断言渲染结果。纯内部实现（动画控制器数值、
// 私有方法是否被调用）一律不断言。
//
// prior art：issue12_injection_fold_test.dart（真实 HttpServer + 全局 api 单例）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/home_screen.dart';
import 'package:dsh_mobile_app/screens/sessions_screen.dart';
import 'package:dsh_mobile_app/session_list.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/session_indicator.dart';

late HttpServer _server;
List<Map<String, dynamic>> _sessionRows = const [];

/// 受控会话响应：形如插件 /m/api/sessions 的 {ok, sessions:[...]}。
Map<String, dynamic> _row({
  required String id,
  String? title,
  int createdAt = 1000,
  int? lastActivity,
  int? lastMessageAt,
  String? origin,
  String? parentSession,
  bool archived = false,
  String? cwd,
}) => {
  'id': id,
  'title': title ?? id,
  'createdAt': createdAt,
  if (lastActivity != null) 'lastActivity': lastActivity,
  'lastMessageAt': lastMessageAt,
  if (origin != null) 'origin': origin,
  if (parentSession != null) 'parentSession': parentSession,
  'archived': archived,
  if (cwd != null) 'cwd': cwd,
};

/// 真实 agent/status 帧（与插件 broadcast 的形状一致）。
Map<String, dynamic> _statusFrame(String sessionId, String status) => {
  'type': 'agent/status',
  'sessionId': sessionId,
  'agentId': 'agent-$sessionId',
  'status': status,
};

/// 真实 mobile/frame 的审批请求帧。
Map<String, dynamic> _approvalFrame(String sessionId, String approvalId) => {
  'type': 'mobile/frame',
  'frame': {
    'type': 'approval/requested',
    'rpcId': 'rpc-$approvalId',
    'approvalId': approvalId,
    'sessionId': sessionId,
    'toolName': 'bash',
  },
};

/// 真实 mobile/frame 的问询请求帧。
Map<String, dynamic> _questionFrame(String sessionId, String rpcId) => {
  'type': 'mobile/frame',
  'frame': {
    'type': 'question/requested',
    'rpcId': rpcId,
    'sessionId': sessionId,
    'questions': [
      {'id': 'q1', 'question': '继续吗？', 'options': <Object>[]},
    ],
  },
};

Future<void> _bootServer() async {
  _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _server.listen((req) {
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
}

void main() {
  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    await _bootServer();
  });

  tearDown(() async {
    await _server.close(force: true);
  });

  /// 构建真实会话列表页，等首屏数据落地，返回 store 以便投递真实帧。
  Future<AppStore> pumpSessions(WidgetTester tester) async {
    final store = AppStore();
    await store.loadPrefs();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionsScreen(store: store, onOpenSession: () {}),
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

  Future<AppStore> pumpHome(WidgetTester tester) async {
    final store = AppStore();
    await store.loadPrefs();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HomeScreen(store: store, onOpenSession: () {})),
        ),
      );
      await store.refreshSessions();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return store;
  }

  /// 当前列表里所有会话行的状态标识组件（按渲染顺序）。
  List<SessionIcon> rowIcons(WidgetTester tester) =>
      tester.widgetList<SessionIcon>(find.byType(SessionIcon)).toList();

  group('会话列表：状态标识', () {
    testWidgets('运行中会话显示旋转标识，空闲会话没有标识', (tester) async {
      _sessionRows = [_row(id: 'session-run'), _row(id: 'session-idle')];
      final store = await pumpSessions(tester);
      // 初始（都空闲）：无状态、无动画
      for (final icon in rowIcons(tester)) {
        expect(icon.state, SessionRowState.idle);
        expect(icon.animation, isNull);
      }

      // 投递真实 agent/status 帧：只有 session-run 在跑
      store.injectFrame(_statusFrame('session-run', 'running'));
      await tester.pump();

      final icons = rowIcons(tester);
      expect(icons.length, 2);
      expect(icons[0].state, SessionRowState.running);
      expect(icons[0].animation, isNotNull, reason: '运行中必须带旋转动画');
      expect(icons[1].state, SessionRowState.idle);
      expect(icons[1].animation, isNull, reason: '空闲行不得有动效');
    });

    testWidgets('会话结束后动效停止（idle 帧让标识消失）', (tester) async {
      _sessionRows = [_row(id: 'session-run')];
      final store = await pumpSessions(tester);
      store.injectFrame(_statusFrame('session-run', 'running'));
      await tester.pump();
      expect(rowIcons(tester)[0].state, SessionRowState.running);

      store.injectFrame(_statusFrame('session-run', 'idle'));
      await tester.pump();
      expect(rowIcons(tester)[0].state, SessionRowState.idle);
      expect(rowIcons(tester)[0].animation, isNull);
    });

    testWidgets('等待审批的会话是 waiting（静态、警示色），且优先于 running', (tester) async {
      _sessionRows = [_row(id: 'session-wait')];
      final store = await pumpSessions(tester);
      store.injectFrame(_statusFrame('session-wait', 'running'));
      store.injectFrame(_approvalFrame('session-wait', 'ap-1'));
      await tester.pump();

      final icon = rowIcons(tester)[0];
      expect(icon.state, SessionRowState.waiting, reason: '等待态优先于运行态');
      expect(icon.animation, isNull, reason: '等待态不旋转（它在等我，不是在干活）');
    });

    testWidgets('空闲但有待答问询 → waiting', (tester) async {
      _sessionRows = [_row(id: 'session-idle-wait')];
      final store = await pumpSessions(tester);
      store.injectFrame(_questionFrame('session-idle-wait', 'q-rpc-1'));
      await tester.pump();

      final icon = rowIcons(tester)[0];
      expect(icon.state, SessionRowState.waiting);
      expect(icon.animation, isNull);
    });

    testWidgets('运行判定：idle 但有 running 后台任务 → 视为运行中', (tester) async {
      _sessionRows = [_row(id: 'session-jobs')];
      final store = await pumpSessions(tester);
      store.jobsBySession['session-jobs'] = [
        {'id': 'job-1', 'status': 'running'},
      ];
      await tester.pump();

      expect(rowIcons(tester)[0].state, SessionRowState.running);
    });

    testWidgets('减弱动态效果下状态标识仍在（静态虚线，靠颜色区分）', (tester) async {
      // 系统「减弱动态效果」开关：走平台无障碍特性（MediaQuery 由此推导）
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      _sessionRows = [_row(id: 'session-run')];
      final store = await pumpSessions(tester);
      store.injectFrame(_statusFrame('session-run', 'running'));
      await tester.pump();

      final icon = rowIcons(tester)[0];
      // 状态语义不因关闭动画而丢失；只是不再旋转
      expect(icon.state, SessionRowState.running);
      expect(icon.animation, isNull, reason: '减弱动效下不得旋转');
    });

    testWidgets('bootstrap 全量快照把会话从 running 拉回 idle 时，标识随之消失', (tester) async {
      _sessionRows = [_row(id: 'session-run')];
      final store = await pumpSessions(tester);
      store.injectFrame(_statusFrame('session-run', 'running'));
      await tester.pump();
      expect(rowIcons(tester)[0].state, SessionRowState.running);

      // 全量快照里该会话的 agent 已消失（会话结束/agent 销毁）→ 必须回落 idle
      await tester.runAsync(() async {
        await store.refreshAll();
      });
      await tester.pump();
      expect(rowIcons(tester)[0].state, SessionRowState.idle);
      expect(rowIcons(tester)[0].animation, isNull);
    });

    testWidgets('已归档但仍在运行的会话同样显示状态', (tester) async {
      _sessionRows = [
        _row(id: 'archived-run', archived: true, lastMessageAt: 9000),
      ];
      final store = await pumpSessions(tester);
      await tester.tap(find.textContaining('已归档'));
      await tester.pump();
      store.injectFrame(_statusFrame('archived-run', 'running'));
      await tester.pump();

      expect(find.text('archived-run'), findsOneWidget);
      expect(rowIcons(tester)[0].state, SessionRowState.running);
    });
  });

  group('会话列表：隐藏子代理会话', () {
    testWidgets('子代理会话不出现，fork 出的会话正常显示', (tester) async {
      _sessionRows = [
        _row(id: 'my-main', lastMessageAt: 3000),
        _row(
          id: 'agent-sub',
          origin: 'subagent',
          parentSession: 'my-main',
          lastMessageAt: 9000,
        ),
        _row(id: 'my-fork', parentSession: 'my-main', lastMessageAt: 5000),
      ];
      await pumpSessions(tester);

      expect(find.text('my-main'), findsOneWidget);
      expect(find.text('my-fork'), findsOneWidget, reason: '用户 fork 的会话必须保留');
      expect(find.text('agent-sub'), findsNothing);
      expect(rowIcons(tester).length, 2, reason: '只有两条主会话进入渲染');
    });

    testWidgets('已归档视图同样隐藏子代理会话', (tester) async {
      _sessionRows = [
        _row(id: 'archived-main', archived: true),
        _row(id: 'archived-sub', archived: true, origin: 'subagent'),
      ];
      await pumpSessions(tester);
      await tester.tap(find.textContaining('已归档'));
      await tester.pump();

      expect(find.text('archived-main'), findsOneWidget);
      expect(find.text('archived-sub'), findsNothing);
    });

    testWidgets('计数与可见条数一致（不因隐藏子代理而让计数虚高）', (tester) async {
      _sessionRows = [
        _row(id: 'main-a'),
        _row(id: 'main-b'),
        _row(id: 'sub-a', origin: 'subagent'),
        _row(id: 'sub-b', origin: 'subagent'),
      ];
      final store = await pumpSessions(tester);

      expect(store.activeSessions.length, 2);
      expect(find.textContaining('活跃 2'), findsOneWidget);
      expect(rowIcons(tester).length, 2);
    });

    testWidgets('旧插件不返回 origin → 不过滤，全部显示且不报错', (tester) async {
      _sessionRows = [_row(id: 'legacy-a'), _row(id: 'legacy-b')];
      final store = await pumpSessions(tester);

      expect(store.activeSessions.length, 2);
      expect(find.text('legacy-a'), findsOneWidget);
      expect(find.text('legacy-b'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('首页「最近会话」同样隐藏子代理会话', (tester) async {
      _sessionRows = [
        _row(id: 'home-main'),
        _row(id: 'home-sub', origin: 'subagent'),
      ];
      await pumpHome(tester);

      expect(find.text('home-main'), findsOneWidget);
      expect(find.text('home-sub'), findsNothing);
    });

    testWidgets('首页与会话列表对同一份数据给出一致的顺序', (tester) async {
      _sessionRows = [
        _row(id: 'shared-old', lastMessageAt: 1000),
        _row(id: 'shared-new', lastMessageAt: 9000),
      ];
      final sessions = await pumpSessions(tester);
      expect(sessions.activeSessions.map((s) => s.id).toList(), [
        'shared-new',
        'shared-old',
      ]);

      final home = await pumpHome(tester);
      expect(home.activeSessions.map((s) => s.id).toList(), [
        'shared-new',
        'shared-old',
      ]);
    });
  });

  group('会话列表：按最新消息时间排序', () {
    testWidgets('按 lastMessageAt 倒序，显示时间与排序同源（不取陈旧的 lastActivity）', (tester) async {
      _sessionRows = [
        _row(id: 'older', lastMessageAt: 1000, lastActivity: 9999),
        _row(id: 'newer', lastMessageAt: 5000, lastActivity: 1000),
      ];
      final store = await pumpSessions(tester);

      expect(store.activeSessions.map((s) => s.id).toList(), ['newer', 'older']);
      // 行内时间取自 sortKey（与排序同源），不是 lastActivity
      expect(store.activeSessions.first.sortKey, 5000);
    });

    testWidgets('打开会话不改变顺序（打开不再写活跃时间）', (tester) async {
      _sessionRows = [
        _row(id: 'first', lastMessageAt: 9000),
        _row(id: 'second', lastMessageAt: 1000),
      ];
      final store = await pumpSessions(tester);
      expect(store.activeSessions.map((s) => s.id).toList(), ['first', 'second']);

      // 打开排在后面的会话，再返回列表
      await tester.runAsync(() async {
        await store.setSession('second');
      });
      await tester.pump();

      expect(
        store.activeSessions.map((s) => s.id).toList(),
        ['first', 'second'],
        reason: '只是打开查看不得改变列表顺序',
      );
    });

    testWidgets('旧插件无 lastMessageAt → 回退 lastActivity，且不提示降级', (tester) async {
      _sessionRows = [
        _row(id: 'a', lastActivity: 1000, createdAt: 1000),
        _row(id: 'b', lastActivity: 8000, createdAt: 1000),
      ];
      final store = await pumpSessions(tester);

      expect(store.activeSessions.map((s) => s.id).toList(), ['b', 'a']);
      expect(find.textContaining('降级'), findsNothing);
    });

    testWidgets('字段缺失 → 回退 createdAt，不报错不阻塞', (tester) async {
      _sessionRows = [
        _row(id: 'by-created', createdAt: 7000),
        _row(id: 'older-created', createdAt: 2000),
      ];
      final store = await pumpSessions(tester);

      expect(store.activeSessions.map((s) => s.id).toList(), [
        'by-created',
        'older-created',
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('时间相同的两个会话顺序稳定（以 id 为次级键）', (tester) async {
      _sessionRows = [
        _row(id: 'session-z', lastMessageAt: 4000),
        _row(id: 'session-a', lastMessageAt: 4000),
      ];
      final store = await pumpSessions(tester);

      expect(store.activeSessions.map((s) => s.id).toList(), [
        'session-a',
        'session-z',
      ]);
    });
  });
}
