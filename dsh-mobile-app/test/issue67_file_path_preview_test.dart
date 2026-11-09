// issue #67（M3 Batch 2-B）：工具卡路径可点预览的 App 验收测试。
//
// 覆盖四态（可点 / 不可点 / 展开态入口 / 旧插件与能力位关闭）、点击只请求 cwd 内路径、
// 返回保持滚动与展开、失败态、无 cwd、semantics，以及控制器 initialRelativePath /
// openRelativeFile / refresh 嵌套路径回归。夹具走真实 Api + MockClient，不 mock 控制器内部。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/screens/session_files_screen.dart';
import 'package:dsh_mobile_app/session_files_controller.dart';
import 'package:dsh_mobile_app/session_files_logic.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
import 'package:dsh_mobile_app/tool_cards.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Batch 1 + Batch 2-A 全部 13 个可投影工具（与服务端能力位一致）。
const List<String> _allTools = [
  'bash',
  'pwsh',
  'read',
  'write',
  'edit',
  'grep',
  'glob',
  'web_fetch',
  'web_search',
  'read_image',
  'todo_write',
  'ask_user_question',
  'skill',
];

/// 假服务端：记录每个目录 / 文件 / 历史请求，按路径返回夹具。
class _PreviewBackend {
  _PreviewBackend({List<String>? tools}) : tools = tools ?? _allTools;

