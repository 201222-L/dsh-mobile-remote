import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/models.dart';

void main() {
  test('用量快照解析来源、Codex 账户与独立额度', () {
    final snapshot = UsageSnapshot.fromJson({
      'fetchedAt': '2030-01-01T00:00:00Z',
      'availableCount': 2,
      'failedCount': 1,
      'sources': [
        {
          'id': 'deepseek',
          'title': 'DeepSeek',
          'kind': 'balance',
          'amount': '12.50',
          'currency': 'CNY',
        },
        {
          'id': 'codex',
          'title': 'Codex',
          'kind': 'quota',
          'account': {
            'displayName': 'Personal',
            'maskedEmail': 'p***@example.com',
          },
          'windows': [
            {
              'window': '5h',
              'remainingPercent': 72,
              'resetAt': '2030-01-01T01:00:00Z',
            },
            {'window': 'weekly', 'remainingPercent': 64, 'limited': true},
          ],
          'credits': {'unlimited': false, 'balance': '8.00'},
          'individualLimit': {
            'limit': '100',
            'used': '28',
            'remaining': '72',
            'remainingPercent': 72,
          },
        },
      ],
    });

    expect(snapshot.sources.length, 2);
    expect(snapshot.failedCount, 1);
    expect(snapshot.sourceOf('deepseek')?.amountNumber, 12.5);
    expect(
      snapshot.sourceOf('codex')?.account?.maskedEmail,
      'p***@example.com',
    );
    expect(snapshot.sourceOf('codex')?.windows.first.remainingPercent, 72);
    expect(snapshot.sourceOf('codex')?.windows[1].limited, isTrue);
    expect(snapshot.sourceOf('codex')?.credits?.balance, '8.00');
    expect(snapshot.sourceOf('codex')?.individualLimit?.remaining, '72');
  });

  test('缺少来源时保留空状态而不抛异常', () {
    final snapshot = UsageSnapshot.fromJson({'sources': [], 'failedCount': 0});
    expect(snapshot.sources, isEmpty);
    expect(snapshot.sourceOf('opencode-go'), isNull);
  });

  test('前向不兼容的字段类型按空值降级', () {
    final snapshot = UsageSnapshot.fromJson({
      'sources': 'unexpected',
      'failedCount': 'bad',
    });
    expect(snapshot.sources, isEmpty);
    expect(snapshot.failedCount, 0);
    final source = UsageSource.fromJson({
      'id': 42,
      'windows': {'bad': true},
      'account': 'bad',
      'credits': {'unlimited': false},
    });
    expect(source.id, '42');
    expect(source.windows, isEmpty);
    expect(source.account, isNull);
    expect(source.credits?.unlimited, isFalse);
  });
}
