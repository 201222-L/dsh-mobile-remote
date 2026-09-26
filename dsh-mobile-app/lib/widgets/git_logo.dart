import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Git's recognizable orange diamond and white branch graph mark.
class GitLogo extends StatelessWidget {
  const GitLogo({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _GitLogoPainter(),
    isComplex: false,
  );
}

class _GitLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final side = size.shortestSide * .70;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(math.pi / 4);
    final diamond = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: side, height: side),
      Radius.circular(size.shortestSide * .07),
    );
    canvas.drawRRect(diamond, Paint()..color = const Color(0xFFF05032));
    canvas.restore();

    final scale = size.shortestSide / 24;
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(center.dx - 1.5 * scale, center.dy - 6 * scale)
      ..lineTo(center.dx - 1.5 * scale, center.dy + 6 * scale)
      ..cubicTo(
        center.dx - 1.5 * scale,
        center.dy + 2 * scale,
        center.dx + 5 * scale,
        center.dy + 2 * scale,
        center.dx + 5 * scale,
        center.dy - 1 * scale,
      );
    canvas.drawPath(path, white);
    final nodePaint = Paint()..color = Colors.white;
    for (final point in [
      Offset(center.dx - 1.5 * scale, center.dy - 6 * scale),
      Offset(center.dx - 1.5 * scale, center.dy + 6 * scale),
      Offset(center.dx + 5 * scale, center.dy - 1 * scale),
    ]) {
      canvas.drawCircle(point, 1.6 * scale, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GitLogoPainter oldDelegate) => false;
}
