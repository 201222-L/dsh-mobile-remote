// 设置页（对齐网页端 settings screen）：连接/默认配置/账户/显示/关于
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../store.dart';
import '../theme.dart';
import 'sheets.dart';

class SettingsScreen extends StatefulWidget {
  final AppStore store;
  final Future<void> Function() onReconfigure;
  const SettingsScreen({super.key, required this.store, required this.onReconfigure});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _balance;
  String _balanceStatus = '查询中…';
  Map<String, dynamic>? _diag;
  bool _diagLoaded = false;
  String _diagTime = '';

  @override
  void initState() {
    super.initState();
    _refreshBalance();
  }

  Future<void> _refreshBalance() async {
    setState(() => _balanceStatus = '查询中…');
    try {
      final b = await api.balanceInfo();
      if (!mounted) return;
      setState(() {
        _balance = b;
        _balanceStatus = b == null ? '无数据' : '实时 · 币种 ${b['currency']}${b['available'] == false ? ' · 不可用' : ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _balanceStatus = '查询失败：$e');
    }
  }

  Future<void> _loadDiag() async {
    final d = await api.diagnostics();
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _diag = d;
      _diagLoaded = true;
      _diagTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    });
  }

  String get _diagText {
    final d = _diag;
    if (d == null) return '检测失败';
    final buf = StringBuffer();
    final runtime = d['runtime'] as Map<String, dynamic>? ?? {};
    buf.writeln('运行形态: ${runtime['form']}${runtime['authEnabled'] == true ? ' · 口令已启用' : ' · 口令未启用'}');
    buf.writeln('监听: ${runtime['host']}:${runtime['port']}');
    buf.writeln('进程目录: ${runtime['cwd']}');
    buf.writeln();
    final services = d['services'] as Map<String, dynamic>? ?? {};
    buf.writeln('服务:');
    services.forEach((k, v) => buf.writeln('  ${v == true ? '✅' : '❌'} $k'));
    buf.writeln();
    final checks = d['checks'] as Map<String, dynamic>? ?? {};
    buf.writeln('端点实测:');
    checks.forEach((k, v) => buf.writeln('  ${v == true ? '✅' : '❌'} $k'));
    final plugin = d['plugin'] as Map<String, dynamic>? ?? {};
    buf.writeln();
    buf.writeln('插件: ${plugin['name']} v${plugin['version']}');
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

    String permName(String? id) => switch (id) {
          'read-only' => 'Read Only',
          'workspace-write' => 'Workspace Write',
          'danger-full-access' => 'Danger Full Access',
          _ => '…',
        };
    String presetName(String? id) => switch (id) {
          'standard' => '标准模式',
          'code' => 'PTC 模式',
          'minimal' => '极简模式',
          'cordis' => '创造模式',
          _ => '…',
        };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card('连接', [
          _row(
            leading: const Icon(Icons.computer_outlined),
            title: '电脑地址',
            sub: api.baseUrl,
            trailing: Text('已连接', style: TextStyle(fontSize: 12, color: ok)),
          ),
          _row(
            leading: const Icon(Icons.settings_outlined),
            title: '重新配置连接',
            sub: '更换电脑地址或访问口令',
            trailing: Text('配置 ▸', style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => widget.onReconfigure(),
          ),
        ]),
        _card('默认配置', [
          _row(
            leading: const Icon(Icons.security_outlined),
            title: '默认权限预设',
            sub: '作用于之后新建的会话',
            trailing: Text(permName(store.catalog?.defaults['permissionPreset'] as String?),
                style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => _pickDefaultPerm(store),
          ),
          _row(
            leading: const Icon(Icons.bolt_outlined),
            title: '默认 Agent 预设',
            sub: '作用于之后新建的会话',
            trailing: Text(presetName(store.catalog?.defaults['agentPreset'] as String?),
                style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => _pickDefaultPreset(store),
          ),
        ]),
        _card('账户', [
          _row(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: '余额',
            sub: _balanceStatus,
            trailing: Text(
              _balance != null ? '¥${(_balance!['total'] as num).toStringAsFixed(2)}' : '—',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brand),
            ),
            onTap: _refreshBalance,
          ),
          _row(
            leading: const Icon(Icons.add_card_outlined),
            title: '充值',
            sub: '跳转 DeepSeek 开放平台',
            trailing: Text('去充值 ▸', style: TextStyle(fontSize: 12, color: brand)),
            onTap: () => launchUrl(
              Uri.parse('https://platform.deepseek.com/top_up'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ]),
        _card('显示', [
          _row(
            leading: const Icon(Icons.visibility_outlined),
            title: '显示工具调用',
            sub: '移动端默认隐藏，只显示结果',
            trailing: GestureDetector(
              onTap: () => store.setShowTools(!store.showTools),
              child: Text(
                store.showTools ? '开' : '关',
                style: TextStyle(fontSize: 13, color: brand),
              ),
            ),
          ),
          _row(
            leading: const Icon(Icons.dark_mode_outlined),
            title: '深色模式',
            sub: switch (store.darkMode) {
              'dark' => '已选深色',
              'light' => '已选浅色',
              _ => '跟随系统',
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
                  'dark' => '深色',
                  'light' => '浅色',
                  _ => '跟随系统',
                },
                style: TextStyle(fontSize: 13, color: brand),
              ),
            ),
          ),
        ]),
        _card('关于', [
          _row(
            leading: const Icon(Icons.info_outline),
            title: '版本',
            sub: 'dsh-mobile-remote v2.1 · DSH Remote App',
          ),
          _row(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: '环境诊断',
            sub: _diagLoaded ? '检测完成 · $_diagTime' : '检测当前环境各项能力',
            trailing: TextButton(
              onPressed: _openDiag,
              child: Text('查看 ▸', style: TextStyle(fontSize: 12, color: brand)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text('DSH Mobile · DeepSeek 配色', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: ink3)),
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
      title: '默认 Agent 预设',
      items: [
        for (final p in cat.agentPresets)
          (id: p.id, name: p.name, sub: p.description),
      ],
      selectedId: current,
      footnote: '作用于之后新建的会话',
      onPick: (id) async {
        try {
          await api.updateDefaults(agentPreset: id);
          await store.refreshAll();
          _toast(msgr, '已设置默认预设');
        } catch (e) {
          _toast(msgr, '设置失败：$e');
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
      title: '默认权限预设',
      items: [
        for (final p in cat.permissionPresets)
          (id: p.id, name: p.name, sub: p.description),
      ],
      selectedId: current,
      footnote: '作用于之后新建的会话',
      onPick: (id) async {
        try {
          await api.updateDefaults(permissionPreset: id);
          await store.refreshAll();
          _toast(msgr, '已设置默认权限');
        } catch (e) {
          _toast(msgr, '设置失败：$e');
        }
      },
    );
  }

  void _toast(ScaffoldMessengerState msgr, String text) {
    msgr
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openDiag() async {
    if (!_diagLoaded) await _loadDiag();
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showSheet(context, '环境诊断', [
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
        child: const Text('复制'),
      ),
    ]);
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }
}
