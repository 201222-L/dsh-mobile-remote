// DSH Remote — 手机远程操作 DeepSeek Harness
// 原生 App：抽屉导航（首页/会话/设置）+ 通知 + 连接配置 + 扫码连接。
// 界面与功能对齐网页端 dsh-mobile-remote（DeepSeek 配色，Claude 式布局）。
import 'package:flutter/material.dart';
import 'api.dart';
import 'store.dart';
import 'theme.dart';
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
  // 全局错误边界：build/布局异常不再白屏或静默闪退，直接显示错误文本（调试用）
  ErrorWidget.builder = (details) {
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
  final _drawerKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configured = api.baseUrl.isNotEmpty && api.token.isNotEmpty;
    if (_configured) {
      _boot();
    }
  }

  @override
  void dispose() {
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
      if (_configured) _boot();
    });
  }

  Future<void> _reconfigure() async {
    await api.save(base: '', token: '');
    store.disposeBridge();
    if (mounted) _recheck();
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
    if (!_configured) {
      return Scaffold(
        body: ConnectionSheet(onConnected: _recheck),
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
        title: Text(
          titles[_index],
          style: TextStyle(
            fontSize: _index == 0 ? 20 : 17,
            fontWeight: FontWeight.w700,
            fontFamily: _index == 0 ? 'Georgia' : null,
          ),
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
              const SizedBox(height: 4),
              _drawerItem(Icons.home_outlined, '首页', 0),
              _drawerItem(Icons.history, '会话', 1),
              _drawerItem(Icons.settings_outlined, '设置', 2),
              const Spacer(),
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
}

/// 连接设置（首次进入/重新配置时显示）
class ConnectionSheet extends StatefulWidget {
  final VoidCallback onConnected;
  const ConnectionSheet({super.key, required this.onConnected});

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
