import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chat app bar keeps task tools without duplicate debug toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(store: AppStore(), onTitleChanged: () {}),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.assignment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.timeline_outlined), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
  });
}
