// issue #53（§6.23 / issue 正文 §5）：按轮末记录坐标打开的全屏文件预览页。
//
// 取数只经 `/m/api/turn-file?sessionId&kind&seq&index`——客户端**不提交路径**，
// 服务端从会话记录解析。文本复用 GitFileViewer（行号/Markdown/复制），图片用
// Image.memory + 缩放手势；二进制/超大给明确不可预览提示；失败给原因 + 重试。
//
// 返回用普通 pop：本页不持有会话滚动/折叠状态，ChatScreen 在下面保持原状。

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../l10n.dart';
import '../session_files_logic.dart';
import '../theme.dart';
import '../turn_tail.dart';
import '../widgets/git_file_viewer.dart';

/// 图片预览上限：图片不能按文本 256 KiB 截断（会解码失败），单独给 8 MiB；
/// 超过时显示"图片过大"而不是渲染半张图。
const int kTurnTailImagePreviewLimit = 8 * 1024 * 1024;

class TurnFilePreviewScreen extends StatefulWidget {
  const TurnFilePreviewScreen({
    super.key,
    required this.api,
    required this.coordinate,
    required this.display,
    required this.name,
  });

  final Api api;
  final TurnFileCoordinate coordinate;

  /// 展示路径（`display`，工作区外通常是 basename）。
  final String display;

  /// 文件名（用于图片判定与下载命名）。
  final String name;

  @override
  State<TurnFilePreviewScreen> createState() => _TurnFilePreviewScreenState();
}

class _TurnFilePreviewScreenState extends State<TurnFilePreviewScreen> {
  bool _loading = true;
  String? _error;
  Uint8List? _imageBytes;
  PreviewVerdict? _preview;
  bool _imageTooLarge = false;
  int? _imageTotalBytes;

  bool get _isImage => isPreviewableImageName(widget.name);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _imageTooLarge = false;
    });
    try {
      if (_isImage) {
        final prefix = await widget.api.turnFilePrefix(
          widget.coordinate,
          kTurnTailImagePreviewLimit,
        );
        final total = prefix.total;
        if (total != null && total > prefix.bytes.length) {
          _imageTooLarge = true;
          _imageTotalBytes = total;
        } else {
          _imageBytes = prefix.bytes;
        }
      } else {
        final prefix = await widget.api.turnFilePrefix(
          widget.coordinate,
          kPreviewByteLimit,
        );
        final bytes = prefix.bytes;
        final encoding = detectPreviewEncoding(bytes);
        if (encoding == PreviewEncoding.gb18030) {
          try {
            final text = await _filesChannel.invokeMethod<String>(
              'decodeText',
              {'bytes': bytes, 'charset': 'GB18030'},
            );
            if (text == null) throw StateError('empty decode result');
            _preview = PreviewText(
              text: text,
              truncated: prefix.truncated,
              bytesShown: bytes.length,
              encodingLabel: previewEncodingLabel(PreviewEncoding.gb18030),
            );
          } catch (_) {
            _preview = const PreviewUnavailable('GB18030 文件：系统解码失败');
          }
        } else {
          _preview = buildPreview(
            bytes,
            encoding: encoding,
            truncated: prefix.truncated,
          );
        }
      }
      _loading = false;
    } catch (e) {
      _loading = false;
      _error = L10n.t('无法读取文件：$e', 'Cannot read file: $e');
    }
    if (mounted) setState(() {});
  }

  static const MethodChannel _filesChannel = MethodChannel('dsh/files');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.display.isEmpty ? widget.name : widget.display,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_isImage) return _imageBody();
    final verdict = _preview;
    if (_loading || verdict == null) {
      return GitFileViewer(
        key: const Key('turn-file-preview'),
        mode: GitFileViewerMode.content,
        path: widget.display,
        loading: _loading,
        error: _loading ? null : _error,
        onRetry: _load,
        keys: const GitFileViewerKeys(prefix: 'turn-file-preview'),
      );
    }
    if (verdict is PreviewUnavailable) {
      return GitFileViewer(
        key: const Key('turn-file-preview'),
        mode: GitFileViewerMode.content,
        path: widget.display,
        notice: verdict.reason,
        keys: const GitFileViewerKeys(prefix: 'turn-file-preview'),
      );
    }
    final text = verdict as PreviewText;
    return GitFileViewer(
      key: const Key('turn-file-preview'),
      mode: GitFileViewerMode.content,
      path: widget.display,
      content: text.text,
      encodingLabel: text.encodingLabel,
      truncated: text.truncated,
      truncatedMessage: L10n.t(
        '文件较大，仅显示前 ${text.bytesShown ~/ 1024} KiB',
        'File is large: showing first ${text.bytesShown ~/ 1024} KiB',
      ),
      keys: const GitFileViewerKeys(prefix: 'turn-file-preview'),
    );
  }

  Widget _imageBody() {
    if (_loading && _imageBytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ImageUnavailable(
        title: widget.display,
        message: _error!,
        onRetry: _load,
      );
    }
    if (_imageTooLarge) {
      return _ImageUnavailable(
        title: widget.display,
        message: L10n.t(
          '图片过大，无法在手机预览（${_formatBytes(_imageTotalBytes)}）',
          'Image too large to preview (${_formatBytes(_imageTotalBytes)})',
        ),
      );
    }
    final bytes = _imageBytes;
    if (bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Container(
      color: DshColors.surface(context),
      alignment: Alignment.center,
      child: InteractiveViewer(
        maxScale: 8,
        minScale: 0.5,
        child: Image.memory(
          bytes,
          key: const Key('turn-file-preview-image'),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => _ImageUnavailable(
            title: widget.display,
            message: L10n.t('图片解码失败', 'Failed to decode image'),
          ),
        ),
      ),
    );
  }

  static String _formatBytes(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}

class _ImageUnavailable extends StatelessWidget {
  const _ImageUnavailable({
    required this.title,
    required this.message,
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined, size: 40, color: ink2),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: ink2),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: ink2),
            ),
            if (onRetry != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextButton(
                  key: const Key('turn-file-preview-retry'),
                  onPressed: onRetry,
                  child: Text(L10n.t('重试', 'Retry')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
