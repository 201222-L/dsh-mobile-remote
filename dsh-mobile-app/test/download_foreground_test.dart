import 'package:dsh_mobile_app/download.dart';
import 'package:dsh_mobile_app/download_foreground.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/download-test');
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'start' ? {'running': true} : null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });
  Future<void> pause(Object? arguments) async {
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('paused', arguments)),
      (_) {},
    );
  }

  test(
    'actual native state enables protection; finish always removes it once',
    () async {
      final guard = DownloadForeground(channel: channel, enabled: true);
      final lease = await guard.start(DownloadCancelToken());
      expect(lease.backgroundActive, isTrue);
      lease.progress(const DownloadProgress(received: 2, total: 10));
      lease.progress(const DownloadProgress(received: 3, total: 10));
      lease.progress(const DownloadProgress(received: 10, total: 10));
      await lease.close();
      await lease.close();
      expect(calls.map((c) => c.method), [
        'start',
        'progress',
        'progress',
        'finish',
      ]);
      expect(lease.backgroundActive, isFalse);
    },
  );

  test(
    'system time limit cancels the matching transfer and retains its reason',
    () async {
      final cancel = DownloadCancelToken();
      final lease = await DownloadForeground(
        channel: channel,
        enabled: true,
      ).start(cancel);
      final id = (calls.first.arguments as Map)['id'];
      await pause({'id': 'another-transfer', 'reason': 'system-time-limit'});
      expect(cancel.cancelled, isFalse);
      await pause({'id': id, 'reason': 'system-time-limit'});
      expect(cancel.cancelled, isTrue);
      expect(lease.pauseReason, 'system-time-limit');
      expect(lease.backgroundActive, isFalse);
      await lease.close();
      await pause({}); // A late event after cleanup is harmless.
    },
  );

  test(
    'native notification pause cancels without discarding the checkpoint',
    () async {
      final cancel = DownloadCancelToken();
      final lease = await DownloadForeground(
        channel: channel,
        enabled: true,
      ).start(cancel);
      await pause({
        'id': (calls.first.arguments as Map)['id'],
        'reason': 'user',
      });
      expect(cancel.cancelled, isTrue);
      expect(lease.pauseReason, 'user');
      await lease.close();
    },
  );

  test(
    'unavailable service reports foreground fallback instead of fake success',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'start'
            ? {'running': false, 'reason': 'notification-disabled'}
            : null,
      );
      final lease = await DownloadForeground(
        channel: channel,
        enabled: true,
      ).start(DownloadCancelToken());
      expect(lease.backgroundActive, isFalse);
      expect(lease.unavailableReason, 'notification-disabled');
      await lease.close();
    },
  );

  test('native startup failure retains a usable foreground transfer', () async {
    final cancel = DownloadCancelToken();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        await pause({
          'id': (call.arguments as Map)['id'],
          'reason': 'service-unavailable',
        });
        return {'running': false, 'reason': 'service-unavailable'};
      }
      return null;
    });
    final lease = await DownloadForeground(
      channel: channel,
      enabled: true,
    ).start(cancel);
    expect(cancel.cancelled, isFalse);
    expect(lease.backgroundActive, isFalse);
    expect(lease.unavailableReason, 'service-unavailable');
    await lease.close();
  });

  test(
    'a second transfer is refused until the first releases its service',
    () async {
      final guard = DownloadForeground(channel: channel, enabled: true);
      final first = await guard.start(DownloadCancelToken());
      await expectLater(
        guard.start(DownloadCancelToken()),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'download-in-progress',
          ),
        ),
      );
      await first.close();
      final next = await guard.start(DownloadCancelToken());
      final nextCancel = DownloadCancelToken();
      await next.close();
      final last = await guard.start(nextCancel);
      await pause({
        'id': (calls.first.arguments as Map)['id'],
        'reason': 'user',
      });
      expect(nextCancel.cancelled, isFalse);
      await last.close();
    },
  );

  test(
    'non-Android downloads use the existing foreground path without a service',
    () async {
      final lease = await DownloadForeground(
        channel: channel,
        enabled: false,
      ).start(DownloadCancelToken());
      expect(lease.backgroundActive, isFalse);
      await lease.close();
      expect(calls, isEmpty);
    },
  );
}
