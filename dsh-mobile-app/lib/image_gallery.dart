// issue #69（M3 Batch 2-D）：工具卡 / 消息附图图库增强。
//
// 统一承载原 `_ImagesGrid`/`_MsgImage` 的能力（纵向缩略图、GIF 角标、宽高回退、
// BoxFit.contain、失败重试、点击全屏、LRU 字节缓存），并补齐：
//   - 多图全屏查看器：左右滑动分页（PageView + N/M 页码，单图不显示分页控件）、
//     每页独立 InteractiveViewer（0.5–4x，缩放状态不串页）；
//   - 元数据行（缩略图下方 + 查看器内）：`width×height`、文件名（缺省「图片 N」）、
//     mediaType 短标签、数字型 `size`/`bytes` 的人类可读字节数（字段不存在则隐藏，
//     服务端契约不变，不猜）；
//   - 保存到手机 / 分享：临时文件 → `dsh/files` 原生 `saveFileFromPath` →
//     分享再调 `shareFile(uri, mime)`；失败给明确提示且可重试；临时文件 finally 清理；
//   - 查看器内加载失败 →「重试」真的重新拉取。
//
// 语义（issue #69 修订）：保存/分享都走系统「保存到手机」通道——Android 10+ 落
// Downloads/DSH-Remote，旧版本落应用下载目录，**不写系统相册**；Android 10 以下
// 原生只能返回应用私有路径，此时分享明确提示「该 Android 版本不支持」。
//
// 查看器是 dialog 路由：不重建 ChatScreen 列表，返回后滚动位置与工具卡展开态天然保持。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'l10n.dart';
import 'theme.dart';
import 'toast.dart';

/// 原生文件通道（保存到手机 / 分享）；widget 测试可经 [ImageGalleryIo] 注入假实现。
const MethodChannel imageGalleryFilesChannel = MethodChannel('dsh/files');

/// 图库宿主 IO：临时目录 + `dsh/files` 通道。
///
/// 生产路径用默认实现；测试注入子类即可完全避开真实文件系统与平台通道
/// （本文件不直接摸 path_provider / MethodChannel）。
class ImageGalleryIo {
  const ImageGalleryIo();

  /// 保存/分享的中转临时文件：默认写系统临时目录并返回路径。
  /// 单独抽成方法，widget 测试可完全避开真实文件系统。
  Future<String> writeTemporaryFile({
    required String prefix,
    required String name,
    required Uint8List bytes,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/$prefix-${DateTime.now().microsecondsSinceEpoch}-$name',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 删除中转临时文件（失败静默：系统临时目录会被回收）。
  Future<void> deleteTemporaryFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // 临时目录由系统回收；删除失败不影响用户结果。
    }
  }

  /// `dsh/files` 原生通道调用（saveFileFromPath / shareFile）。
  Future<T?> invokeMethod<T>(String method, Map<String, dynamic> arguments) =>
      imageGalleryFilesChannel.invokeMethod<T>(method, arguments);
}

// ── 元数据纯函数（缩略图与查看器共用同一套规则，便于单测锁定） ──────────────

/// 元数据行分隔符。
const String imageMetaSeparator = ' · ';

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// 展示名（1-based）：`name` 缺失/空 →「图片 N」。
String imageDisplayName(Map<String, dynamic> image, int index) =>
    _nonEmpty(image['name']) ?? L10n.t('图片 ${index + 1}', 'Image ${index + 1}');

/// `width×height`：两值都存在且 > 0 才显示（缺一不猜）。
String? imagePixelSizeLabel(Map<String, dynamic> image) {
  final width = (image['width'] as num?)?.toInt();
  final height = (image['height'] as num?)?.toInt();
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return '$width×$height';
}

/// 字节数：仅接受数字型 `size`/`bytes`（服务端当前不下发 → 通常为 null）。
int? imageByteSize(Map<String, dynamic> image) {
  final size = image['size'] ?? image['bytes'];
  if (size is num && size >= 0) return size.toInt();
  return null;
}

