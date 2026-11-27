// issue #86 P1-2：graph HTTP 超时必须晚于 30s 面板。
//
// 真实 `Api` + 延迟 MockClient：
// - 5/10 档沿用 `getJson` 默认 15s：16s 即失败（普通错误路径，无 30s 面板）；
// - 不限档显式传 35s：30s 面板先触发、35s 网络层才超时且迟到结果被 generation 丢弃；
// - 超时后「重试」新请求可正常成功，旧请求迟到完成不回写。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _main = GitBranch(
  name: 'refs/heads/main',
  displayName: 'main',
  oid: 'oid-0',
  kind: 'local',
  current: true,
);

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// graph 请求次数 → 延迟/响应（默认返回成功）。
class _DelayedGitServer {
  _DelayedGitServer({this.graphDelay = Duration.zero});

  Duration graphDelay;
  int graphAttempts = 0;
  final List<Duration> delays = [];
  final List<(String method, Map<String, dynamic> body)> graphRequests = [];

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue86-timeout.test'
    ..path = '/m'
    ..token = '';

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/api/git/capabilities')) {
      return _json({
        'git': {
          'available': true,
          'graphTips': {'max': 128, 'getMax': 32},
        },
      });
    }
    if (path.endsWith('/api/git/repository')) {
      return _json({
        'repository': {
          'repositoryId': 'repo',
          'name': 'repo',
          'headOid': 'oid-0',
          'currentBranch': 'refs/heads/main',
        },
      });
    }
    if (path.endsWith('/api/git/branches')) {
      return _json({
        'branches': [
          {
            'name': 'refs/heads/main',
            'displayName': 'main',
            'oid': 'oid-0',
            'kind': 'local',
            'current': true,
          },
          {
            'name': 'refs/heads/b1',
            'displayName': 'b1',
            'oid': 'oid-1',
            'kind': 'local',
          },
        ],
      });
    }
    if (path.endsWith('/api/git/graph')) {
      graphAttempts += 1;
      if (request.method == 'POST') {
        try {
          graphRequests.add((
            request.method,
            jsonDecode(request.body) as Map<String, dynamic>,
          ));
        } catch (_) {}
      } else {
        graphRequests.add((request.method, const {}));
      }
      final delay = graphAttempts <= delays.length
          ? delays[graphAttempts - 1]
          : graphDelay;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return _json({
        'snapshotId': 'snap-$graphAttempts',
        'nextCursor': null,
        'commits': <Object>[],
        'tips': <Object>[],
      });
    }
    return _json({'ok': true});
  }
}

Future<GitBrowserController> _open(
  WidgetTester tester,
  _DelayedGitServer server, {
  GitGraphBranchLimit limit = GitGraphBranchLimit.five,
}) async {
  final controller = GitBrowserController(server.api, branchLimit: limit);
  unawaited(controller.open('session-a'));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  expect(controller.state.loading, isFalse);
  return controller;
}

void main() {
  testWidgets('5 档：graph 走默认 15s，16s 即普通失败（无 30s 面板）', (tester) async {
    final server = _DelayedGitServer(graphDelay: const Duration(seconds: 20));
    final controller = await _open(tester, server);
    addTearDown(controller.dispose);

    unawaited(controller.openBranch(_main));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.state.loadingGraph, isTrue);

    await tester.pump(const Duration(seconds: 16));
    expect(controller.state.loadingGraph, isFalse);
    expect(controller.state.graphTimedOut, isFalse, reason: '5/10 无 30s 超时面板');
    expect(controller.state.error, isNotNull);
    expect(controller.state.error, contains('TimeoutException'));

    // 放掉底层 20s 延迟请求，避免测试结束时残留 timer。
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('不限档：HTTP 用 35s → 30s 面板先触发；35s 超时迟到被丢弃', (tester) async {
    final server = _DelayedGitServer(graphDelay: const Duration(seconds: 40));
    final controller = await _open(
      tester,
      server,
      limit: GitGraphBranchLimit.unlimited,
    );
    addTearDown(controller.dispose);

    unawaited(controller.openBranch(_main));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.state.loadingGraph, isTrue);

    // 31s：controller 面板已超时（若 Api 仍 15s，这里会先变成普通错误）。
    await tester.pump(const Duration(seconds: 31));
    expect(controller.state.graphTimedOut, isTrue);
    expect(controller.state.loadingGraph, isFalse);
    expect(controller.state.error, isNull);

    // 35s 网络层超时（迟到）：generation 已作废，不得覆盖超时态。
    await tester.pump(const Duration(seconds: 5));
    expect(controller.state.graphTimedOut, isTrue);
    expect(controller.state.error, isNull);
    expect(controller.state.commits, isEmpty);

    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('超时后重试：新请求成功，旧请求迟到完成不回写', (tester) async {
    final server = _DelayedGitServer()
      ..delays.addAll([
        const Duration(seconds: 40), // 第一次：挂起被 30s 面板取消
        const Duration(milliseconds: 100), // 重试：正常成功
      ]);
    final controller = await _open(
      tester,
      server,
      limit: GitGraphBranchLimit.unlimited,
    );
    addTearDown(controller.dispose);

    unawaited(controller.openBranch(_main));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 31));
    expect(controller.state.graphTimedOut, isTrue);
    expect(server.graphAttempts, 1);

    unawaited(controller.retryGraphLoad());
    await tester.pump(const Duration(milliseconds: 300));
    expect(server.graphAttempts, 2);
    expect(controller.state.graphTimedOut, isFalse);
    expect(controller.state.error, isNull);
    expect(controller.state.snapshotId, 'snap-2');
    expect(controller.state.loadingGraph, isFalse);

    // 第一次请求在 40s 完成：旧 generation 不得覆盖快照。
    await tester.pump(const Duration(seconds: 10));
    expect(controller.state.snapshotId, 'snap-2');
    expect(controller.state.error, isNull);
  });
  testWidgets('真实 Api.graphPost：POST JSON body（不传路径）、GET 仍走 query', (tester) async {
    final server = _DelayedGitServer();
    final page = await server.api.graphPost(
      'session-a',
      'repo',
      const [
        GitGraphTip(
          name: 'refs/heads/main',
          tipOid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        GitGraphTip(
          name: 'refs/heads/topic',
          tipOid: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ],
      limit: 64,
    );
    expect(page.snapshotId, startsWith('snap-'));
    final recorded = server.graphRequests.last;
    expect(recorded.$1, 'POST');
    expect(recorded.$2['sessionId'], 'session-a');
    expect(recorded.$2['repositoryId'], 'repo');
    expect(recorded.$2['limit'], 64);
    expect(recorded.$2['tips'], [
      {
        'name': 'refs/heads/main',
        'tipOid': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
      {
        'name': 'refs/heads/topic',
        'tipOid': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
    ]);
    expect(recorded.$2.containsKey('path'), isFalse, reason: 'POST 不传路径');

    await server.api.graph(
      'session-a',
      'repo',
      const [
        GitGraphTip(
          name: 'refs/heads/main',
          tipOid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ],
      limit: 1,
    );
    expect(server.graphRequests.last.$1, 'GET');
    await tester.pump();
  });
}
