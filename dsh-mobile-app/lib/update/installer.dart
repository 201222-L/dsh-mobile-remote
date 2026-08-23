// M1：APK 安装——经原生通道触发系统安装器（FileProvider content URI + 未知来源引导）。
import 'dart:io';

import 'package:flutter/services.dart';

class ApkInstaller {
  static const MethodChannel _ch = MethodChannel('dsh/update');

  /// 触发系统安装器；返回 true = 已发起（安装结果由用户在系统界面决定）；
  /// false = 需先在系统设置允许"安装未知来源应用"后重试。
  static Future<bool> install(File apk) async {
    final ok = await _ch.invokeMethod<bool>('installApk', {'path': apk.path});
    return ok ?? false;
  }
}
