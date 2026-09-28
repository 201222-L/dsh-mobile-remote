// 会话状态标识（ADR 0013 / issue #14）：会话图标四周的方形虚线。
//
// 会话列表页与首页「最近会话」共用这一个组件——两处此前各写一份图标容器。
//
// - running：虚线顺时针循环旋转（约 1.2 秒一圈、品牌色、线宽 1.5、约 4 段）
// - waiting：虚线**静态** + 警示色（会话在等答复而不是在推进）
// - idle：无标识，列表保持安静
//
// 系统「减弱动态效果」开启时旋转降级为静态虚线，两种状态仍靠颜色区分——
// 状态本身必须可见（无障碍要求），不能因为关掉动画就丢掉语义。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../session_list.dart';
import '../theme.dart';

/// 一圈的时长（ADR 0013：约 1.2 秒）。
const Duration kSessionIndicatorPeriod = Duration(milliseconds: 1200);

/// 方形虚线的段数（约 4 段）。
const int kSessionIndicatorDashCount = 4;

/// 虚线线宽。
const double kSessionIndicatorStrokeWidth = 1.5;

/// 会话图标 + 状态标识。
///
/// [animate] 由所在列表页统一控制（存在运行中会话才启动、页面不可见时暂停），
/// 见 [SessionIndicatorDriver]；这样每个列表页只有一个动画在跑。
class SessionIcon extends StatelessWidget {
  const SessionIcon({
    super.key,
    required this.state,
    required this.archived,
    this.size = 30,
    this.iconSize = 15,
    this.animation,
  });

  final SessionRowState state;
  final bool archived;
  final double size;
  final double iconSize;

  /// 由列表页共享的旋转 ticker（null = 不旋转，用于静态场景/减弱动效）。
  final Animation<double>? animation;

  /// 该图标**实际**是否在旋转：只有运行中才旋转。
  /// 等待态（静态警示色）与空闲态即使拿到 ticker 也不旋转——这是组件的对外契约，
  /// 也是"等待态不旋转，好让我区分它在等我还是在干活"（US6）的落点。
  Animation<double>? get effectiveAnimation =>
      state == SessionRowState.running ? animation : null;

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    final warn = DshColors.warn(context);

    final Color stroke = switch (state) {
      SessionRowState.running => brand,
      SessionRowState.waiting => warn,
      SessionRowState.idle => Colors.transparent,
    };

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: archived ? line : DshColors.brandSoft(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              archived ? Icons.archive_outlined : Icons.description_outlined,
              size: iconSize,
              color: archived ? ink2 : brand,
            ),
          ),
          if (state != SessionRowState.idle)
            Positioned.fill(
              child: _DashedSquareBorder(
                color: stroke,
                animation: effectiveAnimation,
              ),
            ),
        ],
      ),
    );
  }
}

/// 绘制方形虚线边框；[animation] 非空时按进度旋转。
class _DashedSquareBorder extends StatelessWidget {
  const _DashedSquareBorder({required this.color, this.animation});

  final Color color;
  final Animation<double>? animation;

  @override
  Widget build(BuildContext context) {
    final painter = _DashedSquarePainter(color: color);
    if (animation == null) {
      return CustomPaint(painter: painter, size: Size.infinite);
    }
    return AnimatedBuilder(
      animation: animation!,
      builder: (context, _) => CustomPaint(
        painter: _DashedSquarePainter(color: color, turns: animation!.value),
        size: Size.infinite,
      ),
    );
  }
}

class _DashedSquarePainter extends CustomPainter {
  const _DashedSquarePainter({required this.color, this.turns = 0});

  final Color color;
  /// 旋转进度（0..1 = 一整圈）。
  final double turns;

  @override
  void paint(Canvas canvas, Size size) {
    // 虚线画在图标容器外沿略外扩一点，避免压住图标本身
    final inset = kSessionIndicatorStrokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      math.max(0, size.width - inset * 2),
      math.max(0, size.height - inset * 2),
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = kSessionIndicatorStrokeWidth
      ..strokeCap = StrokeCap.round;

    for (final metric in path.computeMetrics()) {
      final segment = metric.length / kSessionIndicatorDashCount;
      final gap = segment * 0.45;
      final dash = segment - gap;
      // 4 段虚线沿闭合周长均匀分布，因此整段图案每隔一个 segment 就与自身重合；
      // 让相位在一个动画周期内正好推进一个 segment，即可得到无缝的"绕圈流动"。
      final phase = (turns % 1.0) * segment;
      var distance = 0.0;
      while (distance < metric.length) {
        final start = (distance + phase) % metric.length;
        final end = start + dash;
        if (end <= metric.length) {
          canvas.drawPath(metric.extractPath(start, end), paint);
        } else {
          canvas.drawPath(metric.extractPath(start, metric.length), paint);
          canvas.drawPath(metric.extractPath(0, end - metric.length), paint);
        }
        distance += segment;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSquarePainter old) =>
      old.color != color || old.turns != turns;
}

/// 每个列表页共享的动画驱动器。
///
/// - 只在**存在运行中会话**时运行（否则没有任何东西需要旋转）；
/// - 页面不可见（[setVisible] false）时暂停——`IndexedStack` 会让两个列表页
///   同时活着，所以可见性必须显式告知，不能靠 dispose；
/// - 列表滚动不影响它（动画与滚动位置无关）。
class SessionIndicatorDriver extends ChangeNotifier {
  SessionIndicatorDriver({required TickerProvider vsync})
      : _controller = AnimationController(vsync: vsync, duration: kSessionIndicatorPeriod);

  final AnimationController _controller;
  bool _visible = true;
  bool _needed = false;

  /// 供 [SessionIcon] 使用的旋转动画（线性：匀速绕圈，不需要缓动）。
  Animation<double> get animation => _controller;

  /// 旋转是否真的在跑：无运行中会话、页面不可见、或减弱动态效果时都应为 false。
  /// 这条契约保证"没有东西要转时不空转 ticker"（省电），可被测试直接断言。
  bool get isActive => _controller.isAnimating;

  /// 告知本页是否存在运行中会话（驱动启停）。
  void setNeeded(bool value) {
    if (_needed == value) return;
    _needed = value;
    _sync();
  }

  /// 页面可见性（离开列表页时暂停，避免白白耗电）。
  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _sync();
  }

  void _sync() {
    if (_needed && _visible) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      if (_controller.isAnimating) _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// 系统是否要求「减弱动态效果」。
bool prefersReducedMotion(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;
