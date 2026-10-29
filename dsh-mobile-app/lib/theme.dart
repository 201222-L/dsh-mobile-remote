// DeepSeek 设计令牌（对齐网页端 page.html :root，原型 v7 定稿）
// v3.3.0：加入「大肥鱼」三套皮肤（深潜夜航 / 海盐汽水 / 鲸落星海），默认仍是原 DSH 令牌。
import 'package:flutter/material.dart';

/// 皮肤枚举：默认 + 三套大肥鱼主题。
///
/// id 持久化在 SharedPreferences（`dsh_mr_skin`），不要随意改名。
enum DshSkin {
  dsh('dsh', '默认', 'Default'),
  abyss('abyss', '深潜夜航', 'Abyss Night'),
  soda('soda', '海盐汽水', 'Soda Pop'),
  whale('whale', '鲸落星海', 'Whale Fall');

  const DshSkin(this.id, this.label, this.labelEn);

  final String id;
  final String label;
  final String labelEn;

  String labelFor(bool en) => en ? labelEn : label;

  static DshSkin fromId(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return dsh;
  }

  bool get isBigFish => this != DshSkin.dsh;
}

/// 一套皮肤 × 一种明暗的完整令牌。
///
/// 通过 [ThemeExtension] 挂到 ThemeData 上，页面里的 [DshColors] 直接取，
/// 不用把 skin 参数一层层往下传。
@immutable
class DshPalette extends ThemeExtension<DshPalette> {
  const DshPalette({
    required this.skin,
    required this.bg,
    required this.surface,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.brand,
    required this.brandSoft,
    required this.onBrand,
    required this.accent,
    required this.glow,
    required this.ok,
    required this.warn,
    required this.danger,
    required this.gradientTop,
    required this.gradientBottom,
    required this.bubble,
  });

  final DshSkin skin;
  final Color bg;
  final Color surface;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color line;
  final Color brand;
  final Color brandSoft;
  final Color onBrand;
  final Color accent;
  final Color glow;
  final Color ok;
  final Color warn;
  final Color danger;

  /// 首页/空状态背景渐变（上 → 下）。
  final Color gradientTop;
  final Color gradientBottom;

  /// 气泡、星尘、波浪的主色（通常带透明度使用）。
  final Color bubble;

