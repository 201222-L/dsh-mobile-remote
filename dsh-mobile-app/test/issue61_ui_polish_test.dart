// issue #61（alpha.7 真机截图反馈）：轮次过程 UI 收尾的 App 侧覆盖。
//
// 1) 展开态摘要去重：折叠态只有一行摘要；展开态无摘要、有组抬头/过程行，
//    末尾「收起过程」可点；强制展开（运行中/异常结束）无收起控件。
// 2) 协议生命周期事件（job/*、session/jobs、question/*、approval/*）归调试可见：
//    普通模式不渲染裸卡、调试模式可见；问询弹卡不依赖这些历史事件卡。
// 3) 工具名兜底：只有 result（无 call）时从 session 映射补名；彻底缺名显示
//    「工具调用」+ 可读摘要；调试模式保留原始 callId/类型。
// 4) 组抬头运行态只信真实状态：工具全部 settled 不再显示「正在调用工具…」，
//    有未回结果工具才显示，turn/end 后一律不显示。

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
  _Backend({this.events = const []});

  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue61.test'
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
      body = request.url.queryParameters.containsKey('after')
          ? {'ok': true, 'events': <Object>[], 'hasMore': false}
          : {'ok': true, 'events': events, 'hasMore': false};
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

const _sessionId = 'session-61';

