// 共享格式化工具：相对时间 / token 缩略 / 权限预设名。
// Phase 0 收敛：原散落在 home_screen / sessions_screen / chat_screen / settings_screen 的重复实现。
import 'l10n.dart';

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期。
String relTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return L10n.t('刚刚', 'Just now');
  if (diff.inHours < 1) return '${diff.inMinutes}${L10n.t(' 分钟前', ' min ago')}';
  if (diff.inDays < 1) return '${diff.inHours}${L10n.t(' 小时前', ' hr ago')}';
  if (diff.inDays < 7) return '${diff.inDays}${L10n.t(' 天前', ' d ago')}';
  return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

/// token 数量缩略：≥100 万 → M，≥1000 → k，否则原样。
String fmtTokens(num? n) {
  final v = (n ?? 0).toInt();
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

/// 权限预设显示名；未知预设返回 null（由调用方决定兜底文案）。
String? permNameOf(String? id) => switch (id) {
      'read-only' => 'Read Only',
      'workspace-write' => 'Workspace Write',
      'danger-full-access' => 'Danger Full Access',
      _ => null,
    };
