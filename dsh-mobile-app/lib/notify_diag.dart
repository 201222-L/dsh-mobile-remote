// 通知诊断：把"保活是否真的在工作、后台有没有收到帧"变成设置页可见的一行状态。
//
// 背景：真机排查时只能靠抓日志，而日志复制曾经拿到的是最旧的一段（显示倒序、复制正序），
// 来回好几轮才定位。这里把关键事实挂在内存里，设置页一眼可见。
//
// 2026-10-31 评审教训：之前只有"保活在跑"这一条证据，而它并不代表真的收到了帧——
// 四版 APK 的服务其实从未创建。现在把"后台收到几帧"单独计数，它才是判定
// "FGS + Dart SSE 是否成立"的唯一硬指标。
import 'logger.dart';

class NotifyDiag {
  NotifyDiag._();

  /// 最后一次收到审批/问询帧的时间（null = 本次启动以来从未收到）。
  static DateTime? lastFrameAt;

  /// 最后一次帧来自哪个通道：`frame`（SSE 快照）或 `notify`。
  static String? lastFrameKind;

  /// 最后一帧到达时 App 是否在前台（null = 尚未收到帧）。
  static bool? lastFrameInForeground;

  /// 本次启动以来前台 / 后台各收到多少帧。后台计数 > 0 才证明保活真的救活了 SSE。
  static int framesForeground = 0;
  static int framesBackground = 0;

  /// 最后一次判据结论，例如 `background/system=true/banner=false`。
  static String? lastDecision;

  /// 最后一次展示结果：shown / blocked / blocked(failed)。
  static String? lastShowResult;

  /// 保活服务是否在跑（由 Dart 侧查询后回填）。
  static bool keepAliveRunning = false;

  /// 保活服务本次启动的时间（用于显示已运行多久）。
  static DateTime? keepAliveStartedAt;

  /// 原生服务心跳（服务自己每 30 秒 +1）。
  static int serviceBeats = 0;
  static DateTime? lastServiceBeatAt;

  /// Dart 侧心跳（退到后台时每 30 秒 +1）。
  static int dartBeats = 0;
  static DateTime? lastDartBeatAt;

  static void onFrame(String kind, {required bool inForeground}) {
    lastFrameAt = DateTime.now();
    lastFrameKind = kind;
    lastFrameInForeground = inForeground;
    if (inForeground) {
      framesForeground++;
    } else {
      framesBackground++;
    }
  }

  static void onDecision(String detail) => lastDecision = detail;

  static void onShow(String result) => lastShowResult = result;

  /// Dart 心跳：只统计后台期间的次数，用来判断 Dart isolate 是否被冻结。
  static void onDartBeat() {
    dartBeats++;
    lastDartBeatAt = DateTime.now();
  }

  /// 哪一层被冻住了——这是判断"能不能靠保活解决"的唯一依据。
  static String freezeVerdict() {
    if (!keepAliveRunning) return '服务未运行';
    if (framesBackground > 0) return '后台正常';
    // 后台期间：原生心跳还在 + Dart 心跳不增 = 只有 Dart 停了
    final svc = serviceBeats;
    final dart = dartBeats;
    if (svc == 0 && dart == 0) return '尚无线索';
    if (svc > 0 && dart == 0) return 'Dart 被冻结';
    return '两层都正常';
  }

  /// 给设置页的一行摘要。
  static String summary({
    required bool keepAliveEnabled,
    String? keepAliveError,
  }) {
    final alive = keepAliveRunning
        ? '保活在跑${_uptime()}'
        : (keepAliveEnabled
            ? '保活未运行${keepAliveError == null ? "" : "（$keepAliveError）"}'
            : '保活关');
    // 这是判定保活是否有效的硬指标：后台帧数 > 0 说明 FGS + Dart SSE 成立。
    final bg = framesBackground > 0
        ? '后台收到 $framesBackground 帧'
        : (framesForeground > 0 ? '后台 0 帧' : '尚无帧');
    final last = lastFrameAt;
    final frameText = last == null
        ? '本次启动未收到帧'
        : '${_ago(DateTime.now().difference(last))}前收到 ${lastFrameKind ?? "帧"}'
            '（${lastFrameInForeground == true ? "前台" : "后台"}）';
    final dec = lastDecision == null ? '' : ' · $lastDecision';
    final show = lastShowResult == null ? '' : ' · 展示:$lastShowResult';
    // 心跳对比：服务心跳 > 0 而 Dart 心跳 = 0，说明只有 Dart 被冻结（该把网络下沉到原生）；
    // 两个都不动，说明整个进程被 ROM 冻住了（只能靠系统白名单）。
    final beats = ' · 心跳 服务$serviceBeats/Dart$dartBeats';
    return '$alive · $bg$beats · $frameText$dec$show';
  }

  static String _uptime() {
    final started = keepAliveStartedAt;
    if (started == null) return '';
    final d = DateTime.now().difference(started);
    if (d.inSeconds < 60) return '（${d.inSeconds} 秒）';
    if (d.inMinutes < 60) return '（${d.inMinutes} 分钟）';
    return '（${d.inHours} 小时）';
  }

  static String _ago(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} 秒';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
    return '${d.inHours} 小时';
  }

  static void logSummary({required bool keepAliveEnabled}) {
    AppLog.instance.log('通知诊断：${summary(keepAliveEnabled: keepAliveEnabled)}');
  }
}
