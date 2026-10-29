// 首页/空状态动态背景：气泡 / 星尘 / 潮汐波浪，跟随皮肤令牌。
// 性能约定：30fps 上限、页面不可见即停、减少动效时只留静态渐变。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../store.dart';
import '../theme.dart';
import 'session_indicator.dart';

/// 动态背景层。放在页面 Stack 最底层（角色在其上层）。
///
/// 切换皮肤时渐隐；气泡颜色跟随 [DshPalette] 自动变化。
/// 减少动效时停止动画并保留静态渐变，避免打扰。
class DshDynamicBackground extends StatefulWidget {
  const DshDynamicBackground({
    super.key,
    required this.store,
    required this.visible,
  });

  final AppStore store;

  /// 页面是否可见（IndexedStack 下切页时暂停动画）。
  final bool visible;

  @override
  State<DshDynamicBackground> createState() => _DshDynamicBackgroundState();
}

class _DshDynamicBackgroundState extends State<DshDynamicBackground>
    with WidgetsBindingObserver {
  int _seed = 7;
  final List<_Bubble> _bubbles = [];
  late List<_Star> _stars;
  bool _reduced = false;

  /// 30fps 上限：定时器推进时间，不跟 vsync 跑满 60fps。
  Timer? _timer;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _seedBubbles();
    _stars = List.generate(26, (i) => _Star(_rnd(), _rnd(), _rnd()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTicker());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncTicker();
  }

  double _rnd() => math.Random(_seed += 37).nextDouble();

  void _seedBubbles() {
    _bubbles.clear();
    for (var i = 0; i < 14; i++) {
      _bubbles.add(_Bubble(
        x: _rnd(),
        y: _rnd(),
        size: 3 + _rnd() * 6,
        speed: 0.35 + _rnd() * 0.65,
        delay: _rnd() * 20,
      ));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(DshDynamicBackground old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  void _syncTicker() {
    final reduced = prefersReducedMotion(context) || widget.store.petReducedMotion;
    final paused = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
        WidgetsBinding.instance.lifecycleState != null;
    final shouldRun = widget.visible && !reduced && !paused;
    if (reduced != _reduced) {
      setState(() => _reduced = reduced);
    }
    if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted) return;
      setState(() => _t = (_t + 0.000275) % 1.0);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = DshPalette.of(DshColors.skin(context), dark ? Brightness.dark : Brightness.light);
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [p.gradientTop, p.gradientBottom],
            ),
          ),
          child: _reduced
              ? null
              : CustomPaint(
                  painter: _BackgroundPainter(
                    t: _t,
                    bubbleColor: p.bubble,
                    glowColor: p.glow,
                    bubbles: _bubbles,
                    stars: _stars,
                    skin: DshColors.skin(context),
                    starColor: dark ? Colors.white : p.accent,
                    moonColor: dark ? const Color(0xFFFFF4D6) : p.glow,
                  ),
                ),
        ),
      ),
    );
  }
}

class _Bubble {
  _Bubble({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.delay,
  });

  final double x;
  final double y;
  final double size;
  final double speed;
  final double delay;
}

class _Star {
  _Star(this.x, this.y, this.tw);
  final double x;
  final double y;
  final double tw;
}