  /// 能力位声明的工具集合；空列表 = 旧插件/能力位关闭。
  final List<String> tools;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue67.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
      unknownEvents: true,
      callCorrelation: true,
    )
    ..toolCardsCapabilities = tools.isEmpty
        ? const ToolCardsCapabilities()
        : ToolCardsCapabilities(version: 1, tools: tools.toSet());

  final List<String> dirRequests = [];
  final List<String> fileRequests = [];
  int historyRequests = 0;

  Map<String, dynamic> _summary(Map<String, dynamic> summary) => {
    'summary': summary,
  };

  /// 工具卡夹具：可点 read/write/image、不可点 read、非法 relative、失败态。
  List<Map<String, dynamic>> get _events => [
    {
      'seq': 1,
      'type': 'turn/start',
      'data': {'turn': 1},
    },
    {
      'seq': 2,
      'type': 'user/message',
      'data': {'messageId': 'u1', 'text': '看一下这些文件', 'sourceKind': 'user'},
    },
    // 长正文：制造真实可滚动内容，供「返回保持滚动位置」断言。
    {
      'seq': 3,
      'type': 'assistant/message',
      'data': {
        'turn': 1,
        'step': 1,
        'text': List<String>.filled(120, '滚动内容行').join('\n'),
      },
    },
    {
      'seq': 4,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-read',
        'name': 'read',
        'arguments': '{"file_path":"src/b.ts","offset":2,"limit":4}',
        ..._summary({
          'kind': 'file',
          'tool': 'read',
          'filePath': 'src/b.ts',
          'offset': 2,
          'limit': 4,
          'relative': 'src/b.ts',
          'previewable': true,
        }),
      },
    },
    {
      'seq': 5,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-read',
        'name': 'read',
        'text': 'line two',
        'isError': false,
      },
    },
    {
      'seq': 6,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-plain',
        'name': 'read',
        'arguments': '{"file_path":"src/c.ts"}',
        ..._summary({'kind': 'file', 'tool': 'read', 'filePath': 'src/c.ts'}),
      },
    },
    {
      'seq': 7,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-plain',
        'name': 'read',
        'text': 'plain',
        'isError': false,
      },
    },
    {
      'seq': 8,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-bad',
        'name': 'read',
        'arguments': '{"file_path":"x.ts"}',
        ..._summary({
          'kind': 'file',
          'tool': 'read',
          'filePath': 'x.ts',
          // 服务端被攻破/伪造：非法 relative 必须被客户端二次夹取拒绝。
          'relative': '../etc/passwd',
          'previewable': true,
        }),
      },
    },
    {
      'seq': 9,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-bad',
        'name': 'read',
        'text': 'bad',
        'isError': false,
      },
    },
    {
      'seq': 10,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-write',
        'name': 'write',
        'arguments': '{"file_path":"src/a.ts","content":"hi"}',
        ..._summary({
          'kind': 'file',
          'tool': 'write',
          'filePath': 'src/a.ts',
          'sizeKb': 1,
          'diff': '--- /dev/null\n+++ b/src/a.ts\n@@ -0,0 +1,1 @@\n+hi\n',
          'relative': 'src/a.ts',
          'previewable': true,
        }),
      },
    },
    {
      'seq': 11,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-write',
        'name': 'write',
        'text': 'wrote a.ts',
        'isError': false,
      },
    },
    {
      'seq': 12,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-error',
        'name': 'read',
        'arguments': '{"file_path":"src/d.ts"}',
        ..._summary({
          'kind': 'file',
          'tool': 'read',
          'filePath': 'src/d.ts',
          'relative': 'src/d.ts',
          'previewable': true,
        }),
      },
    },
    {
      'seq': 13,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-error',
        'name': 'read',
        'text': 'boom',
        'isError': true,
      },
    },
    {
      'seq': 14,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-img',
        'name': 'read_image',
        'arguments': '{"file_path":"photo.png"}',
        ..._summary({
          'kind': 'image',
          'tool': 'read_image',
          'filePath': 'photo.png',
          'relative': 'photo.png',
          'previewable': true,
        }),
      },
    },
    {
      'seq': 15,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-img',
        'name': 'read_image',
        'text': 'image ok',
        'isError': false,
      },
    },
    {
      'seq': 16,
      'type': 'turn/end',
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
    },
  ];

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    if (path == '/m/api/history') {
      historyRequests++;
      return _json({
        'ok': true,
        'hasMore': false,
        'turnTails': const <String, dynamic>{},
        'events': _events,
      });
    }
    if (path == '/m/api/directories') {
      dirRequests.add(query['path'] ?? '');
      return _json({
        'ok': true,
        'path': query['path'],
        'dirs': const <String>[],
        'files': const <String>[],
      });
    }
    if (path == '/m/api/files') {
      fileRequests.add(query['path'] ?? '');
      return http.Response.bytes(
        utf8.encode('file body line\n'),
        200,
        headers: {'connection': 'close'},
      );
    }
    // 预览页的 Git 历史入口探测：返回不可用 → 不显示入口，不影响文件预览。
    if (path == '/m/api/git/capabilities') {
      return _json({
        'ok': true,
        'git': {'available': false},
      });
    }
    if (path == '/m/api/notifications') {
      return _json({'ok': true, 'items': const <Object>[]});
    }
    if (path == '/m/api/queue') {
      return _json({'ok': true, 'rows': const <Object>[]});
    }
    if (path == '/m/api/todos') {
      return _json({'ok': true, 'todos': const <Object>[]});
    }
    return _json({'ok': true});
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

AppStore _store({String? cwd = '/work'}) {
  final store = AppStore()
    ..sessionId = 'session-tools'
    // 完全展开：M1 的标准档会把已完成轮次的过程折叠，工具卡不构建。
    ..stepDisplayMode = WorkStepDisplayMode.expanded;
  store.sessions = [
    Session(id: 'session-tools', title: 'S', cwd: cwd, createdAt: 1),
  ];
  return store;
}

