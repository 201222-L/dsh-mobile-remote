import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/resumable_download.dart';
import 'package:dsh_mobile_app/screens/download_resume_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Downloads extends ResumableDownloads {
  _Downloads() : super(Directory.systemTemp, Api());
  final discarded = <String>[];
  @override
  Future<void> discard(String path) async => discarded.add(path);
}

void main() {
  testWidgets(
    'recovery entry selects a file, discards a checkpoint, or chooses another file',
    (tester) async {
      final downloads = _Downloads();
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('download'),
                onPressed: () async =>
                    selected = await showDownloadResumePicker(
                      context,
                      downloads,
                      [const PendingDownload('/work/file.txt', 1024)],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();
      expect(find.text('已保留 1 KB'), findsOneWidget);
      await tester.tap(find.text('file.txt'));
      await tester.pumpAndSettle();
      expect(selected, '/work/file.txt');
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除断点'));
      await tester.pumpAndSettle();
      expect(find.text('file.txt'), findsNothing);
      expect(downloads.discarded, ['/work/file.txt']);
      await tester.tap(find.text('选择其他文件'));
      await tester.pumpAndSettle();
      expect(selected, '');
    },
  );
}
