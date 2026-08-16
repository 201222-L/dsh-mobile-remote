// DSH Remote — 手机远程操作 DeepSeek Harness
// 原生 App：抽屉导航（首页/会话/设置）+ 通知 + 连接配置 + 扫码连接。
// 界面与功能对齐网页端 dsh-mobile-remote（DeepSeek 配色，Claude 式布局）。
import 'package:flutter/material.dart';
import 'api.dart';
import 'store.dart';
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
            '界面异常：\n${details.exceptionAsString()}',
            style: const TextStyle(color: Color(0xFFE6E8EC), fontSize: 13),
          ),
        ),
      ),
    );
  };
  await api.load();
  await store.loadPrefs();
  runApp(const DshApp());
}

class DshApp extends StatefulWidget {
  const DshApp({super.key});

  @override
  State<DshApp> createState() => _DshAppState();
}

class _DshAppState extends State<DshApp> {
  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
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
      theme: DshTheme.light(),
      darkTheme: DshTheme.dark(),
      themeMode: mode,
      home: const RootScreen(),
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
      store.resume();
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

  void _openNotifications() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationsScreen(store: store, onOpenSession: () {
          if (mounted) setState(() => _index = 0);
        }),
      ),
    );
  }

  void _openNewSession() {
    showNewSessionSheet(context, store, (id) async {
      await store.setSession(id);
      store.refreshSessions();
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(store: store, onTitleChanged: () {}),
        ),
      );
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
    final titles = ['DSH', '会话', '设置'];
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
                  'connected' => '电脑在线',
                  'connecting' => '连接中…',
                  _ => '电脑离线 · 点按重连',
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
            onPressed: _openNotifications,
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
                      child: const Text('＋ 新建会话'),
                    ),
                  ],
                ),
              ),
              // 中间菜单区：可滚动 —— 工作区数量增多时，导航项（含「设置」）不再被挤出屏幕，
              // 也无需删除工作区才能进入设置区；头部（新建会话）与底部（连接状态）保持固定。
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(height: 4),
                    // 工作区快速切换（对齐 PC 端 workspace 切换；≥2 个工作区时显示）
                    if (store.workspaces.length >= 2) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                          '工作区',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: DshColors.ink3(context)),
                        ),
                      ),
                      _workspaceItem(null),
                      for (final w in store.workspaces) _workspaceItem(w),
                      const SizedBox(height: 8),
                    ],
                    _drawerItem(Icons.home_outlined, '首页', 0),
                    _drawerItem(Icons.history, '会话', 1),
                    _drawerItem(Icons.settings_outlined, '设置', 2),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '本机直连 · DeepSeek Harness',
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
    final title = isAll ? '全部工作区' : ((w['title'] as String?) ?? path);
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
      _status = '连接中…';
    });
    try {
      final probe = Api()
        ..baseUrl = base
        ..token = _tokenCtrl.text.trim();
      await probe.getJson('/api/bootstrap');
      await api.save(base: base, token: _tokenCtrl.text.trim());
      if (!mounted) return;
      setState(() => _status = '✅ 已连接');
      widget.onConnected();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '连接失败：$e');
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
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 重新配置时：放弃返回（旧配置保留，不会被清空）
            if (widget.onCancel != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('返回（保留原配置）', style: TextStyle(fontSize: 13)),
                ),
              ),
            Text('DSH Remote',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: scheme.primary)),
            const SizedBox(height: 6),
            Text('手机远程操作 DeepSeek Harness', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码连接'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Divider(color: scheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('或手动输入', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _baseCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '电脑地址',
                hintText: 'http://192.168.x.x:3080',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '访问口令',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _connect,
              child: Text(_busy ? '连接中…' : '连接'),
            ),
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
