// Seam 3：会话文件浏览页（Widget 层）。
//
// 断言用户能看到与能操作什么：目录列出、点开预览、二进制/截断提示、错误与重试、
// 刷新、浏览根不可用时的说明。用 MockClient 注入假服务端，因此走的是真实
// Api + 真实控制器的完整链路。
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
}
