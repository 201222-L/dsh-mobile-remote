// 会话列表页（对齐网页端 sessions screen）
// 支持归档：主列表只显示活跃会话，长按可归档/恢复；顶部筛选切换已归档视图。
//
// v3.1.6（issue #14 / ADR 0013）：
// - 每行图标带状态标识：running 旋转虚线 / waiting 静态警示色虚线 / idle 无标记；
// - 子代理会话（origin === 'subagent'）不出现，用户 fork 出的会话正常显示；
// - 排序按最新消息时间（lastMessageAt），打开会话不再改变顺序；
// - 计数与可见条数同源（都取自过滤后的列表）。
import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n.dart';
import '../toast.dart';
import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../fmt.dart';
import '../widgets/session_indicator.dart';
import 'chat_screen.dart';

class SessionsScreen extends StatefulWidget {
  final AppStore store;
  final VoidCallback onOpenSession;

  /// 本页当前是否可见（IndexedStack 下三个页面同时活着，需显式告知以暂停动效）。
  final bool visible;
  const SessionsScreen({
    super.key,
    required this.store,
    required this.onOpenSession,
    this.visible = true,
  });

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen>
    with SingleTickerProviderStateMixin {
  bool _showArchived = false;
  late final SessionIndicatorDriver _indicator;

  @override
  void initState() {
    super.initState();
    // 每个列表页共享一个动画控制器，只在存在运行中会话时运行（ADR 0013）
    _indicator = SessionIndicatorDriver(vsync: this)
      ..setVisible(widget.visible);
    widget.store.addListener(_onStore);
    widget.store.refreshSessions();
    _syncIndicator();
  }

  @override
  void didUpdateWidget(SessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _indicator.setVisible(widget.visible);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    _indicator.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) {
      setState(() {});
      _syncIndicator();
    }
  }

  /// 只在「本页可见的列表里存在运行中会话」时启动旋转。
  void _syncIndicator() {
    _indicator.setNeeded(
      widget.store.hasRunningSessions(
        _showArchived
            ? widget.store.archivedSessions
            : widget.store.activeSessions,
      ),
    );
  }

  Future<void> _open(Session s) async {
    // Phase 2(A4)：统一打开会话流程（openChat 内 setSession+refreshSessionConfig+push）
    await openChat(context, widget.store, s.id,
        onTitleChanged: widget.onOpenSession,
        onReturn: () => widget.store.refreshSessions());
  }

  Future<void> _showActions(Session s) async {
    final isArchived = s.archived;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Text(
                s.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline, size: 20),
              title: Text(L10n.t('打开', 'Open'), style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('open'),
            ),
            ListTile(
              leading: Icon(isArchived ? Icons.unarchive_outlined : Icons.archive_outlined, size: 20),
              title: Text(isArchived ? L10n.t('恢复（取消归档）', 'Restore (unarchive)') : L10n.t('归档该会话', 'Archive this session'), style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop(isArchived ? 'unarchive' : 'archive'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'open') {
      await _open(s);
      return;
    }
    try {
      await api.archiveSession(s.id, archive: action == 'archive');
      // v2.7.1：乐观更新——本地立即生效（列表秒变），后台静默刷新校准
      // （服务端列表标题折叠 50+ 会话可达数秒，等它会让"归档要等几秒"）
      widget.store.applyArchiveLocally(s.id, archived: action == 'archive');
      unawaited(widget.store.refreshSessions());
      if (!mounted) return;
      showToast(context, action == 'archive' ? L10n.t('已归档', 'Archived') : L10n.t('已恢复', 'Restored'));
    } catch (e) {
      if (!mounted) return;
      // 失败回滚本地状态（刷新真实列表校准）
      unawaited(widget.store.refreshSessions());
      showToast(context, '${L10n.t('操作失败：', 'Operation failed:')}$e${L10n.t('（桌面端插件需要重启生效）', ' (restart the desktop plugin to take effect)')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final active = store.activeSessions;
    final archived = store.archivedSessions;
    final sessions = _showArchived ? archived : active;
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final reducedMotion = prefersReducedMotion(context);

    return Column(
      children: [
        // 工作区筛选（≥2 个工作区时显示，对齐 PC 端快速切换）
        if (store.workspaces.length >= 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Align(
              // 左对齐：与下方"活跃/已归档"行一致（默认 Column 居中导致观感怪异）
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FilterChip(
                      label: L10n.t('全部', 'All'),
                      selected: store.workspacePath == null,
                      onTap: () => store.setWorkspace(null),
                    ),
                    for (final w in store.workspaces) ...[
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: (w['title'] as String?) ?? (w['path'] as String? ?? ''),
                        // v3.1.1(issue #5)：原始路径做展示，规范化后与 workspacePath（归一存储）匹配
                        selected: store.workspacePath == AppStore.normPath(w['path'] as String? ?? ''),
                        onTap: () => store.setWorkspace(w['path'] as String?),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        // 活跃 / 已归档 筛选（计数与可见条数同源：都来自过滤后的列表）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Row(
            children: [
              _FilterChip(
                label: '${L10n.t('活跃', 'Active')} ${active.length}',
                selected: !_showArchived,
                onTap: () => setState(() {
                  _showArchived = false;
                  _syncIndicator();
                }),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: '${L10n.t('已归档', 'Archived')} ${archived.length}',
                selected: _showArchived,
                onTap: () => setState(() {
                  _showArchived = true;
                  _syncIndicator();
                }),
              ),
            ],
          ),
        ),
        if (_showArchived && archived.isEmpty)
          Expanded(
            child: Center(child: Text(L10n.t('暂无归档会话', 'No archived sessions'), style: TextStyle(fontSize: 13, color: ink3))),
          )
        else
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Text(L10n.t('暂无会话', 'No sessions'), style: TextStyle(fontSize: 13, color: ink3)),
                  )
                : RefreshIndicator(
                  onRefresh: () => widget.store.refreshSessions(),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => Divider(height: 1, color: line),
                    itemBuilder: (context, i) {
                      final s = sessions[i];
                      return InkWell(
                        // 稳定行标识：列表复用（回收重建）时动效状态不能跟错会话
                        key: ValueKey('session-row-${s.id}'),
                        onTap: () => _open(s),
                        onLongPress: () => _showActions(s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
                          child: Row(
                            children: [
                              SessionIcon(
                                state: store.rowStateOf(s.id),
                                archived: s.archived,
                                // 减弱动态效果：旋转降级为静态虚线（状态仍靠颜色可见）
                                animation: reducedMotion ? null : _indicator.animation,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                                    const SizedBox(height: 1),
                                    Text(
                                      // 显示时间与排序依据一致（sortKey = lastMessageAt 优先）
                                      '${relTime(s.sortKey)}${s.cwd != null ? ' · ${s.cwd}' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 11.5, color: ink2),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, size: 18, color: ink3),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? DshColors.brandSoft(context) : DshColors.surface(context),
          border: Border.all(color: selected ? DshColors.brand(context) : DshColors.line(context)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? DshColors.brand(context) : DshColors.ink2(context),
          ),
        ),
      ),
    );
  }
}
