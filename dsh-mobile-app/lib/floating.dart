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

  /// 余额预警配置同步给悬浮球（开关 + 阈值；悬浮球的报警判定完全以此为准，
  /// 开关关闭 → 悬浮球不因余额报警/亮起，仅常驻显示余额数值）。
  static Future<void> setBalanceAlert(bool enabled, double threshold) =>
      _channel.invokeMethod('setBalanceAlert', {
        'enabled': enabled,
        'threshold': threshold.toStringAsFixed(2),
      });

  /// 冷启动暂存的面板动作（一次性消费）：返回 `charge` | `notifs` | `session:<id>` | null。
  /// v2.7.2 review：原生侧投递后仍保留 pending 直到被消费，Dart 首帧后主动拉取，
  /// 解决"Dart handler 注册晚于投递"导致动作丢失。
  static Future<String?> consumeOpenPanel() async =>
      await _channel.invokeMethod<String>('consumeOpenPanel');
}
