// 首页：欢迎 + 最近会话 + 新建会话
import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n.dart';
import '../toast.dart';
import '../models.dart';
import '../session_list.dart';
import '../store.dart';
import '../theme.dart';
import '../fmt.dart';
import '../update_core.dart';
import '../update_flow.dart';
import '../widgets/session_indicator.dart';
import 'chat_screen.dart';
import 'sheets.dart';

class HomeScreen extends StatefulWidget {
  final AppStore store;
  final VoidCallback onOpenSession;

  /// 本页当前是否可见（IndexedStack 下三个页面同时活着，需显式告知以暂停动效）。
  final bool visible;
  const HomeScreen({
    super.key,
    required this.store,
    required this.onOpenSession,
    this.visible = true,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  // v3.0.0 review：新建会话弹层打开中标志（双击防抖）
  bool _openingSheet = false;
  late final SessionIndicatorDriver _indicator;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    // 与会话列表页共用同一个组件与同一套启停规则（ADR 0013：两处表现一致）
    _indicator = SessionIndicatorDriver(vsync: this)
      ..setVisible(widget.visible);
    widget.store.addListener(_onStore);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「减弱动态效果」跟随系统设置；这里同时承担首轮同步（此时才有 MediaQuery）
    _reducedMotion = prefersReducedMotion(context);
    _syncIndicator();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
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

  /// 与会话列表页共用同一条动效启停规则（session_list.dart）。
  /// 页面可见性由 driver 单独持有（setVisible），两者正交。
  void _syncIndicator() {
    _indicator.setNeeded(
      shouldAnimateIndicators(
        hasRunningSessions: widget.store.hasRunningSessions(
          widget.store.activeSessions,
        ),
        reducedMotion: _reducedMotion,
      ),
    );
  }

  Future<void> _openSession(Session s) async {
    // Phase 2(A4)：统一打开会话流程（openChat 内 setSession+refreshSessionConfig+push）
    await openChat(context, widget.store, s.id,
        onTitleChanged: widget.onOpenSession,
        onReturn: () => widget.store.refreshSessions());
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    // v3.1.6（issue #14）：与会话列表页共用同一份过滤 + 排序投影（隐藏子代理、按消息时间）
    final recent = store.activeSessions;
    final reducedMotion = prefersReducedMotion(context);

    return Column(
      children: [
        // 3.0.0+8 自动更新：启动静默检查命中后显示的「有新版本」横幅
        if (store.updateCandidate != null)
          _UpdateBanner(
            candidate: store.updateCandidate!,
            onUpdate: () {
              final c = store.updateCandidate;
              if (c != null) {
                // 取消/失败保留横幅（US22：直到更新或版本变更才消失）
                unawaited(runUpdateFlow(context, store, c, onInstalled: store.clearUpdateCandidate));
              }
            },
            onDismiss: () => store.clearUpdateCandidate(),
          ),
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
                                  if (recent.isEmpty)
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
                                        itemCount: recent.length,
                                        separatorBuilder: (_, _) => Divider(height: 1, color: line),
                                        itemBuilder: (context, i) => _SessionRow(
                                          // 稳定行标识：复用时不跟错会话的状态
                                          key: ValueKey('home-session-row-${recent[i].id}'),
                                          session: recent[i],
                                          workspace: store.workspaceLabelOf(recent[i]),
                                          state: store.rowStateOf(recent[i].id),
                                          indicator: reducedMotion ? null : _indicator.animation,
                                          onTap: () => _openSession(recent[i]),
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
                            // v3.0.0 review：双击防抖——连点会并行弹出两个新建会话弹层
                            onPressed: () {
                              if (_openingSheet) return;
                              _openingSheet = true;
                              showNewSessionSheet(context, store, (id) async {
                                // Phase 2(A4)：openChat 内统一 setSession+refreshSessionConfig+push，这里只刷列表
                                store.refreshSessions();
                                if (!context.mounted) return;
                                await openChat(context, store, id,
                                    onTitleChanged: widget.onOpenSession);
                              }).whenComplete(() => _openingSheet = false);
                            },
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
  final SessionRowState state;
  final Animation<double>? indicator;
  final VoidCallback onTap;
  const _SessionRow({
    super.key,
    required this.session,
    this.workspace,
    required this.state,
    this.indicator,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            // 与会话列表页共用同一个状态标识组件（此前后者是重复实现）
            SessionIcon(state: state, archived: session.archived, animation: indicator),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(session.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Text(relTime(session.sortKey), style: TextStyle(fontSize: 11.5, color: ink2)),
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
}

/// 3.0.0+8：自动更新「有新版本」横幅（顶部单行，可更新/可关闭）。
class _UpdateBanner extends StatelessWidget {
  final UpdateCandidate candidate;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.candidate, required this.onUpdate, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: DshColors.brandSoft(context),
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.system_update_alt, size: 18, color: Color(0xFF426EFE)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                L10n.t('发现新版本 v${candidate.version}（${candidate.source}）', 'New version v${candidate.version} (${candidate.source})'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onUpdate,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(L10n.t('更新', 'Update'), style: TextStyle(fontSize: 12, color: brand)),
            ),
            GestureDetector(
              onTap: onDismiss,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 15, color: Color(0xFF5C6470)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
