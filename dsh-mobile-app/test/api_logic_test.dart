// 多地址自动切换逻辑的单元测试（纯内存逻辑，不依赖网络/平台通道）。
// 覆盖：mergeUrls 去重/规范化/排除回环/首位保持、rotateBaseUrl 轮换与单地址不切换。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Api newApi(String base) {
    final a = Api();
    a.baseUrl = base;
    a.token = '';
    return a;
  }

  group('多地址自动切换', () {
    test('mergeUrls：去重、规范化、排除回环/链路本地、当前地址保持首位', () {
      final a = newApi('http://192.168.1.100:3080');
      a.mergeUrls([
        'http://192.168.1.100:3080', // 当前地址（重复）
        'http://100.64.0.7:3080/', // 尾斜杠 → 规范化
        'http://100.64.0.7:3080/m', // /m 后缀 → 与上一项重复
        'http://127.0.0.1:3080', // 回环排除
        'http://localhost:3080', // 回环排除
        'http://169.254.83.107:3080', // 链路本地排除（未登录 Tailscale 等虚拟网卡）
      ]);
      expect(a.baseUrls, ['http://192.168.1.100:3080', 'http://100.64.0.7:3080']);
    });

    test('mergeUrls：新收集地址追加，上限裁剪', () {
      final a = newApi('http://192.168.1.1:3080');
      a.mergeUrls(List.generate(12, (i) => 'http://10.0.0.$i:3080'));
      expect(a.baseUrls.first, 'http://192.168.1.1:3080');
      expect(a.baseUrls.length, lessThanOrEqualTo(8));
    });

    test('rotateBaseUrl：两个地址循环轮换，回到起点', () {
      final a = newApi('http://192.168.1.100:3080');
      a.mergeUrls(['http://192.168.1.100:3080', 'http://100.64.0.7:3080']);
      expect(a.rotateBaseUrl(), isTrue);
      expect(a.baseUrl, 'http://100.64.0.7:3080');
      expect(a.rotateBaseUrl(), isTrue);
      expect(a.baseUrl, 'http://192.168.1.100:3080');
    });

    test('rotateBaseUrl：仅一个地址时不切换', () {
      final a = newApi('http://192.168.1.100:3080');
      a.mergeUrls(['http://192.168.1.100:3080']);
      expect(a.rotateBaseUrl(), isFalse);
      expect(a.baseUrl, 'http://192.168.1.100:3080');
    });

    test('手动重配置：地址表以用户输入为准（等待后续自动收集扩充）', () {
      final a = newApi('http://192.168.1.100:3080');
      a.mergeUrls(['http://192.168.1.100:3080', 'http://100.64.0.7:3080']);
      expect(a.baseUrls.length, 2);
      // 模拟 save(base: 新地址)：列表重置为单条
      a.baseUrl = 'http://frp.example.com:3080';
      a.baseUrls = [a.baseUrl];
      expect(a.baseUrls.length, 1);
      // 之后 collectUrls 会把 PC 侧网段地址合并进来
      a.mergeUrls(['http://frp.example.com:3080', 'http://192.168.1.100:3080', 'http://100.64.0.7:3080']);
      expect(a.baseUrls.length, 3);
      expect(a.baseUrls.first, 'http://frp.example.com:3080');
    });
  });
}