  /// 默认 DSH 令牌：与旧版完全一致，保证不选皮肤时零变化。
  factory DshPalette.of(DshSkin skin, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    switch (skin) {
      case DshSkin.dsh:
        return dark
            ? const DshPalette(
                skin: DshSkin.dsh,
                bg: Color(0xFF0E1116),
                surface: Color(0xFF161B22),
                ink: Color(0xFFE6E8EC),
                ink2: Color(0xFF8B949E),
                ink3: Color(0xFF5C6470),
                line: Color(0xFF232A33),
                brand: Color(0xFF6C8CFF),
                brandSoft: Color(0x246C8CFF),
                onBrand: Colors.white,
                accent: Color(0xFF6C8CFF),
                glow: Color(0xFF4D7CFF),
                ok: Color(0xFF4CB86F),
                warn: Color(0xFFD9A94A),
                danger: Color(0xFFE0655F),
                gradientTop: Color(0xFF101724),
                gradientBottom: Color(0xFF0A0D12),
                bubble: Color(0xFF6C8CFF),
              )
            : const DshPalette(
                skin: DshSkin.dsh,
                bg: Color(0xFFF6F7F9),
                surface: Color(0xFFFFFFFF),
                ink: Color(0xFF1F2329),
                ink2: Color(0xFF6B7280),
                ink3: Color(0xFF9CA3AF),
                line: Color(0xFFE5E7EB),
                brand: Color(0xFF426EFE),
                brandSoft: Color(0x1A426EFE),
                onBrand: Colors.white,
                accent: Color(0xFF426EFE),
                glow: Color(0xFF4D7CFF),
                ok: Color(0xFF3BA55D),
                warn: Color(0xFFD9730D),
                danger: Color(0xFFD44C47),
                gradientTop: Color(0xFFF6F7F9),
                gradientBottom: Color(0xFFEDF2FF),
                bubble: Color(0xFF426EFE),
              );
      case DshSkin.abyss:
        return dark
            ? const DshPalette(
                skin: DshSkin.abyss,
                bg: Color(0xFF03090C),
                surface: Color(0xFF0A1C18),
                ink: Color(0xFFE9F6F1),
                ink2: Color(0xFF93B6AB),
                ink3: Color(0xFF5F7F75),
                line: Color(0xFF16332C),
                brand: Color(0xFF4BF2D6),
                brandSoft: Color(0x1A4BF2D6),
                onBrand: Color(0xFF04120F),
                accent: Color(0xFF4BF2D6),
                glow: Color(0xFF4BF2D6),
                ok: Color(0xFF62E0A8),
                warn: Color(0xFFE6C576),
                danger: Color(0xFFFF7A70),
                gradientTop: Color(0xFF071712),
                gradientBottom: Color(0xFF03090C),
                bubble: Color(0xFF4BF2D6),
              )
            : const DshPalette(
                skin: DshSkin.abyss,
                bg: Color(0xFFEAF4F0),
                surface: Color(0xFFFFFFFF),
                ink: Color(0xFF0A211D),
                ink2: Color(0xFF4C6A62),
                ink3: Color(0xFF7E9991),
                line: Color(0xFFD6E7E1),
                brand: Color(0xFF0B7D6C),
                brandSoft: Color(0x140B7D6C),
                onBrand: Colors.white,
                accent: Color(0xFF109C88),
                glow: Color(0xFF19C6B4),
                ok: Color(0xFF2E8B57),
                warn: Color(0xFFB7791F),
                danger: Color(0xFFC0392B),
                gradientTop: Color(0xFFF5FBF8),
                gradientBottom: Color(0xFFDDEFE9),
                bubble: Color(0xFF0B7D6C),
              );
      case DshSkin.soda:
        return dark
            ? const DshPalette(
                skin: DshSkin.soda,
                bg: Color(0xFF140E08),
                surface: Color(0xFF221810),
                ink: Color(0xFFFFF3E2),
                ink2: Color(0xFFC9B49B),
                ink3: Color(0xFF8C7862),
                line: Color(0xFF36261A),
                brand: Color(0xFFFF8A7A),
                brandSoft: Color(0x1AFF8A7A),
                onBrand: Color(0xFF2A0E08),
                accent: Color(0xFF9FE8D2),
                glow: Color(0xFFFF6F61),
                ok: Color(0xFF7ED9A8),
                warn: Color(0xFFE6C576),
                danger: Color(0xFFE0655F),
                gradientTop: Color(0xFF2A1810),
                gradientBottom: Color(0xFF120C07),
                bubble: Color(0xFFFF8A7A),
              )
            : const DshPalette(
                skin: DshSkin.soda,
                bg: Color(0xFFFFF3E2),
                surface: Color(0xFFFFFFFF),
                ink: Color(0xFF241A10),
                ink2: Color(0xFF6B5A48),
                ink3: Color(0xFF9C8A76),
                line: Color(0xFFF0E0CB),
                brand: Color(0xFF2438D8),
                brandSoft: Color(0x142438D8),
                onBrand: Colors.white,
                accent: Color(0xFFFF6F61),
                glow: Color(0xFFFF6F61),
                ok: Color(0xFF2E7D5B),
                warn: Color(0xFFB7791F),
                danger: Color(0xFFD23B3B),
                gradientTop: Color(0xFFFFF3E2),
                gradientBottom: Color(0xFFFBE5D2),
                bubble: Color(0xFF2438D8),
              );
      case DshSkin.whale:
        return dark
            ? const DshPalette(
                skin: DshSkin.whale,
                bg: Color(0xFF08061A),
                surface: Color(0xFF14102E),
                ink: Color(0xFFF2EDFF),
                ink2: Color(0xFFB1A8CE),
                ink3: Color(0xFF7B7196),
                line: Color(0xFF2A2350),
                brand: Color(0xFFE6C576),
                brandSoft: Color(0x1AE6C576),
                onBrand: Color(0xFF16102A),
                accent: Color(0xFF9A8CFF),
                glow: Color(0xFFE6C576),
                ok: Color(0xFF7ED9A8),
                warn: Color(0xFFE6C576),
                danger: Color(0xFFFF7A90),
                gradientTop: Color(0xFF0C0A20),
                gradientBottom: Color(0xFF070512),
                bubble: Color(0xFFE6C576),
              )
            : const DshPalette(
                skin: DshSkin.whale,
                bg: Color(0xFFEFE4CE),
                surface: Color(0xFFFFFBF2),
                ink: Color(0xFF1A1232),
                ink2: Color(0xFF5B5169),
                ink3: Color(0xFF8C8299),
                line: Color(0xFFDCCEB4),
                brand: Color(0xFF5A45D8),
                brandSoft: Color(0x1A5A45D8),
                onBrand: Colors.white,
                accent: Color(0xFF9A6F12),
                glow: Color(0xFFC79A3A),
                ok: Color(0xFF2E7D5B),
                warn: Color(0xFFB7791F),
                danger: Color(0xFFC0392B),
                gradientTop: Color(0xFFF8EEDB),
                gradientBottom: Color(0xFFE7D8BC),
                bubble: Color(0xFFE6C576),
              );
    }
  }

