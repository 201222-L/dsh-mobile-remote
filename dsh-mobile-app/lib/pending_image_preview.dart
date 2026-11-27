// issue #85：待上传图片的全屏预览。
//
// 只读本地文件（Image.file），不经服务端、不上传、不预加载；多图左右分页，
// 每页独立 InteractiveViewer；关闭后回到输入框，草稿/待发送列表不变。

import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';

class PendingImagePreviewScreen extends StatefulWidget {
  const PendingImagePreviewScreen({
    super.key,
    required this.paths,
    this.initialIndex = 0,
  });

  /// 待上传图片的本地路径（按输入框顺序）。
  final List<String> paths;
  final int initialIndex;

  @override
  State<PendingImagePreviewScreen> createState() =>
      _PendingImagePreviewScreenState();
}

class _PendingImagePreviewScreenState extends State<PendingImagePreviewScreen> {
  late final PageController _pageController;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.paths.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.paths.length - 1);
    _pageController = PageController(initialPage: _current);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.paths.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (count == 0)
              Center(
                child: Text(
                  L10n.t('没有可预览的图片', 'No image to preview'),
                  style: const TextStyle(color: Colors.white70),
                ),
              )
            else
              PageView.builder(
                controller: _pageController,
                itemCount: count,
                onPageChanged: (index) => setState(() => _current = index),
                itemBuilder: (context, index) {
                  return Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4,
                      child: Image.file(
                        File(widget.paths[index]),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const _BrokenImage(),
                      ),
                    ),
                  );
                },
              ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: L10n.t('关闭', 'Close'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
            if (count > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_current + 1} / $count',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
        const SizedBox(height: 8),
        Text(
          L10n.t('图片读取失败，可删除后重选', 'Cannot read image; remove and pick again'),
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
