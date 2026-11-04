import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/download.dart';
import 'package:dsh_mobile_app/resumable_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Api backend([String token = 'private-test-token']) => Api()
  ..baseUrl = 'http://host.test'
  ..path = '/m'
  ..token = token;

http.StreamedResponse response(
  String body, {
  int status = 200,
  String? range,
  String? etag = '"original"',
  int? length,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  status,
  contentLength: length ?? body.length,
  headers: {
    'content-range': ?range,
    'etag': ?etag,
    'content-type': 'text/plain',
  },
);

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('dsh-resume-'),
  );
  tearDown(() async => root.delete(recursive: true));

  Future<void> interrupt(
    ResumableDownloads downloads, {
    String? etag = '"original"',
  }) async {
    final client = MockClient.streaming(
      (request, _) async => http.StreamedResponse(
        Stream<List<int>>.multi((sink) {
          sink.add(utf8.encode('abc'));
          sink.addError(http.ClientException('network lost'));
          sink.close();
        }),
        200,
        contentLength: 6,
        headers: {'etag': ?etag},
      ),
    );
    await expectLater(
      downloads.download('/work/file.txt', downloadClient: client),
      throwsA(isA<http.ClientException>()),
    );
  }

  test('new store resumes persisted bytes with Range and If-Range', () async {
    final api = backend();
    await interrupt(ResumableDownloads(root, api));
    final restored = ResumableDownloads(root, api);
    expect((await restored.pending()).single.bytes, 3);
    final client = MockClient.streaming((request, _) async {
      expect(request.headers['range'], 'bytes=3-');
      expect(request.headers['if-range'], '"original"');
      expect(request.headers['accept-encoding'], 'identity');
      return response('def', status: 206, range: 'bytes 3-5/6');
    });
    final result = await restored.download(
      '/work/file.txt',
      downloadClient: client,
    );
    expect(await result.file.readAsString(), 'abcdef');
    expect(result.bytes, 6);
    // 保存到 Downloads 失败后，完整私有文件可直接再次保存，不必重下。
    final saved = await ResumableDownloads(root, api).download(
      '/work/file.txt',
      downloadClient: MockClient.streaming(
        (_, _) async => throw StateError('unexpected request'),
      ),
    );
    expect(await saved.file.readAsString(), 'abcdef');
    await restored.discard('/work/file.txt');
    expect(await restored.pending(), isEmpty);
  });

  test('changed file with a full 200 replaces the old prefix', () async {
    final store = ResumableDownloads(root, backend());
    await interrupt(store);
    final result = await store.download(
      '/work/file.txt',
      downloadClient: MockClient.streaming(
        (_, _) async => response('UVWXYZ', etag: '"new"'),
      ),
    );
    expect(await result.file.readAsString(), 'UVWXYZ');
  });

  test(
    'old host returning 206 with a different ETag triggers a clean restart',
    () async {
      final store = ResumableDownloads(root, backend());
      await interrupt(store);
      var calls = 0;
      final result = await store.download(
        '/work/file.txt',
        downloadClient: MockClient.streaming((request, _) async {
          calls++;
          if (calls == 1) {
            return response(
              'XYZ',
              status: 206,
              range: 'bytes 3-5/6',
              etag: '"new"',
            );
          }
          expect(request.headers['range'], isNull);
          return response('UVWXYZ', etag: '"new"');
        }),
      );
      expect(calls, 2);
      expect(await result.file.readAsString(), 'UVWXYZ');
    },
  );

  test(
    'missing ETag restarts rather than combining unverified bytes',
    () async {
      final store = ResumableDownloads(root, backend());
      await interrupt(store, etag: null);
      final result = await store.download(
        '/work/file.txt',
        downloadClient: MockClient.streaming((request, _) async {
          expect(request.headers['range'], isNull);
          return response('abcdef', etag: null);
        }),
      );
      expect(await result.file.readAsString(), 'abcdef');
    },
  );

  test(
    'authenticated hosts are isolated and credentials are not persisted',
    () async {
      final api = backend();
      await interrupt(ResumableDownloads(root, api));
      expect(
        await ResumableDownloads(root, backend('other-token')).pending(),
        isEmpty,
      );
      final otherHost = backend()..baseUrl = 'http://other.test';
      expect(await ResumableDownloads(root, otherHost).pending(), isEmpty);
      await for (final entry in root.list(recursive: true)) {
        expect(entry.path, isNot(contains(api.token)));
        if (entry is File && entry.path.endsWith('.json')) {
          final text = await entry.readAsString();
          expect(text, isNot(contains(api.token)));
          expect(text, isNot(contains(api.baseUrl)));
        }
      }
    },
  );

  test('pause keeps committed bytes and offers them to a new store', () async {
    final cancel = DownloadCancelToken();
    final store = ResumableDownloads(root, backend());
    await expectLater(
      store.download(
        '/work/file.txt',
        cancel: cancel,
        downloadClient: MockClient.streaming(
          (_, _) async => response('abc', length: 6),
        ),
        onProgress: (p) {
          if (p.received == 3) cancel.cancel();
        },
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(
      (await ResumableDownloads(root, backend()).pending()).single.bytes,
      3,
    );
  });

  test(
    'short resumed response is rejected instead of saved as complete',
    () async {
      final target = File('${root.path}/partial')..writeAsStringSync('abc');
      await expectLater(
        backend().downloadFileToFile(
          '/work/file.txt',
          target,
          startOffset: 3,
          downloadClient: MockClient.streaming(
            (_, _) async =>
                response('d', status: 206, range: 'bytes 3-5/6', length: 3),
          ),
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('invalid range boundaries cannot append to the partial file', () async {
    final target = File('${root.path}/partial')..writeAsStringSync('abc');
    await expectLater(
      backend().downloadFileToFile(
        '/work/file.txt',
        target,
        startOffset: 3,
        downloadClient: MockClient.streaming(
          (_, _) async => response('def', status: 206, range: 'bytes 3-5/7'),
        ),
      ),
      throwsA(isA<ApiException>()),
    );
    expect(await target.readAsString(), 'abc');
  });

  test('local offset mismatch fails before sending a request', () async {
    final target = File('${root.path}/partial')..writeAsStringSync('ab');
    await expectLater(
      backend().downloadFileToFile(
        '/work/file.txt',
        target,
        startOffset: 3,
        downloadClient: MockClient.streaming(
          (_, _) async => throw StateError('unexpected request'),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('pause interrupts a request stalled before response headers', () async {
    final cancel = DownloadCancelToken();
    final requested = Completer<void>();
    final result = ResumableDownloads(root, backend()).download(
      '/work/file.txt',
      cancel: cancel,
      downloadClient: MockClient.streaming((_, _) {
        requested.complete();
        return Completer<http.StreamedResponse>().future;
      }),
    );
    final assertion = expectLater(result, throwsA(isA<DownloadCancelled>()));
    await requested.future;
    cancel.cancel();
    await assertion;
    expect(
      (await ResumableDownloads(root, backend()).pending()).single.bytes,
      0,
    );
  });

  test(
    'real HTTP disconnect resumes persisted bytes after reopening the store',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final sockets = <Socket>[];
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final firstBytesRead = Completer<void>();
      var calls = 0;
      server.listen((socket) {
        sockets.add(socket);
        var headers = '';
        var handled = false;
        socket.listen((data) async {
          headers += utf8.decode(data);
          if (handled || !headers.contains('\r\n\r\n')) return;
          handled = true;
          calls++;
          expect(
            headers.toLowerCase(),
            contains('x-mobile-token: private-test-token'),
          );
          if (calls == 1) {
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nETag: "original"\r\nConnection: close\r\n\r\nabc',
              ),
            );
            await socket.flush();
            await firstBytesRead.future;
            socket.destroy();
          } else {
            expect(headers.toLowerCase(), contains('range: bytes=3-'));
            expect(headers.toLowerCase(), contains('if-range: "original"'));
            socket.add(
              utf8.encode(
                'HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 3-5/6\r\nETag: "original"\r\nConnection: close\r\n\r\ndef',
              ),
            );
            await socket.flush();
            await socket.close();
          }
        });
      });
      final api = backend()..baseUrl = 'http://127.0.0.1:${server.port}';
      await expectLater(
        ResumableDownloads(root, api).download(
          '/work/file.txt',
          onProgress: (p) {
            if (p.received == 3 && !firstBytesRead.isCompleted) {
              firstBytesRead.complete();
            }
          },
        ),
        throwsA(isA<http.ClientException>()),
      );
      final restored = ResumableDownloads(root, api);
      expect((await restored.pending()).single.bytes, 3);
      final result = await restored.download('/work/file.txt');
      expect(await result.file.readAsString(), 'abcdef');
      expect(calls, 2);
    },
  );

  test('silent body times out and keeps its existing bytes', () async {
    final stream = StreamController<List<int>>();
    addTearDown(stream.close);
    final result = ResumableDownloads(root, backend()).download(
      '/work/file.txt',
      idleTimeout: const Duration(milliseconds: 20),
      downloadClient: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          stream.stream,
          200,
          contentLength: 6,
          headers: {'etag': '"original"'},
        ),
      ),
      onProgress: (p) {
        if (p.received == 0) stream.add(utf8.encode('abc'));
      },
    );
    await expectLater(result, throwsA(isA<TimeoutException>()));
    expect(
      (await ResumableDownloads(root, backend()).pending()).single.bytes,
      3,
    );
  });
}
