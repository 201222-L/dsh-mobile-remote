// issue #95：工作区图片 LRU（32MiB/64条/pending≤4、命中提升、失败驱逐、clear 迟到不回填）。

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_mobile_app/workspace_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n) => Uint8List(n);

void main() {
  test('LRU：超过条目上限淘汰最旧；命中提升为最近', () async {
    final cache = WorkspaceImageCache(maxEntries: 2, maxBytes: 100);
    await cache.load('a', () async => _bytes(10));
    await cache.load('b', () async => _bytes(10));
    expect(cache.get('a'), isNotNull); // 命中提升 a
    await cache.load('c', () async => _bytes(10));
    expect(cache.get('a'), isNotNull);
    expect(cache.get('b'), isNull, reason: 'b 最久未用被淘汰');
    expect(cache.get('c'), isNotNull);
  });

  test('LRU：字节上限淘汰旧图；单图超过上限不缓存但可返回', () async {
    final cache = WorkspaceImageCache(maxEntries: 10, maxBytes: 20);
    await cache.load('a', () async => _bytes(12));
    await cache.load('b', () async => _bytes(12));
    expect(cache.get('a'), isNull);
    expect(cache.byteSize, lessThanOrEqualTo(20));

    final huge = await cache.load('huge', () async => _bytes(21));
    expect(huge.length, 21);
    expect(cache.get('huge'), isNull, reason: '超过 maxBytes 的图不进缓存');
  });

  test('失败驱逐：抛错不缓存，下次会重试', () async {
    final cache = WorkspaceImageCache();
    var calls = 0;
    Future<Uint8List> fetch() async {
      calls += 1;
      if (calls == 1) throw StateError('network');
      return _bytes(4);
    }

    await expectLater(cache.load('x', fetch), throwsA(isA<StateError>()));
    expect(cache.get('x'), isNull);
    final bytes = await cache.load('x', fetch);
    expect(bytes.length, 4);
    expect(calls, 2);
  });

  test('同 key in-flight 复用；pending 上限 4（第 5 个排队）', () async {
    final cache = WorkspaceImageCache(maxPending: 4);
    final gates = <Completer<Uint8List>>[];
    final futures = <Future<Uint8List>>[];
    for (var i = 0; i < 5; i++) {
      final gate = Completer<Uint8List>();
      gates.add(gate);
      futures.add(cache.load('k$i', () => gate.future));
    }
    expect(cache.loading, 4);
    // 第 5 个排队；完成一个后开始。
    gates[0].complete(_bytes(1));
    await futures[0];
    await Future<void>.delayed(Duration.zero);
    expect(cache.loading, 4);
    for (var i = 1; i < 5; i++) {
      gates[i].complete(_bytes(1));
    }
    await Future.wait(futures);
    expect(cache.load('k0', () async => _bytes(1)), completes);
  });

  test('clear/dispose：迟到响应不回填；旧代结果不被缓存', () async {
    final cache = WorkspaceImageCache();
    final gate = Completer<Uint8List>();
    final future = cache.load('late', () => gate.future);
    cache.clear();
    gate.complete(_bytes(3));
    await expectLater(future, throwsA(isA<StateError>()));
    expect(cache.get('late'), isNull);
  });

  test('会话隔离：不同 key（session|path）互不串图', () async {
    final cache = WorkspaceImageCache();
    await cache.load('s1|pics/a.png', () async => _bytes(2));
    await cache.load('s2|pics/a.png', () async => _bytes(3));
    expect(cache.get('s1|pics/a.png')!.length, 2);
    expect(cache.get('s2|pics/a.png')!.length, 3);
  });

  test('review P1：12 key + gate + clear → 排队不再启动 fetch、loading≤4、无回填', () async {
    final cache = WorkspaceImageCache(maxPending: 4);
    final gate = Completer<Uint8List>();
    var started = 0;
    final futures = <Future<Uint8List>>[];
    for (var i = 0; i < 12; i++) {
      futures.add(cache.load('k$i', () {
        started += 1;
        return gate.future;
      }).catchError((Object _) => _bytes(0)));
    }
    await Future<void>.delayed(Duration.zero);
    expect(started, 4);
    expect(cache.loading, 4);

    cache.clear();
    await Future<void>.delayed(Duration.zero);
    expect(started, 4, reason: 'clear 后排队 waiter 不得启动/fetch');
    expect(cache.loading, lessThanOrEqualTo(4));

    gate.complete(_bytes(2));
    await Future.wait(futures);
    expect(started, 4, reason: '旧代完成不得启动新请求');
    expect(cache.loading, 0);
    expect(cache.length, 0, reason: '旧代结果不回填');
  });

  test('review P1：旧完成不回填/不误删 clear 后的新 in-flight', () async {
    final cache = WorkspaceImageCache();
    final oldGate = Completer<Uint8List>();
    final oldFuture = cache.load('a', () => oldGate.future);
    cache.clear();

    final newGate = Completer<Uint8List>();
    var newFetch = 0;
    final newFuture = cache.load('a', () {
      newFetch += 1;
      return newGate.future;
    });
    // 旧请求迟到完成：抛 stale、不可回填，更不能从 map 删除新请求。
    oldGate.complete(_bytes(9));
    await expectLater(oldFuture, throwsA(isA<StateError>()));
    expect(cache.get('a'), isNull);

    // 新请求仍在 in-flight：同 key 的第三次 load 必须复用，不重复 fetch。
    await Future<void>.delayed(Duration.zero);
    expect(newFetch, 1, reason: 'clear 后的新请求应正常启动');
    var thirdFetch = 0;
    final third = cache.load('a', () {
      thirdFetch += 1;
      return Future.value(_bytes(1));
    });
    expect(thirdFetch, 0);
    newGate.complete(_bytes(3));
    expect((await newFuture).length, 3);
    expect((await third).length, 3);
    expect(cache.get('a')!.length, 3);
  });

  test('review P1：槽位直接交接（不先减后唤醒），连续 load/clear 收敛', () async {
    final cache = WorkspaceImageCache(maxPending: 2);
    final gates = <Completer<Uint8List>>[];
    final pending = <Future<Uint8List>>[];
    var started = 0;
    for (var i = 0; i < 4; i++) {
      final gate = Completer<Uint8List>();
      gates.add(gate);
      pending.add(cache.load('x$i', () {
        started += 1;
        return gate.future;
      }));
    }
    await Future<void>.delayed(Duration.zero);
    expect(started, 2);
    expect(cache.loading, 2);
    gates[0].complete(_bytes(1));
    await Future<void>.delayed(Duration.zero);
    expect(started, 3, reason: '空槽直接交给 waiter，无抖动');
    expect(cache.loading, 2, reason: '交接期间 loading 不降到 1');
    gates[1].complete(_bytes(1));
    gates[2].complete(_bytes(1));
    gates[3].complete(_bytes(1));
    await Future.wait(pending);
    await Future<void>.delayed(Duration.zero);
    expect(cache.loading, 0);

    // 连续 load/clear：每次先 clear 再放行，必须全部 stale 且不累积缓存/槽位。
    for (var i = 0; i < 5; i++) {
      final gate = Completer<Uint8List>();
      final future = cache.load('loop$i', () => gate.future);
      cache.clear();
      gate.complete(_bytes(1));
      await expectLater(future, throwsA(isA<StateError>()));
      expect(cache.loading, lessThanOrEqualTo(2));
      expect(cache.length, 0);
    }
    expect(cache.loading, 0);
  });

}
