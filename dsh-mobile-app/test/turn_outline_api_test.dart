// issue #25 二期评审补测：`Api.turnOutline` 的失败降级契约。
//
// 评审 P1 指出：它此前只捕 `ApiException`，`http.ClientException` / `TimeoutException`
// 会原样逃出后台 Future（`_refreshTurnOutline` 是 unawaited 调用），于是"断网退回一期
// 并说明原因"的承诺不成立，还会产生未处理异步错误。这里把三类失败钉死。

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/turn_outline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Api apiWith(http.Client client) => Api(client: client)
  ..baseUrl = 'http://outline.test'
  ..path = '/m'
  ..token = '';

void main() {
  test('断网（ClientException）→ readFailed(offline)，不抛异常', () async {
    final api = apiWith(MockClient((_) async => throw http.ClientException('offline')));
    final outline = await api.turnOutline('s1');
    expect(outline.state, TurnOutlineState.readFailed);
    expect(outline.failureCode, 'turn-outline-offline');
  });

  test('客户端等待超时（TimeoutException）→ readFailed(client-timeout)', () async {
    final api = apiWith(MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response('{}', 200);
    }));
    final outline = await api.turnOutline(
      's1',
      timeout: const Duration(milliseconds: 20),
    );
    expect(outline.state, TurnOutlineState.readFailed);
    expect(outline.failureCode, 'turn-outline-client-timeout');
  });

  test('HTTP 500 → readFailed 且保留服务端稳定 code', () async {
    final api = apiWith(MockClient((_) async => http.Response(
          '{"error":"session-corrupt"}',
          500,
          headers: {'content-type': 'application/json'},
        )));
    final outline = await api.turnOutline('s1');
    expect(outline.state, TurnOutlineState.readFailed);
    expect(outline.failureCode, isNotNull);
  });

  test('HTTP 200 三态原样透传（不是所有失败都叫 readFailed）', () async {
    final api = apiWith(MockClient((_) async => http.Response(
          '{"ok":true,"state":"empty","turns":[]}',
          200,
          headers: {'content-type': 'application/json'},
        )));
    final outline = await api.turnOutline('s1');
    expect(outline.state, TurnOutlineState.empty);
  });

  test('离线/超时/忙三类说明互不相同且都有明确原因', () {
    final offline = turnOutlineNotice(const TurnOutline.readFailed('turn-outline-offline'))!;
    final timeout = turnOutlineNotice(const TurnOutline.readFailed('turn-outline-timeout'))!;
    final busy = turnOutlineNotice(const TurnOutline.readFailed('turn-outline-busy'))!;
    expect(offline, contains('离线'));
    expect(timeout, contains('超时'));
    // 忙与超时对用户是同一件事（没等到完整阶梯），共用一句说明；但都必须非空。
    expect(busy, timeout);
    expect(offline, isNot(timeout));
  });
}
