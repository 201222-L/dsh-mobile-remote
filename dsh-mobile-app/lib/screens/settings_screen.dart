// 设置页（对齐网页端 settings screen）：连接/默认配置/账户/显示/关于
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../app_icon.dart';
import '../app_icon_switcher.dart';
import '../floating.dart';
import '../keep_alive.dart';
import '../l10n.dart';
import '../logger.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../toast.dart';
import '../fmt.dart';
import 'sheets.dart';
import 'providers_screen.dart';
import 'usage_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AppStore store;
  final Future<void> Function() onReconfigure;
  const SettingsScreen({
    super.key,
    required this.store,
    required this.onReconfigure,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  UsageSnapshot? _usage;
  String? _usageError; // partial | outdated | failed；build 时再翻译
  bool _usageBusy = false; // 用量与额度刷新中
  bool _alertShown = false; // 本次会话内余额预警已提示过
  Map<String, dynamic>? _diag;
  bool _diagLoaded = false;
  String _diagTime = '';
  String _appVersion = ''; // App 自身版本（package_info_plus，构建时打包）
  bool _bubbleOn = false; // 悬浮球开关状态（与服务实际运行状态同步）

  @override
  void initState() {
    super.initState();
    _refreshUsage();
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
      await Floating.setPetConfig(
        height: widget.store.petHeight,
        reducedMotion: widget.store.petReducedMotion,
        edgeHide: widget.store.petEdgeHide,
        hideInApp: widget.store.petHideInApp,
      );
      await Floating.start();
      unawaited(
        Floating.setBalanceAlert(
          widget.store.balanceAlert,
          widget.store.balanceThreshold,
        ),
      );
    }
    // v2.7.2 review(M7)：权限被撤销时开关显示关（此前 want||on 会假开——球实际不在）
    if (mounted) setState(() => _bubbleOn = on || (want && canOverlay));
  }

  /// 桌面宠物开关：打开需悬浮窗权限（未授权 → 居中弹窗引导），关闭即停止服务。
  Future<void> _toggleBubble(bool v) async {
    if (v) {
      final ok = await Floating.canDrawOverlay();
      if (!ok) {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(L10n.t('需要悬浮窗权限', 'Overlay permission needed')),
            content: Text(
              L10n.t(
                '开启桌面宠物需要在系统设置中允许「显示在其他应用上层」。\n点击【去开启】跳转系统设置。',
                'The desktop pet needs the "display over other apps" permission.\nTap Open Settings to grant it.',
              ),
            ),
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
        await Floating.setPetConfig(
          height: widget.store.petHeight,
          reducedMotion: widget.store.petReducedMotion,
          edgeHide: widget.store.petEdgeHide,
          hideInApp: widget.store.petHideInApp,
        );
        await Floating.start();
      } catch (e) {
        if (mounted) {
          setState(() => _bubbleOn = false);
          showToast(
            context,
            '${L10n.t('桌面宠物启动失败：', 'Pet start failed: ')}$e',
          );
        }
        return;
      }
      await widget.store.setFloatingEnabled(true); // v2.7.2：持久化开关（await 确保落盘）
      await widget.store.setAttentionMode('pet'); // issue #55：三选一模式同步
      if (mounted) setState(() => _bubbleOn = true);
    } else {
      await Floating.stop();
      await widget.store.setFloatingEnabled(false); // v2.7.2：持久化开关
      if (widget.store.attentionMode == 'pet') {
        await widget.store.setAttentionMode('off');
      }
      if (mounted) setState(() => _bubbleOn = false);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// 后台提醒三选一（issue #55）：off / service / pet，三者互斥。
  Future<void> _setAttentionMode(String mode) async {
    if (mode == 'pet') {
      await _toggleBubble(true); // 复用悬浮窗权限引导与失败提示
      return;
    }
    if (mode == 'service') {
      // 常驻通知不可见时不启动（否则插件会误判手机在线，把等待从 300s 压到 120s）
      if (!await KeepAliveBridge.notificationsEnabled()) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(L10n.t('需要通知权限', 'Notification permission needed')),
            content: Text(
              L10n.t(
                '常驻通知被系统关闭，后台提醒无法保持连接。请在系统设置里允许 DSH Remote 的通知后重试。',
                'Notifications are disabled for DSH Remote. Allow them in system settings, then try again.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(L10n.t('知道了', 'Got it')),
              ),
            ],
          ),
        );
        return;
      }
      await Floating.stop();
      await KeepAliveBridge.start();
      await widget.store.setAttentionMode('service');
      if (mounted) setState(() => _bubbleOn = false);
      return;
    }
    await KeepAliveBridge.stop();
    await Floating.stop();
    await widget.store.setAttentionMode('off');
    if (mounted) setState(() => _bubbleOn = false);
  }

  /// 后台提醒卡片（issue #55）：三选一 + 当前生效状态。
  Widget _attentionCard() {
    final mode = widget.store.attentionMode;
    final brand = DshColors.brand(context);
    Widget tile(String id, IconData icon, String title, String sub) => _row(
          leading: Icon(icon),
          title: title,
          sub: sub,
          trailing: mode == id
              ? Icon(Icons.check_circle, size: 18, color: brand)
              : null,
          onTap: () => _setAttentionMode(id),
        );
    return _card(L10n.t('后台提醒', 'Background alerts'), [
      tile(
        'off',
        Icons.notifications_off_outlined,
        L10n.t('关闭', 'Off'),
        L10n.t('App 退到后台后收不到审批提醒', 'No alerts once the app is backgrounded'),
      ),
      tile(
        'service',
        Icons.notifications_active_outlined,
        L10n.t('常驻通知', 'Persistent notification'),
        L10n.t(
          '一条低干扰常驻通知保活，后台也能即时提醒',
          'A low-key ongoing notification keeps the connection alive',
        ),
      ),
      tile(
        'pet',
        Icons.pets_outlined,
        L10n.t('桌面宠物', 'Desktop pet'),
        L10n.t(
          '用大肥鱼常驻代替常驻通知（需悬浮窗权限）',
          'Use the pet instead (overlay permission needed)',
        ),
      ),
    ]);
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
              child: Text(
                L10n.t('选择连接地址', 'Choose address'),
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
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
                        c == current
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 18,
                        color: c == current
                            ? DshColors.brand(context)
                            : DshColors.ink3(context),
                      ),
                      title: Text(
                        c,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: c == current ? DshColors.brand(context) : null,
                        ),
                      ),
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
        ..showSnackBar(
          SnackBar(
            content: Text(err),
            duration: const Duration(milliseconds: 2000),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } else {
      showToast(context, L10n.t('已切换 → ', 'Switched to ') + choice);
    }
  }

  String _gitTabName(String id) => switch (id) {
    'branches' => L10n.t('分支', 'Branches'),
    'graph' => L10n.t('图谱', 'Graph'),
    'worktree' => L10n.t('工作区', 'Worktree'),
    _ => id,
  };

  String get _gitTabsSummary =>
      widget.store.gitTabs.map(_gitTabName).join(' · ');

  Future<void> _pickGitTabs() async {
    var selected = List<String>.of(widget.store.gitTabs);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(L10n.t('Git 标签页', 'Git tabs')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                L10n.t(
                  '选择 1–3 项并调整顺序；第一项为默认页。',
                  'Choose 1–3 tabs and reorder them; the first is the default.',
                ),
              ),
              const SizedBox(height: 8),
              for (final id in [
                ...selected,
                ...AppStore.gitTabIds.where((id) => !selected.contains(id)),
              ])
                Builder(
                  builder: (context) {
                    final isSelected = selected.contains(id);
                    final index = selected.indexOf(id);
                    return Semantics(
                      label: _gitTabName(id),
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_gitTabName(id)),
                        value: isSelected,
                        onChanged:
                            (isSelected && selected.length == 1) ||
                                (!isSelected && selected.length == 3)
                            ? null
                            : (value) {
                                if (value == true && selected.length < 3) {
                                  setDialogState(() => selected.add(id));
                                } else if (value == false &&
                                    selected.length > 1) {
                                  setDialogState(() => selected.remove(id));
                                }
                              },
                        secondary: isSelected
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: L10n.t(
                                      '上移 ${_gitTabName(id)}',
                                      'Move ${_gitTabName(id)} up',
                                    ),
                                    onPressed: index > 0
                                        ? () => setDialogState(() {
                                            selected.removeAt(index);
                                            selected.insert(index - 1, id);
                                          })
                                        : null,
                                    icon: const Icon(Icons.arrow_upward),
                                  ),
                                  IconButton(
                                    tooltip: L10n.t(
                                      '下移 ${_gitTabName(id)}',
                                      'Move ${_gitTabName(id)} down',
                                    ),
                                    onPressed: index < selected.length - 1
                                        ? () => setDialogState(() {
                                            selected.removeAt(index);
                                            selected.insert(index + 1, id);
                                          })
                                        : null,
                                    icon: const Icon(Icons.arrow_downward),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    );
                  },
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(L10n.t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: Text(L10n.t('保存', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (result != null) await widget.store.setGitTabs(result);
  }

  Future<void> _refreshUsage() async {
    if (_usageBusy) return;
    setState(() {
      _usageBusy = true;
      _usageError = null;
    });
    try {
      final snapshot = await api.accountUsage();
      if (!mounted) return;
      final deepSeek = snapshot.sourceOf('deepseek');
      final total = deepSeek?.amountNumber;
      setState(() {
        _usage = snapshot;
        _usageError = snapshot.failedCount > 0 ? 'partial' : null;
      });
      // 余额联动悬浮球与预警仍只使用 DeepSeek 金额余额。
      if (total != null) unawaited(Floating.notifyBalance(total));
      if (widget.store.balanceAlert &&
          total != null &&
          total < widget.store.balanceThreshold &&
          !_alertShown) {
        _alertShown = true;
        showToast(
          context,
          L10n.t('余额不足 ¥', 'Low balance ¥') +
              total.toStringAsFixed(1) +
              L10n.t('，建议及时充值', ' — consider topping up'),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final oldPlugin = e is ApiException && e.code == 'not-found';
      setState(() {
        // 保留最后一次成功快照，避免短暂网络失败把账户摘要清空。
        _usageError = oldPlugin ? 'outdated' : 'failed';
      });
    } finally {
      if (mounted) setState(() => _usageBusy = false);
    }
  }

  /// 阈值显示格式：整数不带小数（¥10），非整数两位（¥12.50）。
  String _fmtThreshold(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  /// v3.1.2：发送测试通知——逐个通道验证（服务端绕过节流）。
  Future<void> _sendTestPush() async {
    try {
      final r = await api.pushTest();
      final results = (r['results'] as List? ?? []).whereType<Map>().toList();
      final okCount = results.where((e) => e['ok'] == true).length;
      if (mounted) {
        showToast(
          context,
          L10n.t(
            '测试通知已发送（$okCount/${results.length} 个通道成功）',
            'Test sent ($okCount/${results.length} channels OK)',
          ),
        );
      }
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('发送失败：', 'Send failed: ')}$e');
    }
  }

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
                child: Text(
                  L10n.t('余额预警阈值', 'Low-balance threshold'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ...presets.map(
              (p) => ListTile(
                dense: true,
                title: Text(
                  '¥${_fmtThreshold(p)}',
                  style: const TextStyle(fontSize: 15),
                ),
                trailing: p == current
                    ? Icon(Icons.check, size: 18, color: brand)
                    : null,
                onTap: () => Navigator.of(ctx).pop(p),
              ),
            ),
            ListTile(
              dense: true,
              title: Text(
                L10n.t('自定义…', 'Custom…'),
                style: const TextStyle(fontSize: 15),
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                final ctrl = TextEditingController(
                  text: current == current.roundToDouble()
                      ? current.round().toString()
                      : current.toStringAsFixed(2),
                );
                final v = await showDialog<String>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: Text(
                      L10n.t('自定义阈值（元）', 'Custom threshold (¥)'),
                      style: const TextStyle(fontSize: 16),
                    ),
                    content: TextField(
                      controller: ctrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(hintText: '10'),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dctx).pop(),
                        child: Text(L10n.t('取消', 'Cancel')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(dctx).pop(ctrl.text),
                        child: Text(
                          L10n.t('确定', 'OK'),
                          style: TextStyle(color: brand),
                        ),
                      ),
                    ],
                  ),
                );
                if (v != null && v.trim().isNotEmpty) {
                  final parsed = double.tryParse(v.trim());
                  if (parsed != null && parsed > 0) {
                    await widget.store.setBalanceThreshold(parsed);
                    if (mounted) {
                      showToast(
                        context,
                        L10n.t('阈值已设为 ¥', 'Threshold set to ¥') +
                            _fmtThreshold(parsed),
                      );
                    }
                  } else if (mounted) {
                    showToast(
                      context,
                      L10n.t('请输入大于 0 的金额', 'Enter an amount greater than 0'),
                    );
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

  bool get _deepSeekLow =>
      widget.store.balanceAlert &&
      ((_usage?.sourceOf('deepseek')?.amountNumber ?? double.infinity) <
          widget.store.balanceThreshold);

  String? get _usageErrorText => switch (_usageError) {
    'partial' => L10n.t('部分额度来源刷新失败', 'Some usage sources failed to refresh'),
    'outdated' => L10n.t('电脑端插件版本过旧', 'Desktop plugin is outdated'),
    'failed' => L10n.t('额度查询失败', 'Usage query failed'),
    _ => null,
  };

  /// 用量与额度摘要（build 时求值：语言切换后即时换语言）。
  String get _usageLabel {
    if (_usageBusy && _usage == null) return L10n.t('查询中…', 'Loading…');
    if (_usageErrorText != null) return _usageErrorText!;
    final sources = _usage?.sources;
    if (sources == null) return L10n.t('尚未查询', 'Not queried yet');
    final count = sources.where((source) => source.available).length;
    if (count == 0) return L10n.t('暂无可用额度来源', 'No usage sources');
    return L10n.t(
      '$count 个来源可用',
      '$count source${count == 1 ? '' : 's'} available',
    );
  }

  Future<void> _openUsage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UsageScreen(store: widget.store, initial: _usage),
      ),
    );
    if (mounted) unawaited(_refreshUsage());
  }

  Future<void> _loadDiag() async {
    try {
      final d = await api.diagnostics();
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        _diag = d;
        _diagLoaded = true;
        _diagTime =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
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
    final form = runtime['form'];
    final formText = form == 'desktop'
        ? 'desktop · ${L10n.t('桌面版', 'DSH Desktop')}'
        : form == 'cli'
        ? 'cli · ${L10n.t('命令行/网页', 'CLI / Web')}'
        : '${form ?? '?'}';
    buf.writeln(
      '${L10n.t('运行形态: ', 'Mode: ')}$formText${runtime['authEnabled'] == true ? L10n.t(' · 口令已启用', ' · auth on') : L10n.t(' · 口令未启用', ' · auth off')}',
    );
    buf.writeln(
      '${L10n.t('监听: ', 'Listen: ')}${runtime['host']}:${runtime['port']}',
    );
    buf.writeln('${L10n.t('进程目录: ', 'CWD: ')}${runtime['cwd']}');
    final metrics = runtime['metrics'] as Map<String, dynamic>?;
    if (metrics != null && metrics.isNotEmpty) {
      buf.writeln();
      buf.writeln(L10n.t('实时指标:', 'Live metrics:'));
      metrics.forEach((k, v) {
        final n = _metricsName(k);
        buf.writeln('  • $n（$k）= $v');
      });
    }
    buf.writeln();
    final services = d['services'] as Map<String, dynamic>? ?? {};
    buf.writeln(L10n.t('服务:', 'Services:'));
    services.forEach((k, v) {
      final n = _diagName('services', k);
      buf.writeln('  ${v == true ? '✅' : '❌'} ${k == n ? n : '$n ($k)'}');
    });
    buf.writeln();
    final checks = d['checks'] as Map<String, dynamic>? ?? {};
    buf.writeln(L10n.t('端点实测:', 'Endpoint checks:'));
    checks.forEach((k, v) {
      final n = _diagName('checks', k);
      final shown = k == n ? n : '$n ($k)';
      if (k == 'approvalMode') {
        // v3.1.3：审批策略取值说明（both 双端同卡 / mobile 手机独占 / desktop 仅桌面）
        final m = v == 'both'
            ? L10n.t('both · 双端同卡，先答生效', 'both · both ends, first answer wins')
            : v == 'mobile'
            ? L10n.t('mobile · 手机在线独占', 'mobile · phone-exclusive while online')
            : v == 'desktop'
            ? L10n.t('desktop · 仅桌面 GUI', 'desktop · desktop GUI only')
            : '${v ?? '?'}';
        buf.writeln('  ℹ $shown：$m');
      } else if (v == true) {
        buf.writeln('  ✅ $shown');
      } else if (v == false) {
        buf.writeln('  ❌ $shown');
      } else if (v is num) {
        // 计数字段（如 pendingFrames 挂起待答数）：0 正常，>0 表示有问询/审批待处理
        buf.writeln(
          '  ${v == 0 ? '✅' : '⚠'} $shown = $v${v == 0 ? '' : L10n.t('（有审批/问询待处理）', ' (approval/question pending)')}',
        );
      } else {
        // v3.1.3（issue #9）：策略/状态字符串字段（如 approvalMode = both）友好直读
        buf.writeln('  ℹ $shown = $v');
      }
    });
    final notes = d['notes'] as List? ?? [];
    if (notes.isNotEmpty) {
      buf.writeln();
      buf.writeln(L10n.t('备注:', 'Notes:'));
      for (final n in notes) {
        buf.writeln('  • $n');
      }
    }
    final plugin = d['plugin'] as Map<String, dynamic>? ?? {};
    buf.writeln();
    buf.writeln(
      '${L10n.t('插件: ', 'Plugin: ')}${plugin['name']} v${plugin['version']}',
    );
    return buf.toString();
  }

  /// 实时指标中文名（v3.1.3 runtime.metrics）。未知 key 原样返回。
  String _metricsName(String key) {
    switch (key) {
      case 'mobileOnline':
        return L10n.t('手机在线连接', 'Phone connections');
      case 'agents':
        return L10n.t('运行中 Agent', 'Live agents');
      case 'sessions':
        return L10n.t('会话数', 'Sessions');
      case 'workspaces':
        return L10n.t('工作区数', 'Workspaces');
      case 'pushChannels':
        return L10n.t('推送通道', 'Push channels');
      default:
        return key;
    }
  }

  /// 服务/实测项中文名（环境诊断可读化，v3.1.3+）。未知 key 原样返回。
  /// 渲染时保留英文 key 便于复制粘贴排障（issue/日志对照）。
  String _diagName(String section, String key) {
    switch (section) {
      case 'services':
        switch (key) {
          case 'webServer':
            return L10n.t('网页服务', 'Web server');
          case 'agents':
            return L10n.t('Agent 服务', 'Agents');
          case 'sessions':
            return L10n.t('会话服务', 'Sessions');
          case 'llm':
            return L10n.t('模型服务', 'LLM');
          case 'permissionPresets':
            return L10n.t('权限预设', 'Permission presets');
          case 'agentPresets':
            return L10n.t('Agent 预设', 'Agent presets');
          case 'workspaceRegistry':
            return L10n.t('工作区服务', 'Workspaces');
          case 'approval':
            return L10n.t('审批服务', 'Approval');
          case 'credentials':
            return L10n.t('凭据服务', 'Credentials');
          case 'messageFeedback':
            return L10n.t('消息反馈', 'Message feedback');
          case 'userQuestions':
            return L10n.t('问询服务', 'Questions');
          case 'apiProxy':
            return L10n.t(
              '旧帧桥 apiProxy（0.1.1 内核）',
              'Legacy apiProxy (0.1.1 kernel)',
            );
          default:
            return key;
        }
      default:
        switch (key) {
          case 'modelsRpc':
            return L10n.t('模型目录 RPC', 'Model catalog RPC');
          case 'sessionsList':
            return L10n.t('会话列表', 'Session list');
          case 'directories':
            return L10n.t('目录浏览', 'Directory browse');
          case 'workspaces':
            return L10n.t('工作区列表', 'Workspace list');
          case 'notifications':
            return L10n.t('通知中心', 'Notifications');
          case 'actions':
            return L10n.t('动作区', 'Actions');
          case 'approvalMode':
            return L10n.t('审批策略', 'Approval mode');
          case 'remoteEvents':
            return L10n.t('双端审批通道', 'Dual-end channel');
          case 'respondBridge':
            return L10n.t('旧帧桥应答（0.1.1 内核）', 'Legacy respond (0.1.1 kernel)');
          case 'frameBridge':
            return L10n.t(
              '旧帧桥循环（0.1.1 内核）',
              'Legacy frame loop (0.1.1 kernel)',
            );
          case 'pendingFrames':
            return L10n.t('挂起待答', 'Pending frames');
          default:
            return key;
        }
    }
  }

  /// 外观：主题皮肤（4 选 1）+ App 图标（8 选 1，仅 Android）。
  Widget _appearanceCard() {
    final en = L10n.lang == 'en';
    final ink3 = DshColors.ink3(context);
    return _card(L10n.t('外观', 'Appearance'), [
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(L10n.t('主题皮肤', 'Theme skin'), style: const TextStyle(fontSize: 14)),
                const Spacer(),
                Text(
                  widget.store.skin.labelFor(en),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DshColors.brand(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < DshSkin.values.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _skinTile(DshSkin.values[i]),
                ],
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Divider(height: 1, color: DshColors.line(context)),
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(L10n.t('App 图标', 'App icon'), style: const TextStyle(fontSize: 14)),
                const Spacer(),
                Text(
                  AppIconStyle.byId(widget.store.appIcon).labelFor(en),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DshColors.brand(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              L10n.t(
                '默认是 DSH 原图标；切换后桌面可能需刷新一次',
                'DSH default is kept; the launcher may need a refresh after switching',
              ),
              style: TextStyle(fontSize: 11, color: ink3),
            ),
            const SizedBox(height: 10),
            if (!AppIconSwitcher.supported)
              Text(
                L10n.t('当前平台不支持切换桌面图标', 'Icon switching is Android-only'),
                style: TextStyle(fontSize: 11, color: ink3),
              )
            else
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 8,
                childAspectRatio: 0.82,
                children: [for (final icon in AppIconStyle.all) _iconTile(icon)],
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Divider(height: 1, color: DshColors.line(context)),
      // v3.2.2 build 27：从「桌面宠物」卡挪来——它同时管桌宠、首页角色与首页背景，属于外观。
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _row(
          leading: const Icon(Icons.motion_photos_off_outlined),
          title: L10n.t('减少动效', 'Reduce motion'),
          sub: L10n.t(
            '桌面宠物、首页角色与背景动画一起静止（系统「移除动画」始终优先）',
            'Freezes the desktop pet, home character and background (system setting wins)',
          ),
          trailing: DshSwitch(
            value: widget.store.petReducedMotion,
            onChanged: (v) => widget.store.setPetReducedMotion(v),
          ),
        ),
      ),
    ]);
  }

  Widget _skinTile(DshSkin s) {
    final en = L10n.lang == 'en';
    final selected = widget.store.skin == s;
    // 预览用「签名色」：深潜/星海展示暗色，汽水/默认展示亮色，避免四张卡都发白。
    final previewBrightness =
        s == DshSkin.abyss || s == DshSkin.whale ? Brightness.dark : Brightness.light;
    final p = DshPalette.of(s, previewBrightness);
    return Expanded(
      child: InkWell(
        onTap: () async {
          await widget.store.setSkin(s);
          if (!mounted) return;
          showToast(
            context,
            L10n.t('已切换皮肤：${s.label}', 'Skin: ${s.labelEn}'),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? p.brandSoft : DshColors.surface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? p.brand : DshColors.line(context),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  Container(
                    width: 46,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [p.gradientTop, p.gradientBottom],
                      ),
                      border: Border.all(color: p.line),
                    ),
                    child: Align(
                      alignment: const Alignment(0, 0.6),
                      child: Container(
                        width: 18,
                        height: 3,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.labelFor(en),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? p.brand : DshColors.ink2(context),
                    ),
                  ),
                ],
              ),
              if (selected)
                Positioned(
                  top: -5,
                  right: -2,
                  child: Container(
                    decoration: BoxDecoration(
                      color: DshColors.surface(context),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check_circle, size: 13, color: p.brand),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconTile(AppIconStyle icon) {
    final en = L10n.lang == 'en';
    final selected = widget.store.appIcon == icon.id;
    return InkWell(
      onTap: () => _pickAppIcon(icon),
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? DshColors.brand(context) : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset(icon.asset, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            icon.labelFor(en),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? DshColors.brand(context) : DshColors.ink2(context),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAppIcon(AppIconStyle icon) async {
    if (!AppIconSwitcher.supported) return;
    if (widget.store.appIcon == icon.id) return;
    final ok = await AppIconSwitcher.set(icon.id);
    if (!mounted) return;
    if (!ok) {
      showToast(
        context,
        L10n.t('图标切换失败，请稍后再试', 'Failed to switch the icon. Try again later.'),
      );
      return;
    }
    await widget.store.setAppIcon(icon.id);
    if (!mounted) return;
    showToast(
      context,
      L10n.t(
        '已切换桌面图标；若桌面没变，回桌面刷新一下',
        'Icon changed. Refresh your launcher if it still shows the old one.',
      ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(DshTheme.radiusMd),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? DshTheme.shadowDark
            : DshTheme.shadow,
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

  Widget _row({
    required Widget leading,
    required String title,
    String? sub,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: line, width: 1)),
        ),
        child: Row(
          children: [
            Icon(
              leading is Icon ? leading.icon : Icons.circle,
              size: 15,
              color: ink3,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14)),
                  if (sub != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        sub,
                        style: TextStyle(fontSize: 11, color: ink3),
                      ),
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
    final danger = DshColors.danger(context);
    final ok = DshColors.ok(context);
    final warn = DshColors.warn(context);

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
                ? L10n.t(
                    '${api.baseUrl} · 共 ${api.baseUrls.length} 个地址自动切换 · 点按手动切换',
                    '${api.baseUrl} · ${api.baseUrls.length} addresses · tap to switch',
                  )
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
            trailing: Text(
              L10n.t('配置 ▸', 'Configure ▸'),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: () => widget.onReconfigure(),
          ),
        ]),
        // v3.1.2：推送通道自检（配置在电脑端 cordis.patch.yml 的 pushUrls）
        _card(L10n.t('通知', 'Notifications'), [
          _row(
            leading: const Icon(Icons.notifications_active_outlined),
            title: L10n.t('发送测试通知', 'Send test notification'),
            sub: L10n.t(
              '验证推送通道（电脑端 cordis.patch.yml 配置）',
              'Verify push channels (configured on the PC)',
            ),
            trailing: Text(
              L10n.t('发送 ▸', 'Send ▸'),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: _sendTestPush,
          ),
        ]),
        _card(L10n.t('默认配置', 'Defaults'), [
          _row(
            leading: const Icon(Icons.security_outlined),
            title: L10n.t('默认权限预设', 'Default permission'),
            sub: L10n.t('作用于之后新建的会话', 'Applies to new sessions'),
            trailing: Text(
              permName(store.catalog?.defaults['permissionPreset'] as String?),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: () => _pickDefaultPerm(store),
          ),
          _row(
            leading: const Icon(Icons.bolt_outlined),
            title: L10n.t('默认 Agent 预设', 'Default agent preset'),
            sub: L10n.t('作用于之后新建的会话', 'Applies to new sessions'),
            trailing: Text(
              presetName(store.catalog?.defaults['agentPreset'] as String?),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: () => _pickDefaultPreset(store),
          ),
          _row(
            leading: const Icon(Icons.dns_outlined),
            title: L10n.t('模型提供商', 'Model providers'),
            sub: L10n.t(
              '与 PC 端「设置 → 模型」同一配置通道',
              'Same channel as PC Settings → Models',
            ),
            trailing: Text(
              L10n.t('管理', 'Manage'),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: () {
              // Phase 2：与模型弹层共用提供商页打开入口
              openProviders(context, store);
            },
          ),
        ]),
        _card(L10n.t('账户', 'Account'), [
          _row(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: L10n.t('用量与额度', 'Usage & allowance'),
            sub: _usageLabel,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _usage == null
                      ? '—'
                      : '${_usage!.sources.where((source) => source.available).length}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _deepSeekLow ? danger : brand,
                  ),
                ),
                if (_usageBusy)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
            onTap: _openUsage,
          ),
          _row(
            leading: const Icon(Icons.add_card_outlined),
            title: L10n.t('充值', 'Top up'),
            sub: L10n.t('跳转 DeepSeek 开放平台', 'Go to DeepSeek Open Platform'),
            trailing: Text(
              L10n.t('去充值 ▸', 'Top up ▸'),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: () => launchUrl(
              // 以电脑端插件配置为准（catalog.rechargeUrl），缺省回退官方充值页
              Uri.parse(
                store.catalog?.rechargeUrl ??
                    'https://platform.deepseek.com/top_up',
              ),
              mode: LaunchMode.externalApplication,
            ),
          ),
          _row(
            leading: const Icon(Icons.notifications_active_outlined),
            title: L10n.t('余额预警', 'Low-balance alert'),
            // v2.7.1：副标题动态显示当前阈值
            sub:
                L10n.t('余额低于 ¥', 'Remind to top up when balance is below ¥') +
                _fmtThreshold(store.balanceThreshold) +
                L10n.t(' 时提醒充值（点此修改）', ' — tap to change'),
            onTap: _pickThreshold,
            trailing: DshSwitch(
              value: store.balanceAlert,
              onChanged: (v) => store.setBalanceAlert(v),
            ),
          ),
        ]),
        _appearanceCard(),
        _attentionCard(),
        _card(L10n.t('显示', 'Display'), [
          _row(
            leading: const Icon(Icons.tab_outlined),
            title: L10n.t('Git 标签页', 'Git tabs'),
            sub: _gitTabsSummary,
            onTap: _pickGitTabs,
          ),
          _row(
            leading: const Icon(Icons.psychology_outlined),
            title: L10n.t('思考内容', 'Thinking content'),
            sub: L10n.t(
              '活动条思考状态展开时是否显示思考原文（默认关：只显示状态）',
              'Show raw thinking text when expanded (default off: status only)',
            ),
            trailing: DshSwitch(
              value: store.showReasoning,
              onChanged: (v) => store.setShowReasoning(v),
            ),
          ),
          _row(
            leading: const Icon(Icons.account_tree_outlined),
            title: L10n.t('思维链默认展开', 'Thinking chain default expanded'),
            sub: L10n.t(
              '回复里的「思维链」块默认折叠还是展开（单条消息仍可点按切换）',
              'Whether the thinking-chain block in replies is expanded by default (each message stays toggleable)',
            ),
            trailing: DshSwitch(
              value: store.reasoningDefaultExpanded,
              onChanged: (v) => store.setReasoningDefaultExpanded(v),
            ),
          ),
          _row(
            leading: const Icon(Icons.bug_report_outlined),
            title: L10n.t('对话调试模式', 'Conversation debug mode'),
            sub: L10n.t(
              '显示工具原始参数、结果、事件序号与未知可见事件（默认关闭）',
              'Show raw tool IO, event metadata and unknown visible events (off by default)',
            ),
            trailing: DshSwitch(
              value: store.timelineDebug,
              onChanged: (v) => store.setTimelineDebug(v),
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
              child: Text(switch (store.darkMode) {
                'dark' => L10n.t('深色', 'Dark'),
                'light' => L10n.t('浅色', 'Light'),
                _ => L10n.t('跟随系统', 'System'),
              }, style: TextStyle(fontSize: 13, color: brand)),
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
            leading: const Icon(Icons.pets_outlined),
            title: L10n.t('桌面宠物（大肥鱼）', 'Desktop pet (BigFish)'),
            sub: L10n.t(
              '显示任务状态/通知/余额，点它互动，长按打开面板（默认关）',
              'Shows task status / notifications / balance; tap to interact, long-press for panel (off by default)',
            ),
            trailing: DshSwitch(value: _bubbleOn, onChanged: _toggleBubble),
          ),
          _row(
            leading: const Icon(Icons.straighten_outlined),
            title: L10n.t('宠物大小', 'Pet size'),
            sub: L10n.t('迷你 / 标准 / 大', 'Mini / Standard / Large'),
            trailing: Text(
              _petSizeLabel(widget.store.petHeight),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: () => _pickPetSize(widget.store),
          ),
          _row(
            leading: const Icon(Icons.vertical_align_bottom_outlined),
            title: L10n.t('贴边自动躲藏', 'Auto-hide at edge'),
            sub: L10n.t(
              '5 秒无操作后缩到屏幕边缘并虚化',
              'Tuck into the edge and fade after 5s idle',
            ),
            trailing: DshSwitch(
              value: widget.store.petEdgeHide,
              onChanged: (v) => widget.store.setPetEdgeHide(v),
            ),
          ),
          _row(
            leading: const Icon(Icons.phone_iphone_outlined),
            title: L10n.t('App 在前台时收起', 'Hide while the app is open'),
            sub: L10n.t(
              '避免和首页角色同屏，也不再挡住按钮',
              'Avoids doubling with the home character and covering buttons',
            ),
            trailing: DshSwitch(
              value: widget.store.petHideInApp,
              onChanged: (v) => widget.store.setPetHideInApp(v),
            ),
          ),
          _row(
            leading: const Icon(Icons.help_outline),
            title: L10n.t('桌面宠物操作说明', 'Pet guide'),
            sub: L10n.t('状态含义与手势操作', 'Status meaning and gestures'),
            trailing: Text(
              L10n.t('查看 ▸', 'View ▸'),
              style: TextStyle(fontSize: 12, color: brand),
            ),
            onTap: _showBubbleGuide,
          ),
        ]),
        _card(L10n.t('关于', 'About'), [
          _row(
            leading: const Icon(Icons.info_outline),
            title: L10n.t('版本', 'Version'),
            sub:
                'App v${_appVersion.isEmpty ? '…' : _appVersion}'
                ' · ${L10n.t('插件', 'plugin')} v${api.pluginVersion.isEmpty ? '…' : api.pluginVersion}',
          ),
          _row(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: L10n.t('角色素材', 'Character assets'),
            sub: L10n.t(
              'PC2005-cloud/dsh-pet · MIT（经 dsh-dafeiyu 转码）',
              'PC2005-cloud/dsh-pet · MIT (encoded via dsh-dafeiyu)',
            ),
          ),
          _row(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: L10n.t('环境诊断', 'Diagnostics'),
            sub: _diagLoaded
                ? '${L10n.t('检测完成 · ', 'Done · ')}$_diagTime'
                : L10n.t('检测当前环境各项能力', 'Check environment capabilities'),
            trailing: TextButton(
              onPressed: _openDiag,
              child: Text(
                L10n.t('查看 ▸', 'View ▸'),
                style: TextStyle(fontSize: 12, color: brand),
              ),
            ),
          ),
          _row(
            leading: const Icon(Icons.article_outlined),
            title: L10n.t('应用日志', 'App log'),
            sub: L10n.t(
              '启动/连接/加载事件（排障用）',
              'Startup/connection/load events (troubleshooting)',
            ),
            trailing: TextButton(
              onPressed: _openLog,
              child: Text(
                L10n.t('查看 ▸', 'View ▸'),
                style: TextStyle(fontSize: 12, color: brand),
              ),
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

  String _petSizeLabel(int height) {
    if (height <= 80) return L10n.t('迷你', 'Mini');
    if (height >= 106) return L10n.t('大', 'Large');
    return L10n.t('标准', 'Standard');
  }

  void _pickPetSize(AppStore store) {
    showChoiceSheet(
      context,
      title: L10n.t('宠物大小', 'Pet size'),
      items: [
        (id: '76', name: L10n.t('迷你', 'Mini'), sub: '76dp'),
        (id: '96', name: L10n.t('标准', 'Standard'), sub: '96dp'),
        (id: '116', name: L10n.t('大', 'Large'), sub: '116dp'),
      ],
      selectedId: '${store.petHeight}',
      onPick: (id) async {
        await store.setPetHeight(int.parse(id));
      },
    );
  }

  /// 桌面宠物操作说明弹窗（状态含义 + 手势操作）。
  void _showBubbleGuide() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          L10n.t('桌面宠物操作说明', 'Desktop pet guide'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _guideSection(L10n.t('状态', 'Status'), [
                (
                  L10n.t('动作跟随任务', 'Animation follows the task'),
                  L10n.t(
                    '空闲 / 思考 / 处理 / 待确认 / 完成 / 出错',
                    'Idle / thinking / working / waiting / done / error',
                  ),
                ),
                (
                  L10n.t('红色角标', 'Red badge'),
                  L10n.t('未读通知数（60 秒后自动消退）', 'Unread count (clears after 60s)'),
                ),
                (
                  L10n.t('状态气泡', 'Status bubble'),
                  L10n.t('显示当前任务与进度，点它打开面板', 'Shows the task and progress; tap for panel'),
                ),
              ]),
              const SizedBox(height: 10),
              _guideSection(L10n.t('手势', 'Gestures'), [
                (
                  L10n.t('点头部 / 身体 / 尾巴', 'Tap head / body / tail'),
                  L10n.t('摸头 / 戳一下 / 碰尾巴', 'Head pat / poke / tail'),
                ),
                (
                  L10n.t('双击', 'Double tap'),
                  L10n.t('摸头（专属台词）', 'Head pat (special line)'),
                ),
                (
                  L10n.t('拖动', 'Drag'),
                  L10n.t(
                    '悬空，松手落地并吸附到最近边缘',
                    'Lift, then land and snap to the nearest edge',
                  ),
                ),
                (
                  L10n.t('长按', 'Long press'),
                  L10n.t('打开 / 收起面板', 'Open / close panel'),
                ),
                (
                  L10n.t('贴边 5 秒', '5s at the edge'),
                  L10n.t('缩进边缘并虚化，点一下滑出', 'Tucks in and fades; tap to slide out'),
                ),
              ]),
              const SizedBox(height: 10),
              _guideSection(L10n.t('面板', 'Panel'), [
                (
                  L10n.t('内容', 'Content'),
                  L10n.t(
                    '运行中会话 / 最近通知 / 用量与额度 / 打开 App / 去充值',
                    'Active sessions / notifications / usage & allowance / open app / top up',
                  ),
                ),
                (
                  L10n.t('关闭', 'Close'),
                  L10n.t('点面板外任意位置', 'Tap anywhere outside'),
                ),
                (
                  L10n.t('关闭宠物', 'Turn off pet'),
                  L10n.t('面板底部的「关闭宠物」', 'Use "Turn off pet" at the bottom of the panel'),
                ),
              ]),
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
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: DshColors.brand(context),
          ),
        ),
        const SizedBox(height: 4),
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$k：',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ink2,
                  ),
                ),
                Expanded(
                  child: Text(v, style: TextStyle(fontSize: 13, color: ink3)),
                ),
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
              child: Text(
                L10n.t('选择语言', 'Choose language'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final (id, name) in [('zh', '中文'), ('en', 'English')])
              ListTile(
                title: Text(
                  name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: store.language == id
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: store.language == id ? brand : null,
                  ),
                ),
                trailing: store.language == id
                    ? Icon(Icons.check, size: 18, color: brand)
                    : null,
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
        '${L10n.t('最近 ', 'Last ')}${AppLog.instance.lines.length}${L10n.t(' 条 · 文件 dsh_mobile.log', ' entries · file dsh_mobile.log')}',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: DshColors.ink3(context)),
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          // v3.0.0：日志倒序展示——最新日志在最上面，不用每次翻到底部
          child: SelectableText(
            text.isEmpty ? L10n.t('（暂无日志）', '(No logs)') : _reverseLog(text),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: DshColors.ink(context),
              fontFamily: 'monospace',
            ),
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

  /// v3.0.0：日志倒序展示（最新在上，省去翻到底部）——逐行倒排，丢弃尾部空行。
  static String _reverseLog(String text) {
    final lines = text.split('\n');
    return lines.reversed.where((l) => l.isNotEmpty).join('\n');
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
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: DshColors.ink(context),
            ),
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