List<Map<String, dynamic>> _oneTurn({
  String endKind = 'completed',
}) => [
  {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
  {
    'seq': 2,
    'type': 'user/message',
    'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
  },
  {
    'seq': 3,
    'type': 'tool/call',
    'data': {
      'turn': 1,
      'step': 1,
      'callId': 'call-1',
      'name': 'shell',
      'arguments': '{"command":"ls"}',
    },
    'time': 1100,
  },
  {
    'seq': 4,
    'type': 'tool/result',
    'data': {
      'turn': 1,
      'step': 1,
      'callId': 'call-1',
      'name': 'shell',
      'text': 'ok',
    },
    'time': 1200,
  },
  {
    'seq': 5,
    'type': 'assistant/message',
    'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '最终回答 1'},
    'time': 1300,
  },
  {
    'seq': 6,
    'type': 'turn/end',
    'data': {
      'turn': 1,
      'reason': {'kind': endKind},
    },
    'time': 2000,
  },
];

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  TurnFoldTiming timing = TurnFoldTiming.afterAnswer,
  bool debug = false,
  String keySuffix = '',
}) async {
  final store = AppStore()
    ..sessionId = _sessionId
    ..sessions = [
      Session(id: _sessionId, title: 'S', cwd: null, createdAt: 1),
    ]
    ..stepDisplayMode = mode
    ..turnFoldTiming = timing
    ..timelineDebug = debug;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue61-chat-${mode.name}-$timing-$debug-$keySuffix'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

Map<String, dynamic> _questionFrame() => {
  'type': 'mobile/frame',
  'frame': {
    'type': 'question/requested',
    'rpcId': 'q-rpc-61',
    'sessionId': _sessionId,
    'questions': [
      {
        'id': 'q1',
        'question': '继续吗？',
        'options': <Object>[],
      },
    ],
  },
};

Map<String, dynamic> _questionResolvedFrame() => {
  'type': 'mobile/frame',
  'frame': {
    'type': 'question/resolved',
    'questionRpcId': 'q-rpc-61',
    'sessionId': _sessionId,
  },
};

void main() {
  group('1. 展开态摘要去重与收起控件', () {
    testWidgets('折叠态：只有一行摘要（展开入口），没有组抬头与收起控件', (tester) async {
      await _pumpChat(tester, _Backend(events: _oneTurn()));

      expect(find.textContaining('1 组 · 1 次工具调用'), findsOneWidget);
      expect(find.text('1 次工具调用'), findsNothing);
      expect(find.text('收起过程'), findsNothing);
    });

    testWidgets('展开态：摘要行消失，组抬头/过程行出现，末尾可「收起过程」', (tester) async {
      await _pumpChat(tester, _Backend(events: _oneTurn()));

      await tester.tap(find.textContaining('1 组 · 1 次工具调用'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 组 · 1 次工具调用'), findsNothing,
          reason: '展开后不得再显示整轮摘要行（层级重复）');
      expect(find.text('1 次工具调用'), findsOneWidget);
      expect(find.text('收起过程'), findsOneWidget);

      // 组抬头可展开 → 过程行（工具卡）出现。
      await tester.tap(find.text('1 次工具调用'));
      await tester.pumpAndSettle();
      expect(find.text('shell'), findsOneWidget);

      // 点末尾「收起过程」→ 回到折叠态的一行摘要。
      await tester.tap(find.text('收起过程'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 组 · 1 次工具调用'), findsOneWidget);
      expect(find.text('收起过程'), findsNothing);
      expect(find.text('1 次工具调用'), findsNothing);
    });

    testWidgets('强制展开（运行中）：无摘要行、无收起控件，过程直接可见', (tester) async {
      final events = _oneTurn()..removeWhere((e) => e['type'] == 'turn/end');
      await _pumpChat(tester, _Backend(events: events));

      expect(find.textContaining('组 · 1 次工具调用'), findsNothing);
      expect(find.text('收起过程'), findsNothing, reason: '强制展开不提供收起语义');
      expect(find.text('1 次工具调用'), findsOneWidget);
      expect(find.text('shell'), findsOneWidget);
    });

    testWidgets('强制展开（异常结束 error）：同样无摘要行与收起控件', (tester) async {
      await _pumpChat(tester, _Backend(events: _oneTurn(endKind: 'error')));

      expect(find.textContaining('组 · 1 次工具调用'), findsNothing);
      expect(find.text('收起过程'), findsNothing);
      expect(find.text('1 次工具调用'), findsOneWidget);
    });
  });

  group('2. 协议生命周期事件归调试可见', () {
    final protocolEvents = <Map<String, dynamic>>[
      {
        'seq': 1,
        'type': 'job/registered',
        'data': {'jobId': 'job-1', 'kind': 'shell'},
        'time': 1000,
      },
      {
        'seq': 2,
        'type': 'job/settled',
        'data': {'jobId': 'job-1', 'status': 'completed'},
        'time': 1100,
      },
      {
        'seq': 3,
        'type': 'session/jobs',
        'data': {
          'jobs': <Object>[],
        },
        'time': 1200,
      },
      {
        'seq': 4,
        'type': 'question/requested',
        'data': {'rpcId': 'q-1'},
        'time': 1300,
      },
      {
        'seq': 5,
        'type': 'question/resolved',
        'data': {'rpcId': 'q-1'},
        'time': 1400,
      },
      {
        'seq': 6,
        'type': 'approval/requested',
        'data': {'approvalId': 'ap-1'},
        'time': 1500,
      },
      {
        'seq': 7,
        'type': 'approval/resolved',
        'data': {'approvalId': 'ap-1'},
        'time': 1600,
      },
      {
        'seq': 8,
        'type': 'approval/asked',
        'data': {'approvalId': 'ap-2'},
        'time': 1700,
      },
      {
        'seq': 9,
        'type': 'approval/decided',
        'data': {'approvalId': 'ap-2'},
        'time': 1800,
      },
    ];

    testWidgets('普通模式：不渲染裸协议卡', (tester) async {
      await _pumpChat(tester, _Backend(events: protocolEvents));

      for (final title in [
        'job/registered',
        'job/settled',
        '后台任务状态',
        '等待回答',
        '问询已处理',
        '等待审批',
        '审批已处理',
      ]) {
        expect(find.text(title), findsNothing, reason: '普通模式不应出现裸协议卡：$title');
      }
    });

    testWidgets('调试模式：协议事件仍可审阅', (tester) async {
      await _pumpChat(tester, _Backend(events: protocolEvents), debug: true);

      expect(find.text('job/registered'), findsOneWidget);
      expect(find.text('job/settled'), findsOneWidget);
      expect(find.text('后台任务状态'), findsOneWidget);
      expect(find.text('等待回答'), findsOneWidget);
      expect(find.text('问询已处理'), findsOneWidget);
      // approval/requested 与 approval/asked 共用「等待审批」标题。
      expect(find.text('等待审批'), findsNWidgets(2));
      expect(find.text('审批已处理'), findsNWidgets(2));
    });

    testWidgets('问询弹卡不依赖历史事件卡：普通/调试模式都能出现与消失', (tester) async {
      for (final debug in [false, true]) {
        final store = await _pumpChat(
          tester,
          _Backend(),
          debug: debug,
          keySuffix: '$debug',
        );

        store.injectFrame(_questionFrame());
        await tester.pump();
        expect(
          find.text('继续吗？'),
          findsOneWidget,
          reason: 'debug=$debug：问询帧必须弹出待答卡片',
        );
        if (!debug) {
          // 调试模式允许同时看到裸协议事件卡；普通模式不得靠它承载待答能力。
          expect(
            find.text('等待回答'),
            findsNothing,
            reason: '普通模式的待答卡片不是历史事件卡渲染的',
          );
        }

        store.injectFrame(_questionResolvedFrame());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.text('继续吗？'),
          findsNothing,
          reason: 'debug=$debug：resolved 帧必须收起待答卡片',
        );
      }
    });
  });

  group('3. 工具名兜底', () {
    testWidgets('只有 tool/result（无 tool/call）：从 session 映射补名', (tester) async {
      final events = <Map<String, dynamic>>[
        {
          'seq': 1,
          'type': 'assistant/chunk',
          'data': {
            'callId': 'call-map',
            'toolCall': 'shell',
            'argumentsDelta': '{"command":"ls"}',
          },
          'time': 1000,
        },
        {
          'seq': 2,
          'type': 'tool/result',
          'data': {'callId': 'call-map', 'text': 'ok', 'turn': 1, 'step': 1},
          'time': 1100,
        },
      ];
      await _pumpChat(tester, _Backend(events: events));

      expect(find.text('shell'), findsOneWidget, reason: '结果事件缺 name 时用映射补名');
      expect(find.text('工具调用'), findsNothing);
    });

    testWidgets('彻底缺名：标题「工具调用」+ description 摘要（≤80 字）', (tester) async {
      final events = <Map<String, dynamic>>[
        {
          'seq': 1,
          'type': 'tool/call',
          'data': {
            'callId': 'call-unknown',
            'turn': 1,
            'step': 1,
            'arguments': '{"description":"检查构建状态"}',
          },
          'time': 1000,
        },
        {
          'seq': 2,
          'type': 'tool/result',
          'data': {
            'callId': 'call-unknown',
            'turn': 1,
            'step': 1,
            'text': 'ok',
          },
          'time': 1100,
        },
      ];
      await _pumpChat(tester, _Backend(events: events));

      expect(find.text('工具调用'), findsOneWidget);
      expect(find.text('工具'), findsNothing);
      expect(find.text('检查构建状态'), findsOneWidget, reason: '折叠行优先展示 description');
    });

    testWidgets('彻底缺名：无 description 时用结果首行作可读摘要', (tester) async {
      final events = <Map<String, dynamic>>[
        {
          'seq': 1,
          'type': 'tool/result',
          'data': {
            'callId': 'call-orphan',
            'turn': 1,
            'step': 1,
            'text': 'SUMMARY-FIRST-LINE\nsecond line',
          },
          'time': 1000,
        },
      ];
      await _pumpChat(tester, _Backend(events: events));

      expect(find.text('工具调用'), findsOneWidget);
      expect(find.text('SUMMARY-FIRST-LINE'), findsOneWidget);
    });

    testWidgets('调试模式：缺名卡仍保留原始 callId/类型', (tester) async {
      final events = <Map<String, dynamic>>[
        {
          'seq': 1,
          'type': 'tool/result',
          'data': {
            'callId': 'call-orphan',
            'turn': 1,
            'step': 1,
            'text': 'SUMMARY-FIRST-LINE',
          },
          'time': 1000,
        },
      ];
      await _pumpChat(tester, _Backend(events: events), debug: true);

      expect(find.text('工具调用'), findsOneWidget);
      expect(find.textContaining('callId: call-orphan'), findsOneWidget);
      expect(find.textContaining('tool/activity'), findsOneWidget);
    });
  });

  group('4. 组抬头「正在调用工具…」常驻修复', () {
    testWidgets('运行中轮次、工具已全部成功：组抬头是计数，不是 running', (tester) async {
      final events = _oneTurn()..removeWhere((e) => e['type'] == 'turn/end');
      await _pumpChat(tester, _Backend(events: events));

      expect(find.text('1 次工具调用'), findsOneWidget);
      expect(find.textContaining('正在调用工具…'), findsNothing,
          reason: '工具已 settled，不得再显示「正在调用工具…」');
    });

    testWidgets('运行中轮次、组内有未回结果工具：该组 running，其它组正常', (tester) async {
      final events = <Map<String, dynamic>>[
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
        },
        {
          'seq': 3,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-done',
            'name': 'shell',
            'arguments': '{"command":"ls"}',
          },
          'time': 1100,
        },
        {
          'seq': 4,
          'type': 'tool/result',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-done',
            'name': 'shell',
            'text': 'ok',
          },
          'time': 1200,
        },
        {
          'seq': 5,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 2,
            'callId': 'call-running',
            'name': 'read_file',
            'arguments': '{"path":"a.txt"}',
          },
          'time': 1300,
        },
      ];
      await _pumpChat(tester, _Backend(events: events));

      expect(find.text('正在调用工具…（read_file）'), findsOneWidget);
      expect(find.text('1 次工具调用'), findsOneWidget,
          reason: '已完成组仍显示计数');
    });

    testWidgets('工具结果到达（同一轮内）：抬头立即切回计数态', (tester) async {
      final events = <Map<String, dynamic>>[
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
        },
        {
          'seq': 3,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-1',
            'name': 'shell',
            'arguments': '{"command":"ls"}',
          },
          'time': 1100,
        },
        {
          'seq': 4,
          'type': 'tool/result',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-1',
            'name': 'shell',
            'text': 'ok',
          },
          'time': 1200,
        },
      ];
      await _pumpChat(tester, _Backend(events: events));

      expect(find.textContaining('正在调用工具…'), findsNothing);
      expect(find.text('1 次工具调用'), findsOneWidget);
    });

    testWidgets('turn/end 后（含工具无结果）：任何组都不再 running', (tester) async {
      final events = <Map<String, dynamic>>[
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
        },
        {
          'seq': 3,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-never-ended',
            'name': 'shell',
            'arguments': '{"command":"sleep 1"}',
          },
          'time': 1100,
        },
        {
          'seq': 4,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'aborted'},
          },
          'time': 2000,
        },
      ];
      await _pumpChat(tester, _Backend(events: events));

      // aborted 轮强制展开：组抬头直接可见，且必须为计数态。
      expect(find.text('1 次工具调用'), findsOneWidget);
      expect(find.textContaining('正在调用工具…'), findsNothing,
          reason: '轮次结束后不得再显示 running 抬头');
    });
  });
}
