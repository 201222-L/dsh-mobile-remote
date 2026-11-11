// issue #74：工具结果图片在 App 里「完全没有位置」——折叠层入口回归。
//
// 根因（note 2178）：图片只在 `_ToolActivityCard` 展开体内；过程组默认收起；
// 50 行分批又把 read_image 行藏到 hidden 区 → 三层叠加后图片完全不可达。
// 修复（选项 A）：在摘要行 / 过程组抬头 / 工具折叠行 / 「显示更多」行给「🖼 N」入口，
// 点 chip 直接开图库；不改折叠、分批与服务端。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/image_gallery.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'issue74_turn1_fixture.dart';

/// 1x1 透明 PNG（图库缩略图解码用）。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _Backend {
  _Backend({required this.events, this.attachmentFails = false});

  final List<Map<String, dynamic>> events;
  final bool attachmentFails;

  int attachmentRequests = 0;
  int detailRequests = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue74.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: false,
      unknownEvents: true,
      callCorrelation: true,
    );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/m/api/history') {
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('after')) {
        return _json({'ok': true, 'events': <Object>[], 'hasMore': false});
      }
      if (params.containsKey('before')) {
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final preceding = events.where((e) => (e['seq'] as int) < before).toList();
        final page = preceding.length > limit
            ? preceding.sublist(preceding.length - limit)
            : preceding;
        return _json({
          'ok': true,
          'events': page,
          'hasMore': preceding.length > page.length,
        });
      }
      // issue #74 夹具是「整轮已加载」形态（真机 live 会话形状），全部下发。
      return _json({'ok': true, 'events': events, 'hasMore': false});
    }
    if (path == '/m/api/attachment') {
      attachmentRequests++;
      if (attachmentFails) {
        return http.Response(
          jsonEncode({'ok': false, 'error': {'code': 'attachment-not-found'}}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        _tinyPng,
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    if (path == '/m/api/event-detail') {
      detailRequests++;
      return _json({
        'ok': false,
        'error': {'code': 'event-not-found'},
      });
    }
    if (path == '/m/api/queue') return _json({'ok': true, 'rows': <Object>[]});
    if (path == '/m/api/todos') return _json({'ok': true, 'todos': <Object>[]});
    if (path == '/m/api/session-config') {
      return _json({'ok': true, 'config': <String, dynamic>{}});
    }
    return _json({'ok': true});
  }

  http.Response _json(Map<String, dynamic> body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

Map<String, dynamic> _image(String id, String name) => {
      'attachmentId': id,
      'mediaType': 'image/png',
      'width': 780,
      'height': 1688,
      'name': name,
    };

/// 单组 read_image：可控制是否带图片、是否重复同一张图。
List<Map<String, dynamic>> readImageTurn({
  bool withImages = true,
  bool duplicateImages = false,
}) {
  final events = <Map<String, dynamic>>[
    {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
    {
      'seq': 2,
      'type': 'user/message',
      'data': {'messageId': 'u1', 'text': '看图', 'sourceKind': 'user'},
    },
    {
      'seq': 3,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-read-1',
        'name': 'read_image',
        'arguments': '{"file_path":"/tmp/a.png"}',
      },
      'time': 1100,
    },
    {
      'seq': 4,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-read-1',
        'name': 'read_image',
        'text': 'ok',
        if (withImages)
          'images': [
            _image('sha256:aaaa', 'a.png'),
            if (duplicateImages) _image('sha256:aaaa', 'a-copy.png'),
          ],
      },
      'time': 1200,
    },
    if (duplicateImages) ...[
      {
        'seq': 5,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'call-read-2',
          'name': 'read_image',
          'arguments': '{"file_path":"/tmp/a-copy.png"}',
        },
        'time': 1250,
      },
      {
        'seq': 6,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'call-read-2',
          'name': 'read_image',
          'text': 'ok',
          'images': [_image('sha256:aaaa', 'a-again.png')],
        },
        'time': 1300,
      },
    ],
    {
      'seq': 9,
      'type': 'assistant/message',
      'data': {'turn': 1, 'step': 3, 'messageId': 'a1', 'text': '看到了'},
      'time': 1500,
    },
    {
      'seq': 10,
      'type': 'turn/end',
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
      'time': 2000,
    },
  ];
  return events;
}

Future<AppStore> _pumpChat(WidgetTester tester, _Backend backend) async {
  final store = AppStore()
    ..sessionId = 'session-74'
    ..sessions = [Session(id: 'session-74', title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue74-${backend.hashCode}'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

Finder _imageChip(int count) => find.byTooltip('查看 $count 张图片');

Future<void> _expandTurn(WidgetTester tester) async {
  await tester.tap(find.textContaining('组 · '));
  await tester.pumpAndSettle();
}

/// 长列表懒构建：往上滚到目标进入构建范围（过程块在较早位置）。
Future<void> _scrollUpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('真实 turn-1：整轮折叠摘要即显示 2 张图片入口（含分批隐藏的 read_image）', (tester) async {
    final events = (jsonDecode(issue74Turn1EventsJson) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final backend = _Backend(events: events);
    await _pumpChat(tester, backend);

    // 收起态：摘要行右侧出现「🖼 2」（两张 read_image 都被 50 行分批挡住）。
    await _scrollUpUntil(tester, _imageChip(2));
    expect(_imageChip(2), findsOneWidget);
    expect(find.text('0 次工具调用'), findsNothing);
    // 收起态不应该先构建任何图片内容。
    expect(find.byType(ImageGalleryGrid), findsNothing);
    // 点击 chip 直接开图库，且**不展开整轮**。
    await tester.ensureVisible(_imageChip(2));
    await tester.pumpAndSettle();
    await tester.tap(_imageChip(2));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ImageGalleryViewer), findsOneWidget);
    expect(find.textContaining('1 次工具调用'), findsNothing, reason: 'chip 不应触发展开');
    expect(backend.attachmentRequests, greaterThan(0), reason: '图库应按 attachmentId 取图');
  });

  testWidgets('真实 turn-1：展开整轮后「显示更多」行也有 2 张图片入口', (tester) async {
    final events = (jsonDecode(issue74Turn1EventsJson) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final backend = _Backend(events: events);
    await _pumpChat(tester, backend);
    await _scrollUpUntil(tester, _imageChip(2));
    await _expandTurn(tester);
    // 先展开整轮：前 50 行是可见组，read_image 组在 hidden 区 → 组抬头不渲染(#75)，
    // 但「显示更多」行带聚合图片入口（过程块较长，滚动到它进入构建范围）。
    await _scrollUpUntil(tester, find.textContaining('显示更多（还有'));
    expect(find.textContaining('显示更多（还有'), findsOneWidget);
    expect(_imageChip(2), findsOneWidget);

    await tester.ensureVisible(_imageChip(2));
    await tester.pumpAndSettle();
    await tester.tap(_imageChip(2));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ImageGalleryViewer), findsOneWidget);
  });

  testWidgets('单组 read_image：折叠卡有人数入口 → 点 chip 开图库；展开后显示网格不重复 chip', (
    tester,
  ) async {
    final backend = _Backend(events: readImageTurn());
    await _pumpChat(tester, backend);

    // 整轮折叠 → 摘要 chip「1」。
    expect(_imageChip(1), findsOneWidget);
    await tester.tap(_imageChip(1));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ImageGalleryViewer), findsOneWidget);
    // 关闭图库，继续验证折叠层。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 展开整轮 → 组抬头（组折叠）同样有 chip。
    await _expandTurn(tester);
    expect(_imageChip(1), findsOneWidget, reason: '组折叠态应有图片入口');
    await tester.tap(_imageChip(1));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ImageGalleryViewer), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // chip 与行点击分离：点 chip 不展开组（仍无过程行内容）。
    expect(find.byType(ImageGalleryGrid), findsNothing, reason: 'chip 不应展开组');

    // 展开组（点抬头文字，而不是 chip）→ 工具卡出现且折叠，卡上仍有 chip。
    await tester.tap(find.text('1 次工具调用'));
    await tester.pumpAndSettle();
    expect(_imageChip(1), findsOneWidget, reason: '工具卡折叠态应有图片入口');
    // chip 与行点击分离：点卡上 chip 直接开图库，不展开工具卡。
    await tester.tap(_imageChip(1));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ImageGalleryViewer), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ImageGalleryGrid), findsNothing, reason: 'chip 不应展开工具卡');

    // 展开工具卡 → ImageGalleryGrid 出现，折叠行 chip 消失（同一层不重复挂）。
    await tester.tap(find.text('read_image'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageGalleryGrid), findsOneWidget);
    expect(_imageChip(1), findsNothing);
  });

  testWidgets('无图工具：任何折叠层都不显示图片入口', (tester) async {
    await _pumpChat(tester, _Backend(events: readImageTurn(withImages: false)));
    expect(find.byType(ImageGalleryGrid), findsNothing);
    expect(_imageChip(1), findsNothing);
    await _expandTurn(tester);
    expect(_imageChip(1), findsNothing);
  });

  testWidgets('聚合去重：同一 attachmentId 在多个工具结果出现只计 1 张', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: readImageTurn(duplicateImages: true)),
    );
    expect(_imageChip(1), findsOneWidget);
    expect(_imageChip(2), findsNothing);
  });

  testWidgets('图库加载失败：入口仍可达，缩略图给失败占位与重试', (tester) async {
    final backend = _Backend(events: readImageTurn(), attachmentFails: true);
    await _pumpChat(tester, backend);
    await tester.tap(_imageChip(1));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(ImageGalleryViewer), findsOneWidget);
    expect(find.textContaining('图片加载失败'), findsWidgets);
    expect(find.textContaining('重试'), findsWidgets);
  });
}
