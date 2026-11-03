import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/update_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets(
    'checking does not install; plugin installation requires a separate confirmation',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'DSH Remote',
        packageName: 'com.dsh.remote',
        version: '3.2.3',
        buildNumber: '31',
        buildSignature: '',
      );
      final operations = <String>[];
      var phase = 'idle';
      final client = Api(
        client: MockClient((request) async {
          final action = request.url.path.split('/').last;
          if (request.method == 'POST') {
            operations.add(action);
            if (action == 'stage') {
              phase = 'staged';
            }
            if (action == 'install') {
              expect(jsonDecode(request.body)['confirmed'], isTrue);
              phase = 'awaiting-restart';
            }
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'phase': phase,
              'currentVersion': '3.2.3',
              'restartMode': 'manual',
              'candidate': {
                'version': '3.2.4',
                'appVersionName': '3.2.4',
                'appVersionCode': 32,
                'available': true,
                'digest': 'a' * 64,
              },
              'logs': [],
            }),
            200,
          );
        }),
      )..baseUrl = 'https://host.test';
      await tester.pumpWidget(
        MaterialApp(home: UpdateScreen(apiClient: client)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '检查更新'));
      await tester.pumpAndSettle();
      expect(operations, ['check']);
      await tester.tap(find.text('下载并准备更新'));
      await tester.pumpAndSettle();
      expect(operations, ['check', 'stage']);
      await tester.tap(find.text('安装电脑端插件'));
      await tester.pumpAndSettle();
      expect(find.text('稍后'), findsOneWidget);
      expect(operations, ['check', 'stage']);
      await tester.tap(find.text('准备安装'));
      await tester.pumpAndSettle();
      expect(operations, ['check', 'stage', 'install']);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