/// 人类可读字节数：B / KB / MB（整数不显示 `.0`）。
String formatImageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${_trimNumber(kb)} KB';
  return '${_trimNumber(kb / 1024)} MB';
}

String _trimNumber(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

const Map<String, String> _mediaTypeLabels = {
  'png': 'PNG',
  'jpeg': 'JPEG',
  'jpg': 'JPEG',
  'gif': 'GIF',
  'webp': 'WebP',
  'bmp': 'BMP',
  'heic': 'HEIC',
  'heif': 'HEIF',
  'avif': 'AVIF',
  'svg': 'SVG',
  'svg+xml': 'SVG',
  'tiff': 'TIFF',
  'ico': 'ICO',
};

/// mediaType 可读短标签：`image/png`→`PNG`、`image/webp`→`WebP`；空值返回 null。
String? imageMediaLabel(Map<String, dynamic> image) {
  final mediaType = _nonEmpty(image['mediaType']);
  if (mediaType == null) return null;
  final suffix = mediaType.toLowerCase().startsWith('image/')
      ? mediaType.substring('image/'.length)
      : mediaType;
  final lower = suffix.toLowerCase();
  return _mediaTypeLabels[lower] ?? lower.toUpperCase();
}

/// 元数据行：尺寸 · 名称 · mediaType · 字节数（缺省项省略；名称始终有值）。
String imageMetaLine(
  Map<String, dynamic> image,
  int index, {
  String separator = imageMetaSeparator,
}) {
  final bytes = imageByteSize(image);
  return <String>[
    ?imagePixelSizeLabel(image),
    imageDisplayName(image, index),
    ?imageMediaLabel(image),
    if (bytes != null) formatImageBytes(bytes),
  ].join(separator);
}

/// 扩展名（由 mediaType 推导，保持既有保存命名语义）。
String imageFileExtension(Map<String, dynamic> image) {
  final mediaType = _nonEmpty(image['mediaType']) ?? '';
  final ext = mediaType
      .split('/')
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '')
      .toLowerCase();
  return ext;
}

/// 保存/分享到系统时使用的文件名：优先原始 `name`；缺省用 `dsh-image-<id>`；
/// 缺扩展名时按 mediaType 补，避免系统侧无法识别类型。
String imageExportFileName(Map<String, dynamic> image, int index) {
  final id = _nonEmpty(image['attachmentId']) ?? '';
  final rawName = _nonEmpty(image['name']);
  final ext = imageFileExtension(image);
  final base = rawName != null
      ? rawName.replaceAll(RegExp(r'[/\\]'), '_')
      : (id.isNotEmpty ? 'dsh-image-$id' : 'dsh-image-${index + 1}');
  if (ext.isEmpty) return base;
  final lower = base.toLowerCase();
  if (lower.endsWith('.$ext') || (ext == 'jpeg' && lower.endsWith('.jpg'))) {
    return base;
  }
  return '$base.$ext';
}

// ── 缩略图几何 / GIF 角标（保留 v3.0.0 起的既有行为） ────────────────────────

/// 缩略图固定显示宽度（逻辑像素）。
const double imageThumbBoxWidth = 236;

/// 缩略图显示框：宽 236；高按比例（缺尺寸回退 4:3），并限制在 80–480。
/// 与旧实现逐字一致：宽高各自缺省为 4/3，再 clamp 比例 0.3–3.0。
Size imageThumbBoxSize(Map<String, dynamic> image) {
  final width = (image['width'] as num?)?.toDouble() ?? 4;
  final height = (image['height'] as num?)?.toDouble() ?? 3;
  final ratio = (width > 0 && height > 0)
      ? (width / height).clamp(0.3, 3.0)
      : 1.5;
  return Size(
    imageThumbBoxWidth,
    (imageThumbBoxWidth / ratio).clamp(80.0, 480.0),
  );
}

/// 大 GIF 角标：长边 > 4096 或解码字节 > 16MB（体积只在已加载时可知）。
bool isLargeGifImage(Map<String, dynamic> image, int? decodedBytes) {
  if (image['mediaType'] != 'image/gif') return false;
  final width = (image['width'] as num?)?.toDouble() ?? 0;
  final height = (image['height'] as num?)?.toDouble() ?? 0;
  return (width > 0 && height > 0 && (width > 4096 || height > 4096)) ||
      (decodedBytes ?? 0) > 16 * 1024 * 1024;
}

