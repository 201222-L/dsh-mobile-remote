import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/widgets/git_file_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _diff =
    'diff --git a/staged.txt b/staged.txt\n'
    '@@ -1,10 +1,10 @@\n'
    ' keep 1\n keep 2\n keep 3\n'
    '-old line\n'
    '+new line\n'
    '--- source -- marker\n'
    '+++ source ++ marker\n'
    ' keep 4\n keep 5\n keep 6\n keep 7\n keep 8\n keep 9\n keep 10\n';

Future<void> _pump(WidgetTester tester, Widget viewer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(height: 600, child: viewer)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => L10n.lang = 'en');
  tearDown(() => L10n.lang = 'zh');

  testWidgets('content mode shows numbered source lines', (tester) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'notes.txt',
        content: 'line one\nline two',
      ),
    );

    expect(find.byKey(const Key('git-file-viewer-source')), findsOneWidget);
    expect(find.text('line one'), findsOneWidget);
    expect(find.text('line two'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // 非 Markdown 不提供预览/源码切换。
    expect(find.byKey(const Key('git-file-viewer-mode')), findsNothing);
  });

  testWidgets('markdown content defaults to preview and toggles to source', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'README.md',
        content: '# Title\n\nhello markdown',
      ),
    );

    expect(find.byKey(const Key('git-file-viewer-md')), findsOneWidget);
    expect(find.textContaining('Title'), findsOneWidget);

    await tester.tap(find.byKey(const Key('git-file-viewer-mode-source')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('git-file-viewer-source')), findsOneWidget);
    expect(find.text('# Title'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('git-file-viewer-mode-rendered')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-file-viewer-md')), findsOneWidget);
  });

  testWidgets('caller key prefix keeps existing session-files test seam', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'README.md',
        content: '# Title\n\nbody',
        keys: GitFileViewerKeys(prefix: 'sf-preview'),
      ),
    );

    expect(find.byKey(const Key('sf-preview-md')), findsOneWidget);
    expect(find.byKey(const Key('sf-preview-mode')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sf-preview-mode-source')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-preview-source')), findsOneWidget);
  });

  testWidgets('truncated content shows the supplied safety-limit notice', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'big.txt',
        content: 'prefix',
        truncated: true,
        truncatedMessage: 'File is large: showing first 10 KiB',
      ),
    );

    expect(find.byKey(const Key('git-file-viewer-truncated')), findsOneWidget);
    expect(find.text('File is large: showing first 10 KiB'), findsOneWidget);
  });

  testWidgets('binary and notice states keep the header actions', (tester) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'photo.png',
        binary: true,
        leading: IconButton(
          key: const Key('state-back'),
          onPressed: () {},
          icon: const Icon(Icons.arrow_back),
        ),
        topActions: [
          TextButton(
            key: const Key('state-history'),
            onPressed: () {},
            child: const Text('History'),
          ),
        ],
      ),
    );
    expect(
      find.byKey(const Key('git-file-viewer-unavailable')),
      findsOneWidget,
    );
    expect(find.textContaining('Binary'), findsOneWidget);
    // 状态 body 不能吞掉 leading/topActions（历史入口必须可达）。
    expect(find.byKey(const Key('state-back')), findsOneWidget);
    expect(find.byKey(const Key('state-history')), findsOneWidget);

    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'photo.png',
        binary: true,
        notice: 'GB18030 decode failed',
      ),
    );
    expect(find.text('GB18030 decode failed'), findsOneWidget);
  });

  testWidgets('content loading and error states expose retry', (tester) async {
    // loading 的 spinner 无限动画，不能 pumpAndSettle。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: GitFileViewer(
              mode: GitFileViewerMode.content,
              path: 'a.txt',
              loading: true,
              leading: IconButton(
                key: const Key('state-back'),
                onPressed: () {},
                icon: const Icon(Icons.arrow_back),
              ),
              topActions: [
                TextButton(
                  key: const Key('state-history'),
                  onPressed: () {},
                  child: const Text('History'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('state-back')), findsOneWidget);
    expect(find.byKey(const Key('state-history')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('git-file-viewer-copy')))
          .onPressed,
      isNull,
    );

    var retries = 0;
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'a.txt',
        error: 'network failed',
        onRetry: () => retries++,
        leading: IconButton(
          key: const Key('state-back'),
          onPressed: () {},
          icon: const Icon(Icons.arrow_back),
        ),
        topActions: [
          TextButton(
            key: const Key('state-history'),
            onPressed: () {},
            child: const Text('History'),
          ),
        ],
      ),
    );
    expect(find.byKey(const Key('git-file-viewer-error')), findsOneWidget);
    expect(find.byKey(const Key('state-back')), findsOneWidget);
    expect(find.byKey(const Key('state-history')), findsOneWidget);
    // 无 payload 时复制动作禁用。
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('git-file-viewer-copy')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('git-file-viewer-retry')));
    await tester.pumpAndSettle();
    expect(retries, 1);
  });

  testWidgets('copy action copies the loaded content', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'a.txt',
        content: 'copy me',
      ),
    );
    await tester.tap(find.byKey(const Key('git-file-viewer-copy')));
    await tester.pumpAndSettle();

    final clipboard = calls.where((call) => call.method == 'Clipboard.setData');
    expect(clipboard, hasLength(1));
    expect(
      (clipboard.single.arguments as Map)['text'],
      'copy me',
    );
    expect(find.text('Content copied'), findsOneWidget);
  });

  testWidgets('leading and top actions render in the header', (tester) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'staged.txt',
        diff: _diff,
        leading: IconButton(
          key: const Key('viewer-back'),
          onPressed: () {},
          icon: const Icon(Icons.arrow_back),
        ),
        topActions: [
          TextButton(
            key: const Key('viewer-history'),
            onPressed: () {},
            child: const Text('History'),
          ),
        ],
      ),
    );

    expect(find.byKey(const Key('viewer-back')), findsOneWidget);
    expect(find.byKey(const Key('viewer-history')), findsOneWidget);
  });

  testWidgets('diff mode renders markers and folds long unchanged runs', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'staged.txt',
        diff: _diff,
      ),
    );

    expect(find.text('new line'), findsOneWidget);
    expect(find.text('-- source -- marker'), findsOneWidget);
    expect(find.text('++ source ++ marker'), findsOneWidget);
    // US6：diff 模式同样有行号；旧/新行号来自 hunk header。
    String number(Key key) => tester.widget<Text>(find.byKey(key)).data!;
    expect(number(const Key('git-file-viewer-old-1')), '1');
    expect(number(const Key('git-file-viewer-new-1')), '1');
    expect(number(const Key('git-file-viewer-old-4')), '4'); // -old line
    expect(number(const Key('git-file-viewer-new-4')), ''); // 仅旧侧
    expect(number(const Key('git-file-viewer-old-5')), ''); // +new line 仅新侧
    expect(number(const Key('git-file-viewer-new-5')), '4');
    // hunk header 行不显示行号。
    expect(number(const Key('git-file-viewer-old-0')), '');
    expect(number(const Key('git-file-viewer-new-0')), '');
    expect(find.text('-'), findsNWidgets(2));
    expect(find.text('+'), findsNWidgets(2));
    // 7 行未改动的上下文默认折叠（保留首尾 3 行）。
    expect(find.text('keep 7'), findsNothing);
    expect(
      find.byKey(const Key('git-file-viewer-context-fold-0')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('git-file-viewer-context-fold-0')),
    );
    await tester.pumpAndSettle();
    expect(find.text('keep 7'), findsOneWidget);
  });

  testWidgets('diff lines scroll horizontally inside the shared viewer', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'staged.txt',
        diff: _diff,
      ),
    );

    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((scroll) => scroll.scrollDirection == Axis.horizontal);
    expect(horizontal, isNotEmpty);
  });

  testWidgets('untracked raw content keeps blanks and diff-like source lines', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'new.txt',
        rawAddedContent: true,
        diff:
            'line one\n\nindex literal\ndiff --git literal\n'
            'Binary files are source text\n',
      ),
    );

    expect(find.text('line one'), findsOneWidget);
    expect(
      find.byKey(const Key('git-file-viewer-diff-line-1')),
      findsOneWidget,
    );
    expect(find.text('index literal'), findsOneWidget);
    // 未跟踪内容按新增行展示：只有新侧行号，且空行也占一行。
    expect(
      tester
          .widget<Text>(find.byKey(const Key('git-file-viewer-new-1')))
          .data,
      '2',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('git-file-viewer-old-1')))
          .data,
      '',
    );
    expect(find.text('diff --git literal'), findsOneWidget);
    expect(find.text('Binary files are source text'), findsOneWidget);
  });

  testWidgets('empty diff shows a clear empty state', (tester) async {
    await _pump(
      tester,
      const GitFileViewer(mode: GitFileViewerMode.diff, path: 'a.txt'),
    );

    expect(find.byKey(const Key('git-file-viewer-empty')), findsOneWidget);
    expect(find.text('No line changes to display'), findsOneWidget);
  });

  testWidgets('custom empty message replaces the default empty body', (
    tester,
  ) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.content,
        path: 'a.txt',
        emptyMessage: 'no history',
      ),
    );

    expect(find.byKey(const Key('git-file-viewer-empty')), findsOneWidget);
    expect(find.text('no history'), findsOneWidget);
  });
}
