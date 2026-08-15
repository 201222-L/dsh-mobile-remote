// 会话列表页（对齐网页端 sessions screen）
import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    final sessions = widget.store.sessions;
    if (sessions.isEmpty) {
      return Center(
        child: Text('暂无会话', style: TextStyle(fontSize: 13, color: DshColors.ink3(context))),
      );
    }
    return RefreshIndicator(
      onRefresh: () => widget.store.refreshSessions(),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: sessions.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: DshColors.line(context)),
        itemBuilder: (context, i) {
          final s = sessions[i];
          final dt = DateTime.fromMillisecondsSinceEpoch(s.createdAt).toLocal();
          final time = '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          return InkWell(
            onTap: () => _open(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: DshColors.line(context),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.description_outlined, size: 15, color: DshColors.ink2(context)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                        const SizedBox(height: 1),
                        Text(
                          '$time${s.cwd != null ? ' · ${s.cwd}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: DshColors.ink2(context)),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: DshColors.ink3(context)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
