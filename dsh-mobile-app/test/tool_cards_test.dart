// issue #54（M3 Batch 1）：工具卡纯逻辑（摘要解析、折叠行/统计/退出码/命中数、fail-open）。

import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/tool_cards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolCallSummary 解析', () {
    test('command 字段与缺省', () {
      final bash = ToolCallSummary.fromJson({
        'kind': 'command',
        'tool': 'bash',
        'command': 'ls -la',
        'workdir': 'src',
        'background': true,
        'description': 'List files',
      });
      expect(bash?.kind, ToolCardKind.command);
      expect(bash?.command, 'ls -la');
      expect(bash?.workdir, 'src');
      expect(bash?.background, isTrue);
      expect(bash?.description, 'List files');
      final minimal = ToolCallSummary.fromJson({'kind': 'command', 'tool': 'pwsh'});
      expect(minimal?.command, isNull);
      expect(minimal?.renderable, isFalse, reason: '缺 command → 回退通用卡');
    });

    test('file 字段：read 行范围 / write sizeKb+diff / edit added-deleted', () {
      final read = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'read',
        'filePath': 'src/a.ts',
        'offset': 2,
        'limit': 40,
      });
      expect(read?.filePath, 'src/a.ts');
      expect(read?.offset, 2);
      expect(read?.limit, 40);
      final write = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'write',
        'filePath': 'src/new.ts',
        'sizeKb': 3,
        'diff': '--- /dev/null\n+++ b/src/new.ts\n@@ -0,0 +1,1 @@\n+hi\n',
      });
      expect(write?.sizeKb, 3);
      expect(toolHasInlineDiff(write!), isTrue);
      final edit = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'edit',
        'filePath': 'src/a.ts',
        'sizeKb': 1,
        'added': 2,
        'deleted': 1,
        'diffTruncated': true,
      });
      expect(edit?.added, 2);
      expect(edit?.deleted, 1);
      expect(edit?.diffTruncated, isTrue);
      expect(toolHasInlineDiff(edit!), isFalse);
    });

    test('search/web/image 字段；失败字段逐项降级', () {
      final grep = ToolCallSummary.fromJson({
        'kind': 'search',
        'tool': 'grep',
        'pattern': 'foo',
        'path': 'lib',
        'include': '*.ts',
      });
      expect(grep?.pattern, 'foo');
      expect(grep?.path, 'lib');
      expect(grep?.include, '*.ts');
      final web = ToolCallSummary.fromJson({
        'kind': 'web',
        'tool': 'web_fetch',
        'url': 'https://x.test',
      });
      expect(web?.url, 'https://x.test');
      final image = ToolCallSummary.fromJson({
        'kind': 'image',
        'tool': 'read_image',
        'filePath': 'p.png',
      });
      expect(image?.filePath, 'p.png');
      // 非法 kind/tool/字段类型：整卡或单字段降级，不抛错。
      expect(ToolCallSummary.fromJson({'kind': 'mystery', 'tool': 'x'}), isNull);
      expect(ToolCallSummary.fromJson({'kind': 'command'}), isNull);
      expect(ToolCallSummary.fromJson(null), isNull);
      final weird = ToolCallSummary.fromJson({
        'kind': 'command',
        'tool': 'bash',
        'command': 42,
        'background': 'yes',
      });
      expect(weird?.command, isNull);
      expect(weird?.background, isFalse);
    });
  });

  group('ToolResultSummary 与展示文案', () {
    test('退出码/信号/停止/命中数解析（空对象为 null）', () {
      expect(ToolResultSummary.fromJson({'exitCode': 2})?.exitCode, 2);
      expect(ToolResultSummary.fromJson({'signal': 'SIGTERM'})?.signal, 'SIGTERM');
      expect(ToolResultSummary.fromJson({'stopped': 'cancelled'})?.stopped, 'cancelled');
      expect(ToolResultSummary.fromJson({'resultCount': 3})?.resultCount, 3);
      expect(ToolResultSummary.fromJson(<String, dynamic>{}), isNull);
      expect(ToolResultSummary.fromJson(null), isNull);
    });

    test('折叠行主文案', () {
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.command, tool: 'bash', command: 'ls')),
        '\$ ls',
      );
      expect(
        toolFoldText(const ToolCallSummary(
          kind: ToolCardKind.file,
          tool: 'read',
          filePath: 'src/a.ts',
          offset: 2,
          limit: 4,
        )),
        'src/a.ts · 行 2–5',
      );
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.search, tool: 'grep', pattern: 'foo', path: 'lib')),
        'foo · lib',
      );
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.web, tool: 'web_fetch', url: 'https://x')),
        'https://x',
      );
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.image, tool: 'read_image', filePath: 'p.png')),
        'p.png',
      );
    });

    test('文件统计 / 退出码胶囊 / 命中数胶囊', () {
      expect(
        toolFileStats(const ToolCallSummary(
          kind: ToolCardKind.file,
          tool: 'edit',
          filePath: 'a.ts',
          sizeKb: 2,
          added: 3,
          deleted: 1,
        )),
        '2KB · +3 −1',
      );
      expect(toolFileStats(const ToolCallSummary(kind: ToolCardKind.command, tool: 'bash')), isNull);
      expect(toolExitBadge(const ToolResultSummary(exitCode: 0)), isNull);
      expect(toolExitBadge(const ToolResultSummary(exitCode: 2)), 'exit 2');
      expect(toolExitBadge(const ToolResultSummary(signal: 'SIGTERM', exitCode: 2)), 'signal: SIGTERM');
      expect(toolExitBadge(const ToolResultSummary(stopped: 'cancelled')), '已停止');
      final grep = const ToolCallSummary(kind: ToolCardKind.search, tool: 'grep', pattern: 'foo');
      expect(toolResultCountBadge(grep, const ToolResultSummary(resultCount: 7)), '7 个匹配');
      expect(toolResultCountBadge(grep, null), isNull);
    });
  });

  // ── issue #66（M3 Batch 2-A）：todo_write / ask_user_question / skill ──────────

  group('issue #66：todo_write 摘要', () {
    test('items/counts 解析与逐字段降级', () {
      final todo = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': [
          {'content': '写文档', 'status': 'completed'},
          {'content': '跑测试', 'status': 'in_progress'},
          {'content': '发 PR'}, // 缺 status → pending
          {'content': 42, 'status': 'completed'}, // content 非 String → 丢弃
          'not-a-map',
        ],
        'counts': {'pending': 1, 'inProgress': 1, 'completed': 1},
      });
      expect(todo?.kind, ToolCardKind.todo);
      expect(todo?.isTodo, isTrue);
      expect(todo?.todoItems?.length, 3);
      expect(todo?.todoItems?[2].status, 'pending');
      expect(todo?.todoPending, 1);
      expect(todo?.todoInProgress, 1);
      expect(todo?.todoCompleted, 1);
      expect(todo?.renderable, isTrue);

      // 空数组是合法快照（可渲染 0 项）。
      final empty = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': <Object>[],
        'counts': {'pending': 0, 'inProgress': 0, 'completed': 0},
      });
      expect(empty?.todoItems, isEmpty);
      expect(empty?.renderable, isTrue);
      expect(toolFoldText(empty!), '0 项任务 · 0 完成');

      // items 非数组 → 不可渲染（回退通用卡）。
      final bare = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': 'nope',
        'counts': {'pending': 0, 'inProgress': 0, 'completed': 0},
      });
      expect(bare?.todoItems, isNull);
      expect(bare?.renderable, isFalse);
      expect(toolFoldText(bare!), isNull);

      // counts 三键缺一 → 整体缺省（不展示半份计数）。
      final partialCounts = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': [
          {'content': 'x', 'status': 'completed'},
        ],
        'counts': {'pending': 0, 'completed': 1},
      });
      expect(partialCounts?.todoPending, isNull);
      expect(partialCounts?.todoInProgress, isNull);
      expect(partialCounts?.todoCompleted, isNull);

      // status 保留 wire 原值（归一在展示/服务端侧）。
      final unknownStatus = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': [
          {'content': 'x', 'status': 'blocked'},
        ],
      });
      expect(unknownStatus?.todoItems?.single.status, 'blocked');
    });

    test('折叠行：优先 counts.completed，缺失时按 items 统计', () {
      final counted = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': [
          {'content': 'a', 'status': 'completed'},
          {'content': 'b', 'status': 'completed'},
          {'content': 'c', 'status': 'in_progress'},
        ],
        'counts': {'pending': 0, 'inProgress': 1, 'completed': 2},
      });
      expect(toolFoldText(counted!), '3 项任务 · 2 完成');

      final fallback = ToolCallSummary.fromJson({
        'kind': 'todo',
        'tool': 'todo_write',
        'items': [
          {'content': 'a', 'status': 'completed'},
          {'content': 'b', 'status': 'pending'},
        ],
      });
      expect(toolFoldText(fallback!), '2 项任务 · 1 完成');
    });
  });

  group('issue #66：ask_user_question 摘要', () {
    ToolCallSummary? questionCall() => ToolCallSummary.fromJson({
      'kind': 'question',
      'tool': 'ask_user_question',
      'questions': [
        {
          'id': 'q1',
          'header': '确认',
          'question': '要发布吗？',
          'options': [
            {'label': '发布', 'description': '立即发布'},
            {'label': ''}, // 空 label → 丢弃
            {'label': 42}, // 非 String label → 丢弃
            {'label': '稍后', 'description': 7}, // description 非 String → 缺省
          ],
          'multiSelect': true,
        },
        {
          'id': 42, // 非 String id → 缺省（不影响题目）
          'question': '备注？',
          'options': <Object>[], // 空数组合法 → 空列表
        },
        {'question': 42}, // 缺/非法 question → 整题丢弃
        'not-a-map',
      ],
    });

    test('questions/options/multiSelect 解析与逐项降级', () {
      final call = questionCall()!;
      expect(call.kind, ToolCardKind.question);
      expect(call.isQuestion, isTrue);
      expect(call.questions?.length, 2);
      final q1 = call.questions![0];
      expect(q1.id, 'q1');
      expect(q1.header, '确认');
      expect(q1.question, '要发布吗？');
      expect(q1.options.length, 2);
      expect(q1.options[0].label, '发布');
      expect(q1.options[0].description, '立即发布');
      expect(q1.options[1].label, '稍后');
      expect(q1.options[1].description, isNull);
      expect(q1.multiSelect, isTrue);
      final q2 = call.questions![1];
      expect(q2.id, isNull);
      expect(q2.options, isEmpty);
      expect(q2.multiSelect, isFalse);
      expect(call.renderable, isTrue);
      expect(toolFoldText(call), '2 个问题');

      // R1（issue #66 评审）：id 必须原样保留（不 trim）——它要与 `question/requested`
      // 帧里的 `AskQuestion.id`（models.dart 同样不 trim）精确匹配，决定「打开问询」入口；
      // question 文本本身仍按既有规则 trim。
      final rawId = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
        'questions': [
          {'id': ' q1 ', 'question': ' x '},
        ],
      });
      expect(rawId?.questions?.single.id, ' q1 ');
      expect(rawId?.questions?.single.question, 'x');
      expect(
        questionCallPending(rawId!, {' q1 '}),
        isTrue,
        reason: '带空白 id 与 pending 集合原样精确匹配 → 待答',
      );
      expect(
        questionCallPending(rawId, {'q1'}),
        isFalse,
        reason: 'App 侧不得对 id 做 trim 匹配',
      );
      // 纯空白 id / 非 String id → 缺省（无法关联待答）；题目本身保留。
      final blankId = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
        'questions': [
          {'id': '   ', 'question': 'q'},
          {'id': 7, 'question': 'q2'},
        ],
      });
      expect(blankId?.questions?.length, 2);
      expect(blankId?.questions?[0].id, isNull);
      expect(blankId?.questions?[1].id, isNull);
      expect(questionIdsOf(blankId!), isEmpty);

      // questions 缺失/非数组 → 不可渲染；空数组 → 可解析但不可渲染。
      final missing = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
      });
      expect(missing?.questions, isNull);
      expect(missing?.renderable, isFalse);
      expect(toolFoldText(missing!), isNull);
      final empty = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
        'questions': <Object>[],
      });
      expect(empty?.questions, isEmpty);
      expect(empty?.renderable, isFalse);

      // 所有题都无效 → 空列表（renderable false）。
      final invalid = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
        'questions': [
          {'question': ''},
          {'question': 7},
        ],
      });
      expect(invalid?.questions, isEmpty);
      expect(invalid?.renderable, isFalse);
    });
  });

  group('issue #66：skill 摘要', () {
    test('name 解析、不可渲染与折叠行', () {
      final skill = ToolCallSummary.fromJson({
        'kind': 'skill',
        'tool': 'skill',
        'name': 'guizang-ppt-skill',
      });
      expect(skill?.kind, ToolCardKind.skill);
      expect(skill?.isSkill, isTrue);
      expect(skill?.skillName, 'guizang-ppt-skill');
      expect(skill?.renderable, isTrue);
      expect(toolFoldText(skill!), 'skill · guizang-ppt-skill');

      expect(
        ToolCallSummary.fromJson({'kind': 'skill', 'tool': 'skill'})?.renderable,
        isFalse,
      );
      expect(
        ToolCallSummary.fromJson({
          'kind': 'skill',
          'tool': 'skill',
          'name': '   ',
        })?.skillName,
        isNull,
      );
      // 未知 / 改名前的 kind 仍整体 null（回退通用卡）。
      expect(
        ToolCallSummary.fromJson({'kind': 'todo-write', 'tool': 'todo_write'}),
        isNull,
      );
    });
  });

  group('issue #66：tool/result answers 与只读回放纯函数', () {
    test('answers 解析与逐项丢弃', () {
      final result = ToolResultSummary.fromJson({
        'answers': [
          {'questionId': 'q1', 'values': ['发布', '立即']},
          {'questionId': 'q2', 'values': <Object>[]},
          {'questionId': '', 'values': ['x']}, // 空 id → 丢弃
          {'values': ['x']}, // 缺 id → 丢弃
          {'questionId': 'q3', 'values': 'nope'}, // values 非数组 → 丢弃
          'not-a-map',
        ],
      });
      expect(result?.answers?.length, 2);
      expect(result?.answers?.first.questionId, 'q1');
      expect(result?.answers?.first.values, ['发布', '立即']);
      expect(result?.answers?.last.values, isEmpty);
      expect(result?.exitCode, isNull);

      // 缺失/形状不符/空对象 → 整体缺省（不猜）。
      expect(ToolResultSummary.fromJson({'answers': 'nope'}), isNull);
      expect(ToolResultSummary.fromJson({'answers': <Object>[]}), isNull);
      expect(ToolResultSummary.fromJson(<String, dynamic>{}), isNull);

      // 既有字段与 answers 共存，互不覆盖。
      final both = ToolResultSummary.fromJson({
        'exitCode': 0,
        'resultCount': 3,
        'answers': [
          {'questionId': 'q1', 'values': ['A']},
        ],
      });
      expect(both?.exitCode, 0);
      expect(both?.resultCount, 3);
      expect(both?.answers?.single.questionId, 'q1');

      // R1 同族：答案 questionId 与题目 id 同规则原样保留，带空白 id 也能配对回放。
      final rawIdAnswers = ToolResultSummary.fromJson({
        'answers': [
          {'questionId': ' q1 ', 'values': ['A']},
        ],
      });
      expect(rawIdAnswers?.answers?.single.questionId, ' q1 ');
      expect(answerTextOf(rawIdAnswers, ' q1 '), 'A');
      expect(answerTextOf(rawIdAnswers, 'q1'), isNull);
    });

    test('questionIdsOf / questionCallPending / answerTextOf', () {
      final call = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
        'questions': [
          {'id': 'q1', 'question': '一'},
          {'id': 'q2', 'question': '二'},
          {'question': '无 id'}, // 缺 id 的题不参与关联
        ],
      })!;
      expect(questionIdsOf(call), {'q1', 'q2'});
      expect(questionCallPending(call, {'q1'}), isTrue);
      expect(questionCallPending(call, {'q2', 'x'}), isTrue);
      expect(questionCallPending(call, {'other'}), isFalse);
      expect(questionCallPending(call, const <String>{}), isFalse);

      // 非 question kind 永不待答；无 id 的题集合为空。
      final todo = const ToolCallSummary(
        kind: ToolCardKind.todo,
        tool: 'todo_write',
        todoItems: <TodoCardItem>[],
      );
      expect(questionIdsOf(todo), isEmpty);
      expect(questionCallPending(todo, {'q1'}), isFalse);
      final noIds = ToolCallSummary.fromJson({
        'kind': 'question',
        'tool': 'ask_user_question',
        'questions': [
          {'question': '无 id'},
        ],
      })!;
      expect(questionIdsOf(noIds), isEmpty);
      expect(questionCallPending(noIds, {'q1'}), isFalse);

      final result = ToolResultSummary.fromJson({
        'answers': [
          {'questionId': 'q1', 'values': ['发布', '自定义']},
          {'questionId': 'q2', 'values': <Object>[]},
        ],
      });
      expect(answerTextOf(result, 'q1'), '发布、自定义');
      expect(answerTextOf(result, 'q2'), isNull, reason: '空 values 不算有答案');
      expect(answerTextOf(result, 'missing'), isNull);
      expect(answerTextOf(null, 'q1'), isNull);
      expect(answerTextOf(result, null), isNull);
      expect(answerTextOf(const ToolResultSummary(exitCode: 0), 'q1'), isNull);
    });
  });

  group('issue #66：两语言折叠行文案', () {
    test('英文环境走 L10n 英文文案', () {
      L10n.lang = 'en';
      addTearDown(() => L10n.lang = 'zh');
      final todo = const ToolCallSummary(
        kind: ToolCardKind.todo,
        tool: 'todo_write',
        todoItems: <TodoCardItem>[
          TodoCardItem(content: 'a', status: 'completed'),
          TodoCardItem(content: 'b'),
        ],
      );
      expect(toolFoldText(todo), '2 tasks · 1 done');
      final question = const ToolCallSummary(
        kind: ToolCardKind.question,
        tool: 'ask_user_question',
        questions: <QuestionCardItem>[
          QuestionCardItem(question: 'q'),
        ],
      );
      expect(toolFoldText(question), '1 questions');
      // skill 前缀固定，不翻译。
      final skill = const ToolCallSummary(
        kind: ToolCardKind.skill,
        tool: 'skill',
        skillName: 'demo',
      );
      expect(toolFoldText(skill), 'skill · demo');
    });
  });
}
