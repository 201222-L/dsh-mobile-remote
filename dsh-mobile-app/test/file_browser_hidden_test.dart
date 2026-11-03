// issue #45：会话文件浏览按设置显示隐藏条目（App 侧）。
//
// 覆盖：AppStore 默认/持久化、Api includeHidden 查询参数、SessionFilesController
// 传参与 .git 防御性过滤、隐藏文件预览、目录选择器不受影响。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/session_files_screen.dart';
import 'package:dsh_mobile_app/screens/sheets.dart';
import 'package:dsh_mobile_app/session_files_controller.dart';
import 'package:dsh_mobile_app/session_files_logic.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 模拟新宿主：includeHidden=1 时返回点开头条目；同时故意始终返回 `.git`
/// 以验证客户端防御性过滤。关闭开关时按旧 host 默认行为过滤点开头条目。
class _HiddenBackend {
  _HiddenBackend() {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://hidden.test'
      ..path = '/m'
      ..token = '';
  }

  late final Api api;
  final List<Uri> directoryRequests = [];
  final List<String> fileRequests = [];

  /// 模拟旧宿主：忽略 includeHidden 参数、始终不返回隐藏条目。
  bool ignoreIncludeHidden = false;

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.queryParameters['path'] ?? '';
    if (request.url.path == '/m/api/directories') {
      directoryRequests.add(request.url);
      final includeHidden =
          !ignoreIncludeHidden &&
          request.url.queryParameters['includeHidden'] == '1';
      final dirs = includeHidden ? ['.github', 'src'] : ['src'];
      final files = includeHidden
          ? ['.env', '.gitignore', 'README.md']
          : ['README.md'];
      return http.Response(
        jsonEncode({
          'ok': true,
          'path': path,
          // 旧/第三方 host 错误行为：即使 includeHidden 也返回 `.git`。
          'dirs': [...dirs, '.git'],
          'files': [...files, '.git'],
        }),
        200,
      );
    }
    if (request.url.path == '/m/api/files') {
      fileRequests.add(path);
      return http.Response.bytes(utf8.encode('SECRET=1\n'), 200);
    }
    return http.Response('unexpected ${request.url}', 500);
  }
}

