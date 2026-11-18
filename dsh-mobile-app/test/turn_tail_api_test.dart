// issue #53：App API 层契约测试（能力位 / turnTails / summary / diff / turn-file）。
//
// 服务端契约见 docs/03-api.md §6.20–§6.23；这里用 MockClient 固定请求形状与降级映射。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Api apiWith(MockClient client) => Api(client: client)
  ..baseUrl = 'http://tail.test'
  ..path = '/m'
  ..token = '';

http.Response jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  test('absorbBootstrap 解析 turnTail 能力位；旧插件缺省 → available=false', () {
    final api = apiWith(MockClient((_) async => jsonResponse({})));
    api.absorbBootstrap({
      'capabilities': {
        'turnTail': {
          'version': 1,
          'presented': true,
          'changed': true,
          'changesDiff': true,
        },
      },
    });
    expect(api.turnTailCapabilities.available, isTrue);
    expect(api.turnTailCapabilities.changed, isTrue);
    expect(api.turnTailCapabilities.changesDiff, isTrue);

    final legacy = apiWith(MockClient((_) async => jsonResponse({})));
    legacy.absorbBootstrap({
      'capabilities': {'eventTimeline': {'version': 1}},
    });
    expect(legacy.turnTailCapabilities.available, isFalse);
    expect(legacy.turnTailCapabilities.changed, isFalse);
  });

  test('historyPage 解析 turnTails 增量（旧插件仍返回空 map）', () async {
    final api = apiWith(MockClient((request) async {
      expect(request.url.path, '/m/api/history');
      return jsonResponse({
        'ok': true,
        'events': <Object>[],
        'hasMore': false,
        'turnTails': {
          '2': {'changes': true, 'presented': true},
          '3': {'changes': true, 'presented': false},
        },
      });
    }));
    final page = await api.historyPage('s1');
    expect(page.turnTails[2], const TurnTail(changes: true, presented: true));
    expect(page.turnTails[3]?.changes, isTrue);

    final legacy = apiWith(
      MockClient((_) async => jsonResponse({'ok': true, 'events': <Object>[]})),
    );
    expect((await legacy.historyPage('s1')).turnTails, isEmpty);
  });

  test('changesSummary 透传三态（200 不抛异常）', () async {
    final requests = <Uri>[];
    final api = apiWith(MockClient((request) async {
      requests.add(request.url);
      if (request.url.queryParameters['turn'] == '9') {
        return jsonResponse({'ok': true, 'state': 'absent', 'turn': 9, 'files': []});
      }
      return jsonResponse({
        'ok': true,
        'state': 'available',
        'turn': 2,
        'files': [
          {'seq': 7, 'index': 0, 'display': 'src/a.ts', 'name': 'a.ts', 'added': 2, 'deleted': 1},
        ],
        'total': 1,
        'added': 2,
        'deleted': 1,
        'truncated': false,
      });
    }));
    final available = await api.changesSummary('s1', 2);
    expect(available.state, ChangesState.available);
    expect(available.files.single.seq, 7);
    final absent = await api.changesSummary('s1', 9);
    expect(absent.state, ChangesState.absent);
    expect(requests.first.path, '/m/api/changes/summary');
    expect(requests.first.queryParameters['sessionId'], 's1');
  });

  test('changesDiff 解析统一 diff 文本；404 映射为 diff-not-found', () async {
    final api = apiWith(MockClient((request) async {
      if (request.url.queryParameters['index'] == '9') {
        return jsonResponse({'error': 'diff-not-found'}, 404);
      }
      return jsonResponse({
        'ok': true,
        'state': 'available',
        'diff': {
          'kind': 'text',
          'display': 'src/a.ts',
          'before': true,
          'after': true,
          'coarse': false,
          'diff': '--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,1 +1,1 @@\n-old\n+new\n',
          'truncated': false,
        },
      });
    }));
    final diff = await api.changesDiff('s1', 2, 0);
    expect(diff.isText, isTrue);
    expect(diff.display, 'src/a.ts');
    expect(diff.truncated, isFalse);
    expect(
      () => api.changesDiff('s1', 2, 9),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'diff-not-found')),
    );
  });

  test('turnFilePrefix 只发坐标参数；fileRangeSupported 时带 Range', () async {
    late http.Request captured;
    final api = apiWith(MockClient((request) async {
      captured = request;
      return http.Response.bytes(
        utf8.encode('ABCDEF'),
        206,
        headers: {
          'content-type': 'text/plain',
          'content-range': 'bytes 0-5/10',
        },
      );
    }))
      ..fileRangeSupported = true;
    final prefix = await api.turnFilePrefix(
      const TurnFileCoordinate(
        sessionId: 's1',
        kind: TurnFileKind.presented,
        seq: 3,
        index: 1,
      ),
      6,
    );
    expect(captured.url.path, '/m/api/turn-file');
    expect(captured.url.queryParameters, {
      'sessionId': 's1',
      'kind': 'presented',
      'seq': '3',
      'index': '1',
    });
    expect(captured.headers['range'], 'bytes=0-5');
    expect(utf8.decode(prefix.bytes), 'ABCDEF');
    expect(prefix.total, 10);

    // changed 坐标同样只给 kind=changed；旧插件不发 Range。
    late http.Request legacyReq;
    final legacy = apiWith(MockClient((request) async {
      legacyReq = request;
      return http.Response.bytes(utf8.encode('XY'), 200);
    }));
    await legacy.turnFilePrefix(
      const TurnFileCoordinate(
        sessionId: 's1',
        kind: TurnFileKind.changed,
        seq: 2,
        index: 0,
      ),
      2,
    );
    expect(legacyReq.url.queryParameters['kind'], 'changed');
    expect(legacyReq.headers.containsKey('range'), isFalse);
  });

  test('turnFileToFile 按坐标流式落盘（⋮ 打开/分享/保存的底座）', () async {
    final requests = <Uri>[];
    final downloadClient = MockClient((request) async {
      requests.add(request.url);
      return http.Response.bytes(
        utf8.encode('FILE-BYTES'),
        200,
        headers: {'content-type': 'text/plain'},
      );
    });
    final api = apiWith(downloadClient);
    final dir = await Directory.systemTemp.createTemp('turn-file-api-');
    final target = File('${dir.path}/out.bin');
    try {
      final result = await api.turnFileToFile(
        const TurnFileCoordinate(
          sessionId: 's1',
          kind: TurnFileKind.presented,
          seq: 5,
          index: 0,
        ),
        target,
        downloadClient: downloadClient,
      );
      expect(requests.single.path, '/m/api/turn-file');
      expect(await target.readAsString(), 'FILE-BYTES');
      expect(result.bytes, 10);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });
}
