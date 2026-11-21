// issue #128：移除聊天页「后台任务进行中」悬浮卡。
//
// 验收口径（GitLab #128）：
//   1. 正常模式聊天页不再出现内联卡（含单/多任务、运行中、停止中）；
//   2. 后台任务仍可在「会话工具 → 任务」查看并取消（能力不能丢失）；
//   3. 移除后消息区布局/滚动位置不跳变，正文不空白；
//   4. 调试模式仍可按原始 `session/jobs` 事件查看（不再占用对话区高度）；
//   5. 320dp / 深色 / 1.5x 不溢出。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue128_remove_job_card_test.dart

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

const _session = 'session-128';

// ── ChatScreen 假服务端（MockClient，不发真实网络） ──────────────────────
//
// issue #128 之后，聊天页打开的「会话工具」与页级动作共用同一个注入客户端，
// 因此任务页签的「取消」也能在 widget 测试里验证（见 `_openJobsSheet`）。
class _Backend {
  _Backend(this.history, {List<Map<String, dynamic>>? jobs})
    : jobs = jobs ?? <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> jobs;
  final List<Map<String, dynamic>> kills = [];

  /// 前 N 次 GET /api/jobs 返回 500（模拟首次加载失败，验证重试恢复）。
  int failJobsTimes = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue128.test'
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
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': history, 'hasMore': false};
    } else if (path == '/m/api/jobs' && request.method == 'GET') {
      if (failJobsTimes > 0) {
        failJobsTimes--;
        return http.Response(
          jsonEncode({'ok': false, 'error': 'jobs-unavailable'}),
          500,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      body = {'ok': true, 'jobs': jobs};
    } else if (path == '/m/api/jobs/kill' && request.method == 'POST') {
      final decoded = jsonDecode(request.body) as Map<String, dynamic>;
      kills.add(decoded);
      // 取消后服务端语义：running → stopping（停止中不可再点取消）。
      for (var i = 0; i < jobs.length; i++) {
        if (jobs[i]['id'] == decoded['jobId']) {
          jobs[i] = {...jobs[i], 'status': 'stopping'};
        }
      }
      body = {'ok': true};
    } else if (path == '/m/api/subagents') {
      body = {'ok': true, 'subagents': <Object>[]};
    } else if (path == '/m/api/todos') {
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

Map<String, dynamic> _job(String id, String status, {String? label}) => {
  'id': id,
  'label': label ?? '后台任务 $id',
  'status': status,
};

List<Map<String, dynamic>> _shortHistory() {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) => events.add({
    'seq': seq++,
    'type': type,
    'data': data,
    'time': 1000 + seq * 10,
  });
  add('turn/start', {'turn': 1});
  add('user/message', {
    'messageId': 'u1',
    'text': '开始任务',
    'sourceKind': 'user',
  });
  add('assistant/message', {
    'turn': 1,
    'step': 2,
    'messageId': 'a1',
    'text': '我正在核对。',
  });
  // 调试模式可审阅的原始后台任务事件（既有 debugOnly 口径）。
  add('session/jobs', {
    'sessionId': _session,
    'jobs': [
      {'id': 'j-history', 'label': '历史任务', 'status': 'running'},
    ],
  });
  return events;
}

List<Map<String, dynamic>> _longHistory() {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) => events.add({
    'seq': seq++,
    'type': type,
    'data': data,
    'time': 1000 + seq * 10,
  });
  for (var turn = 1; turn <= 30; turn++) {
    add('turn/start', {'turn': turn});
    add('user/message', {
      'messageId': 'u$turn',
      'text': '第 $turn 轮提问：请检查滚动位置是否稳定',
      'sourceKind': 'user',
    });
    add('assistant/message', {
      'turn': turn,
      'step': 2,
      'messageId': 'a$turn',
      'text': '第 $turn 轮回答：这是一段用于撑高消息区的正文。',
    });
    add('turn/end', {
      'turn': turn,
      'reason': {'kind': 'completed'},
    });
  }
  return events;
}

/// 只读测量层：几何直接取真实 ScrollPosition（与生产同一坐标）。
class _Probe {
  _Probe(this.tester);

  final WidgetTester tester;

  ScrollPosition get position => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable, skipOffstage: false),
            )
            .first,
      )
      .position;
}

