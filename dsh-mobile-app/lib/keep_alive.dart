// 后台保活（issue #55）：让进程保持"前台服务"优先级，使 Dart 侧 SSE 不被冻结。
//
// 约束（见 docs/DESIGN-notification-channels-2026-10-29.md §2.7）：
// - **只续命**：不画界面、不自己连 SSE，业务全在 Dart；
// - 默认关闭（不主动塞常驻通知），用户开启后才在 `onResume` 拉起；
// - Android 12+ 只允许在前台启动 FGS，所以只能在 App 可见时启动（这里由调用方保证）；
// - 与悬浮球互斥：同时开会有两条常驻通知。
import 'package:flutter/services.dart';

import 'logger.dart';
import 'notify_diag.dart';

class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static final BackgroundKeepAlive instance = BackgroundKeepAlive._();

  static const MethodChannel _channel = MethodChannel('dsh/keepalive');
  static const _kEnabled = 'dsh_mr_keepalive';

  bool _enabled = false;
  bool _running = false;
  String? _lastError;

  bool get enabled => _enabled;
  bool get running => _running;

  /// 最近一次启动失败的原因（null = 没失败过）。
  String? get lastError => _lastError;

  /// 读取用户开关（默认关）。
  Future<void> load(bool Function() readFlag, void Function(bool) writeFlag) async {
    _enabled = readFlag();
    AppLog.instance.log('保活：开关读取 → enabled=$_enabled');
    try {
      _running = await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      _running = false;
    }
  }

  /// 设置开关；开启时若 App 可见会立即启动。返回"服务当前是否在跑"。
  Future<bool> setEnabled(bool value, {required bool appVisible}) async {
    _enabled = value;
    AppLog.instance.log('保活：设置 enabled=$value appVisible=$appVisible');
    if (value) {
      if (appVisible) {
        return start();
      }
      AppLog.instance.log('保活：当前不在前台，等下次 onResume 再启动');
      return false;
    }
    await stop();
    return false;
  }

  /// App 回到前台时调用：已开启但服务没跑就补一次启动。
  Future<void> ensureStarted() async {
    if (!_enabled) return;
    final already = await _queryRunning();
    if (!already) await start();
  }

  /// 刷新原生状态（服务是否在跑、启动时间、失败原因），写入诊断。
  Future<void> refreshStatus() async {
    try {
      final res = await _channel.invokeMethod<Map>('status');
      if (res == null) return;
      _running = res['running'] == true;
      final err = (res['error'] as String?) ?? '';
      _lastError = err.isEmpty ? null : err;
      final startedAt = (res['startedAt'] as num?)?.toInt() ?? 0;
      NotifyDiag.keepAliveRunning = _running;
      NotifyDiag.keepAliveStartedAt = (startedAt > 0 && _running)
          ? DateTime.fromMillisecondsSinceEpoch(startedAt)
          : null;
      final beats = (res['beatCount'] as num?)?.toInt() ?? 0;
      final beatAt = (res['beatAt'] as num?)?.toInt() ?? 0;
      NotifyDiag.serviceBeats = beats;
      NotifyDiag.lastServiceBeatAt =
          beatAt > 0 ? DateTime.fromMillisecondsSinceEpoch(beatAt) : null;
    } catch (_) {
      // 通道不可用时保持旧值
    }
  }

  /// 打开系统「应用详情 / 电池优化」页面，让用户把本应用设为不受限制。
  Future<bool> openBatterySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> start() async {
    try {
      final res = await _channel.invokeMethod<Map>('start');
      final ok = (res?['ok'] == true);
      final err = (res?['error'] as String?) ?? '';
      if (!ok) {
        _running = false;
        _lastError = err.isEmpty ? 'unknown' : err;
        AppLog.instance.log('保活：启动失败（$_lastError）');
        return false;
      }
      // 原生 ok 只代表 startForegroundService 没抛异常（组件缺失时它也不抛）。
      // 真正确认以服务自报的 running 为准——这是评审指出的假成功根因。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final real = await _queryRunning();
      _running = real;
      _lastError = real ? null : '服务未进入运行态（onCreate 失败或被系统拒绝）';
      AppLog.instance.log(real ? '保活：启动成功' : '保活：启动未生效（$_lastError）');
      return real;
    } on PlatformException catch (e) {
      _lastError = '${e.code}: ${e.message}';
      AppLog.instance.log('保活：启动异常（$_lastError）');
      return false;
    }
  }

  Future<void> stop() async {
    try {
      // 原生 stop 返回 Map{ok,error}：不要按 bool 解析（真机日志出现过类型错误）。
      await _channel.invokeMethod<Map>('stop');
    } catch (e) {
      AppLog.instance.log('保活：停止异常（$e）');
    }
    _running = false;
  }

  Future<bool> _queryRunning() async {
    try {
      final res = await _channel.invokeMethod<Map>('status');
      _running = res?['running'] == true;
      final err = (res?['error'] as String?) ?? '';
      if (!_running && err.isNotEmpty) _lastError = err;
      return _running;
    } catch (_) {
      return false;
    }
  }

  /// SharedPreferences key（供设置页读写）。
  static String get prefKey => _kEnabled;
}
