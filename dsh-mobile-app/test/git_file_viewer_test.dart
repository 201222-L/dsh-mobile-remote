import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/widgets/git_file_viewer.dart';
import 'package:flutter/gestures.dart';
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

/// 2000 字符的超长行（issue #71）。
///
/// 默认真实 fixture 最长行不到 20 字符，在 800px 测试面下 `maxExtent` 为 0，
/// 横向滚动根本测不出来；必须自造能溢出的内容。
///
/// [fill] 用于生成**同样长、内容不同**的第二份 diff（换 diff 回归测试），
/// 保证换数据后 maxExtent 仍 > 0，不靠边界夹取掩盖偏移未复位的缺陷。
String _longDiff({String fill = 'x'}) {
  final line = fill * 2000;
  return 'diff --git a/long.txt b/long.txt\n'
      '@@ -1,6 +1,6 @@\n'
      ' short one\n'
      ' $line\n'
      '-$line\n'
      '+$line\n'
      ' tail\n';
}

/// 40 行增删内容的 diff：让纵向 ListView 有可滚动内容（否则 Scrollable 不会
/// 创建纵向拖拽识别器），用于手势竞技场回归测试（contract §6.2）。
String _tallDiff() {
  final buffer = StringBuffer()
    ..writeln('diff --git a/tall.txt b/tall.txt')
    ..writeln('@@ -1,40 +1,40 @@');
  for (var i = 1; i <= 40; i++) {
    buffer.writeln('+row $i ${'x' * 400}');
  }
  return buffer.toString();
}

const _viewerKeys = GitFileViewerKeys();

Key _textKey(int index) => _viewerKeys.diffLineText(index);

double _textLeft(WidgetTester tester, int index) =>
    tester.getTopLeft(find.byKey(_textKey(index))).dx;