/// 缩略图与查看器共享的字节缓存：同一 attachmentId 只请求一次（Api 内另有 LRU）。
/// 失败不缓存 —— 重试会真的重新发请求。
class ImageGalleryCache {
  ImageGalleryCache({required this.api, required this.sessionId});

  final Api api;
  final String sessionId;
  final Map<String, Uint8List> _loaded = {};
  final Map<String, Future<Uint8List>> _pending = {};

  Uint8List? bytesOf(String attachmentId) => _loaded[attachmentId];

  Future<Uint8List> load(String attachmentId) {
    final hit = _loaded[attachmentId];
    if (hit != null) return Future<Uint8List>.value(hit);
    final pending = _pending[attachmentId];
    if (pending != null) return pending;
    final future = api
        .attachmentBytes(sessionId, attachmentId)
        .then((bytes) {
          _loaded[attachmentId] = bytes;
          return bytes;
        })
        // 注意：块体，不能写成 `() => _pending.remove(...)`——remove 返回被删的
        // Future 本身，whenComplete 会等这个自引用 Future 而永久挂起。
        .whenComplete(() {
          _pending.remove(attachmentId);
        });
    _pending[attachmentId] = future;
    return future;
  }
}

String _attachmentIdOf(Map<String, dynamic> image) =>
    image['attachmentId']?.toString() ?? '';

// ── 附图区域（chat_screen 的 _ImagesGrid 薄包装到这里） ──────────────────────

/// 消息/工具卡附图区域：纵向缩略图列表，每张图下一行紧凑元数据；点击打开统一
/// 多图查看器（与列表共享字节缓存，打开/切页不重复 HTTP）。
class ImageGalleryGrid extends StatefulWidget {
  const ImageGalleryGrid({
    super.key,
    required this.images,
    required this.sessionId,
    required this.api,
    this.io = const ImageGalleryIo(),
  });

  final List<Map<String, dynamic>> images;
  final String sessionId;
  final Api api;
  final ImageGalleryIo io;

  @override
  State<ImageGalleryGrid> createState() => _ImageGalleryGridState();
}

class _ImageGalleryGridState extends State<ImageGalleryGrid> {
  late ImageGalleryCache _cache;

  @override
  void initState() {
    super.initState();
    _cache = ImageGalleryCache(api: widget.api, sessionId: widget.sessionId);
  }

  @override
  void didUpdateWidget(covariant ImageGalleryGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.api != widget.api) {
      _cache = ImageGalleryCache(api: widget.api, sessionId: widget.sessionId);
    }
  }

  Future<void> _openViewer(int index) async {
    if (widget.images.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => ImageGalleryViewer(
        api: widget.api,
        sessionId: widget.sessionId,
        images: widget.images,
        initialIndex: index,
        cache: _cache,
        io: widget.io,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < widget.images.length; index++) ...[
          if (index > 0) const SizedBox(height: 6),
          _ImageThumbnail(
            key: ValueKey<String>(
              'issue69-thumb-state:${widget.sessionId}:'
              '${_attachmentIdOf(widget.images[index])}:$index',
            ),
            image: widget.images[index],
            index: index,
            cache: _cache,
            onOpen: () => _openViewer(index),
          ),
        ],
      ],
    );
  }
}

class _ImageThumbnail extends StatefulWidget {
  const _ImageThumbnail({
    super.key,
    required this.image,
    required this.index,
    required this.cache,
    required this.onOpen,
  });

  final Map<String, dynamic> image;
  final int index;
  final ImageGalleryCache cache;
  final VoidCallback onOpen;

