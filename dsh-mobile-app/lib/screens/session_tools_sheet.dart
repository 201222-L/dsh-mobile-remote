// 会话工具弹层（v2.7）：任务（后台任务）/ 子代理 / 目标 三个页签。
// 数据与 PC 端同源：任务走 session/jobs 帧 + /api/jobs；子代理/目标走插件端点。
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../toast.dart';

void showSessionToolsSheet(BuildContext context, AppStore store, String sessionId) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _SessionToolsSheet(store: store, sessionId: sessionId),
  );
}

class _SessionToolsSheet extends StatefulWidget {
  final AppStore store;
  final String sessionId;
  const _SessionToolsSheet({required this.store, required this.sessionId});

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
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('会话工具', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              TabBar(
                labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                unselectedLabelStyle: TextStyle(fontSize: 13, color: ink3),
                labelColor: DshColors.brand(context),
                unselectedLabelColor: ink3,
                indicatorColor: DshColors.brand(context),
                tabs: const [
                  Tab(text: '任务'),
                  Tab(text: '子代理'),
                  Tab(text: '目标'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _JobsTab(store: widget.store, sessionId: widget.sessionId),
                    _SubagentsTab(sessionId: widget.sessionId),
                    _GoalTab(sessionId: widget.sessionId),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
    try {
      await api.jobKill(widget.sessionId, job['id'] as String? ?? '');
      if (mounted) showToast(context, '已请求取消任务');
      _load();
    } catch (e) {
      if (mounted) showToast(context, '取消失败：$e');
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
            Text('加载失败：$_error', style: TextStyle(fontSize: 12.5, color: ink2)),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final jobs = _jobs;
    if (jobs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (jobs.isEmpty) {
      return Center(child: Text('暂无任务', style: TextStyle(fontSize: 13, color: ink3)));
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
          final label = (j['label'] as String? ?? j['id'] as String? ?? '任务').toString();
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
                    child: Text('取消', style: TextStyle(fontSize: 12, color: danger)),
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
  const _SubagentsTab({required this.sessionId});

  @override
  State<_SubagentsTab> createState() => _SubagentsTabState();
}

class _SubagentsTabState extends State<_SubagentsTab> {
  List<Map<String, dynamic>>? _subs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _subs = null);
    try {
      final list = await api.subagents(widget.sessionId);
      if (!mounted) return;
      setState(() => _subs = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _interrupt(String childId) async {
    try {
      await api.subagentInterrupt(widget.sessionId, childId);
      if (mounted) showToast(context, '已请求中断子代理');
    } catch (e) {
      if (mounted) showToast(context, '中断失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final warn = DshColors.warn(context);
    final danger = DshColors.danger(context);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$_error', style: TextStyle(fontSize: 12.5, color: ink2)),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final subs = _subs;
    if (subs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (subs.isEmpty) {
      return Center(child: Text('暂无子代理', style: TextStyle(fontSize: 13, color: ink3)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        itemCount: subs.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: line),
        itemBuilder: (context, i) {
          final s = subs[i];
          final id = (s['id'] as String? ?? '').toString();
          final running = s['status'] == 'running';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.polyline_outlined, size: 16, color: warn),
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
                        [id, (s['status'] as String? ?? '').toString()].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: ink3),
                      ),
                    ],
                  ),
                ),
                if (running)
                  TextButton(
                    onPressed: () => _interrupt(id),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('中断', style: TextStyle(fontSize: 12, color: danger)),
                  ),
              ],
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
  const _GoalTab({required this.sessionId});

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
      final g = await api.goal(widget.sessionId);
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
      await api.goalAction(action, sessionId: widget.sessionId, objective: objective);
      if (mounted) showToast(context, '已${action == 'create' ? '创建' : action}');
      if (action == 'create') _objCtrl.clear();
    } catch (e) {
      if (mounted) showToast(context, '操作失败：$e');
    } finally {
      // 无论成败都刷新：PC/目标驱动可能已改变状态（如轮次耗尽→受阻），UI 需反映真实情况
      await _load();
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
            Text('加载失败：$_error', style: TextStyle(fontSize: 12.5, color: ink2)),
            TextButton(onPressed: _load, child: const Text('重试')),
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
          'active' => '进行中',
          'paused' => '已暂停',
          'blocked' => '受阻',
          'complete' => '已完成',
          _ => p,
        };
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (goal == null || goal.isEmpty) ...[
          Text('当前没有目标', style: TextStyle(fontSize: 13, color: ink3)),
          const SizedBox(height: 10),
          TextField(
            controller: _objCtrl,
            style: const TextStyle(fontSize: 13.5),
            maxLines: 2,
            decoration: InputDecoration(
              hintText: '输入目标…',
              hintStyle: TextStyle(fontSize: 12.5, color: ink3),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line)),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : () => _act('create', objective: _objCtrl.text.trim()),
            child: const Text('创建目标'),
          ),
        ] else ...[
          Text(
            (goal['objective'] as String? ?? '').toString(),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            [
              '轮次 ${(goal['roundsStarted'] as num?)?.toInt() ?? 0}/${(goal['maxGoalRounds'] as num?)?.toInt() ?? '∞'}',
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
                  child: Text(phase == 'paused' ? '继续' : '暂停', style: TextStyle(fontSize: 13, color: brand)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _act('complete'),
                  child: Text('标记完成', style: TextStyle(fontSize: 13, color: danger)),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text('目标与 PC 端同源（goal 服务）；修改即时生效。', style: TextStyle(fontSize: 11, color: ink3)),
      ],
    );
  }
}
