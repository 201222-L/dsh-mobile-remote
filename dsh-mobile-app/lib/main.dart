// DSH Remote — 手机远程操作 DeepSeek Harness
// 原生 App：抽屉导航（首页/会话/设置）+ 通知 + 连接配置 + 扫码连接。
// 界面与功能对齐网页端 dsh-mobile-remote（DeepSeek 配色，Claude 式布局）。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'l10n.dart';
import 'api.dart';
import 'store.dart';
import 'floating.dart';
import 'theme.dart';
import 'logger.dart';
import 'scan_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sessions_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/sheets.dart';

final AppStore store = AppStore();

/// 全局导航 key（悬浮球面板等跨页面入口用）。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Phase 2(A8)：打开通知页（抽屉/悬浮球/banner 三入口共用，可选"打开会话后"回调）。
void openNotificationsScreen({VoidCallback? onOpenSession}) {
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  nav.push(MaterialPageRoute(
    builder: (_) => NotificationsScreen(store: store, onOpenSession: onOpenSession ?? () {}),
  ));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.init();
  AppLog.instance.log('main: 启动，baseUrl=${api.baseUrl.isNotEmpty ? "已配置" : "空"}');
  // 全局错误边界：build/布局异常不再白屏或静默闪退，直接显示错误文本（调试用）
  ErrorWidget.builder = (details) {
    AppLog.instance.log('build 异常: ${details.exceptionAsString()}');
    return Material(
      color: const Color(0xFF0E1116),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            '${L10n.t('界面异常：', 'UI error:')}\n${details.exceptionAsString()}',
            style: const TextStyle(color: Color(0xFFE6E8EC), fontSize: 13),
          ),
        ),
      ),
    );
  };
  await api.load();
  await store.loadPrefs();
  // v2.7.1：启动即把余额预警配置同步给悬浮球（可能已在后台运行，判定以 App 端设置为准）
  unawaited(Floating.setBalanceAlert(store.balanceAlert, store.balanceThreshold));
  // v2.7.2：上次开过悬浮球 → 自动恢复服务（清理后台/重启 App 后无需手动重开）
  unawaited(store.restoreFloating());
  runApp(const DshApp());
}

class DshApp extends StatefulWidget {
  const DshApp({super.key});

  @override
  State<DshApp> createState() => _DshAppState();
}

