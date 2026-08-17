// DeepSeek 设计令牌（对齐网页端 page.html :root，原型 v7 定稿）
import 'package:flutter/material.dart';

/// 设计令牌：配色/圆角/阴影，浅色深色两套。
class DshTheme {
  DshTheme._();

  // 浅色
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

  // 深色
  static const bgDark = Color(0xFF0E1116);
  static const surfaceDark = Color(0xFF161B22);
  static const inkDark = Color(0xFFE6E8EC);
  static const ink2Dark = Color(0xFF8B949E);
  static const ink3Dark = Color(0xFF5C6470);
  static const lineDark = Color(0xFF232A33);
  static const brandDark = Color(0xFF6C8CFF);
  static const brandSoftDark = Color(0x246C8CFF); // rgba(108,140,255,.14)
  static const okDark = Color(0xFF4CB86F);
  static const dangerDark = Color(0xFFE0655F);

  // 圆角（v2.7 统一：卡片 14 / 输入框 10 / 胶囊全圆）
  static const radiusLg = 20.0; // 弹层/底部弹窗顶部
  static const radiusMd = 14.0; // 卡片
  static const radiusSm = 10.0; // 输入框/次级元素

  // 轻量阴影：卡片靠"浅底+细边框+极轻投影"分层，不用重阴影（v2.7 弱化）
  static const shadow = [
    BoxShadow(color: Color(0x0A1F2329), blurRadius: 10, offset: Offset(0, 2)),
  ];
  static const shadowDark = [
    BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 2)),
  ];

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? brandDark : brand,
      brightness: b,
      surface: dark ? surfaceDark : surface,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme.copyWith(
        primary: dark ? brandDark : brand,
        secondary: dark ? brandDark : brand,
        surface: dark ? surfaceDark : surface,
        error: dark ? dangerDark : danger,
      ),
      scaffoldBackgroundColor: dark ? bgDark : bg,
      fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei', 'sans-serif'],
      // v2.7：统一页面转场——轻量 iOS 味（新页全宽滑入 + 轻微淡入，旧页静止不重绘，流畅）
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _IosLightTransitionsBuilder(),
        TargetPlatform.iOS: _IosLightTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? bgDark : bg,
        foregroundColor: dark ? inkDark : ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(color: dark ? lineDark : line, thickness: 1),
      cardTheme: CardThemeData(
        color: dark ? surfaceDark : surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? inkDark : ink,
        contentTextStyle: TextStyle(color: dark ? bgDark : bg, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: dark ? brandDark : brand,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? surfaceDark : surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: dark ? lineDark : line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: dark ? lineDark : line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: dark ? brandDark : brand, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}

/// 轻量 iOS 味转场：新页全宽滑入 + 轻微淡入；旧页静止（不参与动画 → 零重绘，流畅）。
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

/// 会话内的语义色（对齐网页端 var(--ok/warn/danger/brand)）。
class DshColors {
  const DshColors._();
  static Color ok(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.okDark : DshTheme.ok;
  static Color warn(BuildContext c) => DshTheme.warn;
  static Color danger(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.dangerDark : DshTheme.danger;
  static Color brand(BuildContext c) => Theme.of(c).colorScheme.primary;
  static Color brandSoft(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.brandSoftDark : DshTheme.brandSoft;
  static Color ink2(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.ink2Dark : DshTheme.ink2;
  static Color ink3(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.ink3Dark : DshTheme.ink3;
  static Color line(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.lineDark : DshTheme.line;
  static Color surface(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.surfaceDark : DshTheme.surface;
  static Color ink(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? DshTheme.inkDark : DshTheme.ink;
}