enum _BgMode { bubbles, stars }

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({
    required this.t,
    required this.bubbleColor,
    required this.glowColor,
    required this.bubbles,
    required this.stars,
    required this.skin,
    required this.starColor,
    required this.moonColor,
  }) : _mode = switch (skin) {
          DshSkin.whale => _BgMode.stars,
          DshSkin.soda => _BgMode.bubbles,
          _ => _BgMode.bubbles,
        };

  final double t;
  final Color bubbleColor;
  final Color glowColor;
  final List<_Bubble> bubbles;
  final List<_Star> stars;
  final DshSkin skin;
  final Color starColor;
  final Color moonColor;
  final _BgMode _mode;

  @override
  void paint(Canvas canvas, Size size) {
    if (_mode == _BgMode.stars) {
      _paintStars(canvas, size);
      _paintConstellation(canvas, size);
      return;
    }
    if (skin == DshSkin.abyss) {
      _paintSonar(canvas, size);
    }
    if (skin == DshSkin.soda) {
      _paintBeams(canvas, size);
    }
    _paintBubbles(canvas, size);
    // 潮汐波浪：只在深潜夜航保留（其余皮肤气泡已够氛围）
    if (skin != DshSkin.soda) _paintWaves(canvas, size);
  }

  void _paintSonar(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.82, size.height * 0.16);
    canvas.drawCircle(
      center,
      size.width * 0.22,
      Paint()
        ..color = glowColor.withValues(alpha: 0.05)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 1; i <= 3; i++) {
      stroke.color = glowColor.withValues(alpha: 0.055);
      canvas.drawCircle(center, size.width * 0.1 * i + 10, stroke);
    }
  }

  void _paintBeams(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.05);
    for (var i = 0; i < 3; i++) {
      final topX = size.width * (0.52 + 0.14 * i);
      final path = Path()
        ..moveTo(topX, 0)
        ..lineTo(topX + size.width * 0.15, 0)
        ..lineTo(topX - size.width * 0.14, size.height * 0.55)
        ..lineTo(topX - size.width * 0.26, size.height * 0.55)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  void _paintConstellation(Canvas canvas, Size size) {
    if (stars.length < 6) return;
    final points = <Offset>[
      for (final s in stars.take(6))
        Offset(s.x * size.width, s.y * size.height),
    ];
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = glowColor.withValues(alpha: 0.08);
    Offset? prev;
    for (final p in points) {
      // 只连相邻且距离不远的星，避免出现横穿屏幕的长线
      if (prev != null && (p - prev).distance < size.width * 0.42) {
        canvas.drawLine(prev, p, paint);
      }
      prev = p;
    }
  }

  void _paintStars(Canvas canvas, Size size) {
    // 月亮：柔光 + 实心月盘
    final moon = Offset(size.width * 0.82, size.height * 0.12);
    canvas.drawCircle(
      moon,
      30,
      Paint()
        ..color = glowColor.withValues(alpha: 0.14)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );
    canvas.drawCircle(moon, 9, Paint()..color = moonColor);
    for (final s in stars) {
      final x = s.x * size.width;
      final y = s.y * size.height;
      final r = 0.7 + s.tw * 1.3;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()..color = starColor.withValues(alpha: 0.35 + 0.5 * s.tw),
      );
    }
  }

  void _paintBubbles(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final b in bubbles) {
      // 上浮：0..1 周期，y 从下到上
      final cycle = (t * b.speed + b.delay) % 1.0;
      final x = b.x * size.width;
      final y = size.height * (1.15 - cycle * 1.3);
      final alpha = 0.08 + 0.22 * math.sin(cycle * math.pi);
      paint.color = bubbleColor.withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), b.size, paint);
      canvas.drawCircle(
        Offset(x - b.size * 0.2, y - b.size * 0.2),
        b.size * 0.4,
        Paint()..color = bubbleColor.withValues(alpha: alpha * 0.35),
      );
    }
  }

  void _paintWaves(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var k = 0; k < 2; k++) {
      final path = Path();
      final baseY = size.height * (0.88 + k * 0.06);
      final amp = size.height * (0.012 + k * 0.006);
      for (var x = 0.0; x <= size.width; x += 4) {
        final y = baseY +
            amp * math.sin((x / size.width) * 2 * math.pi * 1.5 + t * math.pi * 2 + k * 1.2);
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      paint.color = glowColor.withValues(alpha: 0.12 + k * 0.05);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) =>
      old.t != t ||
      old.skin != skin ||
      old.bubbleColor != bubbleColor ||
      old.glowColor != glowColor ||
      old.starColor != starColor ||
      old.moonColor != moonColor;
}
