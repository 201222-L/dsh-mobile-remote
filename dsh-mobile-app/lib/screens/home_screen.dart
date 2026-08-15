// 首页：欢迎 + 最近会话 + 新建会话 + 底部 composer（模型/权限 pills）
import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'sheets.dart';

class HomeScreen extends StatefulWidget {
  final AppStore store;
  final VoidCallback onOpenSession;
  const HomeScreen({super.key, required this.store, required this.onOpenSession});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _inputCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    _inputCtrl.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  String _permName(String? id) => switch (id) {
        'read-only' => 'Read Only',
        'workspace-write' => 'Workspace Write',
        'danger-full-access' => 'Danger Full Access',
        _ => '权限',
      };

  Future<void> _sendFromHome() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final store = widget.store;
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    _inputCtrl.clear();
    try {
      if (store.sessionId == null) {
        final created = await api.createSession({
          'preset': store.catalog?.defaults['agentPreset'] ?? 'standard',
        });
        await store.setSession(created['sessionId'] as String);
        store.refreshSessions();
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(store: store, initialSend: text, onTitleChanged: widget.onOpenSession),
        ),
      );
      store.refreshSessions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openSession(Session s) async {
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
    final store = widget.store;
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final brand = DshColors.brand(context);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              const SizedBox(height: 16),
              // 欢迎
              Text(
                '有什么需要\nHarness 帮忙的？',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 30,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Georgia',
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: switch (store.connState) {
                        'connected' => DshColors.ok(context),
                        'connecting' => DshColors.warn(context),
                        _ => DshColors.ink3(context),
                      },
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    switch (store.connState) {
                      'connected' => '电脑在线',
                      'connecting' => '连接中…',
                      _ => '电脑离线 · 自动重连',
                    },
                    style: TextStyle(fontSize: 13, color: ink2),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // 最近会话卡
              Container(
                decoration: BoxDecoration(
                  color: DshColors.surface(context),
                  borderRadius: BorderRadius.circular(DshTheme.radiusMd),
                  boxShadow: Theme.of(context).brightness == Brightness.dark ? DshTheme.shadowDark : DshTheme.shadow,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 2),
                        child: Text(
                          '最近会话',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                            color: ink3,
                          ),
                        ),
                      ),
                      if (store.sessions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text('暂无会话，点下方新建', style: TextStyle(color: Colors.grey))),
                        )
                      else
                        for (var i = 0; i < store.sessions.take(3).length; i++) ...[
                          if (i > 0) Divider(height: 1, color: line),
                          _SessionRow(
                            session: store.sessions[i],
                            onTap: () => _openSession(store.sessions[i]),
                          ),
                        ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 新建会话
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                onPressed: () => showNewSessionSheet(context, store, (id) async {
                  await store.setSession(id);
                  store.refreshSessions();
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(store: store, onTitleChanged: widget.onOpenSession),
                    ),
                  );
                }),
                child: const Text('＋ 新建会话'),
              ),
              const SizedBox(height: 8),
              Text(
                store.catalog == null ? '' : '构建 v2.1',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: ink3),
              ),
            ],
          ),
        ),
        // 底部 composer
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
              decoration: BoxDecoration(
                color: DshColors.surface(context),
                borderRadius: BorderRadius.circular(20),
                boxShadow: Theme.of(context).brightness == Brightness.dark ? DshTheme.shadowDark : DshTheme.shadow,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // pills
                  SizedBox(
                    height: 28,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _Pill(
                          label: store.sessionConfig.model ?? '选择模型',
                          onTap: () => showModelSheet(context, store),
                        ),
                        const SizedBox(width: 6),
                        _Pill(
                          label: _permName(store.sessionConfig.permissionPreset),
                          onTap: () => showPermSheet(context, store),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputCtrl,
                          minLines: 1,
                          maxLines: 4,
                          style: const TextStyle(fontSize: 14.5),
                          decoration: InputDecoration(
                            hintText: '给 agent 发消息…',
                            hintStyle: TextStyle(color: ink3),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onSubmitted: (_) => _sendFromHome(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _SendButton(
                        onTap: _sending ? null : _sendFromHome,
                        color: brand,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;
  const _SessionRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final dt = DateTime.fromMillisecondsSinceEpoch(session.createdAt).toLocal();
    final time = '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.description_outlined, size: 15, color: ink2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(session.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 1),
                  Text(time, style: TextStyle(fontSize: 11.5, color: ink2)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: ink3),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Pill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ink2)),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final VoidCallback? onTap;
  final Color color;
  const _SendButton({required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)),
        child: const Icon(Icons.arrow_upward, size: 17, color: Colors.white),
      ),
    );
  }
}
