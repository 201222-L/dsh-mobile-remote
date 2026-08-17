// 首页：欢迎 + 最近会话 + 新建会话
import 'package:flutter/material.dart';
import '../l10n.dart';
import '../toast.dart';
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
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
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
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);

    return Column(
      children: [
        Expanded(
          // 下拉刷新：探测 → 自愈（轮换地址/重建连接）→ 拉数据；仅失败时提示
          child: RefreshIndicator(
            onRefresh: () async {
              final ok = await widget.store.refreshAll();
              if (!ok && context.mounted) {
                showToast(context, L10n.t('电脑连接不上，正在自动重连…', 'Cannot reach your PC, reconnecting…'));
              }
            },
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                // 内容不满一屏时整体垂直居中（去掉底部输入框后主页不再空底）；
                // alignment.y=-0.6 让内容块明显偏上（logo 贴近顶部，下半留白）
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: const Alignment(0, -0.6),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 官方 logo（DeepSeek 官网 favicon 转 PNG，蓝鲸标志）
                          Image.asset(
                            'assets/deepseek-logo.png',
                            width: 84,
                            height: 84,
                          ),
                          const SizedBox(height: 10),
                          // 欢迎
                          Text(
                            L10n.t('今天打算设计什么？', 'What are you designing today?'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 30,
                              height: 1.35,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Georgia',
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 24),
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
                                      store.workspaceTitle != null ? '${L10n.t('最近会话', 'Recent Sessions')} · ${store.workspaceTitle}' : L10n.t('最近会话', 'Recent Sessions'),
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.5,
                                        color: ink3,
                                      ),
                                    ),
                                  ),
                                  if (store.activeSessions.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 24),
                                      child: Center(child: Text(L10n.t('暂无会话，点下方新建', 'No sessions yet, create one below'), style: const TextStyle(color: Colors.grey))),
                                    )
                                  else
                                    // 恰好完整显示 3 行（约 3×52+分隔线），第 4 行露边提示可滑动
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxHeight: 176),
                                      child: ListView.separated(
                                        shrinkWrap: true,
                                        padding: EdgeInsets.zero,
                                        itemCount: store.activeSessions.length,
                                        separatorBuilder: (_, _) => Divider(height: 1, color: line),
                                        itemBuilder: (context, i) => _SessionRow(
                                          session: store.activeSessions[i],
                                          workspace: store.workspaceLabelOf(store.activeSessions[i]),
                                          onTap: () => _openSession(store.activeSessions[i]),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
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
                            child: Text(L10n.t('＋ 新建会话', '+ New Session')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
  final String? workspace; // 所属工作区标题（null = 无工作区概念，不显示）
  final VoidCallback onTap;
  const _SessionRow({required this.session, this.workspace, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
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
                  Row(
                    children: [
                      Text(_relTime(session.sortKey), style: TextStyle(fontSize: 11.5, color: ink2)),
                      // 所属工作区小字标注（与 PC 端分组同源）；长标题省略号防溢出
                      if (workspace != null) ...[
                        Text(' · ', style: TextStyle(fontSize: 11, color: ink3)),
                        Icon(Icons.folder_outlined, size: 11, color: ink3),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            workspace!,
                            style: TextStyle(fontSize: 11, color: ink3),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: ink3),
          ],
        ),
      ),
    );
  }

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期。
  String _relTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return L10n.t('刚刚', 'Just now');
    if (diff.inHours < 1) return '${diff.inMinutes}${L10n.t(' 分钟前', ' min ago')}';
    if (diff.inDays < 1) return '${diff.inHours}${L10n.t(' 小时前', ' hr ago')}';
    if (diff.inDays < 7) return '${diff.inDays}${L10n.t(' 天前', ' d ago')}';
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
