// 首页：欢迎 + 最近会话 + 新建会话
import 'package:flutter/material.dart';
import '../l10n.dart';
import '../toast.dart';
import '../models.dart';
import '../session_list.dart';
import '../store.dart';
import '../theme.dart';
import '../fmt.dart';
import '../widgets/dsh_dynamic_background.dart';
import '../widgets/home_pet.dart';
import '../widgets/session_indicator.dart';
import 'chat_screen.dart';
import 'sheets.dart';
import 'usage_screen.dart';

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

  /// 大肥鱼皮肤的首页 Hero：左边一句问候，右边角色（点她/长按都会回应）。
  Widget _bigFishHero(BuildContext context) {
    final en = L10n.lang == 'en';
    final skin = DshColors.skin(context);
    final (String kicker, String title, String sub) = switch (skin) {
      DshSkin.abyss => (
          'ABYSS NIGHT / 01',
          en ? 'What are we writing tonight?' : '今晚写点什么？',
          en ? 'Below the surface, nobody is rushing you.' : '海面以下，没人催你。',
        ),
      DshSkin.soda => (
          'SODA POP / 02',
          en ? "Drop today's idea into the soda." : '把想法丢进汽水里。',
          en ? 'Fizz fizz — it will pop up soon.' : '咕嘟咕嘟，一会儿就冒出来。',
        ),
      DshSkin.whale => (
          'WHALE FALL / 03',
          en ? 'Take your time, in the star sea.' : '在星海里，慢慢想。',
          en ? 'No idea is fine. Drift with me.' : '想不出来也没关系，我陪你漂一会儿。',
        ),
      DshSkin.dsh => (
          'DEEP SEA / 00',
          en ? 'What are you designing today?' : '今天打算设计什么？',
          '',
        ),
    };
    return SizedBox(
      height: 224,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 2,
            top: 6,
            right: 168,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kicker,
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.8,
                    fontWeight: FontWeight.w700,
                    color: DshColors.accent(context),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 27,
                    height: 1.16,
                    fontWeight: FontWeight.w700,
                    color: DshColors.ink(context),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: DshColors.ink2(context),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: -8,
            bottom: 4,
            child: HomePet(
              store: widget.store,
              // 固定 132dp：不跟随桌面宠物大小设置，避免首页角色跟着变大变糊
              height: 132,
              onLongPress: () => _openPetPanel(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 长按角色 → 迷你面板（运行中的会话 / 未读通知 / 桌面宠物状态 + 用量入口）。
  Future<void> _openPetPanel(BuildContext context) async {
    final store = widget.store;
    final en = L10n.lang == 'en';
    final running = store.activeSessions
        .where((s) => store.agentStatusForSession(s.id) == 'running')
        .length;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ClipOval(
                      child: Image.asset(
                        'assets/pet/static-idle.png',
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, -0.25),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'DSH 大肥鱼',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: DshColors.ink(ctx),
                            ),
                          ),
                          Text(
                            en ? 'Idle · waiting for a new task' : '空闲 · 我在这儿等新任务哦',
                            style: TextStyle(fontSize: 11, color: DshColors.ink2(ctx)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(height: 1, color: DshColors.line(ctx)),
                _petPanelRow(ctx, en ? 'Running sessions' : '运行中的会话',
                    running == 0 ? (en ? 'None' : '暂无运行中的会话') : '$running'),
                _petPanelRow(ctx, en ? 'Unread notifications' : '最近通知',
                    store.unread == 0 ? (en ? 'None' : '暂无通知') : '${store.unread}'),
                _petPanelRow(ctx, en ? 'Desktop pet' : '桌面宠物',
                    store.floatingEnabled ? (en ? 'On' : '已开启') : (en ? 'Off' : '未开启')),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => UsageScreen(store: store),
                    ));
                  },
                  child: Text(en ? 'Usage & balance' : '用量与额度'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _petPanelRow(BuildContext c, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: DshColors.ink2(c))),
          const Spacer(),
          Text(value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: DshColors.ink(c),
              )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    // v3.1.6（issue #14）：与会话列表页共用同一份过滤 + 排序投影（隐藏子代理、按消息时间）
    final recent = store.activeSessions;
    final reducedMotion = prefersReducedMotion(context);
    final bigFish = DshColors.skin(context).isBigFish;

    final body = Column(
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
                    alignment: bigFish ? const Alignment(0, -0.35) : const Alignment(0, -0.6),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (bigFish) ...[
                            _bigFishHero(context),
                            const SizedBox(height: 18),
                          ] else ...[
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
                          ],
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
                          if (bigFish) ...[
                            const SizedBox(height: 16),
                            Center(
                              child: Text(
                                L10n.t(
                                  '点她、戳她，或长按打开面板',
                                  'Tap, poke, or long-press the pet',
                                ),
                                style: TextStyle(fontSize: 10.5, color: ink3),
                              ),
                            ),
                          ],
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
    if (!bigFish) return body;
    // 大肥鱼皮肤：动态背景铺在内容下方，角色再叠在背景之上（内容层不拦背景触摸）
    return Stack(
      children: [
        DshDynamicBackground(store: store, visible: widget.visible),
        Positioned.fill(child: body),
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
