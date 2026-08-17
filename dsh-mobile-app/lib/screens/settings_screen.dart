// 设置页（对齐网页端 settings screen）：连接/默认配置/账户/显示/关于
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../l10n.dart';
import '../logger.dart';
import '../store.dart';
import '../theme.dart';
import '../toast.dart';
import 'sheets.dart';
import 'providers_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AppStore store;
  final Future<void> Function() onReconfigure;
  const SettingsScreen({super.key, required this.store, required this.onReconfigure});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _balance;
  String? _balanceError; // 余额查询失败的错误（build 时动态显示）
  bool _busy = false; // 余额刷新中（刷新按钮转圈）
  Map<String, dynamic>? _diag;
  bool _diagLoaded = false;
  String _diagTime = '';
  String _appVersion = ''; // App 自身版本（package_info_plus，构建时打包）

  @override
  void initState() {
    super.initState();
    _refreshBalance();
    _loadAppVersion();
    // 连接状态等 store 变化实时刷新（修复：旧版离开页面重进才能看到状态更新）
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      // 读取失败时版本行显示 App 端为「…」
    }
  }

  /// 手动切换连接地址（回家想切回局域网 / 出门想切蒲公英时用）。
  Future<void> _pickAddress() async {
    final candidates = api.baseUrls;
    if (candidates.isEmpty) return;
    final current = api.baseUrl;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Text(L10n.t('选择连接地址', 'Choose address'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            // 候选地址随使用动态累积（局域网/组网/历史地址），列表区可滚动防溢出
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in candidates)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        c == current ? Icons.check_circle : Icons.circle_outlined,
                        size: 18,
                        color: c == current ? DshColors.brand(context) : DshColors.ink3(context),
                      ),
                      title: Text(c, style: TextStyle(fontSize: 13.5, color: c == current ? DshColors.brand(context) : null)),
                      onTap: () => Navigator.of(ctx).pop(c),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (choice == null || choice == current || !mounted) return;
    final err = await widget.store.switchBase(choice);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(err),
          duration: const Duration(milliseconds: 2000),
          behavior: SnackBarBehavior.floating,
        ));
    } else {
      showToast(context, L10n.t('已切换 → ', 'Switched to ') + choice);
    }
  }

  Future<void> _refreshBalance() async {
    setState(() => _busy = true);
    try {
      final b = await api.balanceInfo();
      if (!mounted) return;
      setState(() => _balance = b);
    } catch (e) {
      if (!mounted) return;
      // 查询失败：记住错误，build 里动态显示（语言切换后也能正确翻译）
      _balanceError = '$e';
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 余额状态行（build 时求值：语言切换后即时换语言）。
  String get _balanceLabel {
    if (_busy) return L10n.t('查询中…', 'Loading…');
    if (_balanceError != null) return '${L10n.t('查询失败：', 'Failed: ')}$_balanceError';
    final b = _balance;
    if (b == null) return L10n.t('无数据', 'No data');
    return '${L10n.t('实时 · 币种 ', 'Live · ')}${b['currency']}${b['available'] == false ? L10n.t(' · 不可用', ' · unavailable') : ''}';
  }

  Future<void> _loadDiag() async {
    try {
      final d = await api.diagnostics();
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        _diag = d;
        _diagLoaded = true;
        _diagTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      });
    } catch (e) {
      // 刷新失败：清空旧数据，明确显示「检测失败」而非静默展示过期结果
      if (!mounted) return;
      setState(() {
        _diag = null;
        _diagTime = '';
      });
      AppLog.instance.log('环境诊断失败: $e');
    }
  }

  String get _diagText {
    final d = _diag;
    if (d == null) return L10n.t('检测失败', 'Check failed');
    final buf = StringBuffer();
    final runtime = d['runtime'] as Map<String, dynamic>? ?? {};
    buf.writeln('${L10n.t('运行形态: ', 'Mode: ')}${runtime['form']}${runtime['authEnabled'] == true ? L10n.t(' · 口令已启用', ' · auth on') : L10n.t(' · 口令未启用', ' · auth off')}');
    buf.writeln('${L10n.t('监听: ', 'Listen: ')}${runtime['host']}:${runtime['port']}');
    buf.writeln('${L10n.t('进程目录: ', 'CWD: ')}${runtime['cwd']}');
    buf.writeln();
    final services = d['services'] as Map<String, dynamic>? ?? {};
    buf.writeln(L10n.t('服务:', 'Services:'));
    services.forEach((k, v) => buf.writeln('  ${v == true ? '✅' : '❌'} $k'));
    buf.writeln();
    final checks = d['checks'] as Map<String, dynamic>? ?? {};
    buf.writeln(L10n.t('端点实测:', 'Endpoint checks:'));
    checks.forEach((k, v) {
      if (v is num) {
        // 计数字段（如 pendingFrames 挂起待答数）：0 正常，>0 表示有问询/审批待处理
        buf.writeln('  ${v == 0 ? '✅' : '⚠'} $k = $v');
      } else {
        buf.writeln('  ${v == true ? '✅' : '❌'} $k');
      }
    });
    final plugin = d['plugin'] as Map<String, dynamic>? ?? {};
    buf.writeln();
    buf.writeln('${L10n.t('插件: ', 'Plugin: ')}${plugin['name']} v${plugin['version']}');
    return buf.toString();
  }

  Widget _card(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(DshTheme.radiusMd),
        boxShadow: Theme.of(context).brightness == Brightness.dark ? DshTheme.shadowDark : DshTheme.shadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text(
                title.toUpperCase(),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: DshColors.ink3(context),
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row({required Widget leading, required String title, String? sub, Widget? trailing, VoidCallback? onTap}) {
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line, width: 1))),
        child: Row(
          children: [
            Icon(leading is Icon ? leading.icon : Icons.circle, size: 15, color: ink3),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14)),
                  if (sub != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(sub, style: TextStyle(fontSize: 11, color: ink3)),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[trailing],
            if (onTap != null) Icon(Icons.chevron_right, size: 16, color: ink3),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final ink3 = DshColors.ink3(context);
    final brand = DshColors.brand(context);
    final ok = DshColors.ok(context);
    final warn = DshColors.warn(context);

    String permName(String? id) => switch (id) {
          'read-only' => 'Read Only',
          'workspace-write' => 'Workspace Write',
          'danger-full-access' => 'Danger Full Access',
          _ => '…',
        };
    String presetName(String? id) => switch (id) {
          'standard' => L10n.t('标准模式', 'Standard'),
          'code' => L10n.t('PTC 模式', 'PTC'),
          'minimal' => L10n.t('极简模式', 'Minimal'),
          'cordis' => L10n.t('创造模式', 'Creative'),
          _ => '…',
        };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(L10n.t('连接', 'Connection'), [
          _row(
            leading: const Icon(Icons.computer_outlined),
            title: L10n.t('电脑地址', 'PC address'),
            sub: api.baseUrls.length > 1
                ? L10n.t('${api.baseUrl} · 共 ${api.baseUrls.length} 个地址自动切换 · 点按手动切换',
                    '${api.baseUrl} · ${api.baseUrls.length} addresses · tap to switch')
                : api.baseUrl,
            onTap: () => _pickAddress(),
            // 连接状态实时显示（修复：旧版写死「已连接」，断线也显示绿色已连接）
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: switch (store.connState) {
                      'connected' => ok,
                      'connecting' => warn,
                      _ => ink3,
                    },
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  switch (store.connState) {
                    'connected' => L10n.t('已连接', 'Connected'),
                    'connecting' => L10n.t('连接中…', 'Connecting…'),
                    _ => L10n.t('离线 · 自动重连', 'Offline · reconnecting'),
                  },
                  style: TextStyle(
                    fontSize: 12,
                    color: switch (store.connState) {
                      'connected' => ok,
                      'connecting' => warn,
                      _ => ink3,
                    },
                  ),
                ),
              ],
            ),
          ),
          _row(
            leading: const Icon(Icons.settings_outlined),
            title: L10n.t('重新配置连接', 'Reconfigure connection'),
            sub: L10n.t('更换电脑地址或访问口令', 'Change PC address or token'),
            trailing: Text(L10n.t('配置 ▸', 'Configure ▸'), style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => widget.onReconfigure(),
          ),
        ]),
        _card(L10n.t('默认配置', 'Defaults'), [
          _row(
            leading: const Icon(Icons.security_outlined),
            title: L10n.t('默认权限预设', 'Default permission'),
            sub: L10n.t('作用于之后新建的会话', 'Applies to new sessions'),
            trailing: Text(permName(store.catalog?.defaults['permissionPreset'] as String?),
                style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => _pickDefaultPerm(store),
          ),
          _row(
            leading: const Icon(Icons.bolt_outlined),
            title: L10n.t('默认 Agent 预设', 'Default agent preset'),
            sub: L10n.t('作用于之后新建的会话', 'Applies to new sessions'),
            trailing: Text(presetName(store.catalog?.defaults['agentPreset'] as String?),
                style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => _pickDefaultPreset(store),
          ),
          _row(
            leading: const Icon(Icons.dns_outlined),
            title: L10n.t('模型提供商', 'Model providers'),
            sub: L10n.t('与 PC 端「设置 → 模型」同一配置通道', 'Same channel as PC Settings → Models'),
            trailing: Text(L10n.t('管理', 'Manage'), style: TextStyle(fontSize: 12, color: brand)),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ProvidersScreen(store: store)),
              );
            },
          ),
        ]),
        _card(L10n.t('账户', 'Account'), [
          _row(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: L10n.t('余额', 'Balance'),
            sub: _balanceLabel,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _balance != null ? '¥${(_balance!['total'] as num).toStringAsFixed(2)}' : '—',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brand),
                ),
                const SizedBox(width: 2),
                // 余额旁独立刷新按钮（点击数字刷新的旧交互已移除）
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(7),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  GestureDetector(
                    onTap: _refreshBalance,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.refresh, size: 17, color: brand),
                    ),
                  ),
              ],
            ),
          ),
          _row(
            leading: const Icon(Icons.add_card_outlined),
            title: L10n.t('充值', 'Top up'),
            sub: L10n.t('跳转 DeepSeek 开放平台', 'Go to DeepSeek Open Platform'),
            trailing: Text(L10n.t('去充值 ▸', 'Top up ▸'), style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => launchUrl(
              // 以电脑端插件配置为准（catalog.rechargeUrl），缺省回退官方充值页
              Uri.parse(store.catalog?.rechargeUrl ?? 'https://platform.deepseek.com/top_up'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ]),
        _card(L10n.t('显示', 'Display'), [
          _row(
            leading: const Icon(Icons.psychology_outlined),
            title: L10n.t('思考内容', 'Thinking content'),
            sub: L10n.t('活动条思考状态展开时是否显示思考原文（默认关：只显示状态）',
                'Show raw thinking text when expanded (default off: status only)'),
            trailing: SizedBox(
              width: 44,
              height: 28,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  value: store.showReasoning,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // 色调适配：打开 = 品牌蓝；关闭 = 浅灰白（深色模式用柔和深灰）
                  activeTrackColor: DshColors.brand(context),
                  activeThumbColor: Colors.white,
                  inactiveTrackColor:
                      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF3C424A) : const Color(0xFFE5E7EB),
                  inactiveThumbColor:
                      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF9AA3AF) : Colors.white,
                  onChanged: (v) => store.setShowReasoning(v),
                ),
              ),
            ),
          ),
          _row(
            leading: const Icon(Icons.dark_mode_outlined),
            title: L10n.t('深色模式', 'Dark mode'),
            sub: switch (store.darkMode) {
              'dark' => L10n.t('已选深色', 'Dark'),
              'light' => L10n.t('已选浅色', 'Light'),
              _ => L10n.t('跟随系统', 'System'),
            },
            trailing: GestureDetector(
              onTap: () {
                final next = switch (store.darkMode) {
                  'system' => 'dark',
                  'dark' => 'light',
                  _ => 'system',
                };
                store.setDarkMode(next);
              },
              child: Text(
                switch (store.darkMode) {
                  'dark' => L10n.t('深色', 'Dark'),
                  'light' => L10n.t('浅色', 'Light'),
                  _ => L10n.t('跟随系统', 'System'),
                },
                style: TextStyle(fontSize: 13, color: brand),
              ),
            ),
          ),
          _row(
            leading: const Icon(Icons.language_outlined),
            title: L10n.t('语言', 'Language'),
            sub: L10n.t('界面显示语言（即时生效）', 'UI language (applies immediately)'),
            onTap: () => _pickLanguage(store),
            trailing: Text(
              store.language == 'en' ? 'English' : '中文',
              style: TextStyle(fontSize: 13, color: brand),
            ),
          ),
        ]),
        _card(L10n.t('关于', 'About'), [
          _row(
            leading: const Icon(Icons.info_outline),
            title: L10n.t('版本', 'Version'),
            sub: 'App v${_appVersion.isEmpty ? '…' : _appVersion}'
                ' · ${L10n.t('插件', 'plugin')} v${api.pluginVersion.isEmpty ? '…' : api.pluginVersion}',
          ),
          _row(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: L10n.t('环境诊断', 'Diagnostics'),
            sub: _diagLoaded ? '${L10n.t('检测完成 · ', 'Done · ')}$_diagTime' : L10n.t('检测当前环境各项能力', 'Check environment capabilities'),
            trailing: TextButton(
              onPressed: _openDiag,
              child: Text(L10n.t('查看 ▸', 'View ▸'), style: TextStyle(fontSize: 12, color: brand)),
            ),
          ),
          _row(
            leading: const Icon(Icons.article_outlined),
            title: L10n.t('应用日志', 'App log'),
            sub: L10n.t('启动/连接/加载事件（排障用）', 'Startup/connection/load events (troubleshooting)'),
            trailing: TextButton(
              onPressed: _openLog,
              child: Text(L10n.t('查看 ▸', 'View ▸'), style: TextStyle(fontSize: 12, color: brand)),
            ),
          ),
        ]),
      ],
    );
  }

  /// 修改默认 Agent 预设（作用于之后新建的会话）
  void _pickDefaultPreset(AppStore store) {
    final cat = store.catalog;
    if (cat == null) return;
    final current = cat.defaults['agentPreset'] as String?;
    final msgr = ScaffoldMessenger.of(context);
    showChoiceSheet(
      context,
      title: L10n.t('默认 Agent 预设', 'Default agent preset'),
      items: [
        for (final p in cat.agentPresets)
          (id: p.id, name: p.name, sub: p.description),
      ],
      selectedId: current,
      footnote: L10n.t('作用于之后新建的会话', 'Applies to new sessions'),
      onPick: (id) async {
        try {
          await api.updateDefaults(agentPreset: id);
          await store.refreshAll();
          _toast(msgr, L10n.t('已设置默认预设', 'Default preset set'));
        } catch (e) {
          _toast(msgr, '${L10n.t('设置失败：', 'Failed: ')}$e');
        }
      },
    );
  }

  /// 修改默认权限预设（作用于之后新建的会话）
  void _pickDefaultPerm(AppStore store) {
    final cat = store.catalog;
    if (cat == null) return;
    final current = cat.defaults['permissionPreset'] as String?;
    final msgr = ScaffoldMessenger.of(context);
    showChoiceSheet(
      context,
      title: L10n.t('默认权限预设', 'Default permission preset'),
      items: [
        for (final p in cat.permissionPresets)
          (id: p.id, name: p.name, sub: p.description),
      ],
      selectedId: current,
      footnote: L10n.t('作用于之后新建的会话', 'Applies to new sessions'),
      onPick: (id) async {
        try {
          await api.updateDefaults(permissionPreset: id);
          await store.refreshAll();
          _toast(msgr, L10n.t('已设置默认权限', 'Default permission set'));
        } catch (e) {
          _toast(msgr, '${L10n.t('设置失败：', 'Failed: ')}$e');
        }
      },
    );
  }

  /// 选择界面语言（中文 / English），即时生效 + 持久化。
  Future<void> _pickLanguage(AppStore store) async {
    final brand = DshColors.brand(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Text(L10n.t('选择语言', 'Choose language'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            for (final (id, name) in [('zh', '中文'), ('en', 'English')])
              ListTile(
                title: Text(name,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: store.language == id ? FontWeight.w700 : FontWeight.w400,
                        color: store.language == id ? brand : null)),
                trailing: store.language == id ? Icon(Icons.check, size: 18, color: brand) : null,
                onTap: () => Navigator.of(ctx).pop(id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null) await store.setLanguage(choice);
  }

  void _toast(ScaffoldMessengerState msgr, String text) {
    // 与全局 showToast 一致的短滞留 + 悬浮样式
    msgr
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ));
  }

  /// 应用日志：查看 / 复制 / 清空
  Future<void> _openLog() async {
    final text = await AppLog.instance.readAll();
    if (!mounted) return;
    final msgr = ScaffoldMessenger.of(context);
    showSheet(context, L10n.t('应用日志', 'App log'), [
      Text(
        '${L10n.t('最近 ', 'Last ')}$AppLog.instance.lines.length${L10n.t(' 条 · 文件 dsh_mobile.log', ' entries · file dsh_mobile.log')}',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: DshColors.ink3(context)),
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: SelectableText(
            text.isEmpty ? L10n.t('（暂无日志）', '(No logs)') : text,
            style: TextStyle(fontSize: 11.5, height: 1.6, color: DshColors.ink(context), fontFamily: 'monospace'),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                await AppLog.instance.clear();
                _toast(msgr, L10n.t('日志已清空', 'Log cleared'));
              },
              child: Text(L10n.t('清空', 'Clear')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: () => _copy(text),
              child: Text(L10n.t('复制', 'Copy')),
            ),
          ),
        ],
      ),
    ]);
  }

  Future<void> _openDiag() async {
    // 每次打开都实时拉取（修复：旧版只在首次加载，之后永远显示过期版本）
    await _loadDiag();
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showSheet(context, L10n.t('环境诊断', 'Diagnostics'), [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: SelectableText(
            _diagText,
            style: TextStyle(fontSize: 13, height: 1.7, color: DshColors.ink(context)),
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () => _copy(_diagText),
        child: Text(L10n.t('复制', 'Copy')),
      ),
    ]);
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showToast(context, L10n.t('已复制', 'Copied'));
    }
  }
}
