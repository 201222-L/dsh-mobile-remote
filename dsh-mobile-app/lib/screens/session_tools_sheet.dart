// 会话工具弹层（v2.7）：任务（后台任务）/ 子代理 / 目标 三个页签。
// 数据与 PC 端同源：任务走 session/jobs 帧 + /api/jobs；子代理/目标走插件端点。
import 'dart:async';

import 'package:flutter/material.dart';
import '../api.dart';
import '../fmt.dart';
import '../l10n.dart';
import '../session_list.dart';
import '../store.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets/session_indicator.dart';
import 'chat_screen.dart';

/// 打开会话工具面板。
///
/// [onTitleChanged] 由调用方（聊天页）透传：跳进子代理会话后，标题变化仍能同步到会话列表。
/// [apiClient] 仅供测试注入（与 `ChatScreen.apiClient` 同款）；生产路径传 null 即用全局 `api`。
void showSessionToolsSheet(BuildContext context, AppStore store, String sessionId,
    {VoidCallback? onTitleChanged, Api? apiClient}) {
  // 面板关闭与子会话跳转都挂在**调用方上下文**上——面板自己的 ctx 在 pop 之后就不能再用。
  final navigator = Navigator.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _SessionToolsSheet(
      store: store,
      sessionId: sessionId,
      apiClient: apiClient,
      // #11 复核补正：子代理行可点 → 跳到该子代理会话。
      // 走统一入口 openChat，返回时恢复原会话（与「分支」流程同款语义：顺路看一眼，不改主会话）。
      onOpenSubagent: (childId) {
        navigator.pop();
        unawaited(openChat(context, store, childId,
            onTitleChanged: onTitleChanged ?? () {},
            apiClient: apiClient,
            onReturn: () async {
          if (sessionId != childId) await store.setSession(sessionId);
        }));
      },
    ),
  );
}

class _SessionToolsSheet extends StatefulWidget {
  final AppStore store;
  final String sessionId;
  final void Function(String childSessionId) onOpenSubagent;
  final Api? apiClient;
  const _SessionToolsSheet({
    required this.store,
    required this.sessionId,
    required this.onOpenSubagent,
    this.apiClient,
  });

  @override
  State<_SessionToolsSheet> createState() => _SessionToolsSheetState();
}

