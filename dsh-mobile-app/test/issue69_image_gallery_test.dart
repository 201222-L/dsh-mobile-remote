// issue #69（M3 Batch 2-D）图库增强测试。
//
// 覆盖验收契约：单图/多图全屏查看器（缩放、分页 N/M、返回）、元数据行（尺寸/名称/
// mediaType/可选字节）、失败重试、保存到手机 / 分享（dsh/files MockChannel 语义）、
// 返回后 ChatScreen 滚动与工具卡展开态保持、深色 + 窄屏无溢出。
//
// 全部走 MockClient + 假 ImageGalleryIo：不触真实网络，也不写真实文件系统。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/image_gallery.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 三张不同的合法 1x1 PNG（红/蓝/绿）：用于断言分页切换后显示的是对应图片字节。
final Uint8List _pngRed = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mP4z8AAAAMBAQD3A0FDAAAAAElFTkSuQmCC',
);
final Uint8List _pngBlue = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mNgYPgPAAEDAQA2dBFAAAAAAElFTkSuQmCC',
);
final Uint8List _pngGreen = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mNgOMEAAAGUAMl/5U5HAAAAAElFTkSuQmCC',
);

Map<String, dynamic> _image(
  String attachmentId, {
  String mediaType = 'image/png',
  int? width,
  int? height,
  String? name,
  num? size,
  num? bytes,
}) => <String, dynamic>{
  'attachmentId': attachmentId,
  'mediaType': mediaType,
  'width': ?width,
  'height': ?height,
  'name': ?name,
  'size': ?size,
  'bytes': ?bytes,
};

/// 附件 HTTP 背板：按 attachmentId 返回字节；可注入失败次数（测重试）。
class _AttachmentBackend {
  _AttachmentBackend({
    Map<String, Uint8List>? bytes,
    Map<String, int>? failures,
  }) : bytes = Map<String, Uint8List>.from(bytes ?? const {}),
       failures = Map<String, int>.from(failures ?? const {});

  final Map<String, Uint8List> bytes;
  final Map<String, int> failures;
  int requests = 0;
  final List<String> requestedIds = [];

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path == '/m/api/attachment') {
      requests += 1;
      final id = request.url.queryParameters['attachmentId'] ?? '';
      requestedIds.add(id);
      final remaining = failures[id] ?? 0;
      if (remaining > 0) {
        failures[id] = remaining - 1;
        return http.Response('boom', 500);
      }
      final data = bytes[id];
      if (data == null) return http.Response('not found', 404);
      return http.Response.bytes(
        data,
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    return http.Response('{}', 404);
  }

  Api get api => Api(client: MockClient(handle))
    ..baseUrl = 'http://issue69.test'
    ..path = '/m'
    ..token = '';
}

/// 假宿主 IO：记录 dsh/files 调用与临时文件读写删，不碰真实文件系统。
class _IoCall {
  _IoCall(this.method, this.arguments);
  final String method;
  final Map<String, dynamic> arguments;
  @override
  String toString() => '$method($arguments)';
}

class _FakeIo extends ImageGalleryIo {
  _FakeIo();

  final List<_IoCall> calls = [];
  final List<String> tempWrites = [];
  final List<String> tempDeletes = [];
  String? saveFileResult = 'content://media/external/downloads/42';
  Object? saveFileError;
  Object? shareFileError;
  int _sequence = 0;

  @override
  Future<String> writeTemporaryFile({
    required String prefix,
    required String name,
    required Uint8List bytes,
  }) async {
    final path = '/fake-tmp/$prefix-${_sequence++}-$name';
    tempWrites.add(path);
    return path;
  }

  @override
  Future<void> deleteTemporaryFile(String path) async {
    tempDeletes.add(path);
  }

  @override
  Future<T?> invokeMethod<T>(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    calls.add(_IoCall(method, arguments));
    if (method == 'saveFileFromPath') {
      final error = saveFileError;
      if (error != null) throw error;
      return saveFileResult as T?;
    }
    if (method == 'shareFile') {
      final error = shareFileError;
      if (error != null) throw error;
      return true as T?;
    }
    return null;
  }

