// 自动更新原生桥：签名读取（自身/下载 APK）与触发系统安装器。
import 'package:flutter/services.dart';

class NativeUpdate {
  static const _channel = MethodChannel('dsh/update');

  /// 本机已装 APK 签名证书 SHA-256（十六进制小写）；读取失败返回 null（保守取消更新）。
  static Future<String?> ownSignatureSha256() async =>
      await _channel.invokeMethod<String>('ownSignatureSha256');

  /// 下载到本地的 APK 文件签名证书 SHA-256；读取失败返回 null（不可信，取消）。
  static Future<String?> apkSignatureSha256(String path) async =>
      await _channel.invokeMethod<String>('apkSignatureSha256', {'path': path});

  /// 校验通过后拉起系统安装器。异常时抛出（由调用方给出提示）。
  static Future<void> installApk(String path) =>
      _channel.invokeMethod('installApk', {'path': path});
}