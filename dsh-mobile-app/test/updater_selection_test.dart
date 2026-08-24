// M2 双源判定纯函数单测：本地记录核对 / 账本冲突 / 胜出选择。
import 'package:dsh_mobile_app/update/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDualSourceSelection（M2 四源自动模式判定）', () {
    test('双源同 sequence 但 digest 不同 → 账本冲突（不优先任一源）', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'pc', sequence: 9, digest: 'd1'),
              (source: 'github', sequence: 9, digest: 'd2'),
            ],
            storedSequence: 5,
            storedDigest: 'old',
          ),
          'conflict');
    });
    test('双源同 sequence 同 digest → 允许；平局优先电脑源', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'pc', sequence: 9, digest: 'd1'),
              (source: 'github', sequence: 9, digest: 'd1'),
            ],
            storedSequence: 5,
            storedDigest: 'old',
          ),
          'pc');
    });
    test('双源异 sequence → 取更高者（不关心来源）', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'pc', sequence: 8, digest: 'd8'),
              (source: 'github', sequence: 9, digest: 'd9'),
            ],
            storedSequence: 5,
            storedDigest: 'old',
          ),
          'github');
    });
    test('两源均低于本地记录 sequence → none（重放）', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'pc', sequence: 6, digest: 'd6'),
              (source: 'github', sequence: 7, digest: 'd7'),
            ],
            storedSequence: 8,
            storedDigest: 'd8',
          ),
          'none');
    });
    test('与本地同 sequence 同 digest → sameAllowed 允许继续（重试/恢复）', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'pc', sequence: 8, digest: 'd8'),
            ],
            storedSequence: 8,
            storedDigest: 'd8',
          ),
          'pc');
    });
    test('单源无本地记录 → 接受', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'github', sequence: 1, digest: 'd1'),
            ],
          ),
          'github');
    });
    test('电脑源旧于 GitHub 新版本 → 不再遮蔽（即使电脑有合法旧 manifest）', () {
      expect(
          resolveDualSourceSelection(
            [
              (source: 'pc', sequence: 4, digest: 'd4'),
              (source: 'github', sequence: 9, digest: 'd9'),
            ],
            storedSequence: 3,
            storedDigest: 'd3',
          ),
          'github');
    });
  });
}