  @override
  DshPalette copyWith({
    DshSkin? skin,
    Color? bg,
    Color? surface,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? line,
    Color? brand,
    Color? brandSoft,
    Color? onBrand,
    Color? accent,
    Color? glow,
    Color? ok,
    Color? warn,
    Color? danger,
    Color? gradientTop,
    Color? gradientBottom,
    Color? bubble,
  }) {
    return DshPalette(
      skin: skin ?? this.skin,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      line: line ?? this.line,
      brand: brand ?? this.brand,
      brandSoft: brandSoft ?? this.brandSoft,
      onBrand: onBrand ?? this.onBrand,
      accent: accent ?? this.accent,
      glow: glow ?? this.glow,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
      gradientTop: gradientTop ?? this.gradientTop,
      gradientBottom: gradientBottom ?? this.gradientBottom,
      bubble: bubble ?? this.bubble,
    );
  }

  @override
  DshPalette lerp(ThemeExtension<DshPalette>? other, double t) {
    if (other is! DshPalette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return DshPalette(
      skin: t < 0.5 ? skin : other.skin,
      bg: c(bg, other.bg),
      surface: c(surface, other.surface),
      ink: c(ink, other.ink),
      ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      line: c(line, other.line),
      brand: c(brand, other.brand),
      brandSoft: c(brandSoft, other.brandSoft),
      onBrand: c(onBrand, other.onBrand),
      accent: c(accent, other.accent),
      glow: c(glow, other.glow),
      ok: c(ok, other.ok),
      warn: c(warn, other.warn),
      danger: c(danger, other.danger),
      gradientTop: c(gradientTop, other.gradientTop),
      gradientBottom: c(gradientBottom, other.gradientBottom),
      bubble: c(bubble, other.bubble),
    );
  }
}

/// 设计令牌：配色/圆角/阴影。
class DshTheme {
  DshTheme._();

  // 默认皮肤常量（保留：旧代码/测试直接引用）
  static const bg = Color(0xFFF6F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF1F2329);
  static const ink2 = Color(0xFF6B7280);
  static const ink3 = Color(0xFF9CA3AF);
  static const line = Color(0xFFE5E7EB);
  static const brand = Color(0xFF426EFE);
  static const brandSoft = Color(0x1A426EFE); // rgba(66,110,254,.1)
  static const ok = Color(0xFF3BA55D);
  static const warn = Color(0xFFD9730D);
  static const danger = Color(0xFFD44C47);

  static const bgDark = Color(0xFF0E1116);
  static const surfaceDark = Color(0xFF161B22);
  static const inkDark = Color(0xFFE6E8EC);
  static const ink2Dark = Color(0xFF8B949E);
  static const ink3Dark = Color(0xFF5C6470);
  static const lineDark = Color(0xFF232A33);
  static const brandDark = Color(0xFF6C8CFF);
  static const brandSoftDark = Color(0x246C8CFF); // rgba(108,140,255,.14)
  static const okDark = Color(0xFF4CB86F);
  static const warnDark = Color(0xFFD9A94A);
  static const dangerDark = Color(0xFFE0655F);

