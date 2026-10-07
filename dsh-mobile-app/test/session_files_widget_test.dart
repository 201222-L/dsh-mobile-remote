// Seam 3：会话文件浏览页（Widget 层）。
//
// 断言用户能看到与能操作什么：目录列出、点开预览、二进制/截断提示、错误与重试、
// 刷新、浏览根不可用时的说明。用 MockClient 注入假服务端，因此走的是真实
// Api + 真实控制器的完整链路。
import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/session_files_screen.dart';
import 'package:dsh_mobile_app/session_files_controller.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Backend {
  _Backend() {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://sf.test'
      ..path = '/m'
      ..token = '';
  }

  bool failDirs = false;
  late final Api api;

  final Map<String, ({List<String> dirs, List<String> files})> listing = {
    '/work': (dirs: ['src'], files: ['README.md', 'photo.png']),
    '/work/src': (dirs: [], files: ['main.dart']),
  };

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.queryParameters['path'] ?? '';
    if (request.url.path == '/m/api/directories') {
      if (failDirs) {
        return http.Response(
          jsonEncode({'error': 'directory-unreadable', 'detail': 'boom'}),
          400,
        );
      }
      final l = listing[path];
      if (l == null) {
        return http.Response(
          jsonEncode({'error': 'directory-unreadable', 'detail': 'no such dir'}),
          400,
        );
      }
      return http.Response(
        jsonEncode({'ok': true, 'path': path, 'dirs': l.dirs, 'files': l.files}),
        200,
      );
    }
    if (request.url.path == '/m/api/files') {
      if (path.endsWith('photo.png')) {
        return http.Response.bytes([0x89, 0x50, 0x00, 0x4E], 200);
      }
      if (path.endsWith('big.txt')) {
        return http.Response.bytes(List<int>.filled(300 * 1024, 0x61), 200);
      }
      return http.Response.bytes(utf8.encode('line one\nline two\n'), 200);
    }
    return http.Response('unexpected ${request.url}', 500);
  }
}

AppStore _store({String sessionId = 's1', String? cwd = '/work'}) {
  final store = AppStore();
  store.sessions = [
    Session(id: sessionId, title: 'S', cwd: cwd, createdAt: 1),
  ];
  return store;
}

Future<void> _pump(
  WidgetTester tester,
  AppStore store,
  Api api, {
  String sessionId = 's1',
}) async {
  final c = SessionFilesController(
    store: store,
    sessionId: sessionId,
    apiClient: api,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: SessionFilesScreen(store: store, sessionId: sessionId, controller: c),
    ),
  );
  await tester.pumpAndSettle();
}

