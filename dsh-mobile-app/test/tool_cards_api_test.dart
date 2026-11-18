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

  // ── issue #66（M3 Batch 2-A）：能力位 13 工具 + 三种新 summary 解析 ─────────

  test('bootstrap 能力位含 Batch 2-A 三工具（共 13 项）', () {
    const allTools = [
      'bash',
      'pwsh',
      'read',
      'write',
      'edit',
      'grep',
      'glob',
      'web_fetch',
      'web_search',
      'read_image',
      'todo_write',
      'ask_user_question',
      'skill',
    ];
    final api = _api();
    api.absorbBootstrap({
      'capabilities': {
        'toolCards': {'version': 1, 'tools': allTools},
      },
    });
    expect(api.toolCardsCapabilities.available, isTrue);
    expect(api.toolCardsCapabilities.tools.length, 13);
    for (final tool in allTools) {
      expect(api.toolCardsCapabilities.supports(tool), isTrue, reason: tool);
    }
    // 旧插件只声明 Batch 1 的 10 个工具：新三工具明确不支持（回退通用卡）。
    final legacy = _api();
    legacy.absorbBootstrap({
      'capabilities': {
        'toolCards': {
          'version': 1,
          'tools': allTools.take(10).toList(),
        },
      },
    });
    expect(legacy.toolCardsCapabilities.supports('todo_write'), isFalse);
    expect(
      legacy.toolCardsCapabilities.supports('ask_user_question'),
      isFalse,
    );
    expect(legacy.toolCardsCapabilities.supports('skill'), isFalse);
    expect(legacy.toolCardsCapabilities.supports('bash'), isTrue);
  });

  test('ChatEvent 解析 todo/question/skill 的 tool/call summary 与 answers', () {
    final todo = ChatEvent.fromJson({
      'seq': 11,
      'type': 'tool/call',
      'data': {
        'callId': 'c-todo',
        'name': 'todo_write',
        'summary': {
          'kind': 'todo',
          'tool': 'todo_write',
          'items': [
            {'content': '写文档', 'status': 'completed'},
            {'content': '跑测试', 'status': 'in_progress'},
          ],
          'counts': {'pending': 0, 'inProgress': 1, 'completed': 1},
        },
      },
    });
    expect(todo.callSummary?.kind, ToolCardKind.todo);
    expect(todo.callSummary?.todoItems?.length, 2);
    expect(todo.callSummary?.todoInProgress, 1);
    expect(todo.callSummary?.todoCompleted, 1);
    expect(todo.callSummary?.renderable, isTrue);

    final question = ChatEvent.fromJson({
      'seq': 12,
      'type': 'tool/call',
      'data': {
        'callId': 'c-ask',
        'name': 'ask_user_question',
        'summary': {
          'kind': 'question',
          'tool': 'ask_user_question',
          'questions': [
            {
              'id': 'q1',
              'question': '要发布吗？',
              'options': [
                {'label': '发布', 'description': '立即发布'},
                {'label': '稍后'},
              ],
              'multiSelect': false,
            },
          ],
        },
      },
    });
    expect(question.callSummary?.isQuestion, isTrue);
    expect(question.callSummary?.questions?.single.id, 'q1');
    expect(question.callSummary?.questions?.single.options.length, 2);
    expect(question.callSummary?.renderable, isTrue);

    final skill = ChatEvent.fromJson({
      'seq': 13,
      'type': 'tool/call',
      'data': {
        'callId': 'c-skill',
        'name': 'skill',
        'summary': {
          'kind': 'skill',
          'tool': 'skill',
          'name': 'guizang-ppt-skill',
        },
      },
    });
    expect(skill.callSummary?.isSkill, isTrue);
    expect(skill.callSummary?.skillName, 'guizang-ppt-skill');
    expect(skill.callSummary?.renderable, isTrue);

    final result = ChatEvent.fromJson({
      'seq': 14,
      'type': 'tool/result',
      'data': {
        'callId': 'c-ask',
        'name': 'ask_user_question',
        'summary': {
          'answers': [
            {
              'questionId': 'q1',
              'values': ['发布', '自定义'],
            },
            {
              'questionId': 'q2',
              'values': <Object>[],
            },
          ],
        },
      },
    });
    expect(result.resultSummary?.answers?.length, 2);
    expect(result.resultSummary?.answers?.first.questionId, 'q1');
    expect(result.resultSummary?.answers?.last.values, isEmpty);
    expect(answerTextOf(result.resultSummary, 'q1'), '发布、自定义');

    // 旧插件/服务端不下发新字段：summary 缺省 → null，由通用卡兜底。
    final legacyCall = ChatEvent.fromJson({
      'seq': 15,
      'type': 'tool/call',
      'data': {
        'callId': 'c-todo2',
        'name': 'todo_write',
        'arguments': '{"todos":[]}',
      },
    });
    expect(legacyCall.callSummary, isNull);
    final legacyResult = ChatEvent.fromJson({
      'seq': 16,
      'type': 'tool/result',
      'data': {
        'callId': 'c-ask2',
        'name': 'ask_user_question',
        'text': '{"pending":true}',
      },
    });
    expect(legacyResult.resultSummary, isNull);
  });
}
