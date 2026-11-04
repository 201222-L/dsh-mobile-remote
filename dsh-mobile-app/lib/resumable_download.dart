import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'download.dart';

class PendingDownload {
  const PendingDownload(this.remotePath, this.bytes);
  final String remotePath;
  final int bytes;
  String get name => remotePath.split(RegExp(r'[\\/]')).last;
}

/// 私有断点按认证宿主隔离；磁盘上只写作用域摘要，不保存地址或口令。
/// 记录先于正文落盘，恢复时以实际文件长度为准。
class ResumableDownloads {
  ResumableDownloads(this.root, this.api) : _scope = _scopeOf(api);

  final Directory root;
  final Api api;
  final String _scope;
  static final Set<String> _active = {};

  static String _hash(String text) =>
      sha256.convert(utf8.encode(text)).toString();
  static String _scopeOf(Api api) =>
      _hash(jsonEncode([api.baseUrl, api.path, api.token]));
  Directory get _directory => Directory('${root.path}/$_scope');
  String _key(String path) => _hash(path);
  File _record(String path) => File('${_directory.path}/${_key(path)}.json');
  File _target(String path) => File('${_directory.path}/${_key(path)}.part');

  Future<Map<String, dynamic>?> _read(String path) async {
    try {
      final value = jsonDecode(await _record(path).readAsString());
      if (value is Map<String, dynamic> &&
          value['version'] == 1 &&
          value['remotePath'] == path) {
        return value;
      }
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _write(String path, Map<String, dynamic> values) async {
    await _directory.create(recursive: true);
    final record = _record(path);
    final temp = File('${record.path}.tmp');
    await temp.writeAsString(
      jsonEncode({'version': 1, 'remotePath': path, ...values}),
      flush: true,
    );
    await temp.rename(record.path);
  }

  /// 同一宿主的恢复入口；自动清除超过七天的断点，最多保留最近八项。
  Future<List<PendingDownload>> pending() async {
    if (!await _directory.exists()) return const [];
    final records = <({String path, int bytes, DateTime modified})>[];
    await for (final entry in _directory.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final value = jsonDecode(await entry.readAsString());
        if (value is! Map || value['remotePath'] is! String) continue;
        final path = value['remotePath'] as String;
        if (File(entry.path).absolute.uri != _record(path).absolute.uri) {
          continue;
        }
        final stat = await entry.stat();
        final target = _target(path);
        if (DateTime.now().difference(stat.modified).inDays >= 7 ||
            !await target.exists()) {
          if (!_active.contains(target.path)) await discard(path);
          continue;
        }
        records.add((
          path: path,
          bytes: await target.length(),
          modified: stat.modified,
        ));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    records.sort((a, b) => b.modified.compareTo(a.modified));
    for (final record in records.skip(8)) {
      if (!_active.contains(_target(record.path).path)) {
        await discard(record.path);
      }
    }
    return [for (final r in records.take(8)) PendingDownload(r.path, r.bytes)];
  }

  Future<void> discard(String path) async {
    if (_active.contains(_target(path).path)) {
      throw StateError('download is active');
    }
    for (final file in [
      _record(path),
      _target(path),
      File('${_record(path).path}.tmp'),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<DownloadResult> download(
    String path, {
    DownloadCancelToken? cancel,
    void Function(DownloadProgress)? onProgress,
    http.Client? downloadClient,
    Duration idleTimeout = const Duration(seconds: 30),
  }) async {
    if (_scopeOf(api) != _scope) throw StateError('connection changed');
    final target = _target(path);
    if (!_active.add(target.path)) throw StateError('download is active');
    try {
      await _directory.create(recursive: true);
      var record = await _read(path) ?? <String, dynamic>{};
      if (record.isEmpty) {
        // 请求尚未收到响应就断网/被暂停时，也保留恢复入口。
        await target.writeAsBytes(const []);
        record = {'complete': false};
        await _write(path, record);
      }
      var bytes = await target.exists() ? await target.length() : 0;
      if (await target.exists() &&
          record['complete'] == true &&
          record['total'] == bytes) {
        return DownloadResult(
          file: target,
          bytes: bytes,
          contentType: record['contentType'] as String?,
        );
      }
      final etag = record['etag'];
      // 无强校验标记的旧宿主仍可下载，但不能可靠地拼接已有字节。
      final canResume =
          etag is String && etag.startsWith('"') && etag.endsWith('"');
      if (!canResume) bytes = 0;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final result = await api.downloadFileToFile(
            path,
            target,
            startOffset: bytes,
            expectedEtag: bytes > 0 ? etag as String : null,
            cancel: cancel,
            keepPartialOnCancel: true,
            onProgress: onProgress,
            idleTimeout: idleTimeout,
            downloadClient: downloadClient,
            onMetadata: (metadata) async {
              record = {
                'etag': metadata.etag,
                'total': metadata.total,
                'contentType': metadata.contentType,
                'complete': false,
              };
              await _write(path, record);
            },
          );
          await _write(path, {
            ...record,
            'total': result.bytes,
            'complete': true,
          });
          return result;
        } on DownloadChanged {
          if (attempt > 0) rethrow;
          bytes = 0;
        }
      }
      throw StateError('download retry exhausted');
    } finally {
      _active.remove(target.path);
    }
  }
}