/// 把浏览页 push 到一个"宿主页"之上，这样才能观察真实的返回行为
/// （home: 只有一条路由，pop 无处可去，观察不到"是否退出页面"）。
Future<void> _pumpPushed(
  WidgetTester tester,
  AppStore store,
  Api api, {
  String sessionId = 's1',
}) async {
  final c = SessionFilesController(
    store: store,
    sessionId: sessionId,
    apiClient: api,
  );
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Center(child: Text('宿主页'))),
    ),
  );
  // 注意：不能 await push —— 它返回的 Future 要到该路由**被 pop 时**才完成，
  // await 会让测试在建立阶段就永久挂住。
  unawaited(
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => SessionFilesScreen(
          store: store,
          sessionId: sessionId,
          controller: c,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 触发一次系统返回（等价于右滑手势 / 返回键）。
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('打开页面即列出当前会话工作目录', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);

    expect(find.byKey(const Key('sf-listing')), findsOneWidget);
    expect(find.text('src'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
    // 浏览根（会话工作目录）作为只读提示展示
    expect(find.byKey(const Key('sf-root')), findsOneWidget);
    expect(find.text('/work'), findsOneWidget);
  });

  testWidgets('点目录下钻，面包屑出现并可跳回', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-dir-src')));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);

    expect(find.byKey(const Key('sf-breadcrumb')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sf-crumb-/work')));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('点文件进入预览并显示行号内容', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-file-README.md')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sf-preview')), findsOneWidget);
    expect(find.text('line one'), findsOneWidget);
    expect(find.text('line two'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('二进制文件显示不可预览而不是乱码', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-file-photo.png')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sf-preview-unavailable')), findsOneWidget);
  });

  testWidgets('从预览返回目录', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);
    await tester.tap(find.byKey(const Key('sf-file-README.md')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sf-preview-back')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sf-listing')), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('大文件预览显示截断提示', (tester) async {
    final b = _Backend();
    b.listing['/work'] = (dirs: [], files: ['big.txt']);
    await _pump(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-file-big.txt')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sf-preview-truncated')), findsOneWidget);
  });

  testWidgets('目录读取失败：给出原因、保留旧内容并可重试', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);
    expect(find.text('README.md'), findsOneWidget);

    b.failDirs = true;
    await tester.tap(find.byKey(const Key('sf-refresh')));
    await tester.pumpAndSettle();

    // 旧内容仍在（不因刷新失败变空），并显示原因
    expect(find.text('README.md'), findsOneWidget);
    expect(find.byKey(const Key('sf-error-banner')), findsOneWidget);

    b.failDirs = false;
    await tester.tap(find.byKey(const Key('sf-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-error-banner')), findsNothing);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('会话没有工作目录时说明原因并可重试，页面不空白', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(cwd: null), b.api);

    expect(find.byKey(const Key('sf-error')), findsOneWidget);
    expect(find.textContaining('工作目录'), findsOneWidget);
    expect(find.byKey(const Key('sf-retry')), findsWidgets);
    // 不应出现目录列表
    expect(find.byKey(const Key('sf-listing')), findsNothing);
  });

  testWidgets('浏览页不提供工作区切换入口（作用域是会话）', (tester) async {
    final b = _Backend();
    await _pump(tester, _store(), b.api);

    expect(find.byKey(const Key('sf-workspace-switch')), findsNothing);
    expect(find.byKey(const Key('sf-workspace-picker')), findsNothing);
  });

  testWidgets('会话工作目录不是已注册工作区时依然可浏览（Git 才是受限的那个）', (tester) async {
    final b = _Backend();
    b.listing[r'/tmp/scratch'] = (dirs: [], files: ['note.txt']);
    final store = _store(cwd: r'/tmp/scratch')..workspaces = [];
    await _pump(tester, store, b.api);

    expect(find.byKey(const Key('sf-listing')), findsOneWidget);
    expect(find.text('note.txt'), findsOneWidget);
  });

  // ── 系统返回（真机右滑）语义：往回走一层，而不是直接退出页面 ──
  //
  // 真机症状：在任意子目录右滑都直接退出整个浏览页，丢掉已下钻的层级。
  // 期望与同栏 Git 页面一致：预览 → 退出预览；子目录 → 回上级；已在根 → 才退出。

  testWidgets('在子目录右滑返回上级，而不是退出页面', (tester) async {
    final b = _Backend();
    await _pumpPushed(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-dir-src')));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);

    await _systemBack(tester);

    // 回到工作目录根，页面仍在（未退出到宿主页）
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('宿主页'), findsNothing);
  });

  testWidgets('预览中右滑退出预览回到所在目录，而不是退出页面', (tester) async {
    final b = _Backend();
    await _pumpPushed(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-file-README.md')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-preview')), findsOneWidget);

    await _systemBack(tester);

    expect(find.byKey(const Key('sf-preview')), findsNothing);
    expect(find.byKey(const Key('sf-listing')), findsOneWidget);
    expect(find.text('宿主页'), findsNothing);
  });

  testWidgets('已在工作目录根时右滑才真正退出页面', (tester) async {
    final b = _Backend();
    await _pumpPushed(tester, _store(), b.api);
    expect(find.text('README.md'), findsOneWidget);

    await _systemBack(tester);

    expect(find.text('宿主页'), findsOneWidget);
  });

  testWidgets('下钻两层后连续右滑逐级返回，最后一次才退出', (tester) async {
    final b = _Backend();
    b.listing['/work/src/deep'] = (dirs: [], files: ['leaf.txt']);
    b.listing['/work/src'] = (dirs: ['deep'], files: ['main.dart']);
    await _pumpPushed(tester, _store(), b.api);

    await tester.tap(find.byKey(const Key('sf-dir-src')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sf-dir-deep')));
    await tester.pumpAndSettle();
    expect(find.text('leaf.txt'), findsOneWidget);

    await _systemBack(tester); // → /work/src
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('宿主页'), findsNothing);

    await _systemBack(tester); // → /work
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('宿主页'), findsNothing);

    await _systemBack(tester); // → 退出页面
    expect(find.text('宿主页'), findsOneWidget);
  });
}