Future<void> _pumpChat(
  WidgetTester tester,
  AppStore store,
  _PreviewBackend backend, {
  Size size = const Size(900, 5000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: const ValueKey('issue67-chat'),
        store: store,
        apiClient: backend.api,
        gitReadApi: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Finder _card(String callId, int seq) =>
    find.byKey(ValueKey<String>('tool:$callId:$seq'));

/// 点击折叠行**路径段的字形**（路径从行首开始；suffix/胶囊不参与命中）。
Future<void> _tapFoldPath(WidgetTester tester, Finder textFinder) async {
  await tester.ensureVisible(textFinder);
  await tester.pumpAndSettle();
  final rect = tester.getRect(textFinder);
  await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
  await tester.pumpAndSettle();
}

/// 连续返回直到退出会话文件页（默认方案：预览 → 父目录 → 逐级 → 会话页）。
Future<void> _backToChat(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    if (find.byType(SessionFilesScreen).evaluate().isEmpty) return;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }
  fail('未能返回到会话页');
}

ScrollableState _mainScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 纯逻辑：wire 模型解析 + 词法夹取 ─────────────────────────────────
  group('ToolCallSummary.relative/previewable 解析', () {
    ToolCallSummary? parse(Map<String, dynamic> json) =>
        ToolCallSummary.fromJson({
          'kind': 'file',
          'tool': 'read',
          'filePath': 'src/b.ts',
          ...json,
        });

    test('previewable:true + 合法 relative → canPreviewFile', () {
      final call = parse({'relative': 'src/b.ts', 'previewable': true});
      expect(call, isNotNull);
      expect(call!.relativePath, 'src/b.ts');
      expect(call.previewable, isTrue);
      expect(call.canPreviewFile, isTrue);
    });

    test('旧插件（两字段缺省）→ 不可点', () {
      final call = parse({});
      expect(call!.relativePath, isNull);
      expect(call.previewable, isFalse);
      expect(call.canPreviewFile, isFalse);
    });

    test('previewable:false + relative → 不可点', () {
      final call = parse({'relative': 'src/b.ts', 'previewable': false});
      expect(call!.relativePath, isNull);
      expect(call.canPreviewFile, isFalse);
    });

    test('previewable:true 但缺 relative / 类型不符 → 不可点', () {
      expect(parse({'previewable': true})!.canPreviewFile, isFalse);
      expect(
        parse({'relative': 42, 'previewable': true})!.canPreviewFile,
        isFalse,
      );
      expect(
        parse({'relative': 'src/b.ts', 'previewable': 'true'})!.canPreviewFile,
        isFalse,
      );
      expect(
        parse({'relative': '../a', 'previewable': true})!.canPreviewFile,
        isFalse,
      );
    });
  });

  group('normalizeSessionRelativePath / resolveSessionRelativePath', () {
    test('非法集合逐条拒绝（与服端词法逐字一致）', () {
      final invalid = <Object?>[
        '/etc/passwd',
        'C:\\x',
        'a\\b',
        '../a',
        'a/../b',
        'a//b',
        './a',
        '',
        '  a ',
        'a\u0000b',
        'a'.padRight(301, 'x'),
        42,
        null,
      ];
      for (final value in invalid) {
        expect(
          normalizeSessionRelativePath(value),
          isNull,
          reason: '$value 必须拒绝',
        );
      }
    });

    test('合法值原样返回（不 trim、不改写）', () {
      for (final value in ['src/b.ts', 'a b/中文.md', '~/.env', 'a/b/c']) {
        expect(normalizeSessionRelativePath(value), value);
      }
      // 恰好 300 字允许。
      final ok = 'a' * 300;
      expect(normalizeSessionRelativePath(ok), ok);
    });

    test('resolve：只在 root 内拼接；Windows 分隔符与尾分隔符', () {
      expect(resolveSessionRelativePath('/work', 'src/b.ts'), '/work/src/b.ts');
      expect(
        resolveSessionRelativePath('/work/', 'src/b.ts'),
        '/work/src/b.ts',
      );
      expect(resolveSessionRelativePath('/', 'src/b.ts'), '/src/b.ts');
      expect(
        resolveSessionRelativePath('C:\\work', 'src/b.ts', sep: '\\'),
        'C:\\work\\src\\b.ts',
      );
      expect(resolveSessionRelativePath('/work', '../etc/passwd'), isNull);
      expect(resolveSessionRelativePath('/work', '/etc/passwd'), isNull);
      expect(resolveSessionRelativePath('/work', 'C:\\x'), isNull);
      expect(resolveSessionRelativePath('', 'src/b.ts'), isNull);
    });

    test('toolFoldPathParts：仅可预览的 file/image 才拆路径段', () {
      final call = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'read',
        'filePath': 'src/b.ts',
        'offset': 2,
        'limit': 4,
        'relative': 'src/b.ts',
        'previewable': true,
      });
      final parts = toolFoldPathParts(call!);
      expect(parts, isNotNull);
      expect(parts!.path, 'src/b.ts');
      expect(parts.suffix, ' · 行 2–5');
      // 不可预览 → null（调用方保持纯 Text）。
      final plain = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'read',
        'filePath': 'src/b.ts',
      });
      expect(toolFoldPathParts(plain!), isNull);
    });
  });

  // ── 控制器：initialRelativePath / openRelativeFile / refresh ─────────
  group('SessionFilesController issue #67', () {
    test('open(initialRelativePath) 直接进预览：只请求父目录 + /files，不列 root', () async {
      final b = _PreviewBackend();
      final c = SessionFilesController(
        store: _store(),
        sessionId: 'session-tools',
        apiClient: b.api,
        initialRelativePath: 'src/b.ts',
      );

      await c.open();

      expect(c.stage, BrowseStage.preview);
      expect(c.previewPath, '/work/src/b.ts');
      expect(c.currentPath, '/work/src');
      expect(b.dirRequests, ['/work/src'], reason: '不先列 root');
      expect(b.fileRequests, ['/work/src/b.ts']);
    });

    test('非法 initialRelativePath：零请求、错误页、不崩', () async {
      final b = _PreviewBackend();
      final c = SessionFilesController(
        store: _store(),
        sessionId: 'session-tools',
        apiClient: b.api,
        initialRelativePath: '../etc/passwd',
      );

      await c.open();

      expect(c.stage, BrowseStage.error);
      expect(b.dirRequests, isEmpty);
      expect(b.fileRequests, isEmpty);
    });

    test('openRelativeFile 合法值只拼 root 内路径；非法值零请求', () async {
      final b = _PreviewBackend();
      final c = SessionFilesController(
        store: _store(),
        sessionId: 'session-tools',
        apiClient: b.api,
      );
      await c.open();
      b.dirRequests.clear();
      b.fileRequests.clear();

      await c.openRelativeFile('src/b.ts');
      expect(c.previewPath, '/work/src/b.ts');
      expect(b.fileRequests, ['/work/src/b.ts']);
      expect(
        b.dirRequests.every((path) => isWithinRoot('/work', path)),
        isTrue,
      );

      final beforeDirs = b.dirRequests.length;
      final beforeFiles = b.fileRequests.length;
      await c.openRelativeFile('/etc/passwd');
      await c.openRelativeFile('a/../../b');
      expect(b.dirRequests.length, beforeDirs, reason: '非法 relative 不发请求');
      expect(b.fileRequests.length, beforeFiles, reason: '非法 relative 不发请求');
    });

    test('预览中 refresh 取回同一嵌套文件（currentPath 必须是父目录）', () async {
      final b = _PreviewBackend();
      final c = SessionFilesController(
        store: _store(),
        sessionId: 'session-tools',
        apiClient: b.api,
        initialRelativePath: 'src/b.ts',
      );
      await c.open();
      b.dirRequests.clear();

      await c.refresh();

      expect(c.stage, BrowseStage.preview);
      expect(c.previewPath, '/work/src/b.ts');
      expect(c.currentPath, '/work/src');
      expect(b.fileRequests, ['/work/src/b.ts', '/work/src/b.ts']);
      expect(b.dirRequests, isEmpty, reason: 'refresh 只重取文件，不重列目录');
    });

    test('closePreview 回到父目录列表而不是根', () async {
      final b = _PreviewBackend();
      final c = SessionFilesController(
        store: _store(),
        sessionId: 'session-tools',
        apiClient: b.api,
        initialRelativePath: 'src/b.ts',
      );
      await c.open();

      await c.closePreview();

      expect(c.stage, BrowseStage.listing);
      expect(c.currentPath, '/work/src');
      expect(b.dirRequests.last, '/work/src');
    });

    test('无 cwd 会话：保持既有错误语义，不浏览', () async {
      final b = _PreviewBackend();
      final c = SessionFilesController(
        store: _store(cwd: null),
        sessionId: 'session-tools',
        apiClient: b.api,
        initialRelativePath: 'src/b.ts',
      );

      await c.open();

      expect(c.stage, BrowseStage.error);
      expect(c.errorReason, contains('工作目录'));
      expect(b.dirRequests, isEmpty);
      expect(b.fileRequests, isEmpty);
    });
  });

  // ── Widget：四态、点击、返回保持、旧插件、能力位、失败态、semantics ──
  group('工具卡路径可点预览（widget）', () {
    testWidgets('A 态：路径段是可点链接，既有折叠行 find.text 不破', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(), backend);

      final key = find.byKey(const Key('tool-path-fold:call-read'));
      expect(key, findsOneWidget);
      // Text.rich 的 toPlainText 仍是整行原字符串（既有断言不破）。
      expect(find.text('src/b.ts · 行 2–5'), findsOneWidget);

      final ctx = tester.element(key);
      final text = tester.widget<Text>(key);
      final rootSpan = text.textSpan as TextSpan;
      final spans = rootSpan.children!.cast<TextSpan>();
      final pathSpan = spans[0];
      final suffixSpan = spans[1];
      expect(pathSpan.text, 'src/b.ts');
      expect(pathSpan.style?.color, DshColors.brand(ctx));
      expect(pathSpan.style?.decoration, TextDecoration.underline);
      expect(suffixSpan.text, ' · 行 2–5');
      expect(suffixSpan.style, isNull, reason: 'suffix 继承 ink3 基础样式');
    });

    testWidgets('B 态：旧插件/非法 relative 保持纯文本，点击无请求不展开', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(), backend);

      expect(find.byKey(const Key('tool-path-fold:call-plain')), findsNothing);
      expect(find.byKey(const Key('tool-path-fold:call-bad')), findsNothing);

      // 旧插件：ink3 纯文本、无下划线。
      final plainCtx = tester.element(find.text('src/c.ts'));
      final plain = tester.widget<Text>(find.text('src/c.ts'));
      expect(plain.style?.color, DshColors.ink3(plainCtx));
      expect(plain.style?.decoration, isNull);

      await _tapFoldPath(tester, find.text('src/c.ts'));
      await _tapFoldPath(tester, find.text('x.ts'));

      expect(find.byType(SessionFilesScreen), findsNothing);
      expect(backend.fileRequests, isEmpty);
      expect(backend.dirRequests, isEmpty);
      expect(find.textContaining('callId: call-plain'), findsNothing);
      expect(find.textContaining('callId: call-bad'), findsNothing);
    });

    testWidgets('点击路径只请求 cwd 内路径并打开预览', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(), backend);

      await _tapFoldPath(tester, find.text('src/b.ts · 行 2–5'));

      expect(find.byType(SessionFilesScreen), findsOneWidget);
      expect(find.byKey(const Key('sf-preview')), findsOneWidget);
      expect(backend.fileRequests, ['/work/src/b.ts']);
      final allRequests = [...backend.dirRequests, ...backend.fileRequests];
      expect(allRequests, isNotEmpty);
      for (final path in allRequests) {
        expect(isWithinRoot('/work', path), isTrue, reason: '请求越界：$path');
        expect(path.contains('..'), isFalse, reason: '请求含 ..：$path');
      }
    });

    testWidgets('展开态不新增重复路径行；write diff 卡链接仍可点', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(), backend);

      // 展开 write diff 卡：diff 查看器（旧行为）与折叠行链接同时存在。
      final writeCard = _card('call-write', 10);
      await tester.ensureVisible(writeCard);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getTopLeft(writeCard) + const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tool-diff-viewer')), findsOneWidget);
      expect(
        find.byKey(const Key('tool-path-fold:call-write')),
        findsOneWidget,
      );
      // 默认方案：展开体不新增重复路径行（折叠行链接仍在）。
      expect(find.byKey(const Key('tool-path-open:call-write')), findsNothing);

      await _tapFoldPath(
        tester,
        find.byKey(const Key('tool-path-fold:call-write')),
      );
      expect(find.byType(SessionFilesScreen), findsOneWidget);
      expect(backend.fileRequests, ['/work/src/a.ts']);
    });

    testWidgets('失败态：previewable 卡仍可点，卡片失败样式与默认收起不变', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(), backend);

      expect(
        find.byKey(const Key('tool-path-fold:call-error')),
        findsOneWidget,
      );
      // 非 debug：失败卡仍默认收起（不因 previewable 变成展开）。
      expect(find.textContaining('callId: call-error'), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsWidgets);

      await _tapFoldPath(tester, find.text('src/d.ts'));
      expect(find.byType(SessionFilesScreen), findsOneWidget);
      expect(backend.fileRequests, ['/work/src/d.ts']);
    });

    testWidgets('无 cwd 会话：卡片仍可点，预览页显示既有错误，卡片不新增错误', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(cwd: null), backend);

      await _tapFoldPath(tester, find.text('src/b.ts · 行 2–5'));

      expect(find.byType(SessionFilesScreen), findsOneWidget);
      expect(find.byKey(const Key('sf-error')), findsOneWidget);
      expect(find.text('这个会话没有工作目录，无法浏览文件'), findsOneWidget);
      expect(backend.dirRequests, isEmpty);
      expect(backend.fileRequests, isEmpty);
    });

    testWidgets('返回保持：滚动位置与卡片展开态不变', (tester) async {
      final backend = _PreviewBackend();
      // 较矮视口 + 长正文 → 存在真实可滚动距离。
      await _pumpChat(tester, _store(), backend, size: const Size(900, 900));

      final card = _card('call-read', 4);
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      // 展开卡片（点标题左上角），记录展开体标记与滚动位置。
      await tester.tapAt(tester.getTopLeft(card) + const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(find.textContaining('callId: call-read'), findsOneWidget);

      final pathText = find.text('src/b.ts · 行 2–5');
      await tester.ensureVisible(pathText);
      await tester.pumpAndSettle();
      final position = _mainScrollable(tester).position;
      final offsetBefore = position.pixels;
      final historyBefore = backend.historyRequests;
      expect(offsetBefore, greaterThan(0), reason: '需要真实滚动位置，断言才有意义');

      await _tapFoldPath(tester, pathText);
      expect(find.byType(SessionFilesScreen), findsOneWidget);

      await _backToChat(tester);

      expect(find.byType(SessionFilesScreen), findsNothing);
      expect(position.pixels, closeTo(offsetBefore, 0.5));
      expect(find.textContaining('callId: call-read'), findsOneWidget);
      expect(find.text('src/b.ts · 行 2–5'), findsOneWidget);
      expect(backend.historyRequests, historyBefore, reason: '返回不应重载历史');
    });

    testWidgets('旧插件/能力位关闭：通用卡无链接、无新图标', (tester) async {
      final backend = _PreviewBackend(tools: const <String>[]);
      await _pumpChat(tester, _store(), backend);

      expect(find.byKey(const Key('tool-path-fold:call-read')), findsNothing);
      expect(find.text('src/b.ts · 行 2–5'), findsNothing);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });

    testWidgets('semantics：折叠行路径暴露「打开文件预览」链接标签', (tester) async {
      final backend = _PreviewBackend();
      await _pumpChat(tester, _store(), backend);
      final handle = tester.ensureSemantics();

      expect(find.bySemanticsLabel('打开文件预览：src/b.ts'), findsOneWidget);
      expect(find.bySemanticsLabel('打开文件预览：src/c.ts'), findsNothing);
      handle.dispose();
    });
  });
}
