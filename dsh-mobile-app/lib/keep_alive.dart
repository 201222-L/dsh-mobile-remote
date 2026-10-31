// issue #55：后台提醒保活。
//
// 只负责拉起/停止原生前台服务（一条低干扰常驻通知），把进程钉住让 SSE 不被
// Android 冻结；收到了什么帧、弹不弹通知仍由 Dart 侧决定。
// 与桌面宠物（FloatingBubbleService）互斥，切换由原生侧 stopService 保证。
import 'package:flutter/services.dart';

class KeepAliveBridge {
  static const _channel = MethodChannel('dsh/keepalive');

  static Future<void> start() => _channel.invokeMethod('start');
  static Future<void> stop() => _channel.invokeMethod('stop');

  static Future<bool> isRunning() async =>
      (await _channel.invokeMethod<bool>('isRunning')) ?? false;

  /// 通知总开关是否开启。被拒时服务仍在跑，但常驻通知不可见，设置页要如实提示。
  static Future<bool> notificationsEnabled() async =>
      (await _channel.invokeMethod<bool>('notificationsEnabled')) ?? true;
}
