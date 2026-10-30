import 'dart:io';
import 'dart:typed_data';

/// 流式下载进度（total 为 null 时表示服务端未给 Content-Length）。
class DownloadProgress {
  const DownloadProgress({required this.received, this.total});

  final int received;
  final int? total;

  /// 0.0–1.0；total 未知时返回 null（UI 用不确定进度条）。
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }
}

/// 下载完成结果；[file] 是 App 临时目录里的文件，调用方负责保存到 Downloads 后删除。
class DownloadResult {
  const DownloadResult({
    required this.file,
    required this.bytes,
    this.contentType,
  });

  final File file;
  final int bytes;
  final String? contentType;
}

/// 用户主动取消（与网络错误区分，UI 不必报“下载失败”）。
class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'download cancelled';
}

/// 前缀下载结果：用于预览只取前 N 字节。
class DownloadPrefix {
  const DownloadPrefix({required this.bytes, this.total});

  final Uint8List bytes;

  /// 文件总字节数；旧插件/无 Content-Length/Content-Range 时为 null。
  final int? total;

  bool get truncated => total != null && total! > bytes.length;
}

/// 下载取消令牌；不持有 http.Client，避免取消时打断其它 API 请求。
class DownloadCancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}
