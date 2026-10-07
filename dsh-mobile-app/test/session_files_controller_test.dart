// Seam 2：会话文件浏览控制器（浏览根=会话工作目录、路径栈、面包屑、夹根、限额、错误）。
//
// 通过 MockClient 注入假的 HTTP 层，因此同时覆盖了真实 Api 的解析路径，
// 而不是只测一个手写的假 Api。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/session_files_controller.dart';
import 'package:dsh_mobile_app/session_files_logic.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假服务端：记录请求，按路径返回预设目录或文件内容。
class _Backend {
  _Backend() {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://sf.test'
      ..path = '/m'
      ..token = '';
  }

  /// 置 true 后所有列目录请求都失败（测试里按需切换）。
  bool failDirs = false;
  final List<String> dirRequests = [];
  final List<String> fileRequests = [];

  /// 路径 → (dirs, files)
  final Map<String, ({List<String> dirs, List<String> files})> listing = {
    '/work': (dirs: ['src', 'docs'], files: ['README.md', '.hidden-ignored']),
    '/work/src': (dirs: [], files: ['main.dart']),
    '/work/docs': (dirs: [], files: []),
    '/other': (dirs: [], files: ['x.txt']),
  };

  /// 路径 → 字节
  final Map<String, List<int>> contents = {
    '/work/README.md': utf8.encode('第一行\n第二行\n'),
    '/work/src/main.dart': utf8.encode('void main() {}'),
    '/work/binary.bin': [0x00, 0x01, 0x02],
  };

  late final Api api;

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.queryParameters['path'] ?? '';
    if (request.url.path == '/m/api/directories') {
      dirRequests.add(path);
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
      fileRequests.add(path);
      final bytes = contents[path];
      if (bytes == null) return http.Response('not found', 404);
      return http.Response.bytes(bytes, 200);
    }
    return http.Response('unexpected ${request.url}', 500);
  }
}

/// 造一个含指定会话（及其 cwd）的 store。
AppStore _storeWithSession(String sessionId, String? cwd) {
  final store = AppStore();
  store.sessions = [
    Session(id: sessionId, title: 'S', cwd: cwd, createdAt: 1),
  ];
  return store;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('浏览根是当前会话的工作目录', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);

    await c.open();

    expect(c.stage, BrowseStage.listing);
    expect(c.root, '/work');
    expect(c.currentPath, '/work');
    expect(c.dirs, ['src', 'docs']);
    expect(c.files, ['README.md', '.hidden-ignored']);
    expect(c.atRoot, isTrue);
    // 只列了一次目录：没有多余的根视图探测
    expect(b.dirRequests, ['/work']);
  });

  test('会话没有工作目录时给出原因，而不是回退全局工作区', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', null);
    // 即便全局选了一个工作区，也不该被用上
    store.workspaces = [
      {'path': '/other', 'title': 'Other'},
    ];
    await store.setWorkspace('/other');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);

    await c.open();

    expect(c.stage, BrowseStage.error);
    expect(c.errorReason, contains('工作目录'));
    expect(c.root, isEmpty);
    // 没有发出任何目录请求
    expect(b.dirRequests, isEmpty);
  });

  test('浏览不读也不写全局「当前选中工作区」', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    store.workspaces = [
      {'path': '/other', 'title': 'Other'},
    ];
    await store.setWorkspace('/other');
    final before = store.workspacePath;

    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    await c.openDir('src');

    // 全局工作区筛选状态保持不变（那是首页会话列表的状态）
    expect(store.workspacePath, before);
    expect(c.root, '/work');
  });

  test('会话不在列表里时补拉一次，仍拿不到就报错', () async {
    final b = _Backend();
    final store = AppStore()..sessions = [];
    final c = SessionFilesController(store: store, sessionId: 'gone', apiClient: b.api);

    await c.open();

    expect(c.stage, BrowseStage.error);
    expect(c.errorReason, contains('工作目录'));
  });

  test('进入子目录并返回上级', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();

    await c.openDir('src');
    expect(c.currentPath, '/work/src');
    expect(c.files, ['main.dart']);
    expect(c.atRoot, isFalse);

    await c.goUp();
    expect(c.currentPath, '/work');
    expect(c.atRoot, isTrue);
  });

  test('已在根时向上不动，也不发请求', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    final before = b.dirRequests.length;

    await c.goUp();

    expect(c.currentPath, '/work');
    expect(b.dirRequests.length, before);
  });

  test('越出浏览根的路径被拦截，不发给服务端', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    final before = b.dirRequests.length;

    await c.loadDir('/etc');

    expect(c.stage, BrowseStage.error);
    expect(c.errorReason, contains('无法向上浏览'));
    expect(b.dirRequests.length, before, reason: '越界请求不应发出');
  });

  test('面包屑从会话工作目录开始，不越出到根', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    await c.openDir('src');

    final crumbs = c.breadcrumbs;
    expect(crumbs.first.path, '/work');
    expect(crumbs.last.path, '/work/src');
    // 不应出现 /work 之上的层级
    expect(crumbs.every((e) => isWithinRoot('/work', e.path)), isTrue);
  });

  test('跳到面包屑上的某一级', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    await c.openDir('src');

    await c.jumpTo('/work');

    expect(c.currentPath, '/work');
    expect(c.files, contains('README.md'));
  });

  test('打开文件预览并返回目录', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();

    await c.openFile('README.md');
    expect(c.stage, BrowseStage.preview);
    expect(c.previewPath, '/work/README.md');
    expect((c.preview! as PreviewText).text, '第一行\n第二行\n');

    await c.closePreview();
    expect(c.stage, BrowseStage.listing);
    expect(c.previewPath, isEmpty);
  });

  test('二进制文件预览给出不可预览原因', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();

    await c.openFile('binary.bin');

    expect(c.preview, isA<PreviewUnavailable>());
  });

  test('目录读取失败时保留旧内容并给出原因', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    expect(c.files, contains('README.md'));

    b.failDirs = true;
    await c.refresh();

    expect(c.stage, BrowseStage.error);
    expect(c.errorReason, contains('无法读取目录'));
    // 旧内容仍在，页面不会变空
    expect(c.files, contains('README.md'));
  });

  test('重试后恢复', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    b.failDirs = true;
    await c.refresh();
    expect(c.stage, BrowseStage.error);

    b.failDirs = false;
    await c.retry();

    expect(c.stage, BrowseStage.listing);
    expect(c.files, contains('README.md'));
  });

  test('预览中刷新重新取同一个文件', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();
    await c.openFile('README.md');
    final before = b.fileRequests.length;

    await c.refresh();

    expect(c.stage, BrowseStage.preview);
    expect(b.fileRequests.length, before + 1);
    expect(b.fileRequests.last, '/work/README.md');
  });

  test('文件不存在时给出原因且不崩', () async {
    final b = _Backend();
    final store = _storeWithSession('s1', '/work');
    final c = SessionFilesController(store: store, sessionId: 's1', apiClient: b.api);
    await c.open();

    await c.openFile('nope.txt');

    expect(c.stage, BrowseStage.error);
    expect(c.errorReason, contains('无法读取文件'));
  });
}
