// M1a 纯逻辑单测：身份 / id / 判据 / ledger 状态机。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/attention.dart';

AttentionEvent _approval({
  String sessionId = 's1',
  String approvalId = 'a1',
  DateTime? at,
  bool isReplay = false,
}) => AttentionEvent(
  kind: AttentionKind.approval,
  sessionId: sessionId,
  identity: approvalId,
  at: at ?? DateTime(2026, 10, 29, 10),
  toolName: 'ops_bash',
  summary: '需要执行命令',
  isReplay: isReplay,
);

AttentionSnapshot _snap({
  AppPhase phase = AppPhase.foreground,
  String? visible,
  bool permission = true,
  bool channel = true,
  bool quiet = false,
}) => AttentionSnapshot(
  phase: phase,
  permissionGranted: permission,
  channelEnabled: channel,
  visibleSession: visible,
  quietHours: quiet,
);

void main() {
  group('身份 key', () {
    test('approval 与 question 的同一 identity 不会互相覆盖', () {
      final a = attentionKey(
        kind: AttentionKind.approval.wire,
        sessionId: 's1',
        identity: 'x',
      );
      final q = attentionKey(
        kind: AttentionKind.question.wire,
        sessionId: 's1',
        identity: 'x',
      );
      expect(a, isNot(q));
    });

    test('key 由 kind|sessionId|identity 组成', () {
      final e = _approval(sessionId: 's9', approvalId: 'a9');
      expect(e.key, 'approval|s9|a9');
    });

    test('sessionId 里含竖线也不会歧义（identity 在末尾）', () {
      final e = _approval(sessionId: 'a|b', approvalId: 'c');
      expect(e.key, 'approval|a|b|c');
      expect(e.key.endsWith('|c'), isTrue);
    });

    test('中文与 emoji 的 key 稳定', () {
      final k1 = attentionKey(
        kind: 'approval',
        sessionId: '会话🎯',
        identity: '调用1',
      );
      final k2 = attentionKey(
        kind: 'approval',
        sessionId: '会话🎯',
        identity: '调用1',
      );
      expect(k1, k2);
    });
  });

  group('通知 id', () {
    test('同一 key 永远得到同一 id', () {
      expect(stableNotificationId('approval|s1|a1'),
          stableNotificationId('approval|s1|a1'));
    });

    test('不同 key 得到不同 id（抽样 500 个）', () {
      final ids = <int>{};
      for (var i = 0; i < 500; i++) {
        ids.add(stableNotificationId('approval|s$i|a$i'));
      }
      expect(ids.length, 500);
    });

    test('id 落在业务号段内', () {
      for (var i = 0; i < 200; i++) {
        final id = stableNotificationId('approval|s|a$i');
        expect(AttentionLedger.isValidNotificationId(id), isTrue, reason: 'id=$id');
      }
    });

    test('id 永远不会等于保活/宠物保留的 0xDBB', () {
      for (var i = 0; i < 2000; i++) {
        final id = stableNotificationId('approval|s|a$i');
        expect(id, isNot(0xDBB));
      }
    });

    test('id 不超过 int32 正区间', () {
      for (var i = 0; i < 200; i++) {
        expect(stableNotificationId('k$i'), lessThan(0x40000000));
      }
    });

    test('FNV-1a 对非 ASCII 也区分', () {
      expect(fnv1a32('abc'), isNot(fnv1a32('abd')));
      expect(fnv1a32('会话一'), isNot(fnv1a32('会话二')));
    });
  });

  group('判据矩阵', () {
    test('前台 + 正看该会话 → 只横幅', () {
      final d = decideAttention(
        _approval(),
        _snap(phase: AppPhase.foreground, visible: 's1'),
        seenRecently: false,
      );
      expect(d.system, isFalse);
      expect(d.banner, isTrue);
      expect(d.reason, 'viewing-session');
    });

    test('前台 + 别的会话 → 系统通知 + 横幅', () {
      final d = decideAttention(
        _approval(),
        _snap(phase: AppPhase.foreground, visible: 'other'),
        seenRecently: false,
      );
      expect(d.system, isTrue);
      expect(d.banner, isTrue);
    });

    test('前台 + 不在任何会话 → 系统通知 + 横幅', () {
      final d = decideAttention(
        _approval(),
        _snap(phase: AppPhase.foreground),
        seenRecently: false,
      );
      expect(d.system, isTrue);
      expect(d.banner, isTrue);
    });

    test('inactive（分屏/弹窗）→ 系统通知 + 横幅', () {
      final d = decideAttention(
        _approval(),
        _snap(phase: AppPhase.inactive),
        seenRecently: false,
      );
      expect(d.system, isTrue);
      expect(d.banner, isTrue);
    });

    test('后台 → 只系统通知', () {
      final d = decideAttention(
        _approval(),
        _snap(phase: AppPhase.background),
        seenRecently: false,
      );
      expect(d.system, isTrue);
      expect(d.banner, isFalse);
    });

    test('无通知权限 → 不发系统通知，但保留横幅', () {
      final d = decideAttention(
        _approval(),
        _snap(phase: AppPhase.background, permission: false),
        seenRecently: false,
      );
      expect(d.system, isFalse);
      expect(d.banner, isTrue);
      expect(d.reason, 'no-permission');
    });

    test('渠道被单独静音 → 同样不发系统通知', () {
      final d = decideAttention(
        _approval(),
        _snap(channel: false),
        seenRecently: false,
      );
      expect(d.system, isFalse);
    });

    test('安静时段 → 两条通道都不发（预留）', () {
      final d = decideAttention(
        _approval(),
        _snap(quiet: true),
        seenRecently: false,
      );
      expect(d.any, isFalse);
      expect(d.reason, 'quiet-hours');
    });

    test('去重命中 → 两条通道都不发', () {
      final d = decideAttention(
        _approval(),
        _snap(),
        seenRecently: true,
      );
      expect(d.any, isFalse);
      expect(d.reason, 'dedupe');
    });

    test('回放帧即使去重命中也应该被吞（不重复提醒）', () {
      final d = decideAttention(
        _approval(isReplay: true),
        _snap(phase: AppPhase.background),
        seenRecently: false,
      );
      expect(d.system, isTrue);
    });

    test('正在看会话优先于无权限：仍只横幅', () {
      final d = decideAttention(
        _approval(),
        _snap(visible: 's1', permission: false),
        seenRecently: false,
      );
      expect(d.system, isFalse);
      expect(d.banner, isTrue);
      expect(d.reason, 'viewing-session');
    });
  });

  group('AttentionLedger', () {
    test('首次占位成功，第二次被去重', () {
      final ledger = AttentionLedger();
      final e = _approval();
      expect(ledger.reserve(e), isTrue);
      expect(ledger.reserve(e), isFalse);
    });

    test('同批两帧不同会话都能占位', () {
      final ledger = AttentionLedger();
      expect(ledger.reserve(_approval(sessionId: 's1', approvalId: 'a1')), isTrue);
      expect(ledger.reserve(_approval(sessionId: 's2', approvalId: 'a2')), isTrue);
      expect(ledger.activeEntries.length, 2);
    });

    test('超过窗口后可再次提醒', () {
      final ledger = AttentionLedger();
      final at = DateTime(2026, 10, 29, 10);
      final e = _approval(at: at);
      expect(ledger.reserve(e), isTrue);
      final later = _approval(at: at.add(const Duration(minutes: 6)));
      expect(ledger.reserve(later), isTrue);
    });

    test('resolved 后不再算作去重命中', () {
      final ledger = AttentionLedger();
      final e = _approval();
      ledger.reserve(e);
      ledger.mark(e.key, AttentionStatus.resolved);
      expect(
        ledger.seenRecently(e.key, now: e.at),
        isFalse,
      );
    });

    test('按 identity 撤销返回 id', () {
      final ledger = AttentionLedger();
      final e = _approval(approvalId: 'call_123');
      ledger.reserve(e);
      final id = ledger.resolveByIdentity('call_123');
      expect(id, e.notificationId);
      expect(ledger.byKey(e.key)!.status, AttentionStatus.resolved);
    });

    test('撤销不存在的 identity 返回 null 且不抛', () {
      final ledger = AttentionLedger();
      expect(ledger.resolveByIdentity('nope'), isNull);
    });

    test('撤销只影响匹配的那一条', () {
      final ledger = AttentionLedger();
      final a = _approval(sessionId: 's1', approvalId: 'a1');
      final b = _approval(sessionId: 's1', approvalId: 'a2');
      ledger.reserve(a);
      ledger.reserve(b);
      ledger.resolveByIdentity('a1');
      expect(ledger.byKey(a.key)!.status, AttentionStatus.resolved);
      expect(ledger.byKey(b.key)!.status, AttentionStatus.active);
    });

    test('blocked 与 dismissed 是不同状态', () {
      final ledger = AttentionLedger();
      final e = _approval();
      ledger.reserve(e);
      ledger.mark(e.key, AttentionStatus.blocked);
      expect(ledger.byKey(e.key)!.status, isNot(AttentionStatus.dismissed));
    });

    test('按 id 能反查回条目', () {
      final ledger = AttentionLedger();
      final e = _approval();
      ledger.reserve(e);
      expect(ledger.byId(e.notificationId)!.key, e.key);
    });

    test('forget 之后按 id 查不到', () {
      final ledger = AttentionLedger();
      final e = _approval();
      ledger.reserve(e);
      ledger.forget(e.key);
      expect(ledger.byId(e.notificationId), isNull);
      expect(ledger.byKey(e.key), isNull);
    });

    test('序列化往返保持状态', () {
      final ledger = AttentionLedger();
      final e = _approval();
      ledger.reserve(e);
      ledger.mark(e.key, AttentionStatus.dismissed);
      final rows = ledger.toJson();

      final restored = AttentionLedger()..restore(rows);
      expect(restored.byKey(e.key)!.status, AttentionStatus.dismissed);
      expect(restored.byKey(e.key)!.id, e.notificationId);
    });

    test('容量上限会淘汰最旧的已结算条目，保留 active', () {
      final ledger = AttentionLedger(capacity: 3);
      final base = DateTime(2026, 10, 29, 10);
      for (var i = 0; i < 3; i++) {
        final e = _approval(approvalId: 'old$i', at: base.add(Duration(minutes: i)));
        ledger.reserve(e);
        ledger.mark(e.key, AttentionStatus.resolved);
      }
      final keep = _approval(approvalId: 'keep', at: base.add(const Duration(minutes: 9)));
      ledger.reserve(keep);
      expect(ledger.byKey(keep.key), isNotNull);
      expect(ledger.entries.length, lessThanOrEqualTo(3));
      expect(ledger.activeEntries.length, 1);
    });

    test('回放到旧事件不会把新条目挤掉（时间回拨）', () {
      final ledger = AttentionLedger(capacity: 2);
      final base = DateTime(2026, 10, 29, 10);
      final newer = _approval(approvalId: 'new', at: base.add(const Duration(minutes: 5)));
      ledger.reserve(newer);
      final older = _approval(
        approvalId: 'old',
        at: base,
        isReplay: true,
      );
      ledger.reserve(older);
      expect(ledger.byKey(newer.key), isNotNull);
    });
  });
}
