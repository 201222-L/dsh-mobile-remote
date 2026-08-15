// 通知中心页（对齐网页端 notifications screen）
// 布局：SafeArea 避开状态栏；紧凑卡片；未读蓝点；三色图标层级；浅色分隔线。
// 删除：长按单条删除；右上角垃圾桶 → 批量多选删除 / 清空全部（插件端 /notifications/delete）。
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
  bool _deleting = false;
  bool _selecting = false; // 批量删除选择模式
  final Set<String> _selected = {};

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
        // 已删除/新到的条目与选择集求交，防止残留选中
        final alive = items.map((n) => n.id).toSet();
        _selected.removeWhere((id) => !alive.contains(id));
        if (_items.isEmpty) _selecting = false;
      });
      widget.store.refreshNotifs();
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _open(AppNotification n) async {
    if (_selecting) {
      setState(() {
        if (!_selected.add(n.id)) _selected.remove(n.id);
      });
      return;
    }
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

  /// 删除通知记录（插件端执行；桌面端插件重启后新接口才可用）。
  Future<void> _delete({List<String>? ids, bool all = false}) async {
    if (_deleting) return;
    _deleting = true;
    try {
      await api.deleteNotifs(ids: ids, all: all);
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(all ? '已清空全部通知' : '已删除 ${ids?.length ?? 0} 条通知')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text('删除失败：请先重启电脑端 dsh 以启用删除接口')));
      }
    } finally {
      _deleting = false;
    }
  }

  /// 长按单条 → 删除该条。
  void _confirmDeleteOne(AppNotification n) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: DshColors.danger(context)),
              title: Text('删除这条通知', style: TextStyle(color: DshColors.danger(context), fontSize: 15)),
              onTap: () {
                Navigator.of(ctx).pop();
                _delete(ids: [n.id]);
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: DshColors.ink3(context)),
              title: const Text('取消', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  /// 右上角垃圾桶 → 批量多选 / 清空全部。
  void _showDeleteMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.checklist, color: DshColors.ink2(context)),
              title: const Text('批量删除…', style: TextStyle(fontSize: 15)),
              onTap: () {
                Navigator.of(ctx).pop();
                setState(() => _selecting = true);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.delete_sweep_outlined, color: DshColors.danger(context)),
              title: Text('清空全部通知', style: TextStyle(color: DshColors.danger(context), fontSize: 15)),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmClearAll();
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: DshColors.ink3(context)),
              title: const Text('取消', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmClearAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部通知', style: TextStyle(fontSize: 16)),
        content: const Text('将删除全部通知记录，此操作不可恢复。', style: TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _delete(all: true);
            },
            child: Text('清空', style: TextStyle(color: DshColors.danger(context))),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteSelected() {
    final n = _selected.length;
    if (n == 0) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除所选通知', style: TextStyle(fontSize: 16)),
        content: Text('将删除选中的 $n 条通知记录，此操作不可恢复。', style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _delete(ids: _selected.toList());
            },
            child: Text('删除', style: TextStyle(color: DshColors.danger(context))),
          ),
        ],
      ),
    );
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _items.length) {
        _selected.clear();
      } else {
        _selected.addAll(_items.map((n) => n.id));
      }
    });
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
    final allSelected = _selecting && _selected.length == _items.length;

    return Scaffold(
      backgroundColor: scheme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_selecting ? '已选 ${_selected.length} 条' : '通知',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          if (_selecting)
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(allSelected ? '取消全选' : '全选', style: TextStyle(fontSize: 13, color: brand)),
            ),
          if (_selecting)
            TextButton(
              onPressed: () => setState(() {
                _selecting = false;
                _selected.clear();
              }),
              child: Text('完成', style: TextStyle(fontSize: 13, color: ink2)),
            ),
          if (!_selecting && unreadCount > 0)
            TextButton(
              onPressed: _readAll,
              child: Text('全部已读', style: TextStyle(fontSize: 13, color: brand)),
            ),
          if (!_selecting && _loaded && _items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: _showDeleteMenu,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _loaded && _items.isEmpty
                  ? Center(child: Text('暂无通知', style: TextStyle(fontSize: 13, color: ink3)))
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
                        itemCount: _items.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: 8, child: Divider(height: 1, color: line.withValues(alpha: 0.5))),
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
                          final selected = _selected.contains(n.id);
                          return Material(
                            color: selected
                                ? brandSoft
                                : n.unread
                                    ? brandSoft
                                    : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _open(n),
                              onLongPress: _selecting
                                  ? null
                                  : () => _confirmDeleteOne(n),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_selecting) ...[
                                      Icon(
                                        selected ? Icons.check_circle : Icons.circle_outlined,
                                        size: 19,
                                        color: selected ? brand : ink3,
                                      ),
                                      const SizedBox(width: 10),
                                    ],
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
            // 批量删除底部操作条
            if (_selecting)
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  decoration: BoxDecoration(
                    color: scheme.scaffoldBackgroundColor,
                    border: Border(top: BorderSide(color: line)),
                  ),
                  child: Row(
                    children: [
                      Text('已选 ${_selected.length} 条', style: TextStyle(fontSize: 13, color: ink2)),
                      const Spacer(),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: danger,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                        ),
                        onPressed: _selected.isEmpty || _deleting ? null : _confirmDeleteSelected,
                        child: Text(_deleting ? '删除中…' : '删除所选', style: const TextStyle(fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
