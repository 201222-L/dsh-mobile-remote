// issue #25 逻辑单测：提交时"这行是不是斜杠命令"的判定 + 命令通路的两处纯函数。
// 背景：`/compact` 曾被当成普通用户消息发给模型（模型还回答了它，且没有任何报错提示）。
// 判定式必须与内核命令行语法同形：`/` + 小写名字 [a-z][a-z0-9_-]* + 空白/行尾。
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isCommandLine（提交时判定命令行）', () {
    test('裸命令名 → 真', () {
      expect(isCommandLine('/compact'), isTrue);
      expect(isCommandLine('/tmp'), isTrue); // 单段文本：语法上无法与命令名区分（有意）
      expect(isCommandLine('/goal'), isTrue);
    });

    test('带参数的命令行 → 真（名字后是空白）', () {
      expect(isCommandLine('/goal do a thing'), isTrue);
      expect(isCommandLine('/goal\tdo'), isTrue);
      expect(isCommandLine('/compact '), isTrue); // 尾随空白
      expect(isCommandLine(' /compact'), isTrue); // 前导空白（与 _send 的 trim 同口径）
    });

    test('名字字符集：小写字母开头，后续可含数字/下划线/连字符 → 真', () {
      expect(isCommandLine('/plan2'), isTrue);
      expect(isCommandLine('/a-b_c9'), isTrue);
      expect(isCommandLine('/sub_agent x'), isTrue);
    });

    test('大写名字 → 假（内核命令名是小写）', () {
      expect(isCommandLine('/Compact'), isFalse);
      expect(isCommandLine('/COMPACT'), isFalse);
    });

    test('名字后紧跟非空白（路径样式的消息）→ 假', () {
      // issue #25 的原始反例：这行的 `m` 之后是 `/`，因此必须原样发给模型
      expect(isCommandLine('/m/api/send 是什么'), isFalse);
      expect(isCommandLine('/tmp/foo'), isFalse);
      expect(isCommandLine('/compact,x'), isFalse);
    });

    test('不是命令的普通文本 → 假', () {
      expect(isCommandLine(''), isFalse);
      expect(isCommandLine('hello'), isFalse);
      expect(isCommandLine('/'), isFalse);
      expect(isCommandLine('//compact'), isFalse);
      expect(isCommandLine('/1compact'), isFalse);
      expect(isCommandLine('/-compact'), isFalse);
      expect(isCommandLine('你好 /compact'), isFalse);
      expect(isCommandLine('https://example.com/a'), isFalse);
    });
  });

  group('commandLineName（取出命令名，供目录查表/执行）', () {
    test('命令行取名字（吃掉前导/尾随空白）', () {
      expect(commandLineName('/compact'), 'compact');
      expect(commandLineName(' /compact '), 'compact');
      expect(commandLineName('/goal do a thing'), 'goal');
      expect(commandLineName('/a-b_c9 x'), 'a-b_c9');
    });

    test('非命令行 → null', () {
      expect(commandLineName('/m/api/send 是什么'), isNull);
      expect(commandLineName('/Compact'), isNull);
      expect(commandLineName('hello'), isNull);
      expect(commandLineName('/'), isNull);
    });
  });

  group('commandMenuSubtitle（⊕ 命令菜单副标题）', () {
    test('有 input.hint → 显示 hint（告诉用户要补什么参数）', () {
      expect(
        commandMenuSubtitle({
          'name': 'goal',
          'description': 'set or view the goal',
          'input': {'hint': '[<objective>|clear]', 'attachments': true},
        }),
        '[<objective>|clear]',
      );
    });

    test('无 hint → 回退 description', () {
      expect(
        commandMenuSubtitle({
          'name': 'goal',
          'description': 'set or view the goal',
          'input': {'attachments': true},
        }),
        'set or view the goal',
      );
      expect(
        commandMenuSubtitle({'name': 'compact', 'description': 'compact it'}),
        'compact it',
      );
    });

    test('hint 为空串/非字符串、描述也缺 → null（不渲染空副标题）', () {
      expect(
        commandMenuSubtitle({
          'name': 'x',
          'description': 'd',
          'input': {'hint': ''},
        }),
        'd',
      );
      expect(
        commandMenuSubtitle({
          'name': 'x',
          'input': {'hint': 42},
        }),
        isNull,
      );
      expect(commandMenuSubtitle({'name': 'compact'}), isNull);
    });
  });

  group('commandExecuteErrorToast（命令执行失败的错误码 → 提示）', () {
    test('504 commands-execute-failed → 结果未知，不断言失败', () {
      final msg = commandExecuteErrorToast(
        ApiException('timeout', code: 'commands-execute-failed', status: 504),
      );
      expect(msg, contains('结果未知'));
      expect(msg, isNot(contains('失败：')));
    });

    test('无 status 的 commands-execute-failed 同样按结果未知处理', () {
      expect(
        commandExecuteErrorToast(
          ApiException('aborted', code: 'commands-execute-failed'),
        ),
        contains('结果未知'),
      );
    });

    test('command-not-found → 目录过期（保留草稿）', () {
      expect(
        commandExecuteErrorToast(
          ApiException('unknown or malformed command', code: 'command-not-found', status: 404),
        ),
        contains('命令目录已过期'),
      );
    });

    test('commands-unavailable → 命令服务不可用', () {
      expect(
        commandExecuteErrorToast(
          ApiException('no service', code: 'commands-unavailable', status: 503),
        ),
        contains('未提供命令服务'),
      );
    });

    test('session-not-found → 会话休眠，先发消息唤醒', () {
      expect(
        commandExecuteErrorToast(
          ApiException('session not found', code: 'session-not-found', status: 404),
        ),
        contains('已休眠'),
      );
    });

    test('其它错误码（含 400 的同码失败）→ 通用失败提示，带错误原文', () {
      expect(
        commandExecuteErrorToast(
          ApiException('bad arguments', code: 'commands-execute-failed', status: 400),
        ),
        allOf(contains('命令执行失败'), contains('bad arguments')),
      );
      expect(
        commandExecuteErrorToast(ApiException('boom')),
        contains('boom'),
      );
    });
  });
}
