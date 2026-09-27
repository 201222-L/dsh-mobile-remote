import 'package:dsh_mobile_app/widgets/git_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Git 图标保留 45° 菱形并随主题反转黑白', (tester) async {
    const logoKey = Key('git-logo-theme-test');

    Future<dynamic> painterFor(Brightness brightness) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Center(child: GitLogo(key: logoKey)),
        ),
      );
      await tester.pumpAndSettle();
      final painter = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(logoKey),
          matching: find.byType(CustomPaint),
        ),
      );
      return painter.painter!;
    }

    final lightPainter = await painterFor(Brightness.light);
    expect(lightPainter.diamondColor, Colors.black);
    expect(lightPainter.markColor, Colors.white);

    final darkPainter = await painterFor(Brightness.dark);
    expect(darkPainter.diamondColor, Colors.white);
    expect(darkPainter.markColor, Colors.black);
    expect(darkPainter.shouldRepaint(lightPainter), isTrue);
  });
}
