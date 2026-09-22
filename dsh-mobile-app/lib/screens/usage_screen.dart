// 手机端“用量与额度”详情页。
// 余额与配额按来源独立展示；配额窗口不相加，凭据永不下发到 App。
import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';

class UsageScreen extends StatefulWidget {
  final AppStore store;
  final UsageSnapshot? initial;

  const UsageScreen({super.key, required this.store, this.initial});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  UsageSnapshot? _snapshot;
  String? _errorCode; // partial | outdated | failed
  bool _loading = false;
  Timer? _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initial;
    widget.store.addListener(_onStoreChanged);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _clock?.cancel();
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  String? get _errorText => switch (_errorCode) {
        'partial' => L10n.t(
            '部分额度来源刷新失败，已隐藏不可用来源',
            'Some usage sources failed to refresh and were hidden',
          ),
        'outdated' => L10n.t(
            '电脑端插件版本过旧，请升级 dsh-mobile-remote 后重启桌面端',
            'The desktop plugin is outdated. Upgrade dsh-mobile-remote and restart the desktop app',
          ),
        'failed' => L10n.t('额度查询失败，请稍后重试', 'Usage query failed. Try again later'),
        _ => null,
      };

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errorCode = null;
    });
    try {
      final snapshot = await api.accountUsage(refresh: true);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _errorCode = snapshot.failedCount > 0 ? 'partial' : null;
      });
    } catch (e) {
      if (!mounted) return;
      final oldPlugin = e is ApiException && e.code == 'not-found';
      setState(() {
        // 保留已有快照，避免短暂网络失败导致页面闪成空状态。
        _snapshot ??= const UsageSnapshot(failedCount: 1);
        _errorCode = oldPlugin ? 'outdated' : 'failed';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          L10n.t('用量与额度', 'Usage & Allowance'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: L10n.t('刷新全部', 'Refresh all'),
            onPressed: _loading ? null : _refresh,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Text(
              L10n.t(
                '各提供方独立显示余额或配额；不同窗口与来源不会相加。',
                'Balances and quota windows are shown independently; windows and sources are never added together.',
              ),
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: DshColors.ink3(context),
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 10),
              _notice(_errorText!, Icons.info_outline, DshColors.warn(context)),
            ],
            const SizedBox(height: 12),
            if (snapshot == null && _loading)
              const Padding(
                padding: EdgeInsets.only(top: 90),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (snapshot == null || snapshot.sources.isEmpty)
              _emptyState(snapshot)
            else ...[
              for (final source in snapshot.sources) _sourceCard(source),
              if (snapshot.fetchedAt != null) ...[
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    '${L10n.t('最近更新：', 'Last updated: ')}${_formatDate(snapshot.fetchedAt!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: DshColors.ink3(context),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(UsageSnapshot? snapshot) {
    final hasFailure = (snapshot?.failedCount ?? 0) > 0;
    return Container(
      margin: const EdgeInsets.only(top: 36),
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 26),
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(DshTheme.radiusMd),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? DshTheme.shadowDark
            : DshTheme.shadow,
      ),
      child: Column(
        children: [
          Icon(
            hasFailure
                ? Icons.cloud_off_outlined
                : Icons.account_balance_wallet_outlined,
            size: 34,
            color: DshColors.ink3(context),
          ),
          const SizedBox(height: 12),
          Text(
            hasFailure
                ? L10n.t('当前没有可用额度来源', 'No usage source is currently available')
                : L10n.t('暂无可用额度来源', 'No usage source is configured'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            L10n.t(
              '请在电脑端「设置 → 模型」配置提供方；Codex 需要安装并登录 dsh-codex-connect。',
              'Configure providers in desktop Settings → Models. Codex requires dsh-codex-connect to be installed and signed in.',
            ),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: DshColors.ink3(context),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 17),
            label: Text(L10n.t('重新查询', 'Try again')),
          ),
        ],
      ),
    );
  }

  Widget _sourceCard(UsageSource source) {
    final icon = switch (source.id) {
      'deepseek' => Icons.account_balance_wallet_outlined,
      'codex' => Icons.auto_awesome_outlined,
      'opencode-go' => Icons.code_outlined,
      _ => Icons.data_usage_outlined,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(DshTheme.radiusMd),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? DshTheme.shadowDark
            : DshTheme.shadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: DshColors.brand(context)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  source.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!source.available)
                _statusChip(
                  L10n.t('不可用', 'Unavailable'),
                  DshColors.warn(context),
                ),
            ],
          ),
          if (source.account != null) ...[
            const SizedBox(height: 5),
            Text(
              [source.account!.displayName, source.account!.maskedEmail]
                  .whereType<String>()
                  .where((v) => v.trim().isNotEmpty)
                  .join(' · '),
              style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
            ),
          ],
          const SizedBox(height: 14),
          if (source.kind == 'balance')
            _balanceBody(source)
          else
            _quotaBody(source),
        ],
      ),
    );
  }

  Widget _balanceBody(UsageSource source) {
    final currency = source.currency == 'CNY'
        ? '¥'
        : (source.currency == null || source.currency!.isEmpty
              ? ''
              : '${source.currency} ');
    final amount = source.amountNumber;
    final amountColor = source.available ? DshColors.brand(context) : DshColors.ink3(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          currency,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: amountColor,
          ),
        ),
        Text(
          amount == null ? (source.amount ?? '—') : amount.toStringAsFixed(2),
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: amountColor,
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            source.available
                ? L10n.t('可用余额', 'available balance')
                : L10n.t('余额不可用', 'balance unavailable'),
            style: TextStyle(fontSize: 12, color: DshColors.ink3(context)),
          ),
        ),
      ],
    );
  }

  Widget _quotaBody(UsageSource source) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final window in source.windows) _windowRow(window),
        if (source.credits != null) ...[
          if (source.windows.isNotEmpty) const SizedBox(height: 12),
          _detailRow(
            L10n.t('Credits', 'Credits'),
            _creditsText(source.credits!),
          ),
        ],
        if (source.individualLimit != null) ...[
          if (source.windows.isNotEmpty || source.credits != null)
            const SizedBox(height: 8),
          _detailRow(
            L10n.t('个人消费上限', 'Individual limit'),
            '${source.individualLimit!.remaining} / ${source.individualLimit!.limit}',
            sub: L10n.t('已用 ', 'Used ') + source.individualLimit!.used,
          ),
        ],
      ],
    );
  }

  Widget _windowRow(UsageWindow window) {
    final remaining = window.remainingPercent.clamp(0, 100).toDouble();
    final color = _quotaColor(remaining);
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        _windowName(window.window),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (window.limited) ...[
                      const SizedBox(width: 6),
                      _statusChip(
                        L10n.t('已限流', 'Rate limited'),
                        DshColors.danger(context),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                '${_percentText(remaining)}${L10n.t(' 剩余', ' left')}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: remaining / 100,
              minHeight: 7,
              backgroundColor: color.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (window.resetAt != null) ...[
            const SizedBox(height: 5),
            Text(
              _resetText(window.resetAt!),
              style: TextStyle(fontSize: 11, color: DshColors.ink3(context)),
            ),
          ],
        ],
      ),
    );
  }

  String _creditsText(UsageCredits credits) {
    if (credits.unlimited) return L10n.t('无限', 'Unlimited');
    final value = credits.balance ?? '—';
    if (value == '—' || value.startsWith('\$')) return value;
    return '\$$value';
  }

  Widget _detailRow(String label, String value, {String? sub}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: DshColors.ink2(context),
                ),
              ),
              if (sub != null)
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11,
                    color: DshColors.ink3(context),
                  ),
                ),
            ],
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _notice(String text, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: color, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _quotaColor(double percent) {
    if (percent < 20) return DshColors.danger(context);
    if (percent < 50) return DshColors.warn(context);
    return DshColors.ok(context);
  }

  String _windowName(String id) => switch (id) {
    '5h' => L10n.t('5 小时滚动窗口', '5-hour rolling window'),
    'weekly' => L10n.t('每周窗口', 'Weekly window'),
    'monthly' => L10n.t('每月窗口', 'Monthly window'),
    'credits' => L10n.t('Credits', 'Credits'),
    _ => id,
  };

  String _percentText(double value) => value == value.roundToDouble()
      ? '${value.round()}%'
      : '${value.toStringAsFixed(1)}%';

  String _resetText(DateTime resetAt) {
    final local = resetAt.toLocal();
    final delta = resetAt.difference(_now);
    if (delta.isNegative) {
      return L10n.t(
        '已到重置时间 · ${_formatDate(resetAt)}',
        'Reset due · ${_formatDate(resetAt)}',
      );
    }
    final totalSeconds = delta.inSeconds;
    final totalMinutes = delta.inMinutes;
    final relative = totalSeconds < 60
        ? L10n.t('$totalSeconds 秒后', 'in ${totalSeconds}s')
        : totalMinutes < 60
        ? L10n.t('$totalMinutes 分钟后', 'in ${totalMinutes}m')
        : totalMinutes < 24 * 60
        ? L10n.t('${delta.inHours} 小时后', 'in ${delta.inHours}h')
        : L10n.t('${delta.inDays} 天后', 'in ${delta.inDays}d');
    return '${L10n.t('重置 ', 'Resets ')}${_formatDate(local)} · $relative';
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $hh:$mm';
  }
}
