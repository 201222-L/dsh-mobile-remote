// issue #14 / ADR 0013：会话列表的纯判定逻辑单测。
//
// 这些是无 I/O 纯函数，因此用普通 test() 覆盖即可（prior art：issue13_logic_test.dart）。
// 覆盖：运行判定（agentStatus=running 或有 running 任务）、等待判定（挂起问询/审批）、
// 等待优先于运行、子代理过滤、排序键回退链、等值稳定性、宽松降级。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/session_list.dart';

Session makeSession({
  required String id,
  int createdAt = 0,
  int? lastActivity,
  int? lastMessageAt,
  String? origin,
  String? parentSession,
  bool archived = false,
}) => Session(
  id: id,
  createdAt: createdAt,
  lastActivity: lastActivity,
  lastMessageAt: lastMessageAt,
  origin: origin,
  parentSession: parentSession,
  archived: archived,
);

void main() {
  group('运行判定 isSessionRunning', () {
    test('agentStatus=running → 运行中', () {
      expect(
        isSessionRunning(agentStatus: 'running', hasRunningJobs: false),
        isTrue,
      );
    });

    test('agentStatus=idle 但有 running 后台任务 → 视为运行中', () {
      expect(
        isSessionRunning(agentStatus: 'idle', hasRunningJobs: true),
        isTrue,
      );
    });

    test('idle 且无任务 → 不运行', () {
      expect(
        isSessionRunning(agentStatus: 'idle', hasRunningJobs: false),
        isFalse,
      );
    });

    test('无状态映射（null）→ 不运行', () {
      expect(
        isSessionRunning(agentStatus: null, hasRunningJobs: false),
        isFalse,
      );
    });
  });

  group('等待判定 isSessionWaitingForUser', () {
    test('有挂起问询 → 等待用户处理', () {
      expect(
        isSessionWaitingForUser(hasPendingQuestion: true, hasPendingApproval: false),
        isTrue,
      );
    });

    test('有挂起审批 → 等待用户处理', () {
      expect(
        isSessionWaitingForUser(hasPendingQuestion: false, hasPendingApproval: true),
        isTrue,
      );
    });

    test('都没有 → 不在等待', () {
      expect(
        isSessionWaitingForUser(hasPendingQuestion: false, hasPendingApproval: false),
        isFalse,
      );
    });
  });

  group('行状态合成 sessionRowState', () {
    test('运行中 + 无待答 → running', () {
      expect(
        sessionRowState(
          agentStatus: 'running',
          hasRunningJobs: false,
          hasPendingQuestion: false,
          hasPendingApproval: false,
        ),
        SessionRowState.running,
      );
    });

    test('等待态优先于运行态（内核在等答复时驱动仍是 running）', () {
      expect(
        sessionRowState(
          agentStatus: 'running',
          hasRunningJobs: false,
          hasPendingQuestion: true,
          hasPendingApproval: false,
        ),
        SessionRowState.waiting,
      );
    });

    test('空转但有待答审批 → waiting（不因没在跑就忽略等待）', () {
      expect(
        sessionRowState(
          agentStatus: 'idle',
          hasRunningJobs: false,
          hasPendingQuestion: false,
          hasPendingApproval: true,
        ),
        SessionRowState.waiting,
      );
    });

    test('idle 且无待答 → idle（无标记）', () {
      expect(
        sessionRowState(
          agentStatus: 'idle',
          hasRunningJobs: false,
          hasPendingQuestion: false,
          hasPendingApproval: false,
        ),
        SessionRowState.idle,
      );
    });
  });

  group('子代理会话过滤 visibleSessions', () {
    test('origin=subagent 的会话被隐藏', () {
      final out = visibleSessions([
        makeSession(id: 'main'),
        makeSession(id: 'sub', origin: 'subagent', parentSession: 'main'),
      ]);
      expect(out.map((s) => s.id), ['main']);
    });

    test('用户 fork 的会话（只有 parentSession、无 origin）正常显示', () {
      final out = visibleSessions([
        makeSession(id: 'forked', parentSession: 'main'),
      ]);
      expect(out.map((s) => s.id), ['forked']);
    });

    test('旧插件不返回 origin → 不过滤任何会话（宽松降级）', () {
      final out = visibleSessions([
        makeSession(id: 'a'),
        makeSession(id: 'b', parentSession: 'a'),
      ]);
      expect(out.map((s) => s.id), ['a', 'b']);
    });

    test('Session.isSubagent 只认 origin', () {
      expect(makeSession(id: 'x', origin: 'subagent').isSubagent, isTrue);
      expect(makeSession(id: 'x', parentSession: 'p').isSubagent, isFalse);
      expect(makeSession(id: 'x').isSubagent, isFalse);
    });
  });

  group('排序键与排序 sortSessionsForList', () {
    test('排序键回退链：lastMessageAt → lastActivity → createdAt', () {
      expect(makeSession(id: 'a', lastMessageAt: 3, lastActivity: 2, createdAt: 1).sortKey, 3);
      expect(makeSession(id: 'a', lastActivity: 2, createdAt: 1).sortKey, 2);
      expect(makeSession(id: 'a', createdAt: 1).sortKey, 1);
    });

    test('按最新消息时间倒序（最近的在最前）', () {
      final out = sortSessionsForList([
        makeSession(id: 'old', lastMessageAt: 100),
        makeSession(id: 'new', lastMessageAt: 300),
        makeSession(id: 'mid', lastMessageAt: 200),
      ]);
      expect(out.map((s) => s.id), ['new', 'mid', 'old']);
    });

    test('打开会话（lastActivity 更新）不改变顺序——排序只看消息时间', () {
      final before = sortSessionsForList([
        makeSession(id: 'a', lastMessageAt: 100, lastActivity: 100),
        makeSession(id: 'b', lastMessageAt: 200, lastActivity: 200),
      ]);
      // 模拟打开 a（touch 只推高 lastActivity）
      final after = sortSessionsForList([
        makeSession(id: 'a', lastMessageAt: 100, lastActivity: 999),
        makeSession(id: 'b', lastMessageAt: 200, lastActivity: 200),
      ]);
      expect(before.map((s) => s.id), ['b', 'a']);
      expect(after.map((s) => s.id), ['b', 'a']);
    });

    test('旧插件无 lastMessageAt → 回退 lastActivity 排序', () {
      final out = sortSessionsForList([
        makeSession(id: 'a', lastActivity: 100, createdAt: 1),
        makeSession(id: 'b', lastActivity: 200, createdAt: 1),
      ]);
      expect(out.map((s) => s.id), ['b', 'a']);
    });

    test('时间相同时以 id 为次级键，顺序稳定不抖动', () {
      final input = [
        makeSession(id: 'session-c', lastMessageAt: 500),
        makeSession(id: 'session-a', lastMessageAt: 500),
        makeSession(id: 'session-b', lastMessageAt: 500),
      ];
      final first = sortSessionsForList(input);
      final second = sortSessionsForList(input.reversed);
      expect(first.map((s) => s.id), ['session-a', 'session-b', 'session-c']);
      // 输入顺序不同，输出顺序一致（稳定）
      expect(second.map((s) => s.id), ['session-a', 'session-b', 'session-c']);
    });

    test('有/无消息时间的会话混排：按各自排序键的值比较（回退值参与真实比较）', () {
      // 回退不是"一律排在最后"，而是把 lastActivity 当作该会话的排序键参与比较——
      // 这正是 ADR 0013 记录的兼容例外：无消息时间的会话仍可能上浮。
      final out = sortSessionsForList([
        makeSession(id: 'no-msg', lastActivity: 900),
        makeSession(id: 'has-msg', lastMessageAt: 100),
      ]);
      expect(out.map((s) => s.id), ['no-msg', 'has-msg']);

      // 反过来：消息时间更新时，有消息时间的会话排前
      final out2 = sortSessionsForList([
        makeSession(id: 'no-msg', lastActivity: 100),
        makeSession(id: 'has-msg', lastMessageAt: 900),
      ]);
      expect(out2.map((s) => s.id), ['has-msg', 'no-msg']);
    });

    test('兼容例外：旧 App 的 touch 推高无消息会话的 lastActivity 后它会重排（已接受）', () {
      final before = sortSessionsForList([
        makeSession(id: 'has-msg', lastMessageAt: 500),
        makeSession(id: 'no-msg', lastActivity: 100),
      ]);
      expect(before.map((s) => s.id), ['has-msg', 'no-msg']);

      // 旧版 App 打开 no-msg（touch 只推高 lastActivity）→ 它上浮到第一位
      final after = sortSessionsForList([
        makeSession(id: 'has-msg', lastMessageAt: 500),
        makeSession(id: 'no-msg', lastActivity: 9999),
      ]);
      expect(
        after.map((s) => s.id),
        ['no-msg', 'has-msg'],
        reason: 'docs/03 明确：这项兼容回退不保证打开后顺序始终不变',
      );
    });
  });

  group('projectSessions（列表页与首页共用的投影）', () {
    test('先过滤子代理会话，再按消息时间排序', () {
      final out = projectSessions([
        makeSession(id: 'main-old', lastMessageAt: 100),
        makeSession(id: 'sub', origin: 'subagent', lastMessageAt: 999),
        makeSession(id: 'fork', parentSession: 'main', lastMessageAt: 300),
      ]);
      expect(out.map((s) => s.id), ['fork', 'main-old']);
    });

    test('归档会话也在投影里（归档只是分类，不代表会话停了）', () {
      final out = projectSessions([
        makeSession(id: 'archived', lastMessageAt: 200, archived: true),
        makeSession(id: 'active', lastMessageAt: 100),
      ]);
      expect(out.map((s) => s.id), ['archived', 'active']);
    });
  });
}