  List<String> get methods => [for (final call in calls) call.method];
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  required Api api,
  required List<Map<String, dynamic>> images,
  ImageGalleryIo io = const ImageGalleryIo(),
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ImageGalleryGrid(
              images: images,
              sessionId: 's69',
              api: api,
              io: io,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 通过宿主页按钮以 dialog 路由打开查看器（与 ChatScreen 内打开方式一致）。
Future<void> _pumpViewer(
  WidgetTester tester, {
  required Api api,
  required List<Map<String, dynamic>> images,
  int initialIndex = 0,
  ImageGalleryCache? cache,
  ImageGalleryIo io = const ImageGalleryIo(),
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open-viewer'),
              onPressed: () => showDialog<void>(
                context: context,
                barrierColor: Colors.black87,
                builder: (_) => ImageGalleryViewer(
                  api: api,
                  sessionId: 's69',
                  images: images,
                  initialIndex: initialIndex,
                  cache: cache,
                  io: io,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-viewer')));
  await tester.pumpAndSettle();
}

Uint8List _viewerImageBytes(WidgetTester tester, int index) {
  final widget = tester.widget<Image>(
    find.byKey(ValueKey<String>('issue69-viewer-image-$index')),
  );
  return (widget.image as MemoryImage).bytes;
}

Text _metaText(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key));

ScrollableState _mainScrollable(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byType(CustomScrollView),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(finder.first);
}

/// 只替换临时文件层的 IO：invokeMethod 保留生产实现，用于 MethodChannel mock 契约测试。
class _ChannelIo extends ImageGalleryIo {
  final List<String> tempWrites = [];
  final List<String> tempDeletes = [];
  int _sequence = 0;

  @override
  Future<String> writeTemporaryFile({
    required String prefix,
    required String name,
    required Uint8List bytes,
  }) async {
    final path = '/fake-channel-tmp/$prefix-${_sequence++}-$name';
    tempWrites.add(path);
    return path;
  }

  @override
  Future<void> deleteTemporaryFile(String path) async {
    tempDeletes.add(path);
  }
}

// ── ChatScreen 级背板：/history 带附图事件 + 附件字节计数 + 轮询接口兜底 ──────

class _ChatBackend {
  _ChatBackend({this.toolImageSize});

  final int? toolImageSize;
  int historyRequests = 0;
  int attachmentRequests = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://chat69.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
    );

  List<Map<String, dynamic>> get events {
    final events = <Map<String, dynamic>>[
      {
        'seq': 1,
        'type': 'turn/start',
        'data': {'turn': 1},
      },
    ];
    var seq = 2;
    // 足够多的消息保证列表可滚动；内容较长以便产生真实 offset。
    for (var i = 0; i < 12; i++) {
      events.add({
        'seq': seq++,
        'type': 'user/message',
        'data': {
          'messageId': 'u$i',
          'text': '第 $i 条消息：这里是一段足够长的正文，用于撑开滚动区域。' * 2,
          'sourceKind': 'user',
        },
      });
    }
    events.add({
      'seq': seq++,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-image69',
        'name': 'shell',
        'arguments': '{"command":"produce image"}',
      },
    });
    events.add({
      'seq': seq++,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-image69',
        'name': 'shell',
        'text': 'image ready',
        'isError': false,
        'images': [
          _image(
            'att-tool',
            width: 40,
            height: 30,
            name: 'tool-shot.png',
            size: toolImageSize,
          ),
        ],
      },
    });
    events.add({
      'seq': seq++,
      'type': 'turn/end',
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
    });
    return events;
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      historyRequests += 1;
      return _json({'ok': true, 'events': events, 'hasMore': false});
    }
    if (request.url.path == '/m/api/attachment') {
      attachmentRequests += 1;
      return http.Response.bytes(
        _pngRed,
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    if (request.url.path == '/m/api/notifications') {
      return _json({'ok': true, 'items': <Object>[]});
    }
    if (request.url.path == '/m/api/queue') {
      return _json({'ok': true, 'rows': <Object>[]});
    }
    if (request.url.path == '/m/api/todos') {
      return _json({'ok': true, 'todos': <Object>[]});
    }
    return _json({'ok': true});
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _pumpChat(WidgetTester tester, _ChatBackend backend) async {
  final store = AppStore()
    ..sessionId = 'session-69'
    ..stepDisplayMode = WorkStepDisplayMode.expanded;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  // 首屏历史是异步加载的；沿用既有 chat 测试的稳定等待方式。
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _pumpChatEvents(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  required Map<String, Uint8List> attachmentBytes,
  bool timelineDebug = false,
}) async {
  final chatApi =
      Api(
          client: MockClient((request) async {
            if (request.url.path == '/m/api/history') {
              return http.Response(
                jsonEncode({'ok': true, 'events': events, 'hasMore': false}),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (request.url.path == '/m/api/attachment') {
              final id = request.url.queryParameters['attachmentId'] ?? '';
              final data = attachmentBytes[id];
              if (data == null) return http.Response('not found', 404);
              return http.Response.bytes(
                data,
                200,
                headers: {'content-type': 'image/png'},
              );
            }
            return http.Response(
              jsonEncode({
                'ok': true,
                'rows': <Object>[],
                'items': <Object>[],
                'todos': <Object>[],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        )
        ..baseUrl = 'http://chat69-user.test'
        ..path = '/m'
        ..token = '';
  final store = AppStore()
    ..sessionId = 'session-69'
    ..stepDisplayMode = WorkStepDisplayMode.expanded
    ..timelineDebug = timelineDebug;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(store: store, apiClient: chatApi, onTitleChanged: () {}),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// 覆盖用户消息 / 助手消息两处附图调用点（工具卡、注入消息由各自测试覆盖）。
Future<void> _pumpChatWithImages(
  WidgetTester tester, {
  required List<Map<String, dynamic>> images,
}) => _pumpChatEvents(
  tester,
  events: [
    {
      'seq': 1,
      'type': 'user/message',
      'data': {
        'messageId': 'u1',
        'text': '请看我发的图',
        'sourceKind': 'user',
        'images': [_image('att-user', width: 20, height: 10, name: 'u.png')],
      },
    },
    {
      'seq': 2,
      'type': 'assistant/message',
      'data': {'messageId': 'a1', 'text': '收到，这里是工具结果图', 'images': images},
    },
    {
      'seq': 3,
      'type': 'turn/end',
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
    },
  ],
  attachmentBytes: {
    'att-user': _pngRed,
    'att-assistant-1': _pngRed,
    'att-assistant-2': _pngBlue,
  },
);

void main() {
  group('元数据纯函数', () {
    test('name 缺失/空白回退「图片 N」（1-based）', () {
      expect(imageDisplayName(_image('a'), 0), '图片 1');
      expect(imageDisplayName(_image('a', name: '  '), 2), '图片 3');
      expect(imageDisplayName(_image('a', name: 'photo.png'), 5), 'photo.png');
    });

    test('尺寸只在宽高都存在且为正数时显示', () {
      expect(
        imagePixelSizeLabel(_image('a', width: 1920, height: 1080)),
        '1920×1080',
      );
      expect(imagePixelSizeLabel(_image('a', width: 1920)), isNull);
      expect(imagePixelSizeLabel(_image('a', height: 1080)), isNull);
      expect(imagePixelSizeLabel(_image('a', width: 0, height: 10)), isNull);
      expect(imagePixelSizeLabel(_image('a')), isNull);
    });

    test('字节数仅接受数字型 size/bytes，展示 B/KB/MB', () {
      expect(imageByteSize(_image('a', size: 1536)), 1536);
      expect(imageByteSize(_image('a', bytes: 2048)), 2048);
      expect(imageByteSize({'attachmentId': 'a', 'size': '1536'}), isNull);
      expect(imageByteSize(_image('a')), isNull);
      expect(formatImageBytes(0), '0 B');
      expect(formatImageBytes(512), '512 B');
      expect(formatImageBytes(1024), '1 KB');
      expect(formatImageBytes(1536), '1.5 KB');
      expect(formatImageBytes(10240), '10 KB');
      expect(formatImageBytes(1048064), '1023.5 KB');
      expect(formatImageBytes(1048576), '1 MB');
      expect(formatImageBytes(12345678), '11.8 MB');
    });

    test('mediaType 可读短标签（GIF/WebP/JPEG/缺省）', () {
      expect(imageMediaLabel(_image('a', mediaType: 'image/gif')), 'GIF');
      expect(imageMediaLabel(_image('a', mediaType: 'image/webp')), 'WebP');
      expect(imageMediaLabel(_image('a', mediaType: 'image/jpeg')), 'JPEG');
      expect(imageMediaLabel(_image('a', mediaType: 'image/png')), 'PNG');
      expect(imageMediaLabel(_image('a', mediaType: 'image/avif')), 'AVIF');
      expect(imageMediaLabel(_image('a', mediaType: '')), isNull);
    });

    test('元数据行按存在字段拼接，名称始终有值', () {
      expect(
        imageMetaLine(
          _image('a', width: 1920, height: 1080, name: 'photo.png', size: 1536),
          0,
        ),
        '1920×1080 · photo.png · PNG · 1.5 KB',
      );
      // 无 size → 不出现字节段。
      expect(
        imageMetaLine(_image('b', width: 4, height: 3, name: 'b.png'), 0),
        '4×3 · b.png · PNG',
      );
      // 无 name →「图片 N」；缺尺寸/mediaType 时只留名称。
      expect(imageMetaLine(_image('c'), 1), '图片 2 · PNG');
      expect(
        imageMetaLine(_image('d', width: 4, height: 3, name: 'd.png'), 3),
        '4×3 · d.png · PNG',
      );
    });

    test('缩略图回退比例：缺尺寸 4:3，极端比例 clamp 到 80–480', () {
      final fallback = imageThumbBoxSize(_image('a'));
      expect(fallback.width, 236);
      expect(fallback.height, closeTo(177, 0.001));
      // 横向超宽图：比例 clamp 到 3.0 → 高 78.7 → 下限 80。
      final wide = imageThumbBoxSize(_image('a', width: 10000, height: 100));
      expect(wide.height, 80);
      // 竖向超长图：比例 clamp 到 0.3 → 高 786.7 → 上限 480。
      final tall = imageThumbBoxSize(_image('a', width: 100, height: 10000));
      expect(tall.height, 480);
    });

    test('导出文件名：优先原名、缺省 dsh-image、缺扩展名按 mediaType 补', () {
      expect(
        imageExportFileName(_image('att', name: 'photo.png'), 0),
        'photo.png',
      );
      expect(imageExportFileName(_image('att', name: 'photo'), 0), 'photo.png');
      expect(imageExportFileName(_image('att'), 0), 'dsh-image-att.png');
      expect(imageExportFileName(_image('att', name: 'a/b.png'), 0), 'a_b.png');
      expect(
        imageExportFileName(
          _image('att', name: 'x.gif', mediaType: 'image/gif'),
          0,
        ),
        'x.gif',
      );
    });
  });

  group('缩略图', () {
    testWidgets('单图：缩略图元数据 + 点击打开查看器，系统返回可关', (tester) async {
      final backend = _AttachmentBackend()..bytes['att-one'] = _pngRed;
      final api = backend.api;
      final image = _image(
        'att-one',
        width: 1920,
        height: 1080,
        name: 'photo.png',
        size: 1536,
      );
      await _pumpGrid(tester, api: api, images: [image]);
      expect(backend.requests, 1);

      final meta = _metaText(tester, const ValueKey('issue69-meta-att-one'));
      expect(meta.data, '1920×1080 · photo.png · PNG · 1.5 KB');
      expect(meta.maxLines, 1);
      expect(meta.overflow, TextOverflow.ellipsis);

      await tester.tap(find.byKey(const ValueKey('issue69-thumb-att-one')));
      await tester.pumpAndSettle();

      // 全屏查看器：黑底 Dialog + InteractiveViewer 0.5–4x。
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      expect(
        tester.widget<Dialog>(find.byType(Dialog).last).backgroundColor,
        Colors.black,
      );
      final viewer = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey('issue69-viewer-page-0')),
      );
      expect(viewer.minScale, 0.5);
      expect(viewer.maxScale, 4.0);
      // 单图不显示分页控件。
      expect(
        find.byKey(const Key('issue69-viewer-page-indicator')),
        findsNothing,
      );
      expect(
        _metaText(tester, const Key('issue69-viewer-meta')).data,
        '1920×1080 · photo.png · PNG · 1.5 KB',
      );

      // 系统返回键关闭 dialog（不重建 ChatScreen/宿主页）。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsNothing);
      // 宿主页仍在，缩略图未被销毁。
      expect(
        find.byKey(const ValueKey('issue69-thumb-att-one')),
        findsOneWidget,
      );
    });

    testWidgets('多图：缩略图元数据独立，未命名回退「图片 N」', (tester) async {
      final backend = _AttachmentBackend()
        ..bytes['att-a'] = _pngRed
        ..bytes['att-b'] = _pngBlue;
      await _pumpGrid(
        tester,
        api: backend.api,
        images: [
          _image('att-a', width: 40, height: 30, name: 'a.png', size: 2048),
          _image('att-b', width: 30, height: 40),
        ],
      );
      expect(
        _metaText(tester, const ValueKey('issue69-meta-att-a')).data,
        '40×30 · a.png · PNG · 2 KB',
      );
      expect(
        _metaText(tester, const ValueKey('issue69-meta-att-b')).data,
        '30×40 · 图片 2 · PNG',
      );
    });

    testWidgets('加载失败：显示重试，点按后真的重新请求并恢复', (tester) async {
      final backend = _AttachmentBackend(failures: {'att-broken': 1})
        ..bytes['att-broken'] = _pngRed;
      await _pumpGrid(
        tester,
        api: backend.api,
        images: [_image('att-broken', width: 10, height: 10)],
      );
      expect(backend.requests, 1);
      expect(find.text('加载失败，点按重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('issue69-thumb-image-att-broken')),
        findsNothing,
      );

      await tester.tap(find.text('加载失败，点按重试'));
      await tester.pumpAndSettle();

      expect(backend.requests, 2);
      expect(
        find.byKey(const ValueKey('issue69-thumb-image-att-broken')),
        findsOneWidget,
      );
    });

    testWidgets('GIF/WebP 标签与大 GIF 角标（既有行为保留）', (tester) async {
      final backend = _AttachmentBackend()
        ..bytes['att-gif-big'] = _pngRed
        ..bytes['att-gif-small'] = _pngBlue
        ..bytes['att-webp'] = _pngGreen;
      await _pumpGrid(
        tester,
        api: backend.api,
        images: [
          _image(
            'att-gif-big',
            mediaType: 'image/gif',
            width: 5000,
            height: 100,
            name: 'big.gif',
          ),
          _image(
            'att-gif-small',
            mediaType: 'image/gif',
            width: 100,
            height: 100,
            name: 'small.gif',
          ),
          _image(
            'att-webp',
            mediaType: 'image/webp',
            width: 100,
            height: 100,
            name: 'photo.webp',
          ),
        ],
      );
      // 只有长边 > 4096 的大 GIF 有角标。
      expect(find.text('GIF·原图较大'), findsOneWidget);
      expect(
        _metaText(tester, const ValueKey('issue69-meta-att-gif-big')).data,
        contains('GIF'),
      );
      expect(
        _metaText(tester, const ValueKey('issue69-meta-att-webp')).data,
        contains('WebP'),
      );
    });
  });

  group('全屏查看器', () {
    testWidgets('多图分页：N/M、滑动切换、已加载页不重复请求', (tester) async {
      final backend = _AttachmentBackend()
        ..bytes['att-0'] = _pngRed
        ..bytes['att-1'] = _pngBlue
        ..bytes['att-2'] = _pngGreen;
      final images = [
        _image('att-0', width: 4, height: 3, name: 'one.png'),
        _image('att-1', width: 4, height: 3, name: 'two.png'),
        _image('att-2', width: 4, height: 3, name: 'three.png'),
      ];
      await _pumpViewer(tester, api: backend.api, images: images);

      expect(find.text('1/3'), findsOneWidget);
      expect(backend.requests, 1, reason: '只加载当前页');
      expect(_viewerImageBytes(tester, 0), _pngRed);

      // 左滑 → 第 2 页（对应蓝色字节）。
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(backend.requests, 2);
      expect(_viewerImageBytes(tester, 1), _pngBlue);

      // 左滑 → 第 3 页。
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      expect(backend.requests, 3);
      expect(_viewerImageBytes(tester, 2), _pngGreen);

      // 回到已看过的第 2/1 页：不得重复 HTTP（缓存命中）。
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(_viewerImageBytes(tester, 1), _pngBlue);
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      expect(_viewerImageBytes(tester, 0), _pngRed);
      expect(backend.requests, 3, reason: '已加载页切回不得重复请求');
      expect(backend.requestedIds.toSet().length, 3);
    });

    testWidgets('缩放：InteractiveViewer 0.5–4x，缩放状态不串页', (tester) async {
      final backend = _AttachmentBackend()
        ..bytes['att-0'] = _pngRed
        ..bytes['att-1'] = _pngBlue;
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-0'), _image('att-1')],
      );

      final pageFinder = find.byKey(const ValueKey('issue69-viewer-page-0'));
      final viewer = tester.widget<InteractiveViewer>(pageFinder);
      expect(viewer.minScale, 0.5);
      expect(viewer.maxScale, 4.0);
      final controller = viewer.transformationController!;
      expect(controller.value.getMaxScaleOnAxis(), 1.0);

      // 双指放大。
      final center = tester.getCenter(pageFinder);
      final first = await tester.createGesture();
      final second = await tester.createGesture();
      await first.down(center - const Offset(24, 0));
      await second.down(center + const Offset(24, 0));
      await tester.pump();
      await first.moveBy(const Offset(-48, 0));
      await second.moveBy(const Offset(48, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.05));

      // 缩放态下横向拖动交给 InteractiveViewer：不翻页。
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);

      // 复位缩放后翻页，新页是初始变换（上一页缩放不串到新页）。
      controller.value = Matrix4.identity();
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);
      final nextPage = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey('issue69-viewer-page-1')),
      );
      expect(
        nextPage.transformationController!.value.getMaxScaleOnAxis(),
        1.0,
        reason: '切页后不得沿用上一页的缩放状态',
      );
    });

    testWidgets('缺 width/height 不崩，打开查看器正常', (tester) async {
      final backend = _AttachmentBackend()..bytes['att-nosize'] = _pngRed;
      await _pumpGrid(
        tester,
        api: backend.api,
        images: [_image('att-nosize', name: 'nosize.png')],
      );
      final size = tester.getSize(
        find.byKey(const ValueKey('issue69-thumb-box-att-nosize')),
      );
      expect(size.width, 236);
      expect(size.height, closeTo(177, 0.001));

      await tester.tap(find.byKey(const ValueKey('issue69-thumb-att-nosize')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('issue69-viewer-pages')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(
        _metaText(tester, const Key('issue69-viewer-meta')).data,
        'nosize.png · PNG',
      );
    });

    testWidgets('size 字段缺失不显示、存在时显示（查看器）', (tester) async {
      final backend = _AttachmentBackend()
        ..bytes['att-sized'] = _pngRed
        ..bytes['att-unsized'] = _pngBlue;
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [
          _image('att-sized', name: 'sized.png', size: 1536),
          _image('att-unsized', name: 'unsized.png'),
        ],
      );
      expect(
        _metaText(tester, const Key('issue69-viewer-meta')).data,
        'sized.png · PNG · 1.5 KB',
      );
      await tester.drag(
        find.byKey(const Key('issue69-viewer-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      final meta = _metaText(tester, const Key('issue69-viewer-meta')).data!;
      expect(meta, contains('unsized.png'));
      expect(meta, isNot(contains('KB')));
      expect(meta, isNot(contains(' B')));
    });

    testWidgets('查看器内加载失败：失败态 + 重试真的重新请求并恢复', (tester) async {
      final backend = _AttachmentBackend(failures: {'att-fail': 1})
        ..bytes['att-fail'] = _pngRed;
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-fail', name: 'f.png')],
      );
      expect(backend.requests, 1);
      expect(find.text('图片加载失败'), findsOneWidget);
      expect(find.text('图片加载失败，可点重试'), findsOneWidget);
      expect(find.byKey(const Key('issue69-viewer-retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('issue69-viewer-retry')));
      await tester.pumpAndSettle();
      expect(backend.requests, 2);
      expect(
        find.byKey(const ValueKey('issue69-viewer-image-0')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('issue69-viewer-retry')), findsNothing);
    });

    testWidgets('查看器内连续失败：每次都明确提示且可继续重试', (tester) async {
      final backend = _AttachmentBackend(failures: {'att-fail2': 2})
        ..bytes['att-fail2'] = _pngRed;
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-fail2', name: 'f.png')],
      );
      expect(backend.requests, 1);
      expect(find.text('图片加载失败，可点重试'), findsOneWidget);

      await tester.tap(find.byKey(const Key('issue69-viewer-retry')));
      await tester.pumpAndSettle();
      expect(backend.requests, 2);
      expect(find.text('图片加载失败，可点重试'), findsOneWidget);
      expect(find.byKey(const Key('issue69-viewer-retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('issue69-viewer-retry')));
      await tester.pumpAndSettle();
      expect(backend.requests, 3);
      expect(
        find.byKey(const ValueKey('issue69-viewer-image-0')),
        findsOneWidget,
      );
    });
  });

  group('保存 / 分享（dsh/files 通道语义）', () {
    testWidgets('保存成功：写临时文件 → saveFileFromPath，toast 已保存，临时文件清理', (
      tester,
    ) async {
      final backend = _AttachmentBackend()..bytes['att-save'] = _pngRed;
      final io = _FakeIo();
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-save', mediaType: 'image/png', name: 'photo.png')],
        io: io,
      );

      await tester.tap(find.byKey(const Key('issue69-viewer-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(io.methods, ['saveFileFromPath']);
      expect(io.calls.single.arguments['name'], 'photo.png');
      expect(io.calls.single.arguments['path'], io.tempWrites.single);
      expect(find.textContaining('已保存到手机'), findsOneWidget);
      // 临时文件 finally 清理。
      expect(io.tempDeletes, io.tempWrites);
    });

    testWidgets('保存失败：通道抛错 → toast 含「保存失败」，临时文件仍清理', (tester) async {
      final backend = _AttachmentBackend()..bytes['att-save'] = _pngRed;
      final io = _FakeIo()
        ..saveFileError = PlatformException(code: 'save-failed', message: 'no');
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-save', name: 'photo.png')],
        io: io,
      );

      await tester.tap(find.byKey(const Key('issue69-viewer-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(io.shareFileError, isNull);
      expect(io.tempDeletes, io.tempWrites);
    });

    testWidgets('分享成功：先 saveFileFromPath 再 shareFile，content:// + mime 正确', (
      tester,
    ) async {
      final backend = _AttachmentBackend()..bytes['att-share'] = _pngRed;
      final io = _FakeIo()
        ..saveFileResult = 'content://media/external/downloads/777';
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [
          _image('att-share', mediaType: 'image/png', name: 'photo.png'),
        ],
        io: io,
      );

      await tester.tap(find.byKey(const Key('issue69-viewer-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(io.methods, ['saveFileFromPath', 'shareFile']);
      expect(io.calls[0].arguments['name'], 'photo.png');
      expect(io.calls[0].arguments['path'], io.tempWrites.single);
      expect(
        io.calls[1].arguments['uri'],
        'content://media/external/downloads/777',
      );
      expect(io.calls[1].arguments['mime'], 'image/png');
      expect(find.text('已打开分享面板'), findsOneWidget);
      expect(io.tempDeletes, io.tempWrites);
    });

    testWidgets('分享失败：channel 抛错 → 提示含「分享失败」，可再次重试', (tester) async {
      final backend = _AttachmentBackend()..bytes['att-share'] = _pngRed;
      final io = _FakeIo()
        ..shareFileError = PlatformException(
          code: 'share-failed',
          message: 'no',
        );
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-share', name: 'photo.png')],
        io: io,
      );

      await tester.tap(find.byKey(const Key('issue69-viewer-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('分享失败'), findsOneWidget);
      expect(io.tempDeletes, io.tempWrites);

      // 失败后可重试：清掉故障再点一次，这一次真的走到 shareFile 并成功。
      io.shareFileError = null;
      await tester.tap(find.byKey(const Key('issue69-viewer-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(io.methods.where((m) => m == 'shareFile').length, 2);
      expect(find.text('已打开分享面板'), findsOneWidget);
    });

    testWidgets('分享在落盘阶段失败：提示含「分享失败」，可重试成功', (tester) async {
      final backend = _AttachmentBackend()..bytes['att-share2'] = _pngRed;
      final io = _FakeIo()
        ..saveFileError = PlatformException(code: 'save-failed', message: 'io');
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-share2', name: 'photo.png')],
        io: io,
      );

      await tester.tap(find.byKey(const Key('issue69-viewer-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('分享失败'), findsOneWidget);
      expect(io.methods, ['saveFileFromPath']);
      expect(io.tempDeletes, io.tempWrites);

      // 恢复后重试：同一按钮可再次触发完整分享流程并成功。
      io.saveFileError = null;
      await tester.tap(find.byKey(const Key('issue69-viewer-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(io.methods, ['saveFileFromPath', 'saveFileFromPath', 'shareFile']);
      expect(find.text('已打开分享面板'), findsOneWidget);
    });

    testWidgets(
      'dsh/files 通道契约：saveFileFromPath 后 shareFile（真实 MethodChannel mock）',
      (tester) async {
        final backend = _AttachmentBackend()..bytes['att-channel'] = _pngRed;
        final io = _ChannelIo();
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(imageGalleryFilesChannel, (
          call,
        ) async {
          calls.add(call);
          switch (call.method) {
            case 'saveFileFromPath':
              return 'content://media/external/downloads/7';
            case 'shareFile':
              return true;
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            imageGalleryFilesChannel,
            null,
          ),
        );

        await _pumpViewer(
          tester,
          api: backend.api,
          images: [
            _image('att-channel', mediaType: 'image/webp', name: 'pic.webp'),
          ],
          io: io,
        );

        await tester.tap(find.byKey(const Key('issue69-viewer-save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(calls.single.method, 'saveFileFromPath');
        final saveArgs = calls.single.arguments as Map<Object?, Object?>;
        expect(saveArgs['path'], io.tempWrites.single);
        expect(saveArgs['name'], 'pic.webp');

        calls.clear();
        await tester.tap(find.byKey(const Key('issue69-viewer-share')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          [for (final call in calls) call.method],
          ['saveFileFromPath', 'shareFile'],
        );
        final shareArgs = calls[1].arguments as Map<Object?, Object?>;
        expect(shareArgs['uri'], 'content://media/external/downloads/7');
        expect(shareArgs['mime'], 'image/webp');
      },
    );

    testWidgets('原生返回非 content://：明确提示「该 Android 版本不支持」且不调 shareFile', (
      tester,
    ) async {
      final backend = _AttachmentBackend()..bytes['att-old'] = _pngRed;
      final io = _FakeIo()
        ..saveFileResult = '/data/user/0/app/files/downloads/photo.png';
      await _pumpViewer(
        tester,
        api: backend.api,
        images: [_image('att-old', name: 'photo.png')],
        io: io,
      );

      await tester.tap(find.byKey(const Key('issue69-viewer-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('该 Android 版本不支持'), findsOneWidget);
      expect(io.methods, ['saveFileFromPath']);
      expect(io.tempDeletes, io.tempWrites);
    });
  });

  group('ChatScreen 级回归', () {
    testWidgets('用户/助手附图调用点：各自渲染并可打开统一查看器', (tester) async {
      await _pumpChatWithImages(
        tester,
        images: [
          _image(
            'att-assistant-1',
            width: 40,
            height: 30,
            name: 'a1.png',
            size: 1536,
          ),
          _image('att-assistant-2', width: 30, height: 40, name: 'a2.png'),
        ],
      );

      // 底部（最新）是助手消息附图（call site：assistant/message）；
      // size 经 _imagesOf 透传后可见。
      expect(
        _metaText(tester, const ValueKey('issue69-meta-att-assistant-1')).data,
        contains('1.5 KB'),
      );
      // 附图在底部消息里可能高于视口，先滚到可见再点按。
      final assistantThumb = find.byKey(
        const ValueKey('issue69-thumb-att-assistant-1'),
      );
      await tester.ensureVisible(assistantThumb);
      await tester.pumpAndSettle();
      await tester.tap(assistantThumb);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      // 该组只有 2 张助手附图 → N/M 从 1/2 开始。
      expect(find.text('1/2'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsNothing);

      // 滚到顶部：用户消息附图（call site：user/message）同样渲染且可打开。
      _mainScrollable(tester).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.textContaining('请看我发的图'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('issue69-thumb-att-user')),
        findsOneWidget,
      );
      expect(
        _metaText(tester, const ValueKey('issue69-meta-att-user')).data,
        '20×10 · u.png · PNG',
      );
      await tester.tap(find.byKey(const ValueKey('issue69-thumb-att-user')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      // 用户消息只有 1 张附图 → 不显示分页控件。
      expect(
        find.byKey(const Key('issue69-viewer-page-indicator')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('issue69-viewer-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsNothing);
    });

    testWidgets('注入消息附图调用点：展开折叠块后渲染并可打开查看器', (tester) async {
      await _pumpChatEvents(
        tester,
        events: [
          {
            'seq': 1,
            'type': 'user/message',
            'data': {
              'messageId': 'inj1',
              'text': '这里是系统注入的上下文快照',
              'sourceKind': 'plugin',
              'images': [
                _image('att-inj', width: 20, height: 10, name: 'inj.png'),
              ],
            },
          },
          {
            'seq': 2,
            'type': 'turn/end',
            'data': {
              'turn': 1,
              'reason': {'kind': 'completed'},
            },
          },
        ],
        attachmentBytes: {'att-inj': _pngRed},
        // 注入折叠块只在调试模式可见（普通模式按设计隐藏）。
        timelineDebug: true,
      );
      // 注入块默认收起：附图不渲染。
      expect(find.byKey(const ValueKey('issue69-thumb-att-inj')), findsNothing);

      await tester.tap(find.textContaining('插件注入'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('issue69-thumb-att-inj')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('issue69-thumb-att-inj')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      expect(
        _metaText(tester, const Key('issue69-viewer-meta')).data,
        '20×10 · inj.png · PNG',
      );
      await tester.tap(find.byKey(const Key('issue69-viewer-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsNothing);
    });

    testWidgets('返回后滚动位置与工具卡展开态保持，图片不重复拉取', (tester) async {
      final backend = _ChatBackend(toolImageSize: 2048);
      await _pumpChat(tester, backend);

      // 展开工具卡（不新增折叠态：只是把既有卡片展开）。
      await tester.tap(find.byKey(const ValueKey('tool:call-image69:14')));
      await tester.pumpAndSettle();
      expect(find.textContaining('callId: call-image69'), findsOneWidget);

      final thumb = find.byKey(const ValueKey('issue69-thumb-att-tool'));
      await tester.ensureVisible(thumb);
      await tester.pumpAndSettle();

      final position = _mainScrollable(tester).position;
      final offsetBefore = position.pixels;
      expect(offsetBefore, greaterThan(0), reason: '需要真实滚动位置，断言才有意义');
      final attachmentBefore = backend.attachmentRequests;
      final historyBefore = backend.historyRequests;
      expect(attachmentBefore, 1);

      // 打开查看器：使用缩略图已加载的字节（同一缓存），不应新增 HTTP。
      await tester.tap(thumb);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      expect(find.byKey(const Key('issue69-viewer-meta')), findsOneWidget);
      expect(
        backend.attachmentRequests,
        attachmentBefore,
        reason: '打开查看器不应重复拉取已加载的图片',
      );

      // 关闭查看器（系统返回）。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsNothing);

      // 滚动位置不变 + 工具卡展开体仍在（列表未被重建/折叠）。
      expect(position.pixels, closeTo(offsetBefore, 0.5));
      expect(find.textContaining('callId: call-image69'), findsOneWidget);
      expect(thumb, findsOneWidget);
      // 没有额外的 /history 或 attachment 请求。
      expect(backend.historyRequests, historyBefore);
      expect(backend.attachmentRequests, attachmentBefore);

      // 再次打开/关闭：缓存命中，仍无新增请求。
      await tester.tap(thumb);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      await tester.tap(find.byKey(const Key('issue69-viewer-close')));
      await tester.pumpAndSettle();
      expect(backend.attachmentRequests, attachmentBefore);
      expect(position.pixels, closeTo(offsetBefore, 0.5));
    });
  });

  group('深色 / 窄屏', () {
    testWidgets('320 宽深色主题：缩略图与查看器（含长文件名）无 overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final backend = _AttachmentBackend()..bytes['att-long'] = _pngRed;
      final longName = '${'超长文件名-' * 12}.png';
      await _pumpGrid(
        tester,
        api: backend.api,
        images: [
          _image(
            'att-long',
            width: 1920,
            height: 1080,
            name: longName,
            size: 1536,
          ),
        ],
        theme: ThemeData.dark(),
      );
      expect(tester.takeException(), isNull);
      final meta = _metaText(tester, const ValueKey('issue69-meta-att-long'));
      expect(meta.overflow, TextOverflow.ellipsis);
      expect(meta.maxLines, 1);

      await tester.tap(find.byKey(const ValueKey('issue69-thumb-att-long')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('issue69-viewer-pages')), findsOneWidget);
      final viewerMeta = _metaText(tester, const Key('issue69-viewer-meta'));
      expect(viewerMeta.data, contains('1920×1080'));
      expect(viewerMeta.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('issue69-viewer-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
