import 'dart:convert';

import 'package:dsh_mobile_app/attention.dart';
import 'package:dsh_mobile_app/attention_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AttentionEvent event(String source, String identity) => AttentionEvent(
  kind: AttentionKind.approval,
  sessionId: 'session',
  identity: identity,
  source: source,
  at: DateTime(2026, 11, 3),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('restart restores identity and snapshot removes only settled notifications from that host', () async {
    final first = AttentionLedger();
    final waiting = event('host-a', 'pending');
    final done = event('host-a', 'settled');
    final other = event('host-b', 'settled');
    for (final e in [waiting, done, other]) {
      first.reserve(e);
    }
    await AttentionStorage().save(first);
    final restored = AttentionLedger();
    await AttentionStorage().restore(restored);
    expect(restored.reconcile('host-a', {waiting.key}), [done.notificationId]);
    expect(restored.byKey(waiting.key)!.status, AttentionStatus.active);
    expect(restored.byKey(other.key)!.status, AttentionStatus.active);
    expect(
      restored.resolveByIdentity('settled', source: 'host-b'),
      other.notificationId,
    );
    expect(restored.reconcile('host-a', {waiting.key}), isEmpty);
    await AttentionStorage().save(restored);
    final restarted = AttentionLedger();
    await AttentionStorage().restore(restarted);
    expect(restarted.byKey(done.key)!.status, AttentionStatus.resolved);
  });

  test('duplicate replay cannot create another alert, foreground denial uses banner fallback', () {
    final original = event('host', 'a');
    final replay = AttentionEvent(
      kind: original.kind,
      source: original.source,
      sessionId: original.sessionId,
      identity: original.identity,
      at: original.at,
      isReplay: true,
    );
    final snapshot = const AttentionSnapshot(
      phase: AppPhase.foreground,
      permissionGranted: false,
      channelEnabled: false,
    );
    expect(decideAttention(replay, snapshot, seenRecently: true).any, isFalse);
    final fallback = decideAttention(original, snapshot, seenRecently: false);
    expect(fallback.system, isFalse);
    expect(fallback.banner, isTrue);
  });

  test('resolved cannot be resurrected by an asynchronous show result', () {
    final ledger = AttentionLedger();
    final e = event('host', 'a');
    ledger.reserve(e);
    ledger.resolveByIdentity('a', source: 'host');
    ledger.mark(e.key, AttentionStatus.active);
    expect(ledger.byKey(e.key)!.status, AttentionStatus.resolved);
  });

  test(
    'malformed persisted entries cannot target the foreground-service ID',
    () async {
      SharedPreferences.setMockInitialValues({
        AttentionStorage.preferenceKey: jsonEncode({
          'version': 1,
          'entries': [
            {
              'key': 'approval|s|a',
              'kind': 'approval',
              'sessionId': 's',
              'id': 0xDBB,
            },
            {'key': 'bad', 'kind': 3, 'id': 9000},
          ],
        }),
      });
      final ledger = AttentionLedger();
      await AttentionStorage().restore(ledger);
      expect(ledger.entries, isEmpty);
    },
  );
}
