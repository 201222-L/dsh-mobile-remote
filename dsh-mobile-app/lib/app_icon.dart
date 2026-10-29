// 桌面图标样式清单（id 与 Android activity-alias 后缀一致）。
class AppIconStyle {
  const AppIconStyle({
    required this.id,
    required this.label,
    required this.labelEn,
  });

  final String id;
  final String label;
  final String labelEn;

  String get asset => 'assets/icons/$id.png';

  String labelFor(bool en) => en ? labelEn : label;

  /// 顺序即设置页展示顺序；default 固定第一。
  static const List<AppIconStyle> all = [
    AppIconStyle(id: 'default', label: 'DSH 原图标', labelEn: 'DSH default'),
    AppIconStyle(id: 'deepsea', label: '深海头像', labelEn: 'Deep sea'),
    AppIconStyle(id: 'shell', label: '贝壳徽章', labelEn: 'Shell badge'),
    AppIconStyle(id: 'moon', label: '月夜潮线', labelEn: 'Moonlit'),
    AppIconStyle(id: 'sticker', label: '奶油贴纸', labelEn: 'Sticker'),
    AppIconStyle(id: 'stamp', label: '鲸邮票', labelEn: 'Stamp'),
    AppIconStyle(id: 'neon', label: '霓虹灯牌', labelEn: 'Neon'),
    AppIconStyle(id: 'mono', label: '鲸尾剪影', labelEn: 'Monochrome'),
  ];

  static AppIconStyle byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return all.first;
  }
}
