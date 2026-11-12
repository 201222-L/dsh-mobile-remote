// issue #95（#94 review）：工作区图片字节的会话级 LRU 缓存。
//
// - 32MiB / 64 条；命中提升为最近使用；失败/超限不缓存；
// - 最多 4 个并发加载，其余排队；同一 key 的 in-flight 请求复用；
// - clear/dispose 后旧代迟到响应不得回填；
// - key 由调用方带 sessionId，避免跨会话串图。

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

class WorkspaceImageCache {
  WorkspaceImageCache({
    this.maxBytes = 32 * 1024 * 1024,
    this.maxEntries = 64,
    this.maxPending = 4,
  });

  final int maxBytes;
  final int maxEntries;
  final int maxPending;

  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  final Map<String, Future<Uint8List>> _inFlight = {};
  final List<Completer<void>> _waiters = [];
  int _bytes = 0;
  int _loading = 0;
  int _generation = 0;

  int get byteSize => _bytes;
  int get length => _entries.length;
  int get loading => _loading;

  Uint8List? get(String key) {
    final bytes = _entries.remove(key);
    if (bytes == null) return null;
    _entries[key] = bytes; // LRU：命中的放到最新
    return bytes;
  }

  Future<Uint8List> load(
    String key,
    Future<Uint8List> Function() fetch, {
    bool Function()? stillWanted,
  }) {
    final hit = get(key);
    if (hit != null) return Future.value(hit);
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;
    final generation = _generation;
    final future = _run(key, fetch, stillWanted, generation);
    _inFlight[key] = future;
    return future;
  }

  Future<Uint8List> _run(
    String key,
    Future<Uint8List> Function() fetch,
    bool Function()? stillWanted,
    int generation,
  ) async {
    await _acquire();
    try {
      final bytes = await fetch();
      // clear/dispose 或会话切走：不缓存、不返回给已卸载页面（由调用方 FutureBuilder 丢弃）。
      if (generation != _generation || stillWanted?.call() == false) {
        throw StateError('image-load-stale');
      }
      if (bytes.length <= maxBytes) _put(key, bytes);
      return bytes;
    } finally {
      _inFlight.remove(key);
      _release();
    }
  }

  void _put(String key, Uint8List bytes) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;
    _entries[key] = bytes;
    _bytes += bytes.length;
    while (_entries.length > maxEntries ||
        (_bytes > maxBytes && _entries.isNotEmpty)) {
      final oldest = _entries.keys.first;
      final removed = _entries.remove(oldest);
      _bytes -= removed?.length ?? 0;
    }
  }

  Future<void> _acquire() async {
    if (_loading < maxPending) {
      _loading += 1;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _loading += 1;
  }

  void _release() {
    if (_loading > 0) _loading -= 1;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  /// 失败驱逐：调用方 catch 后可显式丢弃（本次失败本来就不会写入；保留 API 供测试）。
  void evict(String key) {
    final bytes = _entries.remove(key);
    if (bytes != null) _bytes -= bytes.length;
  }

  void clear() {
    _generation += 1;
    _entries.clear();
    _bytes = 0;
    _inFlight.clear();
    // 正在排队的加载不再启动；在途请求由 generation 检查丢弃回填。
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }
}
