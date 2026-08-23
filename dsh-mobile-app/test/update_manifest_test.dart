// M1 自动更新核心逻辑单测：JCS / 重复键检测 / manifest 解析验签（双签名）/ payloadDigest 跨序列化一致 / sequence 四规则。
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/update/jcs.dart';
import 'package:dsh_mobile_app/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

// 测试夹具密钥（由 _diag/gen-fixture.mjs 一次性生成，仅测试用，非发布密钥）
const testPubA = '9M53yV1V2muZmQ4kHqmVb0FBFAyer6L05YLL4Wbnwgo';
const testPubB = 'jrNbTTfobNfcxL1pT05khnAQKVC3V47Qgw-EWz6kax4';

String fixtureRaw() =>
    File('test/fixtures/signed-manifest.json').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('jcs（RFC 8785，与 JS 发布工具逐字节一致）', () {
    test('金样本', () {
      final input = <String, Object?>{
        'numbers': [333333333.33333329, 1e30, 4.5, 0.002, 1e-27],
        'string': '€\$' '\u000f\n' "A'B" '"' '\\\\' '"' '/',
        'literals': [null, true, false],
      };
      final expected = '''{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€\$\\u000f\\nA'B\\"\\\\\\\\\\"/"}''';
      expect(jcs(input), expected);
    });
    test('键排序与嵌套', () {
      expect(jcs({'b': 1, 'a': {'d': 2, 'c': [3, null, true]}}),
          '{"a":{"c":[3,null,true],"d":2},"b":1}');
    });
    test('整数值 double 归一为 int 形式（1.0 → "1"，与 ES6 一致）', () {
      expect(jcs({'n': 1.0, 'x': 1}), '{"n":1,"x":1}');
    });
    test('控制符短转义', () {
      expect(jcs('a\u0001"\b\t\\b'), '"a\\u0001\\"\\b\\t\\\\b"');
    });
  });

  group('hasDuplicateKeys', () {
    test('重复键检测', () {
      expect(hasDuplicateKeys('{"a":1,"a":2}'), isTrue);
      expect(hasDuplicateKeys('{"a":1,"b":{"c":2,"c":3}}'), isTrue);
    });
    test('合法 JSON 无重复键', () {
      expect(hasDuplicateKeys(fixtureRaw()), isFalse);
      expect(hasDuplicateKeys('{"a":1,"b":[{"c":2},{"c":3}]}'), isFalse);
    });
  });

  group('parseAndVerifyManifest', () {
    test('夹具双签名：两个受信密钥各自可验', () async {
      final (m, kid) = await parseAndVerifyManifest(fixtureRaw(),
          trustedKeys: {'test-key-a': testPubA, 'test-key-b': testPubB});
      expect(kid, 'test-key-a');
      expect(m.schemaVersion, 1);
      expect(m.sequence, 3);
      expect(m.app.versionName, '3.1.0');
      expect(m.app.versionCode, 15);
      expect(m.plugin.versionName, '3.1.0');
      expect(m.minPluginVersion, '3.0.0');
      expect(m.minAppVersionCode, 14);
      expect(m.minKeyringVersionCode, 15);
    });
    test('仅信任 key-b 也可验（模拟旧钥移除后仍可验新签）', () async {
      final (_, kid) = await parseAndVerifyManifest(fixtureRaw(),
          trustedKeys: {'test-key-b': testPubB});
      expect(kid, 'test-key-b');
    });
    test('篡改内容 → signature-invalid', () async {
      final tampered = fixtureRaw().replaceFirst('"sequence": 3', '"sequence": 4');
      await expectLater(
        parseAndVerifyManifest(tampered, trustedKeys: {'test-key-a': testPubA}),
        throwsA(isA<UpdateManifestException>()
            .having((e) => e.code, 'code', 'signature-invalid')),
      );
    });
    test('未知受信密钥 → signature-invalid', () async {
      await expectLater(
        parseAndVerifyManifest(fixtureRaw(),
            trustedKeys: {'other-key': testPubA}),
        throwsA(isA<UpdateManifestException>()
            .having((e) => e.code, 'code', 'signature-invalid')),
      );
    });
    test('未知顶层字段 → unknown-field', () async {
      final raw = fixtureRaw().replaceFirst(
          '"signatures"', '"extraField":1,"signatures"');
      await expectLater(
        parseAndVerifyManifest(raw, trustedKeys: {'test-key-a': testPubA}),
        throwsA(isA<UpdateManifestException>()
            .having((e) => e.code, 'code', 'unknown-field')),
      );
    });
    test('重复键 → duplicate-key', () async {
      final raw = fixtureRaw().replaceFirst('"sequence": 3', '"sequence": 3,"sequence": 3');
      await expectLater(
        parseAndVerifyManifest(raw, trustedKeys: {'test-key-a': testPubA}),
        throwsA(isA<UpdateManifestException>()
            .having((e) => e.code, 'code', 'duplicate-key')),
      );
    });
    test('非法 schemaVersion → schema-version', () async {
      final raw = fixtureRaw().replaceFirst('"schemaVersion": 1', '"schemaVersion": 2');
      await expectLater(
        parseAndVerifyManifest(raw, trustedKeys: {'test-key-a': testPubA}),
        throwsA(isA<UpdateManifestException>()
            .having((e) => e.code, 'code', 'schema-version')),
      );
    });
  });

  group('payloadDigestOf（跨序列化一致）', () {
    test('原样与重新序列化后 digest 相同', () async {
      final raw = fixtureRaw();
      final d1 = await payloadDigestOf(raw);
      final compact = jsonEncode(jsonDecode(raw)); // 模拟服务端重序列化
      final d2 = await payloadDigestOf(compact);
      expect(d1, d2);
      expect(d1.length, 64); // sha256 hex
    });
  });

  group('decideSequence 四规则', () {
    test('更小 → 拒绝', () {
      expect(
          decideSequence(
              storedSequence: 5, storedDigest: 'd',
              sequence: 4, payloadDigest: 'x'),
          SequenceDecision.rejectOlder);
    });
    test('相同且 digest 相同 → 允许（重试/恢复/稍后）', () {
      expect(
          decideSequence(
              storedSequence: 5, storedDigest: 'd',
              sequence: 5, payloadDigest: 'd'),
          SequenceDecision.sameAllowed);
    });
    test('相同但 digest 不同 → 冲突拒绝', () {
      expect(
          decideSequence(
              storedSequence: 5, storedDigest: 'd',
              sequence: 5, payloadDigest: 'e'),
          SequenceDecision.sameConflict);
    });
    test('更大 → 接受', () {
      expect(
          decideSequence(
              storedSequence: 5, storedDigest: 'd',
              sequence: 6, payloadDigest: 'x'),
          SequenceDecision.acceptNew);
    });
    test('无记录 → 接受', () {
      expect(
          decideSequence(
              storedSequence: null, storedDigest: null,
              sequence: 1, payloadDigest: 'x'),
          SequenceDecision.acceptNew);
    });
  });
}
