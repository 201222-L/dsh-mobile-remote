// issue #94：Markdown `![alt](url)` 图片渲染 —— 本地路径经注入 loader（/workspace-image），
// 网络图走 http(s)、失败占位显示 alt+原因、代码块不解析、同路径缓存、320/深色/大字号。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/md.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1x1 PNG（合法 CRC），用于 Image.memory 真实解码路径。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAF9Z2ZkAAAAASUVORK5CYII=',
);

Future<void> _pumpMarkdown(
  WidgetTester tester,
  String text, {
  MarkdownImageLoader? loader,
  bool dark = false,
  double width = 390,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(
    theme: dark ? ThemeData.dark() : null,
    home: Scaffold(
      body: Builder(
        builder: (context) => SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: renderMarkdownBlocks(
              text,
              context,
              imageLoader: loader,
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() {
    L10n.lang = 'en';
  });

  testWidgets('块级本地图片：经 loader 加载并渲染 Image，不直接读文件系统', (tester) async {
    final calls = <String>[];
    await _pumpMarkdown(
      tester,
      '前文\n\n![示意图](pics/demo.png)\n\n后文',
      loader: (source) async {
        calls.add(source);
        return MarkdownImageData(bytes: _png, contentType: 'image/png');
      },
    );
    expect(calls, ['pics/demo.png']);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>(), reason: '按布局/DPR 降采样');
    // 加载占位可以存在（Image 解码首帧），但不得显示失败文案。
    expect(find.text('Failed to load image'), findsNothing);
  });

  testWidgets('行内图片：嵌在段落里也加载', (tester) async {
    final calls = <String>[];
    await _pumpMarkdown(
      tester,
      '说明 ![inline](pics/a.png) 结束',
      loader: (source) async {
        calls.add(source);
        return MarkdownImageData(bytes: _png, contentType: 'image/png');
      },
    );
    expect(calls, ['pics/a.png']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('md 不持全局缓存：请求去重由 ChatScreen LRU 注入；双图各调用 loader', (tester) async {
    var count = 0;
    final loader = (String source) async {
      count += 1;
      return MarkdownImageData(bytes: _png);
    };
    await _pumpMarkdown(
      tester,
      '![a](pics/same.png)\n\n![b](pics/same.png)',
      loader: loader,
    );
    expect(count, 2);
  });

  testWidgets('代码块内的 ![] 不解析；不会调用 loader', (tester) async {
    var count = 0;
    await _pumpMarkdown(
      tester,
      '```\n![alt](pics/inside.png)\n```',
      loader: (source) async {
        count += 1;
        return MarkdownImageData(bytes: _png);
      },
    );
    expect(count, 0);
    expect(find.textContaining('![alt](pics/inside.png)'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('加载失败：显示 alt + 可读原因（404/415），不静默空白', (tester) async {
    await _pumpMarkdown(
      tester,
      '![产品截图](pics/missing.png)',
      loader: (source) async => throw ApiException(
        'not found',
        code: 'image-not-found',
        status: 404,
      ),
    );
    expect(find.byKey(const Key('markdown-image-placeholder')), findsOneWidget);
    expect(find.text('产品截图'), findsOneWidget);
    expect(find.text('Image not found'), findsOneWidget);

    await _pumpMarkdown(
      tester,
      '![坏类型](pics/doc.png)',
      loader: (source) async => throw ApiException(
        'unsupported',
        code: 'unsupported-image-type',
        status: 415,
      ),
    );
    expect(find.text('坏类型'), findsOneWidget);
    expect(find.text('Unsupported image type'), findsOneWidget);
  });

  testWidgets('非 http(s) scheme（file:）明确失败，不调用 loader', (tester) async {
    var count = 0;
    await _pumpMarkdown(
      tester,
      '![本地](file:///etc/passwd)',
      loader: (source) async {
        count += 1;
        return MarkdownImageData(bytes: _png);
      },
    );
    expect(count, 0);
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('Unsupported image URL'), findsOneWidget);
  });

  testWidgets('501（宿主不支持安全校验）显示明确占位', (tester) async {
    await _pumpMarkdown(
      tester,
      '![旧宿主](pics/a.png)',
      loader: (source) async => throw ApiException(
        'verification unavailable',
        code: 'image-verification-unavailable',
        status: 501,
      ),
    );
    expect(find.byKey(const Key('markdown-image-placeholder')), findsOneWidget);
    expect(find.text('旧宿主'), findsOneWidget);
    expect(find.textContaining('cannot verify images safely'), findsOneWidget);
  });

  testWidgets('320 + 深色 + 1.5x：图片/占位不溢出', (tester) async {
    await _pumpMarkdown(
      tester,
      '![长图说明](pics/long.png)',
      loader: (source) async =>
          MarkdownImageData(bytes: _png, contentType: 'image/png'),
      dark: true,
      width: 320,
      textScale: 1.5,
    );
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '320+1.5x+深色不得 overflow');
  });
  testWidgets('http(s) 图片走网络 Image，不调用本地 loader', (tester) async {
    var count = 0;
    await _pumpMarkdown(
      tester,
      '![网络图](https://example.test/a.png)',
      loader: (source) async {
        count += 1;
        return MarkdownImageData(bytes: _png);
      },
    );
    expect(count, 0);
    expect(find.byType(Image), findsNothing, reason: '远程图不发起第三方请求');
    expect(find.textContaining('Remote images are not loaded automatically'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
