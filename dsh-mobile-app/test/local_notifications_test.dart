// issue #46：本地通知的文案与去重（纯逻辑，不依赖平台通道）。
import 'package:dsh_mobile_app/local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('attentionCopy', () {
    test('审批：标题带工具名，正文带理由与会话标题', () {
      final copy = attentionCopy(
        kind: 'approval',
        sessionId: 'session-1',
        toolName: 'Bash',
        reason: '运行测试',
        sessionTitle: '修 GitHub issues',
      );
      expect(copy.title, '需要授权：Bash');
      expect(copy.body, '运行测试\n修 GitHub issues');
    });

    test('审批：缺工具名/理由时给出稳定兜底，不回显空串', () {
      final copy = attentionCopy(kind: 'approval', sessionId: 'session-2');
      expect(copy.title, '需要授权：工具调用');
      expect(copy.body, '等待你授权\nsession-2');
    });

    test('问询：标题固定，正文取首个问题与会话标题', () {
      final copy = attentionCopy(
        kind: 'question',
        sessionId: 'session-3',
        prompt: '用哪个分支？',
        sessionTitle: '发布 3.3.0',
      );
      expect(copy.title, '需要你回答');
      expect(copy.body, '用哪个分支？\n发布 3.3.0');
    });

    test('问询：空标题回退 sessionId（不显示 null）', () {
      final copy = attentionCopy(
        kind: 'question',
        sessionId: 'session-4',
        prompt: '  ',
        sessionTitle: '   ',
      );
      expect(copy.title, '需要你回答');
      expect(copy.body, 'agent 在等你回答\nsession-4');
    });
  });

  group('AttentionDeduper', () {
    test('同一 rpcId 在窗口内只放行一次', () {
      final dedupe = AttentionDeduper(window: const Duration(minutes: 5));
      final at = DateTime(2026, 1, 1, 12);
      expect(dedupe.shouldNotify('approval:r1', now: at), isTrue);
      expect(
        dedupe.shouldNotify('approval:r1', now: at.add(const Duration(seconds: 30))),
        isFalse,
      );
      expect(
        dedupe.shouldNotify('approval:r1', now: at.add(const Duration(minutes: 6))),
        isTrue,
      );
    });

    test('不同 rpcId 互不影响', () {
      final dedupe = AttentionDeduper();
      final at = DateTime(2026, 1, 1, 12);
      expect(dedupe.shouldNotify('approval:r1', now: at), isTrue);
      expect(dedupe.shouldNotify('question:r1', now: at), isTrue);
      expect(dedupe.shouldNotify('approval:r2', now: at), isTrue);
    });

    test('条目超过上限时按最久未提醒淘汰', () {
      final dedupe = AttentionDeduper(maxEntries: 2);
      final at = DateTime(2026, 1, 1, 12);
      expect(dedupe.shouldNotify('a', now: at), isTrue);
      expect(dedupe.shouldNotify('b', now: at.add(const Duration(minutes: 1))), isTrue);
      expect(dedupe.shouldNotify('c', now: at.add(const Duration(minutes: 2))), isTrue);
      // a 已被淘汰 → 再次提醒
      expect(dedupe.shouldNotify('a', now: at.add(const Duration(minutes: 3))), isTrue);
    });
  });

  // 回归：payload 从「裸 sessionId」改成 JSON 之后，点击回调忘了跟着改，
  // 真机上表现为「点了通知打不开会话」。这里锁住解析契约。
  group('通知 payload 解析', () {
    final notifier = LocalNotifier.instance;

    test('JSON payload 取 s 字段', () {
      const payload =
          '{"s":"session-abc","k":"approval","key":"approval|session-abc|r1","id":123}';
      expect(notifier.sessionIdFromPayload(payload), 'session-abc');
    });

    test('兼容旧的裸 sessionId payload', () {
      expect(notifier.sessionIdFromPayload('session-old'), 'session-old');
    });

    test('空/异常 payload 返回 null，不抛异常', () {
      expect(notifier.sessionIdFromPayload(null), isNull);
      expect(notifier.sessionIdFromPayload(''), isNull);
      // 不是合法 JSON → 按裸 id 处理（兼容极端输入，不抛）
      expect(notifier.sessionIdFromPayload('{bad json'), '{bad json');
      // 合法 JSON 但没有会话 → null，不能把整段 JSON 当会话 id
      expect(notifier.sessionIdFromPayload('{"k":"approval"}'), isNull);
    });

    test('s 为空串时返回 null', () {
      expect(notifier.sessionIdFromPayload('{"s":"","k":"approval"}'), isNull);
    });
  });
}