  // 圆角
  static const radiusLg = 20.0;
  static const radiusMd = 14.0;
  static const radiusSm = 10.0;

  // 轻量阴影
  static const shadow = [
    BoxShadow(color: Color(0x0A1F2329), blurRadius: 10, offset: Offset(0, 2)),
  ];
  static const shadowDark = [
    BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 2)),
  ];

  /// 默认皮肤（向后兼容）。
  static ThemeData light() => forSkin(DshSkin.dsh, Brightness.light);
  static ThemeData dark() => forSkin(DshSkin.dsh, Brightness.dark);

  /// 指定皮肤 + 明暗的唯一入口。
  static ThemeData forSkin(DshSkin skin, Brightness brightness) =>
      _base(skin, brightness);

  static ThemeData _base(DshSkin skin, Brightness b) {
    final p = DshPalette.of(skin, b);
    final scheme = ColorScheme.fromSeed(
      seedColor: p.brand,
      brightness: b,
      surface: p.surface,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme.copyWith(
        primary: p.brand,
        onPrimary: p.onBrand,
        secondary: p.accent,
        onSecondary: p.onBrand,
        surface: p.surface,
        onSurface: p.ink,
        error: p.danger,
      ),
      extensions: [p],
      scaffoldBackgroundColor: p.bg,
      fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei', 'sans-serif'],
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _IosLightTransitionsBuilder(),
        TargetPlatform.iOS: _IosLightTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(color: p.line, thickness: 1),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.ink,
        contentTextStyle: TextStyle(color: p.bg, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: p.onBrand,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: p.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: p.brand, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}

/// 轻量 iOS 味转场（保持不变）。
class _IosLightTransitionsBuilder extends PageTransitionsBuilder {
  const _IosLightTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0.7, end: 1.0).animate(curved),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}

/// 会话内的语义色（走当前皮肤的 [DshPalette]，默认皮肤与旧版一致）。
class DshColors {
  const DshColors._();

  static DshPalette _p(BuildContext c) =>
      Theme.of(c).extension<DshPalette>() ??
      DshPalette.of(DshSkin.dsh, Theme.of(c).brightness);

  static DshSkin skin(BuildContext c) => _p(c).skin;
  static Color ok(BuildContext c) => _p(c).ok;
  static Color warn(BuildContext c) => _p(c).warn;
  static Color danger(BuildContext c) => _p(c).danger;
  static Color brand(BuildContext c) => _p(c).brand;
  static Color onBrand(BuildContext c) => _p(c).onBrand;
  static Color accent(BuildContext c) => _p(c).accent;
  static Color glow(BuildContext c) => _p(c).glow;
  static Color bubble(BuildContext c) => _p(c).bubble;
  static Color gradientTop(BuildContext c) => _p(c).gradientTop;
  static Color gradientBottom(BuildContext c) => _p(c).gradientBottom;
  static Color brandSoft(BuildContext c) => _p(c).brandSoft;
  static Color ink2(BuildContext c) => _p(c).ink2;
  static Color ink3(BuildContext c) => _p(c).ink3;
  static Color line(BuildContext c) => _p(c).line;
  static Color surface(BuildContext c) => _p(c).surface;
  static Color ink(BuildContext c) => _p(c).ink;
}

/// 设置项专用开关：小尺寸胶囊（44×28）+ 品牌色。
class DshSwitch extends StatelessWidget {
  const DshSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 44,
      height: 28,
      child: FittedBox(
        fit: BoxFit.contain,
        child: Switch(
          value: value,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          activeTrackColor: DshColors.brand(context),
          activeThumbColor: Colors.white,
          inactiveTrackColor: dark ? const Color(0xFF3C424A) : const Color(0xFFE5E7EB),
          inactiveThumbColor: dark ? const Color(0xFF9AA3AF) : Colors.white,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
