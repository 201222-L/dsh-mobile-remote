// 通知中心页（对齐网页端 notifications screen）
// 布局：SafeArea 避开状态栏；紧凑卡片；未读蓝点；三色图标层级；浅色分隔线。
import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'chat_screen.dart';

class NotificationsScreen extends StatefulWidget {
  final AppStore store;
  final VoidCallback onOpenSession;
  const NotificationsScreen({super.key, required this.store, required this.onOpenSession});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _items = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await api.notifications();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loaded = true;
      });
      widget.store.refreshNotifs();
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _open(AppNotification n) async {
    try {
      await api.markNotifsRead(ids: [n.id]);
      _refresh();
    } catch (_) {}
    await widget.store.setSession(n.sessionId);
    widget.store.refreshSessionConfig();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(store: widget.store, onTitleChanged: widget.onOpenSession),
      ),
    );
    widget.store.refreshSessions();
  }

  Future<void> _readAll() async {
    try {
      await api.markNotifsRead(all: true);
      _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text('已全部标记为已读')));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final brandSoft = DshColors.brandSoft(context);
    final brand = DshColors.brand(context);
    final ok = DshColors.ok(context);
    final danger = DshColors.danger(context);
    final warn = DshColors.warn(context);
    final unreadCount = _items.where((n) => n.unread).length;

    return Scaffold(
      backgroundColor: scheme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('通知', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          if (unreadCount > 0)
            TextButton(
              onPressed: _readAll,
              child: Text('全部已读', style: TextStyle(fontSize: 13, color: brand)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loaded && _items.isEmpty
                ? Center(child: Text('暂无通知', style: TextStyle(fontSize: 13, color: ink3)))
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => SizedBox(height: 8, child: Divider(height: 1, color: line.withValues(alpha: 0.5))),
                      itemBuilder: (context, i) {
                        final n = _items[i];
                        final (icon, color, bg) = switch (n.kind) {
                          'completed' => (Icons.check_circle_outline, ok, ok.withValues(alpha: 0.12)),
                          'failed' => (Icons.error_outline, danger, danger.withValues(alpha: 0.12)),
                          _ => (Icons.warning_amber_rounded, warn, warn.withValues(alpha: 0.12)),
                        };
                        final dt = DateTime.fromMillisecondsSinceEpoch(n.time).toLocal();
                        final tm = '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
                            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                        return Material(
                          color: n.unread ? brandSoft : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _open(n),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
                                    child: Icon(icon, size: 17, color: color),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          n.title,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: n.unread ? FontWeight.w600 : FontWeight.w500,
                                            color: scheme.colorScheme.onSurface,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (n.detail.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            n.detail,
                                            style: TextStyle(fontSize: 12, color: ink2, height: 1.4),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                        const SizedBox(height: 3),
                                        Text(tm, style: TextStyle(fontSize: 11, color: ink3)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // 未读蓝点
                                  Container(
                                    width: 8,
                                    height: 8,
                                    margin: const EdgeInsets.only(top: 5),
                                    decoration: BoxDecoration(
                                      color: n.unread ? brand : Colors.transparent,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}
