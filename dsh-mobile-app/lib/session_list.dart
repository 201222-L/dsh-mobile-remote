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
  bool hasRunningSubagents = false,
}) =>
    agentStatus == 'running' || hasRunningJobs || hasRunningSubagents;

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
  bool hasRunningSubagents = false,
  required bool hasPendingQuestion,
  required bool hasPendingApproval,
}) {
  if (isSessionWaitingForUser(
    hasPendingQuestion: hasPendingQuestion,
    hasPendingApproval: hasPendingApproval,
  )) {
    return SessionRowState.waiting;
  }
  if (isSessionRunning(
    agentStatus: agentStatus,
    hasRunningJobs: hasRunningJobs,
    hasRunningSubagents: hasRunningSubagents,
  )) {
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

/// issue #124/#133：子代理运行聚合结果。
///
/// [hasKnownChildren]：当前 `/api/sessions` 里能看到该会话的子代理行（可用于本地实时
/// 聚合）；[running]：递归子代理中是否有 running。
class SubagentRunAggregate {
  final bool hasKnownChildren;
  final bool running;
  const SubagentRunAggregate({
    required this.hasKnownChildren,
    required this.running,
  });

  static const none = SubagentRunAggregate(
    hasKnownChildren: false,
    running: false,
  );
}

/// 递归聚合子代理运行状态（纯函数）。
///
/// 数据源完全来自现有 `/api/sessions`（子代理会话带 `origin=subagent` 与
/// `parentSession`，列表层按 ADR 0013 过滤不显示）与 SSE/`bootstrap` 维护的
/// 每会话 agent 状态——**不逐会话请求**；同时带 visited 防御环。
///
/// 用户 fork 的会话只有 `parentSession` 而没有 `origin`，不得当子代理聚合。
SubagentRunAggregate subagentRunAggregate({
  required String sessionId,
  required Iterable<Session> sessions,
  required String Function(String sessionId) agentStatusOf,
}) {
  final childrenByParent = <String, List<Session>>{};
  for (final s in sessions) {
    if (s.origin != 'subagent') continue;
    final parent = s.parentSession;
    if (parent == null || parent.isEmpty) continue;
    childrenByParent.putIfAbsent(parent, () => <Session>[]).add(s);
  }
  if (childrenByParent.isEmpty) return SubagentRunAggregate.none;
  var running = false;
  final visited = <String>{sessionId};
  final queue = <String>[sessionId];
  while (queue.isNotEmpty) {
    final parent = queue.removeLast();
    for (final child in childrenByParent[parent] ?? const <Session>[]) {
      if (!visited.add(child.id)) continue;
      if (agentStatusOf(child.id) == 'running') {
        running = true;
        break;
      }
      queue.add(child.id);
    }
    if (running) break;
  }
  return SubagentRunAggregate(hasKnownChildren: true, running: running);
}

/// 该会话是否有递归运行中的子代理（聚合结果的便捷读法）。
bool hasRunningSubagentDescendant({
  required String sessionId,
  required Iterable<Session> sessions,
  required String Function(String sessionId) agentStatusOf,
}) => subagentRunAggregate(
  sessionId: sessionId,
  sessions: sessions,
  agentStatusOf: agentStatusOf,
).running;

/// 列表/首页面板共用的“运行中会话数”（issue #124/#133：面板计数必须与行同口径）。
///
/// 传 [rowStateOf]（通常是 `store.rowStateOf`）而不是直接读 agent 状态，保证
/// “根 idle + 子代理 running”的行在转时，面板计数不会显示 0。
int runningSessionCountOf(
  Iterable<Session> visible,
  SessionRowState Function(String sessionId) rowStateOf,
) => visible.where((s) => rowStateOf(s.id) == SessionRowState.running).length;

/// 状态标识的旋转是否需要 ticker 运行（ADR 0013 的动效生命周期）。
///
/// 只管**内容**维度：列表里确有运行中会话、且系统未要求减弱动态效果。
/// **不含页面可见性**——可见性由 [SessionIndicatorDriver] 自己持有并门控。
/// 早先把 visible 也算进这里，导致「可见」成了两个地方的状态：隐藏期间本函数返回
/// false 把 needed 置死，切回页签时只改 visible 而不重算 needed，动效就卡在静止态
/// （安静运行的会话可能长时间没有 store 通知，表现为"虚线不转"）。
bool shouldAnimateIndicators({
  required bool hasRunningSessions,
  required bool reducedMotion,
}) => hasRunningSessions && !reducedMotion;

// ── 子代理列表（issue #17）──
//
// 子代理本身就是**会话**（CONTEXT.md「子代理会话」），所以行状态直接复用上面
// 同一套 [sessionRowState]，不再发明第二套运行状态语义。
//
// 但**排序有意与会话列表不同**：会话列表用 lastMessageAt（"最近聊了什么"），
// 子代理列表用 createdAt 降序（"我最近派了什么"）。后者不随子代理干活而跳动，
// 顺序稳定可预期——这是刻意的不一致，勿"修正"为与会话列表相同。

/// 子代理条目的创建时间；缺失时返回 null（由调用方回退）。
int? subagentCreatedAt(Map<String, dynamic> entry) {
  final v = entry['createdAt'];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

/// 子代理排序：`createdAt` **降序**（最新派生在最上），等值按 id 升序保证稳定。
///
/// 时间缺失的条目排在最后（而不是最前）：缺字段是插件/旧数据的降级情况，
/// 不该因此抢占"最近派生"的位置。返回新列表，不修改入参。
List<Map<String, dynamic>> sortSubagentsForSheet(Iterable<Map<String, dynamic>> entries) {
  final list = entries.toList();
  list.sort((a, b) {
    final ta = subagentCreatedAt(a);
    final tb = subagentCreatedAt(b);
    if (ta != tb) {
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    }
    return (a['id'] as String? ?? '').compareTo(b['id'] as String? ?? '');
  });
  return list;
}
