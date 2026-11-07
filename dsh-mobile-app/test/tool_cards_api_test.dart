// issue #54：工具卡能力位解析（bootstrap 与 ChatEvent 摘要字段）。

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/tool_cards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Api _api() => Api(client: MockClient((_) async => http.Response('{}', 200)))
  ..baseUrl = 'http://tools.test'
  ..path = '/m'
  ..token = '';

void main() {
  test('bootstrap 解析 toolCards 能力位；旧插件缺省时 available=false', () {
    final api = _api();
    api.absorbBootstrap({
      'capabilities': {
        'toolCards': {
          'version': 1,
          'tools': ['bash', 'read', 'write'],
        },
      },
    });
    expect(api.toolCardsCapabilities.available, isTrue);
    expect(api.toolCardsCapabilities.supports('bash'), isTrue);
    expect(api.toolCardsCapabilities.supports('unknown'), isFalse);
    expect(api.toolCardsCapabilities.supports(null), isFalse);

    final legacy = _api();
    legacy.absorbBootstrap({'capabilities': {'eventTimeline': {'version': 1}}});
    expect(legacy.toolCardsCapabilities.available, isFalse);
    expect(legacy.toolCardsCapabilities.supports('bash'), isFalse);
  });

  test('ChatEvent 解析 tool/call 与 tool/result 的 summary（只增字段，缺省不失败）', () {
    final call = ChatEvent.fromJson({
      'seq': 1,
      'type': 'tool/call',
      'data': {
        'callId': 'c1',
        'name': 'bash',
        'summary': {'kind': 'command', 'tool': 'bash', 'command': 'ls'},
      },
    });
    expect(call.callSummary?.kind, ToolCardKind.command);
    expect(call.callSummary?.command, 'ls');
    expect(call.resultSummary, isNull);

    final result = ChatEvent.fromJson({
      'seq': 2,
      'type': 'tool/result',
      'data': {
        'callId': 'c1',
        'summary': {'exitCode': 2, 'resultCount': 3},
      },
    });
    expect(result.resultSummary?.exitCode, 2);
    expect(result.resultSummary?.resultCount, 3);

    // 旧插件/未知工具：summary 缺省或形状不符 → null，由通用卡兜底。
    final legacy = ChatEvent.fromJson({
      'seq': 3,
      'type': 'tool/call',
      'data': {'callId': 'c2', 'name': 'bash', 'arguments': '{}'},
    });
    expect(legacy.callSummary, isNull);
    final malformed = ChatEvent.fromJson({
      'seq': 4,
      'type': 'tool/call',
      'data': {
        'callId': 'c3',
        'name': 'bash',
        'summary': {'kind': 'mystery'},
      },
    });
    expect(malformed.callSummary, isNull);
  });
}
