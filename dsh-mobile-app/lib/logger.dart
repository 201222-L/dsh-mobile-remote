// 应用日志：关键事件写入本地文件 + 内存环形缓冲，设置页可查看/复制/清空。
// 用途：排查"加载不出来/连接异常"等问题（release 无控制台输出时唯一手段）。
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  final List<String> _buf = [];
  File? _file;
  static const _maxBuf = 800;
  /// 日志文件体积近似计账（不每行 stat——移动端 flash 上每行 stat+fsync 会让 SSE 流式期间掉帧）
  int _approxBytes = 0;
  /// 日志保留天数（默认 15 天）：文件最后写入时间超过该期限，启动时清空。
  static const _keepDays = 15;

  /// 启动时调用：定位日志文件（应用文档目录 dsh_mobile.log），并做过期清理。
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/dsh_mobile.log');
      // 默认 15 天清理一次：上次写日志距今超过保留期 → 清空（保留文件避免重建权限问题）
      try {
        if (await f.exists()) {
          final age = DateTime.now().difference(await f.lastModified());
          if (age.inDays >= _keepDays) {
            await f.writeAsString('');
          }
          _approxBytes = (await f.length()).toInt();
        }
      } catch (_) {
        // 清理失败不影响日志功能
      }
      _file = f;
      log('==== App 启动 ====');
    } catch (_) {
      // 无文件系统权限时仅内存日志
    }
  }

  void log(String msg) {
    final line = '[${DateTime.now().toString().substring(5, 23)}] $msg';
    _buf.add(line);
    if (_buf.length > _maxBuf) _buf.removeAt(0);
    // print 在 release 下也会进入 logcat（tag=flutter），便于 adb 抓取排障
    // ignore: avoid_print
    print(line);
    final f = _file;
    if (f == null) return;
    try {
      // v3.0.0：去 flush:true——同步 append 保留（日志有序、不丢行），但 fsync 每行一次
      // 在 SSE chunk 高频路径上会显著掉帧；尺寸用近似记账，超限时才做一次全量截断。
      f.writeAsStringSync('$line\n', mode: FileMode.append);
      _approxBytes += line.length + 1;
      // 控制体积：超过 256KB 截断保留后半
      if (_approxBytes > 256 * 1024) {
        final lines = f.readAsLinesSync();
        f.writeAsStringSync('${lines.sublist(lines.length ~/ 2).join('\n')}\n');
        _approxBytes = lines.length ~/ 2 * 16; // 截半后的近似值（仅用于下一轮截断判定）
      }
    } catch (_) {
      // 日志失败不影响功能
    }
  }

  /// 当前内存中的日志（最新在后）
  List<String> get lines => List.of(_buf);

  /// 完整日志文本（文件内容，空则用内存）
  Future<String> readAll() async {
    try {
      final f = _file;
      if (f != null && await f.exists()) return await f.readAsString();
    } catch (_) {}
    return _buf.join('\n');
  }

  Future<void> clear() async {
    _buf.clear();
    try {
      await _file?.writeAsString('');
    } catch (_) {}
  }
}
