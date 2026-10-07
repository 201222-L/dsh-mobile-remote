// issue #17：子代理列表的排序与状态复用逻辑单测。
//
// 覆盖两件容易回归的事：
// 1. 排序**有意与会话列表不同**——会话列表用 lastMessageAt，子代理列表用
//    createdAt 降序（"我最近派了什么"）。缺时间时排最后，等值时按 id 稳定。
// 2. 行状态直接复用会话列表的 sessionRowState（子代理本身就是会话），
//    不发明第二套运行状态语义；等待态优先于运行态。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/session_list.dart';

Map<String, dynamic> sub({
  required String id,
  int? createdAt,
  String status = 'inactive',
  String? title,
}) => {
  'id': id,
  if (createdAt != null) 'createdAt': createdAt,
  'status': status,
  if (title != null) 'title': title,
};

void main() {
  group('子代理排序（createdAt 降序）', () {
    test('最新派生的排在最上', () {
      final sorted = sortSubagentsForSheet([
        sub(id: 'a', createdAt: 1000),
        sub(id: 'b', createdAt: 3000),
        sub(id: 'c', createdAt: 2000),
      ]);
      expect(sorted.map((e) => e['id']).toList(), ['b', 'c', 'a']);
    });

    test('缺 createdAt 的排最后，不抢占"最近派生"的位置', () {
      final sorted = sortSubagentsForSheet([
        sub(id: 'no-time'),
        sub(id: 'older', createdAt: 1000),
        sub(id: 'newer', createdAt: 2000),
      ]);
      expect(sorted.map((e) => e['id']).toList(), ['newer', 'older', 'no-time']);
    });

    test('createdAt 等值时按 id 升序，保证稳定不抖动', () {
      final sorted = sortSubagentsForSheet([
        sub(id: 'zeta', createdAt: 5000),
        sub(id: 'alpha', createdAt: 5000),
      ]);
      expect(sorted.map((e) => e['id']).toList(), ['alpha', 'zeta']);
    });

    test('不修改入参（调用方可能共享同一份列表）', () {
      final input = [sub(id: 'a', createdAt: 1), sub(id: 'b', createdAt: 2)];
      final snapshot = input.map((e) => e['id']).toList();
      sortSubagentsForSheet(input);
      expect(input.map((e) => e['id']).toList(), snapshot);
    });

    test('与会话列表的排序键不同：子代理不因"最近有消息"而跳位', () {
      // 会话列表按 lastMessageAt；子代理条目即便带有更新的活动时间，
      // 也只看 createdAt —— 这是刻意的不一致（issue #17）。
      final sorted = sortSubagentsForSheet([
        sub(id: 'early-but-chatty', createdAt: 1000),
        sub(id: 'late', createdAt: 2000),
      ]);
      expect(sorted.first['id'], 'late');
    });
  });

  group('子代理行状态复用会话运行状态', () {
    test('agentStatus=running 即运行中', () {
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

    test('只有后台任务在跑也算运行中（与列表页同一规则）', () {
      expect(
        sessionRowState(
          agentStatus: 'idle',
          hasRunningJobs: true,
          hasPendingQuestion: false,
          hasPendingApproval: false,
        ),
        SessionRowState.running,
      );
    });

    test('挂起问询优先于运行态', () {
      expect(
        sessionRowState(
          agentStatus: 'running',
          hasRunningJobs: true,
          hasPendingQuestion: true,
          hasPendingApproval: false,
        ),
        SessionRowState.waiting,
      );
    });

    test('空闲即无标识', () {
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

  group('subagentCreatedAt 解析', () {
    test('接受 int 与 num，拒绝缺失/非法', () {
      expect(subagentCreatedAt({'createdAt': 123}), 123);
      expect(subagentCreatedAt({'createdAt': 123.0}), 123);
      expect(subagentCreatedAt({'createdAt': '123'}), isNull);
      expect(subagentCreatedAt({}), isNull);
    });
  });
}