AppStore _store({String cwd = '/work'}) {
  final store = AppStore();
  store.sessions = [
    Session(id: 's1', title: 'S', cwd: cwd, createdAt: 1),
  ];
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppStore.showHiddenFiles', () {
    test('defaults to true and persists across restarts', () async {
      final store = AppStore();
      await store.loadPrefs();
      expect(store.showHiddenFiles, isTrue);

      await store.setShowHiddenFiles(false);
      final restored = AppStore();
      await restored.loadPrefs();
      expect(restored.showHiddenFiles, isFalse);
    });
  });

  group('Api.directories(includeHidden)', () {
    test('default requests omit includeHidden and true adds includeHidden=1', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({'ok': true, 'dirs': <String>[], 'files': <String>[]}),
          200,
        );
      });
      final clientApi = Api(client: client)
        ..baseUrl = 'https://host.example'
        ..path = '/m';

      await clientApi.directories('/work');
      expect(requests.last.url.path, '/m/api/directories');
      expect(requests.last.url.queryParameters['path'], '/work');
      expect(
        requests.last.url.queryParameters.containsKey('includeHidden'),
        isFalse,
      );

      await clientApi.directories('/work', includeHidden: true);
      expect(requests.last.url.queryParameters['includeHidden'], '1');
    });
  });

  group('SessionFilesController hidden entries', () {
    test('passes includeHidden and drops .git defensively', () async {
      final backend = _HiddenBackend();
      final controller = SessionFilesController(
        store: _store(),
        sessionId: 's1',
        apiClient: backend.api,
      );
      await controller.open();

      expect(
        backend.directoryRequests.last.queryParameters['includeHidden'],
        '1',
      );
      expect(controller.dirs, containsAll(['.github', 'src']));
      expect(
        controller.files,
        containsAll(['.env', '.gitignore', 'README.md']),
      );
      expect(controller.dirs, isNot(contains('.git')));
      expect(controller.files, isNot(contains('.git')));
    });

    test('disabled setting omits includeHidden and old-host behavior stays', () async {
      final backend = _HiddenBackend();
      final store = _store()..showHiddenFiles = false;
      final controller = SessionFilesController(
        store: store,
        sessionId: 's1',
        apiClient: backend.api,
      );
      await controller.open();

      expect(
        backend.directoryRequests.last.queryParameters.containsKey(
          'includeHidden',
        ),
        isFalse,
      );
      expect(controller.dirs, ['src']);
      expect(controller.files, ['README.md']);
      expect(controller.dirs, isNot(contains('.git')));
    });

    test('setting change takes effect on next refresh', () async {
      final backend = _HiddenBackend();
      final store = _store();
      final controller = SessionFilesController(
        store: store,
        sessionId: 's1',
        apiClient: backend.api,
      );
      await controller.open();
      expect(controller.files, contains('.env'));

      store.showHiddenFiles = false;
      await controller.refresh();

      expect(controller.files, ['README.md']);
      expect(
        backend.directoryRequests.last.queryParameters.containsKey(
          'includeHidden',
        ),
        isFalse,
      );
    });

    test('old host ignoring includeHidden degrades silently', () async {
      final backend = _HiddenBackend()..ignoreIncludeHidden = true;
      final controller = SessionFilesController(
        store: _store(),
        sessionId: 's1',
        apiClient: backend.api,
      );
      await controller.open();

      // 请求仍带 includeHidden=1，但旧宿主不返回隐藏条目：不报错、正常列表。
      expect(
        backend.directoryRequests.last.queryParameters['includeHidden'],
        '1',
      );
      expect(controller.stage, BrowseStage.listing);
      expect(controller.dirs, ['src']);
      expect(controller.files, ['README.md']);
    });

    test('hidden file previews through the normal read-only path', () async {
      final backend = _HiddenBackend();
      final controller = SessionFilesController(
        store: _store(),
        sessionId: 's1',
        apiClient: backend.api,
      );
      await controller.open();
      await controller.openFile('.env');

      expect(controller.stage, BrowseStage.preview);
      final verdict = controller.preview;
      expect(verdict, isA<PreviewText>());
      expect((verdict! as PreviewText).text, contains('SECRET=1'));
    });

    test('withoutGitEntries only removes the exact .git name', () {
      expect(
        withoutGitEntries(['.git', '.gitignore', '.github', 'git', 'a.git']),
        ['.gitignore', '.github', 'git', 'a.git'],
      );
    });
  });

  testWidgets('session file browser shows hidden entries but never .git', (
    tester,
  ) async {
    final backend = _HiddenBackend();
    final store = _store();
    final controller = SessionFilesController(
      store: store,
      sessionId: 's1',
      apiClient: backend.api,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SessionFilesScreen(
          store: store,
          sessionId: 's1',
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 隐藏目录/文件与普通条目同一列表展示；`.git` 不出现。
    expect(find.byKey(const Key('sf-dir-.github')), findsOneWidget);
    expect(find.byKey(const Key('sf-file-.env')), findsOneWidget);
    expect(find.byKey(const Key('sf-file-.gitignore')), findsOneWidget);
    expect(find.byKey(const Key('sf-dir-src')), findsOneWidget);
    expect(find.text('.git'), findsNothing);

    // 隐藏文件正常预览。
    await tester.tap(find.byKey(const Key('sf-file-.env')));
    await tester.pumpAndSettle();
    expect(find.textContaining('SECRET=1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sf-preview-back')));
    await tester.pumpAndSettle();

    // 关闭设置后刷新：下一次目录加载生效。
    await store.setShowHiddenFiles(false);
    await tester.tap(find.byKey(const Key('sf-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-dir-.github')), findsNothing);
    expect(find.byKey(const Key('sf-file-.env')), findsNothing);
    expect(find.byKey(const Key('sf-file-README.md')), findsOneWidget);
  });

  testWidgets('directory picker requests never include includeHidden', (
    tester,
  ) async {
    final directoryRequests = <http.Request>[];
    final pickerApi = Api(
      client: MockClient((request) async {
        if (request.url.path == '/m/api/workspaces') {
          return http.Response(
            jsonEncode({'ok': true, 'workspaces': <Object>[]}),
            200,
          );
        }
        if (request.url.path == '/m/api/directories') {
          directoryRequests.add(request);
          return http.Response(
            jsonEncode({
              'ok': true,
              'path': request.url.queryParameters['path'] ?? '',
              'dirs': ['home'],
              'files': <String>[],
              'sep': '/',
            }),
            200,
          );
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    )
      ..baseUrl = 'http://dir.test'
      ..path = '/m'
      ..token = '';

    final store = AppStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-dir-picker'),
              onPressed: () => showDirPicker(
                context,
                store,
                (_) {},
                apiClient: pickerApi,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dir-picker')));
    await tester.pumpAndSettle();

    // 目录选择器复用同一 Api.directories，但必须保持默认 false：
    // 设置开关只影响会话文件浏览。
    expect(directoryRequests, isNotEmpty);
    expect(
      directoryRequests.every(
        (request) => !request.url.queryParameters.containsKey('includeHidden'),
      ),
      isTrue,
    );
  });
}
