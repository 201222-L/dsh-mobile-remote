// 会话列表的共享判定与排序（ADR 0013 / issue #14）。
//
// 这里的每个函数都是**无 I/O 纯函数**：会话列表页与首页「最近会话」共用同一
// 排序与过滤规则，两处不再各写一份（此前是重复实现，行为容易漂移）。
// 纯函数形态也让判定逻辑可以在普通 `test()` 下覆盖，不必启动 widget。
import 'models.dart';

/// 会话行状态标识（会话图标的方形虚线）：
/// - [running]：会话正在推进 → 虚线顺时针循环旋转
/// - [waiting]：会话在等用户审批/作答 → 虚线静态 + 警示色
/// - [idle]：无标记，列表保持安静
enum SessionRowState { idle, running, waiting }

/// 运行判定：会话运行状态为 `running`，或该会话存在运行中的后台任务。
///
/// 注意「等待用户处理」**不是**运行状态的第三个取值（内核 `AgentStatus`
/// 只有 idle/running，等待审批时驱动仍是 running）——它由 [sessionRowState]
/// 单独叠加，见 ADR 0013。
bool isSessionRunning({
  required String? agentStatus,
  required bool hasRunningJobs,
}) => agentStatus == 'running' || hasRunningJobs;

/// 等待判定：该会话存在挂起的问询或审批。
/// 该信息来自已有的独立待答通道，与会话运行状态无关。
bool isSessionWaitingForUser({
  required bool hasPendingQuestion,
  required bool hasPendingApproval,
}) => hasPendingQuestion || hasPendingApproval;

/// 行状态合成：等待态优先于运行态（两者同时满足时显示"需要你介入"）。
SessionRowState sessionRowState({
  required String? agentStatus,
  required bool hasRunningJobs,
  required bool hasPendingQuestion,
  required bool hasPendingApproval,
}) {
  if (isSessionWaitingForUser(
    hasPendingQuestion: hasPendingQuestion,
    hasPendingApproval: hasPendingApproval,
  )) {
    return SessionRowState.waiting;
  }
  if (isSessionRunning(agentStatus: agentStatus, hasRunningJobs: hasRunningJobs)) {
    return SessionRowState.running;
  }
  return SessionRowState.idle;
}

/// 子代理会话过滤（ADR 0013）：只认 `origin === 'subagent'`。
///
/// **宽松降级**：旧插件不返回 `origin` 时 [Session.isSubagent] 为 false，
/// 于是不过滤任何会话——宁可多显示也不错误隐藏，且不提示、不阻塞。
/// 用户主动 fork 的会话只有 `parentSession` 而没有 `origin`，因此正常显示。
List<Session> visibleSessions(Iterable<Session> sessions) =>
    sessions.where((s) => !s.isSubagent).toList();

/// 排序：`lastMessageAt ?? lastActivity ?? createdAt` 倒序；
/// **等值时以会话 id 为次级键**，保证顺序稳定不抖动（US29）。
///
/// 返回新列表，不修改入参（调用方共享同一份 `sessions`）。
List<Session> sortSessionsForList(Iterable<Session> sessions) {
  final list = sessions.toList();
  list.sort((a, b) {
    final byTime = b.sortKey.compareTo(a.sortKey);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  });
  return list;
}

/// 会话列表页与首页共用的投影：先过滤子代理会话，再按最新消息时间排序。
///
/// 归档只是分类，不代表会话停了——因此**已归档但仍运行**的会话同样带状态标识。
List<Session> projectSessions(Iterable<Session> sessions) =>
    sortSessionsForList(visibleSessions(sessions));