class _DshAppState extends State<DshApp> {
  // v2.7.1：通知横幅全局状态（MaterialApp.builder 渲染在所有 route 之上；
  // 页面内 Stack 会被 push 的聊天页/通知页遮挡，OverlayEntry 又有 remove 残留 bug）
  int? _bannerCount;
  Timer? _bannerTimer;
  DateTime _lastBannerAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
    // 新增未读通知 → 全局顶部横幅
    store.onNewNotifications = _onNewNotifications;
    // 悬浮球迷你面板动作（原生 → Flutter）：打开会话 / 去充值
    const MethodChannel('dsh/floating').setMethodCallHandler((call) async {
      final nav = rootNavigatorKey.currentState;
      if (nav == null) return null;
      switch (call.method) {
        case 'openSessionRequested':
          final id = call.arguments as String?;
          if (id == null || id.isEmpty) break;
          await _handleFloatingAction('session:$id');
          break;
        case 'openChargeRequested':
          await _handleFloatingAction('charge');
          break;
        case 'openNotifsRequested':
          // 打开通知页（与抽屉入口同款：先切到首页再推通知页）
          await _handleFloatingAction('notifs');
          break;
      }
      return null;
    });
    // v2.7.2 review：冷启动面板动作兜底——Dart handler 注册晚于原生 deliver，
    // 首帧后主动拉取原生暂存的动作（可能已被 handler 消费，幂等）
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingFloatingAction());
  }

  /// 统一处理悬浮球面板动作（热启动 handler 与冷启动 consume 共用）。
  Future<void> _handleFloatingAction(String action) async {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    if (action.startsWith('session:')) {
      final id = action.substring(8);
      if (id.isEmpty) return;
      final prev = store.sessionId;
      // Phase 2(A4)：统一打开会话流程；返回后恢复原会话（悬浮球进入的会话页不改变主会话）
      await openChat(nav.context, store, id,
          onReturn: () async {
        if (prev != null && prev != id) await store.setSession(prev);
      });
    } else if (action == 'charge') {
      await launchUrl(
        Uri.parse(store.catalog?.rechargeUrl ?? 'https://platform.deepseek.com/top_up'),
        mode: LaunchMode.externalApplication,
      );
    } else if (action == 'notifs') {
      // 打开通知页（与抽屉入口同款：先切到首页再推通知页）
      await store.refreshNotifs();
      openNotificationsScreen();
    }
  }

  /// 冷启动兜底：拉取原生暂存的面板动作（configureFlutterEngine 投递时 Dart 侧可能未就绪）。
  Future<void> _consumePendingFloatingAction() async {
    final action = await Floating.consumeOpenPanel();
    if (action == null || action.isEmpty) return;
    AppLog.instance.log('Floating: 冷启动消费动作 $action');
    await _handleFloatingAction(action);
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  /// 新增未读通知横幅：顶部滑入，6 秒自动消失（可左右滑动手动关闭），点击跳通知页；10 秒内不重复。
  /// force=true（悬浮球跳转/回前台）时绕过防抖——"错过的也提醒"。
  void _onNewNotifications(int count, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastBannerAt).inSeconds < 10) {
      AppLog.instance.log('Banner: 防抖拦截（距上次 ${now.difference(_lastBannerAt).inSeconds}s）');
      return;
    }
    _lastBannerAt = now;
    _bannerTimer?.cancel();
    _bannerTimer = null;
    if (!mounted) return;
    setState(() => _bannerCount = count);
    AppLog.instance.log('Banner: 出现 count=$count');
    // v2.8.0：滞留 6 秒自动消失（可左右滑动手动关闭，所以敢放长）；同时更新未读基线防反复弹。
    _bannerTimer = Timer(const Duration(milliseconds: 6000), () {
      _bannerTimer = null;
      AppLog.instance.log('Banner: 到期 timer 触发');
      if (!mounted) return;
      setState(() => _bannerCount = null);
      store.markNotifsSeen();
      AppLog.instance.log('Banner: 到期清理完成');
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = switch (store.darkMode) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      theme: DshTheme.light(),
      darkTheme: DshTheme.dark(),
      themeMode: mode,
      home: const RootScreen(),
      // 全局横幅：渲染在 Navigator（所有 route）之上
      builder: (context, child) {
        final bannerCount = _bannerCount;
        if (bannerCount != null) {
          AppLog.instance.log('Banner: builder 渲染中 count=$bannerCount');
        }
        if (bannerCount == null) return child!;
        return Stack(
          children: [
            child!,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  // v2.8.0：左右滑动关闭横幅（Dismissible，横向双向）；滑掉即消失+清未读基线
                  child: Dismissible(
                    key: const ValueKey('notif-banner'),
                    direction: DismissDirection.horizontal,
                    onDismissed: (_) {
                      AppLog.instance.log('Banner: 滑动关闭');
                      _bannerTimer?.cancel();
                      _bannerTimer = null;
                      if (!mounted) return;
                      setState(() => _bannerCount = null);
                      store.markNotifsSeen();
                    },
                    child: Material(
                      color: Colors.transparent,
                      child: GestureDetector(
                        onTap: () {
                          AppLog.instance.log('Banner: 点击关闭');
                          _bannerTimer?.cancel();
                          _bannerTimer = null;
                          if (!mounted) return;
                          setState(() => _bannerCount = null);
                          store.markNotifsSeen();
                          // Phase 2(A8)：与抽屉/悬浮球入口共用通知页打开逻辑
                          openNotificationsScreen();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          decoration: BoxDecoration(
                            // 跟随主题：浅色=白底深字，深色=深底浅字
                            color: Theme.of(context).brightness == Brightness.dark ? DshTheme.surfaceDark : Colors.white,
                            borderRadius: BorderRadius.circular(DshTheme.radiusMd),
                            boxShadow: const [
                              BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
                            ],
                            border: Theme.of(context).brightness == Brightness.dark
                                ? null
                                : Border.all(color: DshColors.line(context)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.notifications_active, size: 17, color: DshColors.brand(context)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  L10n.t('有 $bannerCount 条新通知', '$bannerCount new notification${bannerCount > 1 ? 's' : ''}'),
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DshColors.ink(context)),
                                ),
                              ),
                              Icon(Icons.chevron_right, size: 16, color: DshColors.ink3(context)),
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
      },
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> with WidgetsBindingObserver {
  bool _configured = false;
  int _index = 0;
  bool _reconfiguring = false; // 重新配置进行中：显示连接页但保留旧配置，取消可回退
  final _drawerKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 全局状态变化（工作区切换、未读数、连接状态等）→ 重建自身（含抽屉），
    // 否则 const RootScreen 会被父级重建跳过，抽屉里的工作区选中态不会跟着变。
    store.addListener(_onStore);
    _configured = api.baseUrl.isNotEmpty && api.token.isNotEmpty;
    if (_configured) {
      _boot();
    }
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 回到前台：主动探测电脑端在线状态（PC 退出/恢复实时反映，无需清后台重进）
    if (state == AppLifecycleState.resumed && _configured) {
      store.resume().then((_) {
        // v2.7.1：错过的也提醒——悬浮球跳转/切回 App 时若有未读（后台期间错过的），
        // 强制弹横幅（绕过防抖；后台时横幅已触发过但用户没看到，基线已同步所以增量不触发）
        if (store.unread > 0) {
          store.onNewNotifications?.call(store.unread, force: true);
        }
      });
    }
  }

  void _boot() {
    store.connect();
    store.refreshAll();
    store.onSessionsChanged = () {
      if (mounted) setState(() {});
    };
  }

  void _recheck() {
    setState(() {
      _configured = api.baseUrl.isNotEmpty && api.token.isNotEmpty;
      _reconfiguring = false;
      if (_configured) _boot();
    });
  }

  Future<void> _reconfigure() async {
    // 修复：旧版在此立即清空已保存的连接信息，若用户未完成新配置就退出，
    // App 变成空配置永远连不上。现改为：进入连接页时保留旧配置，
    // 只有新配置保存成功才覆盖（连接页提供「返回」放弃操作）。
    store.disposeBridge();
    setState(() => _reconfiguring = true);
  }

  void _openNewSession() {
    showNewSessionSheet(context, store, (id) async {
      // Phase 2(A4)：openChat 内统一 setSession+refreshSessionConfig+push，这里只刷列表
      store.refreshSessions();
      if (!mounted) return;
      await openChat(context, store, id);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_configured || _reconfiguring) {
      return Scaffold(
        body: ConnectionSheet(
          onConnected: _recheck,
          // 重新配置时允许放弃：保留旧配置返回主界面
          onCancel: _reconfiguring
              ? () => setState(() => _reconfiguring = false)
              : null,
        ),
      );
    }
    final titles = ['DSH', L10n.t('会话', 'Sessions'), L10n.t('设置', 'Settings')];
    // 返回键：非首页 tab 按返回 → 先回首页；首页再按返回 → 退出 App
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) {
          setState(() => _index = 0);
        }
      },
      child: Scaffold(
      key: _drawerKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu, size: 20),
          onPressed: () => _drawerKey.currentState?.openDrawer(),
        ),
        // 去掉默认 16px 标题间距：状态点紧贴抽屉菜单按钮右侧
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 电脑在线状态点：贴靠抽屉图标；点按立即探测/重连，长按看状态文字
            Transform.translate(
              offset: const Offset(-6, 0), // 再向抽屉菜单靠近一点
              child: Tooltip(
                message: switch (store.connState) {
                  'connected' => L10n.t('电脑在线', 'PC online'),
                  'connecting' => L10n.t('连接中…', 'Connecting…'),
                  _ => L10n.t('电脑离线 · 点按重连', 'PC offline · tap to reconnect'),
                },
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => store.resume(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: switch (store.connState) {
                          'connected' => DshColors.ok(context),
                          'connecting' => DshColors.warn(context),
                          _ => DshColors.ink3(context),
                        },
                        shape: BoxShape.circle,
                        border: Border.all(color: DshColors.line(context), width: 1),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              titles[_index],
              style: TextStyle(
                fontSize: _index == 0 ? 20 : 17,
                fontWeight: FontWeight.w700,
                fontFamily: _index == 0 ? 'Georgia' : null,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: store.unread > 0,
              backgroundColor: DshColors.danger(context),
              label: Text(
                '${store.unread}',
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              child: const Icon(Icons.notifications_none, size: 20),
            ),
            onPressed: () => openNotificationsScreen(onOpenSession: () {
              // 通知页里打开会话后回到首页 tab（原抽屉入口行为）
              if (mounted) setState(() => _index = 0);
            }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      drawer: Drawer(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('DSH', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, fontFamily: 'Georgia')),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openNewSession();
                      },
                      child: Text(L10n.t('＋ 新建会话', '+ New Session')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // 工作区快速切换（对齐 PC 端 workspace 切换；≥2 个工作区时显示）
              // 封顶 35% 屏高 + 可滚动：工作区再多也不会把下方导航挤出屏幕
              if (store.workspaces.length >= 2) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text(
                    L10n.t('工作区', 'Workspaces'),
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: DshColors.ink3(context)),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.35),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _workspaceItem(null),
                      for (final w in store.workspaces) _workspaceItem(w),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              _drawerItem(Icons.home_outlined, L10n.t('首页', 'Home'), 0),
              _drawerItem(Icons.history, L10n.t('会话', 'Sessions'), 1),
              _drawerItem(Icons.settings_outlined, L10n.t('设置', 'Settings'), 2),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  L10n.t('本机直连 · DeepSeek Harness', 'Direct connection · DeepSeek Harness'),
                  style: TextStyle(fontSize: 12, color: DshColors.ink3(context)),
                ),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(store: store, onOpenSession: () {
            if (mounted) setState(() {});
          }),
          SessionsScreen(store: store, onOpenSession: () {
            if (mounted) setState(() {});
          }),
          SettingsScreen(store: store, onReconfigure: _reconfigure),
        ],
      ),
      ),
    );
  }

  Widget _drawerItem(IconData icon, String label, int index) {
    final brand = DshColors.brand(context);
    final brandSoft = DshColors.brandSoft(context);
    final ink2 = DshColors.ink2(context);
    final selected = _index == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          setState(() => _index = index);
          Navigator.of(context).pop();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: selected ? brandSoft : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: selected ? brand : ink2),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  color: selected ? brand : ink2,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  /// 工作区切换项（null = 全部工作区）。
  Widget _workspaceItem(Map<String, dynamic>? w) {
    final brand = DshColors.brand(context);
    final brandSoft = DshColors.brandSoft(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final isAll = w == null;
    final path = w?['path'] as String? ?? '';
    final title = isAll ? L10n.t('全部工作区', 'All Workspaces') : ((w['title'] as String?) ?? path);
    final selected = isAll ? store.workspacePath == null : store.workspacePath == path;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          store.setWorkspace(isAll ? null : path);
          Navigator.of(context).pop();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? brandSoft : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(isAll ? Icons.folder_open_outlined : Icons.folder_outlined, size: 18, color: selected ? brand : ink2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: selected ? brand : ink2,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                    if (!isAll)
                      Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: ink3)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check, size: 15, color: brand),
            ],
          ),
        ),
      ),
    );
  }
}

