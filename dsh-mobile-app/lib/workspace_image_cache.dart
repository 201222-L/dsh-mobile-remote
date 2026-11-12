// issue #95（#94 review）：工作区图片字节的会话级 LRU 缓存。
//
// - 32MiB / 64 条；命中提升为最近使用；失败/超限不缓存；
// - 最多 maxPending 个活跃 fetch；同 key 的 in-flight 复用；
// - clear/dispose 后：排队 waiter 一律不启动、不 fetch；活跃请求不可取消，但其
//   generation 已过期 → 不缓存/不返回（抛 stale）。槽位直接交接，绝不先减后唤醒；
// - in-flight 用 token 身份，旧 future 的 finally 不会误删 clear 之后的新请求。

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

class _Waiter {
  _Waiter(this.generation);
  final int generation;
  final Completer<bool> completer = Completer<bool>();
}

class _InFlight {
  _InFlight(this.token);
  final int token;
  late final Future<Uint8List> future;
}

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
  final Map<String, _InFlight> _inFlight = {};
  final ListQueue<_Waiter> _waiters = ListQueue();
  int _bytes = 0;
  int _loading = 0;
  int _generation = 0;
  int _token = 0;

  int get byteSize => _bytes;
  int get length => _entries.length;
  int get loading => _loading;
  int get generation => _generation;

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
    final existing = _inFlight[key];
    if (existing != null) return existing.future;

    final generation = _generation;
    final token = ++_token;
    final entry = _InFlight(token);
    entry.future = _run(key, fetch, stillWanted, generation, token);
    _inFlight[key] = entry;
    return entry.future;
  }

  Future<Uint8List> _run(
    String key,
    Future<Uint8List> Function() fetch,
    bool Function()? stillWanted,
    int generation,
    int token,
  ) async {
    final acquired = await _acquire(generation);
    if (!acquired) {
      // clear/dispose 后排队：不得 fetch，也不占用槽位。
      _removeInFlight(key, token);
      throw StateError('image-load-stale');
    }
    try {
      // acquire 与 fetch 之间没有 await；clear 不可能插入到这里。
      if (generation != _generation) {
        throw StateError('image-load-stale');
      }
      final bytes = await fetch();
      // 活跃请求不可取消，但 clear/会话切走后不得回填/返回旧代结果。
      if (generation != _generation || stillWanted?.call() == false) {
        throw StateError('image-load-stale');
      }
      if (bytes.length <= maxBytes) _put(key, bytes);
      return bytes;
    } finally {
      _removeInFlight(key, token);
      _release(generation);
    }
  }

  void _removeInFlight(String key, int token) {
    final current = _inFlight[key];
    if (current != null && current.token == token) _inFlight.remove(key);
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

  Future<bool> _acquire(int generation) async {
    if (generation != _generation) return false;
    if (_loading < maxPending) {
      _loading += 1;
      return true;
    }
    final waiter = _Waiter(generation);
    _waiters.add(waiter);
    final granted = await waiter.completer.future;
    // granted=true 表示槽位已直接交接；若随后 clear 让 generation 失效，_run 会在
    // try/finally 里 release 归还槽位（不能让槽位凭空消失）。
    return granted;
  }

  void _release(int generation) {
    // 活跃槽位结束：优先直接交接给下一个**当前代** waiter，不先减后唤醒；
    // 过期 waiter（clear 前排队）已完成 false，不消耗槽位，继续找下一个。
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.generation != _generation) {
        if (!waiter.completer.isCompleted) waiter.completer.complete(false);
        continue;
      }
      if (!waiter.completer.isCompleted) waiter.completer.complete(true);
      return; // 槽位交接，_loading 不变
    }
    if (_loading > 0) _loading -= 1;
  }

  /// 失败驱逐：调用方 catch 后可显式丢弃（本次失败本来就不会写入；保留 API 供测试）。
  void evict(String key) {
    final bytes = _entries.remove(key);
    if (bytes != null) _bytes -= bytes.length;
  }

  /// 清空缓存/队列（ChatScreen dispose 或切会话）。
  ///
  /// 活跃请求保持运行但 generation 失效（迟到结果丢弃）；排队 waiter 全部取消，
  /// 不启动、不 fetch。_loading 保留活跃槽位数（≤ maxPending）。
  void clear() {
    _generation += 1;
    _entries.clear();
    _bytes = 0;
    _inFlight.clear();
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.completer.isCompleted) waiter.completer.complete(false);
    }
  }
}
