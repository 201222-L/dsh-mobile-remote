// Chrome Custom Tabs（v2.7）：App 内打开网页，复用系统浏览器登录态 + 支付能力。
// 比 WebView 套壳安全（无 JS bridge、地址栏可见），比跳浏览器少一次切换。
import 'package:flutter/services.dart';

class CustomTabs {
  static const _channel = MethodChannel('dsh/custom_tabs');

  /// 用 Custom Tabs 打开链接；设备不支持时自动兜底普通浏览器。
  /// 返回 true 表示已尝试打开（是否成功由系统决定）。
  static Future<bool> open(String url) async {
    try {
      final ok = await _channel.invokeMethod<bool>('open', {'url': url});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