Future<AppStore> _mount(
  WidgetTester tester, {
  _Backend? backend,
  Map<String, List<Map<String, dynamic>>> jobs = const {},
  bool debug = false,
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
  ThemeData? theme,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = WorkStepDisplayMode.expanded
    ..timelineDebug = debug;
  store.jobsBySession.addAll(jobs);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // 注入帧会起 800ms 的会话列表去抖 Timer：结束时先让它跑完，避免
  // "Timer is still pending" 掩盖真正的失败原因。
  addTearDown(() async {
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? DshTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: ChatScreen(
            key: ValueKey<String>('issue128-$debug-${size.width}'),
            store: store,
            apiClient: backend?.api ?? _Backend(_shortHistory()).api,
            onTitleChanged: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return store;
}

/// 从聊天页按真实入口打开「会话工具」任务页签：对话操作 → 任务 / 子代理 / 目标。
Future<void> _openJobsSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('对话操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('任务 / 子代理 / 目标'));
  await tester.pumpAndSettle();
  expect(find.text('会话工具'), findsOneWidget, reason: '会话工具面板应弹出');
}

/// 让注入产生的去抖 Timer 结束（无论断言是否失败都清理）。
Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('#128 普通模式：聊天页不再渲染内联卡', () {
    testWidgets('store 有运行中/停止中后台任务时也不出卡，正文照常', (tester) async {
      await _mount(
        tester,
        jobs: {
          _session: [
            _job('j1', 'running'),
            _job('j2', 'running'),
            _job('j3', 'stopping'),
          ],
        },
      );
      expect(find.textContaining('后台任务进行中'), findsNothing);
      expect(
        find.textContaining('个进行中'),
        findsNothing,
        reason: '任务面板的「N 进行中」若存在也不能是后台任务卡',
      );
      expect(
        find.textContaining('后台任务状态'),
        findsNothing,
        reason: '原始 session/jobs 事件只应在调试模式可见',
      );
      expect(
        find.byIcon(Icons.hourglass_top_outlined),
        findsNothing,
        reason: '内联卡的沙漏图标不应再出现',
      );
      expect(find.text('开始任务'), findsOneWidget);
      expect(find.textContaining('我正在核对。'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('注入多任务/运行中/停止中帧不报错、不跳变、不影响正文', (tester) async {
      final store = await _mount(tester);
      final probe = _Probe(tester);
      expect(probe.position.maxScrollExtent, greaterThanOrEqualTo(0));

      store.injectFrame({
        'type': 'session/jobs',
        'sessionId': _session,
        'jobs': [_job('j1', 'running'), _job('j2', 'running')],
      });
      await tester.pump();
      store.injectFrame({
        'type': 'session/jobs',
        'sessionId': _session,
        'jobs': [
          _job('j1', 'stopping'),
          _job('j2', 'running'),
          _job('j3', 'running'),
        ],
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        store.jobsOf(_session),
        hasLength(3),
        reason: 'store 仍须接收后台任务事件（会话列表/工具面板数据源）',
      );
      expect(
        store.hasRunningJobs(_session),
        isTrue,
        reason: '会话列表的运行指示仍依赖 running/stopping 任务',
      );
      expect(find.textContaining('后台任务进行中'), findsNothing);
      expect(find.textContaining('个进行中'), findsNothing);
      expect(find.text('开始任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('320dp / 深色 / 1.5x：有后台任务时仍不溢出、不出卡', (tester) async {
      await _mount(
        tester,
        jobs: {
          _session: [_job('j1', 'running'), _job('j2', 'stopping')],
        },
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(1.5),
        theme: DshTheme.dark(),
      );
      expect(find.textContaining('后台任务进行中'), findsNothing);
      expect(find.textContaining('个进行中'), findsNothing);
      expect(find.text('开始任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('session/jobs 帧不再改变布局：阅读位置保持不变', (tester) async {
      final store = await _mount(tester, backend: _Backend(_longHistory()));
      final probe = _Probe(tester);
      final position = probe.position;
      expect(
        position.maxScrollExtent,
        greaterThan(300),
        reason: '长会话必须可滚动，才能验证「不跳变」',
      );
      position.jumpTo(position.maxScrollExtent - 300);
      await tester.pump();
      final before = position.pixels;

      store.injectFrame({
        'type': 'session/jobs',
        'sessionId': _session,
        'jobs': [_job('j1', 'running')],
      });
      await tester.pump();
      store.injectFrame({
        'type': 'session/jobs',
        'sessionId': _session,
        'jobs': [_job('j1', 'stopping'), _job('j2', 'running')],
      });
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        (position.pixels - before).abs(),
        lessThanOrEqualTo(1.0),
        reason: '会话任务帧不再进入布局，不得移动滚动位置',
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('#128 调试模式：按原始事件查看，不恢复内联卡', () {
    testWidgets('调试模式可见「后台任务状态」事件卡，仍无内联卡', (tester) async {
      await _mount(tester, debug: true);
      expect(
        find.text('后台任务状态'),
        findsOneWidget,
        reason: '调试模式应保留原始 session/jobs 事件审阅能力',
      );
      expect(
        find.textContaining('后台任务进行中'),
        findsNothing,
        reason: '调试模式也不恢复占用对话区的内联卡',
      );
      expect(find.textContaining('个进行中'), findsNothing);
      await _finish(tester);
    });

    testWidgets('普通模式同一事件不可见（调试口径无泄漏）', (tester) async {
      await _mount(tester);
      expect(find.text('后台任务状态'), findsNothing);
      expect(find.textContaining('后台任务进行中'), findsNothing);
      await _finish(tester);
    });
  });

  group('#128 取消能力保留在「会话工具 → 任务」', () {
    testWidgets('从聊天页进入任务页签：多任务可见、运行中可取消、停止中无取消按钮', (tester) async {
      final backend = _Backend(
        _shortHistory(),
        jobs: [
          _job('j1', 'running', label: '后台任务 A'),
          _job('j2', 'running', label: '后台任务 B'),
          _job('j3', 'stopping', label: '后台任务 C'),
        ],
      );
      await _mount(tester, backend: backend);
      await _openJobsSheet(tester);

      expect(find.text('后台任务 A'), findsOneWidget);
      expect(find.text('后台任务 B'), findsOneWidget);
      expect(find.text('后台任务 C'), findsOneWidget);
      expect(
        find.text('取消'),
        findsNWidgets(2),
        reason: '仅 running 任务可取消；stopping 已在停止流程中',
      );
      expect(find.textContaining('stopping'), findsOneWidget);

      await tester.tap(find.text('取消').first);
      await tester.pumpAndSettle();
      expect(backend.kills, hasLength(1));
      expect(backend.kills.single['sessionId'], _session);
      expect(backend.kills.single['jobId'], 'j1');
      expect(
        find.text('取消'),
        findsOneWidget,
        reason: '取消后该任务转 stopping，刷新列表后不再显示取消按钮',
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('无后台任务时任务页签显示空态，不报错', (tester) async {
      final backend = _Backend(_shortHistory());
      await _mount(tester, backend: backend);
      await _openJobsSheet(tester);

      expect(find.text('暂无任务'), findsOneWidget);
      expect(find.textContaining('后台任务进行中'), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('首次加载失败 → 重试成功：任务可见且可取消（P2 回归）', (tester) async {
      final backend = _Backend(
        _shortHistory(),
        jobs: [_job('j1', 'running', label: '后台任务 A')],
      )..failJobsTimes = 1;
      await _mount(tester, backend: backend);
      await _openJobsSheet(tester);

      expect(find.textContaining('加载失败：'), findsOneWidget);
      expect(find.text('后台任务 A'), findsNothing);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('加载失败：'),
        findsNothing,
        reason: '重试开始必须清掉旧错误，否则成功后仍停在错误页',
      );
      expect(find.text('后台任务 A'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(backend.kills, hasLength(1));
      expect(backend.kills.single['jobId'], 'j1', reason: '恢复后取消入口必须真的可用');
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('切页再切回：任务页签仍可查看与取消（不丢失能力）', (tester) async {
      final backend = _Backend(
        _shortHistory(),
        jobs: [
          _job('j1', 'running', label: '后台任务 A'),
          _job('j2', 'running', label: '后台任务 B'),
        ],
      );
      await _mount(tester, backend: backend);
      await _openJobsSheet(tester);
      expect(find.text('后台任务 A'), findsOneWidget);

      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无子代理'), findsOneWidget);

      await tester.tap(find.byType(Tab).at(0));
      await tester.pumpAndSettle();
      expect(find.text('后台任务 A'), findsOneWidget);
      expect(find.text('取消'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });
}