class _SessionToolsSheetState extends State<_SessionToolsSheet> {
  @override
  Widget build(BuildContext context) {
    final ink3 = DshColors.ink3(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(L10n.t('会话工具', 'Session Tools'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              TabBar(
                labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                unselectedLabelStyle: TextStyle(fontSize: 13, color: ink3),
                labelColor: DshColors.brand(context),
                unselectedLabelColor: ink3,
                indicatorColor: DshColors.brand(context),
                tabs: [
                  Tab(text: L10n.t('任务', 'Jobs')),
                  Tab(text: L10n.t('子代理', 'Subagents')),
                  Tab(text: L10n.t('目标', 'Goal')),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _JobsTab(store: widget.store, sessionId: widget.sessionId),
                    _SubagentsTab(
                      sessionId: widget.sessionId,
                      onOpenSubagent: widget.onOpenSubagent,
                      store: widget.store,
                      apiClient: widget.apiClient,
                    ),
                    _GoalTab(sessionId: widget.sessionId, apiClient: widget.apiClient),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 任务页签 ──
class _JobsTab extends StatefulWidget {
  final AppStore store;
  final String sessionId;
  const _JobsTab({required this.store, required this.sessionId});

  @override
  State<_JobsTab> createState() => _JobsTabState();
}

class _JobsTabState extends State<_JobsTab> {
  List<Map<String, dynamic>>? _jobs;
  String? _error;
  // v3.0.0 review：取消任务在途锁（防连点重复请求/闪烁）
  bool _killBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // v2.7.2 review：弹层可下滑关闭,异步回调后必须防 setState-after-dispose
    if (!mounted) return;
    setState(() => _jobs = null);
    try {
      final list = await api.jobs(widget.sessionId);
      if (!mounted) return;
      setState(() => _jobs = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _kill(Map<String, dynamic> job) async {
    if (_killBusy) return;
    _killBusy = true;
    try {
      await api.jobKill(widget.sessionId, job['id'] as String? ?? '');
      if (mounted) showToast(context, L10n.t('已请求取消任务', 'Cancel requested'));
      if (mounted) _load();
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('取消失败：', 'Cancel failed: ')}$e');
    } finally {
      _killBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final ok = DshColors.ok(context);
    final warn = DshColors.warn(context);
    final danger = DshColors.danger(context);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${L10n.t('加载失败：', 'Failed to load: ')}$_error', style: TextStyle(fontSize: 12.5, color: ink2)),
            TextButton(onPressed: _load, child: Text(L10n.t('重试', 'Retry'))),
          ],
        ),
      );
    }
    final jobs = _jobs;
    if (jobs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (jobs.isEmpty) {
      return Center(child: Text(L10n.t('暂无任务', 'No jobs'), style: TextStyle(fontSize: 13, color: ink3)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        itemCount: jobs.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: line),
        itemBuilder: (context, i) {
          final j = jobs[i];
          final status = j['status'] as String? ?? '';
          final color = status == 'completed'
              ? ok
              : (status == 'running' || status == 'stopping')
                  ? warn
                  : (status == 'failed' ? danger : ink3);
          final label = (j['label'] as String? ?? j['id'] as String? ?? L10n.t('任务', 'Job')).toString();
          final kind = j['kind'] as String?;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        [if (kind != null && kind.isNotEmpty) kind, status].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: ink3),
                      ),
                    ],
                  ),
                ),
                if (status == 'running')
                  TextButton(
                    onPressed: () => _kill(j),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(L10n.t('取消', 'Cancel'), style: TextStyle(fontSize: 12, color: danger)),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── 子代理页签 ──
class _SubagentsTab extends StatefulWidget {
  final String sessionId;
  final void Function(String childSessionId) onOpenSubagent;
  final Api? apiClient;
  final AppStore store;
  const _SubagentsTab({
    required this.sessionId,
    required this.onOpenSubagent,
    required this.store,
    this.apiClient,
  });

  @override
  State<_SubagentsTab> createState() => _SubagentsTabState();
}

class _SubagentsTabState extends State<_SubagentsTab> with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>>? _subs;
  String? _error;
  // v3.0.0 review：中断在途锁（防连点重复请求/闪烁）
  bool _interruptBusy = false;
  // 与子代理行共用一个旋转 ticker（issue #17）：复用会话列表的动效契约，
  // 而不是每行各起一个动画。
  late final SessionIndicatorDriver _indicator = SessionIndicatorDriver(vsync: this);

  @override
  void initState() {
    super.initState();
    // store 变化（SSE 推送运行状态）时重绘行状态与"中断"按钮；列表顺序不受影响。
    widget.store.addListener(_onStoreChanged);
    _load();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _indicator.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _subs = null);
    try {
      final list = await (widget.apiClient ?? api).subagents(widget.sessionId);
      if (!mounted) return;
      setState(() => _subs = sortSubagentsForSheet(list));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _interrupt(String childId) async {
    if (_interruptBusy) return;
    _interruptBusy = true;
    try {
      await (widget.apiClient ?? api).subagentInterrupt(widget.sessionId, childId);
      if (mounted) showToast(context, L10n.t('已请求中断子代理', 'Interrupt requested'));
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('中断失败：', 'Interrupt failed: ')}$e');
    } finally {
      _interruptBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final danger = DshColors.danger(context);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${L10n.t('加载失败：', 'Failed to load: ')}$_error', style: TextStyle(fontSize: 12.5, color: ink2)),
            TextButton(onPressed: _load, child: Text(L10n.t('重试', 'Retry'))),
          ],
        ),
      );
    }
    final subs = _subs;
    if (subs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (subs.isEmpty) {
      return Center(child: Text(L10n.t('暂无子代理', 'No subagents'), style: TextStyle(fontSize: 13, color: ink3)));
    }
    // 有运行中的子代理才转（与列表页同一规则）；减弱动态效果时交回静态虚线。
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _indicator.setNeeded(
      shouldAnimateIndicators(
        hasRunningSessions: subs.any((s) => widget.store.rowStateOf(s['id'] as String? ?? '') == SessionRowState.running),
        reducedMotion: reducedMotion,
      ),
    );
    return RefreshIndicator(
      onRefresh: _load,
      // issue #17：按 createdAt 降序（最新派生在最上）。与会话列表的 lastMessageAt
      // 有意不同——子代理列表是"我最近派了什么"，不该因子代理干活而跳动。
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        itemCount: subs.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: line),
        itemBuilder: (context, i) {
          final s = subs[i];
          final id = (s['id'] as String? ?? '').toString();
          // 状态真源是 store（实时 SSE），不是 REST 的 activity：
          // 后者在休眠父会话下恒为 inactive，会与实时状态自相矛盾（issue #17）。
          final rowState = widget.store.rowStateOf(id);
          final createdAt = subagentCreatedAt(s);
          return InkWell(
            // v3.1.5（#11 复核补正）：整行可点 → 跳到该子代理会话；右侧箭头提示可进入。
            onTap: id.isEmpty ? null : () => widget.onOpenSubagent(id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  // 复用会话列表同一套方形虚线（running 旋转 / waiting 静态警示），
                  // 只把图标换成子代理自己的，避免第二套运行状态语义。
                  SessionIcon(
                    state: rowState,
                    archived: false,
                    size: 24,
                    iconSize: 16,
                    icon: Icons.polyline_outlined,
                    squircle: false,
                    animation: _indicator.animation,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (s['title'] as String? ?? id).toString(),
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          // 状态不再印英文 activity（改由指示器表达，避免与 store 冲突）；
                          // 时间与排序同源，让"为什么是这个顺序"自解释。
                          createdAt == null
                              ? id
                              : [id, relTime(createdAt)].join(' · '),
                          style: TextStyle(fontSize: 11.5, color: ink3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // 「中断」只在真的运行时可用——用 store 判定，与指示器同源。
                  if (rowState == SessionRowState.running)
                    TextButton(
                      onPressed: () => _interrupt(id),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(L10n.t('中断', 'Interrupt'), style: TextStyle(fontSize: 12, color: danger)),
                    ),
                  if (id.isNotEmpty) Icon(Icons.chevron_right, size: 18, color: ink3),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── 目标页签 ──
class _GoalTab extends StatefulWidget {
  final String sessionId;
  final Api? apiClient;
  const _GoalTab({required this.sessionId, this.apiClient});

  @override
  State<_GoalTab> createState() => _GoalTabState();
}

class _GoalTabState extends State<_GoalTab> {
  Map<String, dynamic>? _goal;
  String? _error;
  bool _loaded = false; // 区分「加载中」与「已加载但无目标」（goal 为 null 是合法状态）
  final _objCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _objCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loaded = false;
      _error = null;
    });
    try {
      final g = await (widget.apiClient ?? api).goal(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _goal = g;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _act(String action, {String? objective}) async {
    setState(() => _busy = true);
    try {
      await (widget.apiClient ?? api).goalAction(action, sessionId: widget.sessionId, objective: objective);
      if (mounted) showToast(context, '${L10n.t('已', '')}${action == 'create' ? L10n.t('创建', 'Created') : action}');
      if (action == 'create') _objCtrl.clear();
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('操作失败：', 'Action failed: ')}$e');
    } finally {
      // 无论成败都刷新：PC/目标驱动可能已改变状态（如轮次耗尽→受阻），UI 需反映真实情况
      // v2.7.2 review：弹层可下滑关闭,await 后必须防 setState-after-dispose
      if (mounted) await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final brand = DshColors.brand(context);
    final danger = DshColors.danger(context);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${L10n.t('加载失败：', 'Failed to load: ')}$_error', style: TextStyle(fontSize: 12.5, color: ink2)),
            TextButton(onPressed: _load, child: Text(L10n.t('重试', 'Retry'))),
          ],
        ),
      );
    }
    final goal = _goal;
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    // 内核 GoalView 状态字段是 phase（active/paused/blocked/complete）
    final phase = (goal?['phase'] as String? ?? '').toString();
    String phaseLabel(String p) => switch (p) {
          'active' => L10n.t('进行中', 'Active'),
          'paused' => L10n.t('已暂停', 'Paused'),
          'blocked' => L10n.t('受阻', 'Blocked'),
          'complete' => L10n.t('已完成', 'Complete'),
          _ => p,
        };
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (goal == null || goal.isEmpty) ...[
          Text(L10n.t('当前没有目标', 'No goal yet'), style: TextStyle(fontSize: 13, color: ink3)),
          const SizedBox(height: 10),
          TextField(
            controller: _objCtrl,
            style: const TextStyle(fontSize: 13.5),
            maxLines: 2,
            decoration: InputDecoration(
              hintText: L10n.t('输入目标…', 'Enter a goal…'),
              hintStyle: TextStyle(fontSize: 12.5, color: ink3),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line)),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : () => _act('create', objective: _objCtrl.text.trim()),
            child: Text(L10n.t('创建目标', 'Create Goal')),
          ),
        ] else ...[
          Text(
            (goal['objective'] as String? ?? '').toString(),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            [
              '${L10n.t('轮次 ', 'Rounds: ')}${(goal['roundsStarted'] as num?)?.toInt() ?? 0}/${(goal['maxGoalRounds'] as num?)?.toInt() ?? '∞'}',
              phaseLabel(phase),
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: ink3),
          ),
          if (phase == 'blocked' && goal['blockedReason'] is Map) ...[
            const SizedBox(height: 6),
            Text(
              ((goal['blockedReason'] as Map)['message'] as String? ?? '').toString(),
              style: TextStyle(fontSize: 11.5, color: danger),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _act(phase == 'paused' ? 'resume' : 'pause'),
                  child: Text(phase == 'paused' ? L10n.t('继续', 'Resume') : L10n.t('暂停', 'Pause'), style: TextStyle(fontSize: 13, color: brand)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _act('complete'),
                  child: Text(L10n.t('标记完成', 'Mark Complete'), style: TextStyle(fontSize: 13, color: danger)),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(L10n.t('目标与 PC 端同源（goal 服务）；修改即时生效。', 'Goal data is synced with the desktop app (goal service); changes take effect immediately.'), style: TextStyle(fontSize: 11, color: ink3)),
      ],
    );
  }
}
