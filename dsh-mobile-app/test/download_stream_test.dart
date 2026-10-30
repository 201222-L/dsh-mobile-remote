import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Api _api() => Api()
  ..baseUrl = 'http://127.0.0.1:3080'
  ..path = '/m';

void main() {
  test('downloadFileToFile streams bytes and reports progress', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-dl-test-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/a.txt');
    final progress = <DownloadProgress>[];
    final client = MockClient.streaming((request, bodyStream) async {
      expect(request.headers['range'], isNull);
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode('abc'),
          utf8.encode('def'),
        ]),
        200,
        contentLength: 6,
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    });

    final result = await _api().downloadFileToFile(
      'a.txt',
      target,
      downloadClient: client,
      onProgress: progress.add,
    );

    expect(await target.readAsString(), 'abcdef');
    expect(result.bytes, 6);
    expect(result.contentType, 'text/plain; charset=utf-8');
    expect(progress, isNotEmpty);
    expect(progress.last.received, 6);
    expect(progress.last.total, 6);
  });

  test('downloadFileToFile surfaces server error detail', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-dl-test-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/a.txt');
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"detail":"no such file"}')),
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    await expectLater(
      _api().downloadFileToFile('a.txt', target, downloadClient: client),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.message, 'message', 'no such file'),
      ),
    );
  });

  test('cancel token aborts and deletes the partial file', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-dl-test-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/a.txt');
    final cancel = DownloadCancelToken();
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode('a'),
          utf8.encode('b'),
        ]),
        200,
        contentLength: 2,
      );
    });

    await expectLater(
      _api().downloadFileToFile(
        'a.txt',
        target,
        downloadClient: client,
        cancel: cancel,
        onProgress: (p) {
          if (p.received > 0) cancel.cancel();
        },
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(target.existsSync(), isFalse);
  });

  test('startOffset sends Range and appends 206 bytes', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-dl-test-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/a.txt');
    await target.writeAsString('abc');
    final client = MockClient.streaming((request, bodyStream) async {
      expect(request.headers['range'], 'bytes=3-');
      return http.StreamedResponse(
        Stream.value(utf8.encode('def')),
        206,
        contentLength: 3,
        headers: {'content-range': 'bytes 3-5/6'},
      );
    });

    final result = await _api().downloadFileToFile(
      'a.txt',
      target,
      downloadClient: client,
      startOffset: 3,
    );

    expect(await target.readAsString(), 'abcdef');
    expect(result.bytes, 6);
  });

  test('downloadFilePrefix caps a full 200 response and reports total', () async {
    final client = MockClient.streaming((request, bodyStream) async {
      expect(request.headers['range'], isNull);
      return http.StreamedResponse(
        Stream.value(utf8.encode('abcdef')),
        200,
        contentLength: 6,
      );
    });

    final prefix = await _api().downloadFilePrefix(
      'a.txt',
      4,
      downloadClient: client,
    );

    expect(utf8.decode(prefix.bytes), 'abcd');
    expect(prefix.total, 6);
    expect(prefix.truncated, isTrue);
  });

  test('downloadFilePrefix uses Range and parses total from 206', () async {
    final api = _api()..fileRangeSupported = true;
    final client = MockClient.streaming((request, bodyStream) async {
      expect(request.headers['range'], 'bytes=0-3');
      return http.StreamedResponse(
        Stream.value(utf8.encode('abcd')),
        206,
        contentLength: 4,
        headers: {'content-range': 'bytes 0-3/6'},
      );
    });

    final prefix = await api.downloadFilePrefix(
      'a.txt',
      4,
      downloadClient: client,
    );

    expect(utf8.decode(prefix.bytes), 'abcd');
    expect(prefix.total, 6);
    expect(prefix.truncated, isTrue);
  });
}
