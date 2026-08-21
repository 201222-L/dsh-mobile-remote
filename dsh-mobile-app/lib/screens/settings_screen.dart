// 设置页（对齐网页端 settings screen）：连接/默认配置/账户/显示/关于
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../floating.dart';
import '../l10n.dart';
import '../logger.dart';
import '../store.dart';
import '../theme.dart';
import '../toast.dart';
import '../fmt.dart';
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
  bool _alertShown = false; // 本次会话内余额预警已提示过
  Map<String, dynamic>? _diag;
  bool _diagLoaded = false;
  String _diagTime = '';
  String _appVersion = ''; // App 自身版本（package_info_plus，构建时打包）
  bool _bubbleOn = false; // 悬浮球开关状态（与服务实际运行状态同步）

  @override
  void initState() {
    super.initState();
    _refreshBalance();
    _loadAppVersion();
    _initBubbleState();
    // 连接状态等 store 变化实时刷新（修复：旧版离开页面重进才能看到状态更新）
    widget.store.addListener(_onStoreChanged);
  }

  Future<void> _initBubbleState() async {
    final on = await Floating.isRunning();
    final want = widget.store.floatingEnabled;
    final canOverlay = await Floating.canDrawOverlay();
    // v2.7.2：偏好是开但服务没跑（清理后台/重启后）→ 自动拉起，开关保持开
    if (want && !on && canOverlay) {
      await Floating.start();
      unawaited(Floating.setBalanceAlert(widget.store.balanceAlert, widget.store.balanceThreshold));
    }
    // v2.7.2 review(M7)：权限被撤销时开关显示关（此前 want||on 会假开——球实际不在）
    if (mounted) setState(() => _bubbleOn = on || (want && canOverlay));
  }

  /// 悬浮球开关：打开需悬浮窗权限（未授权 → 居中弹窗引导），关闭即停止服务。
  Future<void> _toggleBubble(bool v) async {
    if (v) {
      final ok = await Floating.canDrawOverlay();
      if (!ok) {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(L10n.t('需要悬浮窗权限', 'Overlay permission needed')),
            content: Text(L10n.t('开启悬浮球需要在系统设置中允许「显示在其他应用上层」。\n点击【去开启】跳转系统设置。',
                'The floating bubble needs the "display over other apps" permission.\nTap Open Settings to grant it.')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(L10n.t('取消', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(L10n.t('去开启', 'Open Settings')),
              ),
            ],
          ),
        );
        if (go == true) {
          await Floating.openOverlaySettings();
        }
        return; // 授权后由用户重新打开开关（或重进页面状态同步）
      }
      try {
        await Floating.start();
      } catch (e) {
        if (mounted) {
          setState(() => _bubbleOn = false);
          showToast(context, '${L10n.t('悬浮球启动失败：', 'Bubble start failed: ')}$e');
        }
        return;
      }
      await widget.store.setFloatingEnabled(true); // v2.7.2：持久化开关（await 确保落盘）
      if (mounted) setState(() => _bubbleOn = true);
    } else {
      await Floating.stop();
      await widget.store.setFloatingEnabled(false); // v2.7.2：持久化开关
      if (mounted) setState(() => _bubbleOn = false);
    }
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
      // 余额联动悬浮球（低余额时悬浮球亮起 + 气泡）
      if (b != null) {
        final total = (b['total'] as num?)?.toDouble() ?? 0;
        unawaited(Floating.notifyBalance(total));
      }
      // 余额预警：低于阈值时提示一次（本次会话内不重复打扰）
      if (widget.store.balanceAlert && b != null) {
        final total = (b['total'] as num?)?.toDouble() ?? double.infinity;
        if (total < widget.store.balanceThreshold && !_alertShown) {
          _alertShown = true;
          showToast(context, L10n.t('余额不足 ¥', 'Low balance ¥') + total.toStringAsFixed(1) + L10n.t('，建议及时充值', ' — consider topping up'));
        }
      }
    } catch (e) {
      if (!mounted) return;
      // 查询失败：记住错误，build 里动态显示（语言切换后也能正确翻译）
      _balanceError = '$e';
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 阈值显示格式：整数不带小数（¥10），非整数两位（¥12.50）。
  String _fmtThreshold(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  /// 余额预警阈值选择：¥5 / ¥10 / ¥20 / ¥50 / 自定义输入。
  Future<void> _pickThreshold() async {
    final presets = [5.0, 10.0, 20.0, 50.0];
    final current = widget.store.balanceThreshold;
    final scheme = Theme.of(context);
    final brand = DshColors.brand(context);
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: scheme.scaffoldBackgroundColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(L10n.t('余额预警阈值', 'Low-balance threshold'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            ...presets.map((p) => ListTile(
                  dense: true,
                  title: Text('¥${_fmtThreshold(p)}', style: const TextStyle(fontSize: 15)),
                  trailing: p == current
                      ? Icon(Icons.check, size: 18, color: brand)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(p),
                )),
            ListTile(
              dense: true,
              title: Text(L10n.t('自定义…', 'Custom…'), style: const TextStyle(fontSize: 15)),
              onTap: () async {
                Navigator.of(ctx).pop();
                final ctrl = TextEditingController(text: current == current.roundToDouble()
                    ? current.round().toString()
                    : current.toStringAsFixed(2));
                final v = await showDialog<String>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: Text(L10n.t('自定义阈值（元）', 'Custom threshold (¥)'),
                        style: const TextStyle(fontSize: 16)),
                    content: TextField(
                      controller: ctrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(hintText: '10'),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(dctx).pop(),
                          child: Text(L10n.t('取消', 'Cancel'))),
                      TextButton(
                        onPressed: () => Navigator.of(dctx).pop(ctrl.text),
                        child: Text(L10n.t('确定', 'OK'),
                            style: TextStyle(color: brand)),
                      ),
                    ],
                  ),
                );
                if (v != null && v.trim().isNotEmpty) {
                  final parsed = double.tryParse(v.trim());
                  if (parsed != null && parsed > 0) {
                    await widget.store.setBalanceThreshold(parsed);
                    if (mounted) {
                      showToast(context,
                          L10n.t('阈值已设为 ¥', 'Threshold set to ¥') + _fmtThreshold(parsed));
                    }
                  } else if (mounted) {
                    showToast(context, L10n.t('请输入大于 0 的金额', 'Enter an amount greater than 0'));
                  }
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) {
      await widget.store.setBalanceThreshold(selected);
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
    final danger = DshColors.danger(context);

    String permName(String? id) => permNameOf(id) ?? '…';
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
              // Phase 2：与模型弹层共用提供商页打开入口
              openProviders(context, store);
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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    // 预警开启且低于阈值 → 红色警示
                    color: (store.balanceAlert &&
                            (_balance?['total'] as num?)?.toDouble() != null &&
                            ((_balance!['total'] as num).toDouble() < store.balanceThreshold))
                        ? danger
                        : brand,
                  ),
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
          _row(
            leading: const Icon(Icons.notifications_active_outlined),
            title: L10n.t('余额预警', 'Low-balance alert'),
            // v2.7.1：副标题动态显示当前阈值
            sub: L10n.t('余额低于 ¥', 'Remind to top up when balance is below ¥') +
                _fmtThreshold(store.balanceThreshold) +
                L10n.t(' 时提醒充值（点此修改）', ' — tap to change'),
            onTap: _pickThreshold,
            trailing: DshSwitch(
              value: store.balanceAlert,
              onChanged: (v) => store.setBalanceAlert(v),
            ),
          ),
        ]),
        _card(L10n.t('显示', 'Display'), [
          _row(
            leading: const Icon(Icons.psychology_outlined),
            title: L10n.t('思考内容', 'Thinking content'),
            sub: L10n.t('活动条思考状态展开时是否显示思考原文（默认关：只显示状态）',
                'Show raw thinking text when expanded (default off: status only)'),
            trailing: DshSwitch(
              value: store.showReasoning,
              onChanged: (v) => store.setShowReasoning(v),
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
          _row(
            leading: const Icon(Icons.bubble_chart_outlined),
            title: L10n.t('悬浮球', 'Floating bubble'),
            sub: L10n.t('桌面悬浮球：agent 运行/通知/余额低时亮起，单击展开面板（默认关）',
                'Floating bubble: lights up on activity, tap to open panel (off by default)'),
            trailing: DshSwitch(
              value: _bubbleOn,
              onChanged: _toggleBubble,
            ),
          ),
          _row(
            leading: const Icon(Icons.help_outline),
            title: L10n.t('悬浮球操作说明', 'Bubble guide'),
            sub: L10n.t('状态含义与手势操作', 'Status meaning and gestures'),
            trailing: Text(L10n.t('查看 ▸', 'View ▸'), style: TextStyle(fontSize: 12, color: brand)),
            onTap: _showBubbleGuide,
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
          showToastAt(msgr, L10n.t('已设置默认预设', 'Default preset set'));
        } catch (e) {
          showToastAt(msgr, '${L10n.t('设置失败：', 'Failed: ')}$e');
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
          showToastAt(msgr, L10n.t('已设置默认权限', 'Default permission set'));
        } catch (e) {
          showToastAt(msgr, '${L10n.t('设置失败：', 'Failed: ')}$e');
        }
      },
    );
  }

  /// 悬浮球操作说明弹窗（状态含义 + 手势操作）。
  void _showBubbleGuide() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('悬浮球操作说明', 'Floating bubble guide'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _guideSection(
                L10n.t('状态', 'Status'),
                [
                  (L10n.t('灰色鲸鱼', 'Gray whale'), L10n.t('一切正常，空闲', 'All good, idle')),
                  (L10n.t('蓝色鲸鱼', 'Blue whale'), L10n.t('agent 运行中 / 有新通知 / 余额不足', 'Agent running / new notification / low balance')),
                  (L10n.t('红色角标', 'Red badge'), L10n.t('未读通知数（60 秒后自动消退）', 'Unread count (clears after 60s)')),
                ],
              ),
              const SizedBox(height: 10),
              _guideSection(
                L10n.t('手势', 'Gestures'),
                [
                  (L10n.t('单击', 'Tap'), L10n.t('展开 / 收起面板', 'Open / close panel')),
                  (L10n.t('拖动', 'Drag'), L10n.t('移动位置，松手贴边，5 秒无操作自动缩进', 'Move; snaps to edge, auto-hides after 5s')),
                  (L10n.t('双击', 'Double tap'), L10n.t('打开 App', 'Open the app')),
                  (L10n.t('长按', 'Long press'), L10n.t('退出悬浮球', 'Exit the bubble')),
                ],
              ),
              const SizedBox(height: 10),
              _guideSection(
                L10n.t('面板', 'Panel'),
                [
                  (L10n.t('内容', 'Content'), L10n.t('运行中会话 / 最近通知 / 打开 App / 去充值', 'Active sessions / notifications / open app / top up')),
                  (L10n.t('关闭', 'Close'), L10n.t('点面板外任意位置', 'Tap anywhere outside')),
                ],
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.t('知道了', 'Got it')),
          ),
        ],
      ),
    );
  }

  Widget _guideSection(String title, List<(String, String)> rows) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DshColors.brand(context))),
        const SizedBox(height: 4),
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$k：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink2)),
                Expanded(child: Text(v, style: TextStyle(fontSize: 13, color: ink3))),
              ],
            ),
          ),
      ],
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
                showToastAt(msgr, L10n.t('日志已清空', 'Log cleared'));
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
