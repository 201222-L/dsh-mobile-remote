// 桌面图标切换：Dart ↔ Android activity-alias。
// 仅 Android 支持；iOS 直接返回 false（设置页隐藏入口）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppIconSwitcher {
  const AppIconSwitcher._();

  static const MethodChannel _channel = MethodChannel('dsh/app_icon');

  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  /// 切换桌面图标；返回是否成功（原生侧会 disable 其余 alias、enable 目标 alias）。
  static Future<bool> set(String id) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setIcon', {'id': id});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 启动时把已保存的图标同步到系统（数据清除/重装后 alias 可能回到默认）。
  static Future<bool> sync(String id) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('syncIcon', {'id': id});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