/// 在整块 diff 的横向滚动表面上拖拽（gestureSettings.touchSlop 已压到 4px）。
Future<void> _dragDiff(WidgetTester tester, Offset offset) async {
  await tester.drag(find.byKey(_viewerKeys.diffScrollSurface), offset);
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

  testWidgets('diff rows share one horizontal scroll surface', (tester) async {
    await _pump(
      tester,
      const GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'staged.txt',
        diff: _diff,
      ),
    );

    // issue #71 新契约：整块 diff 共用一个横向偏移（行号列固定），不再是
    // 每行各自一个横向 SingleChildScrollView。旧断言只检查「存在横向
    // SingleChildScrollView」，改造后仍会通过，属于碰巧为真的假断言。
    expect(find.byKey(_viewerKeys.diffScrollSurface), findsOneWidget);
    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((scroll) => scroll.scrollDirection == Axis.horizontal);
    expect(horizontal, isEmpty);
  });

  testWidgets('one horizontal drag shifts every diff line by the same amount', (
    tester,
  ) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'long.txt',
        diff: _longDiff(),
      ),
    );

    // 取三个不同行的正文（上下文 / 删除 / 新增各一行）。
    final before = <int, double>{
      for (final index in [2, 3, 4]) index: _textLeft(tester, index),
    };

    await _dragDiff(tester, const Offset(-260, 0));

    final shifts = <double>[
      for (final index in [2, 3, 4]) before[index]! - _textLeft(tester, index),
    ];
    expect(shifts.first, greaterThan(60), reason: '横拖后正文确实左移');
    expect(
      shifts[1],
      moreOrLessEquals(shifts.first, epsilon: 0.001),
      reason: '同一偏移下每行平移量必须相等',
    );
    expect(
      shifts[2],
      moreOrLessEquals(shifts.first, epsilon: 0.001),
      reason: '同一偏移下每行平移量必须相等',
    );
  });

  testWidgets('line numbers stay pinned while diff text scrolls', (
    tester,
  ) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'long.txt',
        diff: _longDiff(),
      ),
    );

    final keys = const GitFileViewerKeys();
    final oldNumber = find.byKey(keys.diffLineOldNumber(3));
    final newNumber = find.byKey(keys.diffLineNewNumber(3));
    final text = find.byKey(keys.diffLineText(3));
    final oldLeft = tester.getTopLeft(oldNumber).dx;
    final newLeft = tester.getTopLeft(newNumber).dx;
    final textLeftBefore = tester.getTopLeft(text).dx;

    await _dragDiff(tester, const Offset(-260, 0));

    // Q2/Q23：行号列（含旧/新行号）钉住不动，只有正文平移。
    expect(tester.getTopLeft(oldNumber).dx, oldLeft);
    expect(tester.getTopLeft(newNumber).dx, newLeft);
    expect(tester.getTopLeft(text).dx, lessThan(textLeftBefore - 60));
  });

  testWidgets('horizontal offset clamps at the widest diff line', (
    tester,
  ) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'long.txt',
        diff: _longDiff(),
      ),
    );

    // 拖到远超最宽行能提供的余量：偏移必须停在 maxExtent，不越界。
    await _dragDiff(tester, const Offset(-60000, 0));
    final clamped = _textLeft(tester, 2);
    expect(clamped, lessThan(0), reason: '确实滚到了最右端');

    await _dragDiff(tester, const Offset(-60000, 0));
    expect(_textLeft(tester, 2), clamped, reason: '到边界后不再继续移动');
  });

  testWidgets('switching diff resets the shared offset for visible rows', (
    tester,
  ) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'long.txt',
        diff: _longDiff(),
      ),
    );
    final origin = _textLeft(tester, 2);

    await _dragDiff(tester, const Offset(-260, 0));
    expect(_textLeft(tester, 2), lessThan(origin - 60));

    // 同一个 State 换一份同样长、内容不同的 diff（位置/类型不变，State 保留）：
    // 已物化的行必须重新读到 0 偏移，不能停在旧 diff 的横滑位置——旧实现
    // 静默 reset 不广播，ValueListenableBuilder 会继续用缓存的旧 value。
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'long.txt',
        diff: _longDiff(fill: 'y'),
      ),
    );

    expect(_textLeft(tester, 2), closeTo(origin, 0.001));
    expect(find.textContaining('yyyy'), findsWidgets);
  });

  testWidgets('a fling keeps gliding after the finger is released', (
    tester,
  ) async {
    await _pump(
      tester,
      GitFileViewer(
        mode: GitFileViewerMode.diff,
        path: 'long.txt',
        diff: _longDiff(),
      ),
    );

    final before = _textLeft(tester, 2);
    // 与普通拖拽同样的 200px，但松手时带速度：真惯性会继续滑行一段
    // （Q20/Q25；纯拖拽位移约 180px，这里要求明显超过 200px）。
    await tester.fling(
      find.byKey(_viewerKeys.diffScrollSurface),
      const Offset(-200, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(before - _textLeft(tester, 2), greaterThan(260));
  });

  testWidgets('horizontal drag inside a vertical list stays with the diff', (
    tester,
  ) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: outer,
            children: [
              const SizedBox(height: 40, child: Text('header')),
              SizedBox(
                height: 600,
                child: GitFileViewer(
                  mode: GitFileViewerMode.diff,
                  path: 'long.txt',
                  diff: _longDiff(),
                ),
              ),
              const SizedBox(height: 2000, child: Text('footer')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = _textLeft(tester, 2);
    await _dragDiff(tester, const Offset(-260, 0));
    // Q24：横滑被 diff 自己消化（touchSlop 压到 4px），外层纵向列表不动。
    expect(outer.offset, 0);
    expect(before - _textLeft(tester, 2), greaterThan(60));
  });

  testWidgets('asymmetric touch slop keeps a near-diagonal drag horizontal', (
    tester,
  ) async {
    // 组件测试的 ambient slop 为 null（→18），`tester.drag` 首段 20px 会越过
    // 任何阈值，测不出手势竞争。这里把环境模拟成 Android 的 8px，并用单个
    // (8,8) 事件构造「横向越线、纵向不越线」：只有「横向 4 / 纵向 8」的非
    // 对称实现能让横向赢下竞技场（contract §2.3 / §6.2）。
    Widget withAndroidSlop(Widget child) => Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          gestureSettings: const DeviceGestureSettings(touchSlop: 8),
        ),
        child: child,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: withAndroidSlop(
              GitFileViewer(
                mode: GitFileViewerMode.diff,
                path: 'tall.txt',
                diff: _tallDiff(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = _textLeft(tester, 2);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_viewerKeys.diffScrollSurface)),
    );
    // 单事件 (8,8)：横向 8>4 越线、纵向 8 不>8 → 横向赢下竞技场（若纵向
    // 先 accept，内层列表会先滚、正文不动）。之后横向已获 arena，负向增量
    // 才会写进共享偏移（offset 从 0 起，负 dx 才是向右滚动内容）。
    await gesture.moveBy(const Offset(8, 8));
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_textLeft(tester, 2), lessThan(before));
  });

  test(
    'DiffScroll clamps offsets, tracks extent and stops at drag boundaries',
    () {
      final scroll = DiffScroll();
      addTearDown(scroll.dispose);

      expect(scroll.value, 0);
      expect(scroll.maxExtent, 0);
      expect(scroll.canScroll, isFalse);

      // maxExtent 重算：装得下时不可滚动，装不下时按新边界限制。
      scroll.updateExtent(120);
      expect(scroll.maxExtent, 120);
      expect(scroll.canScroll, isTrue);

      scroll.jumpTo(40);
      expect(scroll.value, 40);

      // jumpTo 夹取到 [0, maxExtent]。
      scroll.jumpTo(500);
      expect(scroll.value, 120);
      scroll.jumpTo(-5);
      expect(scroll.value, 0);

      // 视口变宽 → maxExtent 变小，当前偏移被夹回新边界并需要广播。
      scroll.jumpTo(100);
      expect(scroll.updateExtent(30), isTrue);
      expect(scroll.maxExtent, 30);
      expect(scroll.value, 30);

      // dragBy 到边界即停，不越界。
      scroll.jumpTo(0);
      scroll.dragBy(20);
      expect(scroll.value, 20);
      scroll.dragBy(90);
      expect(scroll.value, 30);
      scroll.dragBy(-90);
      expect(scroll.value, 0);

      // 数据切换时回位必须走会广播的 jumpTo(0)：ValueListenableBuilder 缓存
      // value，静默改值不会刷新已物化的行（回归：同 State 换 diff 错位）。
      var notifications = 0;
      scroll.addListener(() => notifications++);
      scroll.jumpTo(25);
      expect(scroll.value, 25);
      expect(notifications, 1);
      scroll.jumpTo(25); // 值不变不广播
      expect(notifications, 1);
      scroll.jumpTo(0);
      expect(scroll.value, 0);
      expect(notifications, 2);

      // 非有限输入（NaN/±inf）按 0 处理，不污染内部状态。
      scroll.updateExtent(double.nan);
      expect(scroll.maxExtent, 0);
      scroll.updateExtent(double.infinity);
      expect(scroll.maxExtent, 0);
      scroll.jumpTo(double.nan);
      expect(scroll.value, 0);
      scroll.jumpTo(double.infinity);
      expect(scroll.value, 0);
    },
  );

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