  @override
  State<_ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends State<_ImageThumbnail> {
  Uint8List? _bytes;
  bool _loading = true;
  int _loadToken = 0;

  String get _attachmentId => _attachmentIdOf(widget.image);

  @override
  void initState() {
    super.initState();
    _primeFromCache();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startLoad();
    });
  }

  @override
  void didUpdateWidget(covariant _ImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = _attachmentIdOf(oldWidget.image);
    if (oldId != _attachmentId || oldWidget.cache != widget.cache) {
      _loadToken++;
      _bytes = null;
      _loading = true;
      _primeFromCache();
      // didUpdateWidget 发生在构建阶段，异步收尾用 post-frame，避免 build 中 setState。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startLoad();
      });
    }
  }

  void _primeFromCache() {
    final cached = widget.cache.bytesOf(_attachmentId);
    if (cached != null) {
      _bytes = cached;
      _loading = false;
    }
  }

  Future<void> _startLoad() async {
    final token = ++_loadToken;
    final id = _attachmentId;
    final cache = widget.cache;
    if (id.isEmpty || cache.sessionId.isEmpty) {
      if (mounted && token == _loadToken) {
        setState(() => _loading = false);
      }
      return;
    }
    final cached = cache.bytesOf(id);
    if (cached != null) {
      if (mounted && token == _loadToken) {
        setState(() {
          _bytes = cached;
          _loading = false;
        });
      }
      return;
    }
    try {
      final bytes = await cache.load(id);
      if (!mounted || token != _loadToken || id != _attachmentId) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || token != _loadToken || id != _attachmentId) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final box = imageThumbBoxSize(image);
    final boxW = box.width;
    final boxH = box.height;
    final line = DshColors.line(context);
    final bigGif = isLargeGifImage(image, _bytes?.length);
    final bytes = _bytes;
    final metaLine = imageMetaLine(image, widget.index);
    final id = _attachmentId;
    final metaKey = ValueKey<String>(
      id.isEmpty ? 'issue69-meta-index-${widget.index}' : 'issue69-meta-$id',
    );
    final thumbKey = ValueKey<String>(
      id.isEmpty ? 'issue69-thumb-index-${widget.index}' : 'issue69-thumb-$id',
    );
    final boxKey = ValueKey<String>(
      id.isEmpty
          ? 'issue69-thumb-box-index-${widget.index}'
          : 'issue69-thumb-box-$id',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: thumbKey,
          onTap: bytes != null ? widget.onOpen : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              key: boxKey,
              width: boxW,
              height: boxH,
              color: line,
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : bytes != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        // v3.1.6（app-audit ①4）：按卡片显示宽度 2x 解码，
                        // 避免每条附图都按原始分辨率（12MP≈48MB）解码。
                        Image.memory(
                          bytes,
                          key: ValueKey<String>(
                            id.isEmpty
                                ? 'issue69-thumb-image-index-${widget.index}'
                                : 'issue69-thumb-image-$id',
                          ),
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          cacheWidth: 480,
                        ),
                        if (bigGif)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                L10n.t('GIF·原图较大', 'GIF · large file'),
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : InkWell(
                      onTap: _startLoad,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image_outlined,
                              size: 24,
                              color: DshColors.ink3(context),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              L10n.t(
                                '加载失败，点按重试',
                                'Failed to load — tap to retry',
                              ),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: DshColors.ink3(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 3),
        // issue #69：每张缩略图下紧凑一行元数据；长文件名截断不溢出。
        SizedBox(
          width: boxW,
          child: Text(
            metaLine,
            key: metaKey,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              height: 1.25,
              color: DshColors.ink3(context),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 全屏查看器（所有附图统一入口；dialog 路由，不重建会话列表） ─────────────

/// 全屏图库查看器：黑底、系统返回可关；多图 PageView 左右切换 + `N/M` 页码；
/// 每页独立缩放（InteractiveViewer 0.5–4x）；元数据行；保存到手机 / 分享；
/// 加载失败可重试。
class ImageGalleryViewer extends StatefulWidget {
  const ImageGalleryViewer({
    super.key,
    required this.api,
    required this.sessionId,
    required this.images,
    this.initialIndex = 0,
    this.cache,
    this.io = const ImageGalleryIo(),
  });

  final Api api;
  final String sessionId;
  final List<Map<String, dynamic>> images;
  final int initialIndex;

  /// 缩略图已加载的字节缓存（共享 → 打开/切回已加载页不重复请求）。
  final ImageGalleryCache? cache;
  final ImageGalleryIo io;

  @override
  State<ImageGalleryViewer> createState() => _ImageGalleryViewerState();
}

class _ImageGalleryViewerState extends State<ImageGalleryViewer> {
  late final ImageGalleryCache _cache;
  late final PageController _pageController;
  final Map<int, TransformationController> _zoomControllers = {};
  final Map<String, Uint8List> _bytes = {};
  final Set<String> _pending = {};
  final Map<String, String> _errors = {};
  final Map<int, Offset> _pointers = {};
  int _index = 0;
  bool _zoomed = false;
  bool _dragging = false;
  double _dragDx = 0;
  bool _saving = false;
  bool _sharing = false;

  List<Map<String, dynamic>> get _images => widget.images;

  @override
  void initState() {
    super.initState();
    _index = widget.images.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.images.length - 1);
    _cache =
        widget.cache ??
        ImageGalleryCache(api: widget.api, sessionId: widget.sessionId);
    _pageController = PageController(initialPage: _index);
    _seedFromCache();
    _ensureLoaded(_index);
  }

  @override
  void dispose() {
    for (final controller in _zoomControllers.values) {
      controller.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  void _seedFromCache() {
    for (final image in _images) {
      final id = _attachmentIdOf(image);
      if (id.isEmpty) continue;
      final cached = _cache.bytesOf(id);
      if (cached != null) _bytes[id] = cached;
    }
  }

  String? get _currentBytesId =>
      _images.isEmpty ? null : _attachmentIdOf(_images[_index]);

  Uint8List? get _currentBytes {
    final id = _currentBytesId;
    if (id == null || id.isEmpty) return null;
    return _bytes[id] ?? _cache.bytesOf(id);
  }

  /// 登记并开始加载某页（同步登记 loading 状态；调用方负责触发重建）。
  void _ensureLoaded(int index) {
    if (index < 0 || index >= _images.length) return;
    final id = _attachmentIdOf(_images[index]);
    if (id.isEmpty || _cache.sessionId.isEmpty) return;
    if (_bytes.containsKey(id) || _pending.contains(id)) return;
    final cached = _cache.bytesOf(id);
    if (cached != null) {
      _bytes[id] = cached;
      return;
    }
    _pending.add(id);
    unawaited(_load(id));
  }

  Future<void> _load(String id) async {
    try {
      final bytes = await _cache.load(id);
      if (!mounted) return;
      setState(() {
        _bytes[id] = bytes;
        _pending.remove(id);
        _errors.remove(id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pending.remove(id);
        _errors[id] = L10n.t('图片加载失败', 'Image failed to load');
      });
      // 明确提示（连续失败仍会再次提示）；页内同时显示失败态 + 重试按钮。
      showToast(
        context,
        L10n.t('图片加载失败，可点重试', 'Image failed to load. Tap retry.'),
      );
    }
  }

  void _retryCurrent() {
    if (_images.isEmpty) return;
    final id = _attachmentIdOf(_images[_index]);
    if (id.isEmpty) return;
    setState(() {
      _errors.remove(id);
      _pending.remove(id);
      _ensureLoaded(_index);
    });
  }

  TransformationController _zoomControllerFor(int index) {
    return _zoomControllers.putIfAbsent(index, () {
      final controller = TransformationController();
      controller.addListener(() {
        if (!mounted || index != _index) return;
        final zoomed = controller.value.getMaxScaleOnAxis() > 1.05;
        if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
      });
      return controller;
    });
  }

  // ── 左右滑动分页：PageView 固定 NeverScrollable，由指针状态机驱动 ──────────
  // 原因：InteractiveViewer 的 scale 手势会赢下 PageView 的横向 drag 竞争，
  // 直接用可滚动 PageView 会导致「滑动无法翻页」。这里手动识别单指横向拖动
  // （缩放态不翻页，交给 InteractiveViewer 拖动/缩放）。

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 1) {
      _dragDx = 0;
      _dragging = false;
    } else {
      _resetDrag();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointers.length != 1 || _zoomed || _images.length < 2) {
      _resetDrag();
      return;
    }
    final start = _pointers[event.pointer];
    if (start == null) return;
    final dx = event.position.dx - start.dx;
    final dy = event.position.dy - start.dy;
    if (!_dragging) {
      if (dx.abs() < 24 || dx.abs() < dy.abs() * 1.2) return;
      _dragging = true;
    }
    final atEdge =
        (_index == 0 && dx > 0) || (_index == _images.length - 1 && dx < 0);
    final damped = atEdge ? dx * 0.2 : dx * 0.6;
    final next = damped.clamp(-160.0, 160.0);
    if ((next - _dragDx).abs() < 0.5) return;
    setState(() => _dragDx = next);
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) {
      _resetDrag();
      return;
    }
    final dx = _dragDx;
    final wasDragging = _dragging;
    _dragging = false;
    _dragDx = 0;
    if (mounted) setState(() {});
    if (wasDragging && dx.abs() > 72) {
      _goToPage(_index + (dx < 0 ? 1 : -1));
    }
  }

  void _resetDrag() {
    if (_dragDx == 0 && !_dragging) return;
    _dragging = false;
    _dragDx = 0;
    if (mounted) setState(() {});
  }

  void _goToPage(int target) {
    if (target < 0 || target >= _images.length || target == _index) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() {
      _index = index;
      _dragDx = 0;
      _dragging = false;
      final zoomController = _zoomControllers[index];
      _zoomed =
          zoomController != null &&
          zoomController.value.getMaxScaleOnAxis() > 1.05;
      _ensureLoaded(index);
    });
  }

  // ── 保存到手机 / 分享（dsh/files 原生通道；不写系统相册） ─────────────────

  Future<String?> _writeTempFile(String prefix) async {
    final bytes = _currentBytes;
    if (bytes == null) return null;
    final name = imageExportFileName(_images[_index], _index);
    return widget.io.writeTemporaryFile(
      prefix: prefix,
      name: name,
      bytes: bytes,
    );
  }

  Future<void> _saveCurrent() async {
    if (_saving || _currentBytes == null) return;
    _saving = true;
    String? temp;
    try {
      temp = await _writeTempFile('dsh-save');
      if (temp == null) return;
      final name = imageExportFileName(_images[_index], _index);
      final saved = await widget.io.invokeMethod<String>('saveFileFromPath', {
        'path': temp,
        'name': name,
      });
      if (!mounted) return;
      if (saved == null || saved.isEmpty) {
        showToast(
          context,
          L10n.t('保存失败：未获取到保存位置', 'Save failed: no destination'),
        );
        return;
      }
      // Android 10+ 返回 content://（已落系统 Downloads/DSH-Remote），不把 URI
      // 号串抛给用户；旧版本返回应用下载目录路径，照实展示。
      final location = saved.startsWith('content://')
          ? L10n.t('系统下载目录 DSH-Remote', 'Downloads/DSH-Remote')
          : saved;
      showToast(context, '${L10n.t('已保存到手机：', 'Saved to phone: ')}$location');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${L10n.t('保存失败：', 'Save failed: ')}$e');
    } finally {
      _saving = false;
      if (temp != null) await widget.io.deleteTemporaryFile(temp);
    }
  }

  Future<void> _shareCurrent() async {
    if (_sharing || _currentBytes == null) return;
    _sharing = true;
    String? temp;
    try {
      temp = await _writeTempFile('dsh-share');
      if (temp == null) return;
      final name = imageExportFileName(_images[_index], _index);
      final saved = await widget.io.invokeMethod<String>('saveFileFromPath', {
        'path': temp,
        'name': name,
      });
      if (!mounted) return;
      if (saved == null || saved.isEmpty) {
        showToast(
          context,
          L10n.t('分享失败：未获取到可分享的文件', 'Share failed: no shareable file'),
        );
        return;
      }
      if (!saved.startsWith('content://')) {
        // Android 10 以下 saveFileFromPath 只能返回应用私有路径，原生 shareFile
        // 只接受 content:// —— 给出明确提示而不是泛化的异常。
        showToast(
          context,
          L10n.t(
            '该 Android 版本不支持直接分享（已保存到应用下载目录）',
            'Sharing is not supported on this Android version '
                '(saved to the app download folder)',
          ),
        );
        return;
      }
      final mediaType = _nonEmpty(_images[_index]['mediaType']) ?? '';
      final mime = mediaType.isEmpty ? 'application/octet-stream' : mediaType;
      await widget.io.invokeMethod<dynamic>('shareFile', {
        'uri': saved,
        'mime': mime,
      });
      if (!mounted) return;
      showToast(context, L10n.t('已打开分享面板', 'Share sheet opened'));
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${L10n.t('分享失败：', 'Share failed: ')}$e');
    } finally {
      _sharing = false;
      if (temp != null) await widget.io.deleteTemporaryFile(temp);
    }
  }

  // ── 构建 ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final imageCount = _images.length;
    final current = imageCount == 0 ? null : _images[_index];
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: (_) => _resetDrag(),
                child: Transform.translate(
                  offset: Offset(_dragDx, 0),
                  child: PageView.builder(
                    key: const Key('issue69-viewer-pages'),
                    controller: _pageController,
                    // 手势由上面的 Listener 手动驱动；InteractiveViewer 独占缩放/拖动。
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: _onPageChanged,
                    itemCount: imageCount,
                    itemBuilder: (context, index) => _buildPage(index),
                  ),
                ),
              ),
            ),
            Positioned(top: 0, left: 0, right: 0, child: _buildToolbar()),
            if (current != null)
              Positioned(left: 0, right: 0, bottom: 0, child: _buildMetaBar()),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final imageCount = _images.length;
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          IconButton(
            key: const Key('issue69-viewer-close'),
            tooltip: L10n.t('关闭', 'Close'),
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Center(
              child: imageCount > 1
                  ? Text(
                      '${_index + 1}/$imageCount',
                      key: const Key('issue69-viewer-page-indicator'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          IconButton(
            key: const Key('issue69-viewer-save'),
            tooltip: L10n.t('保存到手机', 'Save to phone'),
            icon: const Icon(Icons.download_outlined, color: Colors.white),
            onPressed: _currentBytes == null ? null : _saveCurrent,
          ),
          IconButton(
            key: const Key('issue69-viewer-share'),
            tooltip: L10n.t('分享', 'Share'),
            icon: const Icon(Icons.share_outlined, color: Colors.white),
            onPressed: _currentBytes == null ? null : _shareCurrent,
          ),
        ],
      ),
    );
  }

  Widget _buildMetaBar() {
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(
        imageMetaLine(_images[_index], _index),
        key: const Key('issue69-viewer-meta'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _buildPage(int index) {
    final image = _images[index];
    final id = _attachmentIdOf(image);
    final unavailable = id.isEmpty || _cache.sessionId.isEmpty;
    final bytes = id.isEmpty ? null : (_bytes[id] ?? _cache.bytesOf(id));
    final failure = _errors[id];
    final controller = _zoomControllerFor(index);
    final pageKey = ValueKey<String>('issue69-viewer-page-$index');
    if (bytes != null) {
      return SizedBox.expand(
        child: InteractiveViewer(
          key: pageKey,
          transformationController: controller,
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            // 查看器为全屏，直接按可用尺寸 contain（不再受缩略图 cacheWidth 限制）。
            child: Image.memory(
              bytes,
              key: ValueKey<String>('issue69-viewer-image-$index'),
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
            ),
          ),
        ),
      );
    }
    if (failure != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: 8),
            Text(
              failure,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              key: const Key('issue69-viewer-retry'),
              onPressed: _retryCurrent,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: Text(
                L10n.t('重试', 'Retry'),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }
    // 首次构建 / 切页动画中：加载中。
    return Center(
      child: unavailable
          ? Text(
              L10n.t('图片不可用', 'Image unavailable'),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            )
          : const CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
