// 悬浮球（v2.7）：原生 overlay 服务桥接。
// 小球常驻系统上层（App 被杀仍工作），自己连 SSE 收事件；
// App 侧负责开关、权限引导、余额联动、面板页。
import 'package:flutter/services.dart';

class Floating {
  static const _channel = MethodChannel('dsh/floating');

  static Future<void> start() => _channel.invokeMethod('start');
  static Future<void> stop() => _channel.invokeMethod('stop');
  static Future<bool> isRunning() async =>
      (await _channel.invokeMethod<bool>('isRunning')) ?? false;

  /// 是否已授权悬浮窗权限。
  static Future<bool> canDrawOverlay() async =>
      (await _channel.invokeMethod<bool>('canDrawOverlay')) ?? false;

  /// 跳转系统悬浮窗权限设置页。
  static Future<void> openOverlaySettings() =>
      _channel.invokeMethod('openOverlaySettings');

  /// 余额刷新后同步给悬浮球（低余额时亮起 + 气泡）。value 形如 "10.5:CNY"。
  static Future<void> notifyBalance(double total) =>
      _channel.invokeMethod('notifyBalance', {'value': total.toStringAsFixed(2)});

  /// 悬浮球单击打开的面板标志（一次性消费）。
  static Future<bool> consumeOpenPanel() async =>
      (await _channel.invokeMethod<bool>('consumeOpenPanel')) ?? false;
}
