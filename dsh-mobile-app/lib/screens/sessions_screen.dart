// 会话列表页（对齐网页端 sessions screen）
// 支持归档：主列表只显示活跃会话，长按可归档/恢复；顶部筛选切换已归档视图。
import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'chat_screen.dart';

class SessionsScreen extends StatefulWidget {
  final AppStore store;
  final VoidCallback onOpenSession;
  const SessionsScreen({super.key, required this.store, required this.onOpenSession});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
    widget.store.refreshSessions();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  Future<void> _open(Session s) async {
    await widget.store.setSession(s.id);
    widget.store.refreshSessionConfig();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(store: widget.store, onTitleChanged: widget.onOpenSession),
      ),
    );
    widget.store.refreshSessions();
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
              title: const Text('打开', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('open'),
            ),
            ListTile(
              leading: Icon(isArchived ? Icons.unarchive_outlined : Icons.archive_outlined, size: 20),
              title: Text(isArchived ? '恢复（取消归档）' : '归档该会话', style: const TextStyle(fontSize: 14)),
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
      await widget.store.refreshSessions();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(action == 'archive' ? '已归档' : '已恢复')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('操作失败：$e（桌面端插件需要重启生效）')));
    }
  }

  String _relTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final sessions = _showArchived ? store.archivedSessions : store.activeSessions;
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final brand = DshColors.brand(context);

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
                      label: '全部',
                      selected: store.workspacePath == null,
                      onTap: () => store.setWorkspace(null),
                    ),
                    for (final w in store.workspaces) ...[
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: (w['title'] as String?) ?? (w['path'] as String? ?? ''),
                        selected: store.workspacePath == w['path'],
                        onTap: () => store.setWorkspace(w['path'] as String?),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        // 活跃 / 已归档 筛选
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Row(
            children: [
              _FilterChip(
                label: '活跃 ${store.activeSessions.length}',
                selected: !_showArchived,
                onTap: () => setState(() => _showArchived = false),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: '已归档 ${store.archivedSessions.length}',
                selected: _showArchived,
                onTap: () => setState(() => _showArchived = true),
              ),
            ],
          ),
        ),
        if (_showArchived && store.archivedSessions.isEmpty)
          Expanded(
            child: Center(child: Text('暂无归档会话', style: TextStyle(fontSize: 13, color: ink3))),
          )
        else
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Text('暂无会话', style: TextStyle(fontSize: 13, color: ink3)),
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
                        onTap: () => _open(s),
                        onLongPress: () => _showActions(s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: s.archived ? line : DshColors.brandSoft(context),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  s.archived ? Icons.archive_outlined : Icons.description_outlined,
                                  size: 15,
                                  color: s.archived ? ink2 : brand,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                                    const SizedBox(height: 1),
                                    Text(
                                      '${_relTime(s.sortKey)}${s.cwd != null ? ' · ${s.cwd}' : ''}',
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
