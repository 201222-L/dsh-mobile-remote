import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/md.dart';

void main() {
  group('safeLinkUrl（v2.6.0 链接 scheme 白名单）', () {
    test('放行 http/https', () {
      expect(safeLinkUrl('https://example.com/a?b=1')?.toString(), 'https://example.com/a?b=1');
      expect(safeLinkUrl('http://192.168.1.100:3080/m')?.toString(), 'http://192.168.1.100:3080/m');
    });

    test('拒绝危险 scheme（file/intent/tel/javascript/data）', () {
      expect(safeLinkUrl('file:///etc/passwd'), isNull);
      expect(safeLinkUrl('intent://scan/#Intent;scheme=zxing;end'), isNull);
      expect(safeLinkUrl('tel:10086'), isNull);
      expect(safeLinkUrl('javascript:alert(1)'), isNull);
      expect(safeLinkUrl('data:text/html,<script>alert(1)</script>'), isNull);
    });

    test('解析失败 / 空串返回 null', () {
      expect(safeLinkUrl('http://[::1'), isNull);
      expect(safeLinkUrl(''), isNull);
      expect(safeLinkUrl('   '), isNull);
    });

    test('大小写 scheme 与首尾空白容忍', () {
      expect(safeLinkUrl('  HTTPS://Example.com/ '), isNotNull);
      expect(safeLinkUrl('HTTP://x.y/z')?.scheme, 'http');
    });
  });
}