/// 连接设置（首次进入/重新配置时显示）
class ConnectionSheet extends StatefulWidget {
  final VoidCallback onConnected;
  /// 非空时显示「返回」按钮：放弃重新配置、保留旧配置返回主界面。
  final VoidCallback? onCancel;
  const ConnectionSheet({super.key, required this.onConnected, this.onCancel});

  @override
  State<ConnectionSheet> createState() => _ConnectionSheetState();
}

class _ConnectionSheetState extends State<ConnectionSheet> {
  final _baseCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (api.baseUrl.isNotEmpty) _baseCtrl.text = api.baseUrl;
    if (api.token.isNotEmpty) _tokenCtrl.text = api.token;
  }

  Future<void> _connect() async {
    var base = _baseCtrl.text.trim();
    if (!base.startsWith('http')) base = 'http://$base';
    base = base.replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/m')) base = base.substring(0, base.length - 2);
    setState(() {
      _busy = true;
      _status = L10n.t('连接中…', 'Connecting…');
    });
    try {
      // v3.0.0：探测客户端与 save() 同源的地址/路径规范化（防 /m 重复拼接 404）
      final probe = Api.forProbe(base, _tokenCtrl.text.trim());
      await probe.getJson('/api/bootstrap');
      await api.save(base: base, token: _tokenCtrl.text.trim());
      if (!mounted) return;
      setState(() => _status = L10n.t('✅ 已连接', '✅ Connected'));
      widget.onConnected();
    } catch (e) {
      if (!mounted) return;
      // v3.0.0：网络原因引导（MiUI 智能网络/蜂窝把局域网流量分流时会表现为超时或 404）
      final hint = L10n.t(
          '；请确认手机与电脑在同一 Wi-Fi，并关闭手机流量/智能网络后重试',
          '; make sure the phone is on the same Wi-Fi as the PC, and turn off mobile data / smart network switch');
      setState(() => _status = '${L10n.t('连接失败：', 'Connection failed:')}$e$hint');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onScanned(String base, String token) async {
    _baseCtrl.text = base;
    _tokenCtrl.text = token;
    if (mounted) Navigator.of(context).pop();
    await _connect();
  }

  Future<void> _scan() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ScanScreen(onScanned: _onScanned)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        children: [
          // 返回按钮固定在左上角（重新配置时可见，放弃保留原配置）
          if (widget.onCancel != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: IconButton(
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.arrow_back, size: 22),
                  tooltip: L10n.t('返回（保留原配置）', 'Back (keep current settings)'),
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                // 键盘弹出/小屏时表单可滚动，避免连接页溢出
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            Text('DSH Remote',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: scheme.primary)),
            const SizedBox(height: 6),
            Text(L10n.t('手机远程操作 DeepSeek Harness', 'Control DeepSeek Harness from your phone'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(L10n.t('扫码连接', 'Scan to Connect')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Divider(color: scheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(L10n.t('或手动输入', 'Or enter manually'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _baseCtrl,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: L10n.t('电脑地址', 'Computer Address'),
                hintText: 'http://192.168.x.x:3080',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L10n.t('访问口令', 'Token'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _connect,
              child: Text(_busy ? L10n.t('连接中…', 'Connecting…') : L10n.t('连接', 'Connect')),
            ),
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
