import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';

const _installer = MethodChannel('dsh/update');

class PairedAppRelease {
  const PairedAppRelease({
    required this.version,
    required this.build,
    required this.size,
    required this.hash,
    required this.certificate,
  });
  final String version, hash, certificate;
  final int build, size;

  factory PairedAppRelease.fromJson(Map<String, dynamic> json) {
    final size = json['size'], build = json['versionCode'];
    final hash = json['sha256'], certificate = json['certificateSha256'];
    if (json['packageName'] != 'com.dsh.remote' ||
        json['versionName'] is! String ||
        size is! int ||
        size <= 0 ||
        size > 300 * 1024 * 1024 ||
        build is! int ||
        build <= 0 ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        certificate is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(certificate)) {
      throw const FormatException('配对 App 信息不完整');
    }
    return PairedAppRelease(
      version: json['versionName'] as String,
      build: build,
      size: size,
      hash: hash,
      certificate: certificate,
    );
  }
}

Future<String> downloadPairedApp(
  Api api,
  PairedAppRelease release, {
  void Function(int received, int total)? onProgress,
}) async {
  final directory = Directory(
    '${(await getTemporaryDirectory()).path}/updates',
  );
  await directory.create(recursive: true);
  final file = File('${directory.path}/${release.hash}.apk');
  final part = File('${file.path}.part');
  IOSink? sink;
  try {
    final response = api.openPairedAppDownload();
    var received = 0;
    sink = part.openWrite();
    await sink.addStream(
      response
          .timeout(const Duration(seconds: 30))
          .transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleData: (chunk, output) {
                received += chunk.length;
                if (received > release.size) {
                  output.addError(const FormatException('安装包大小不符'));
                  return;
                }
                onProgress?.call(received, release.size);
                output.add(chunk);
              },
            ),
          ),
    );
    await sink.close();
    sink = null;
    if (received != release.size ||
        (await sha256.bind(part.openRead()).first).toString() != release.hash) {
      throw const FormatException('安装包校验失败，请重新下载');
    }
    if (await file.exists()) await file.delete();
    await part.rename(file.path);
    return file.path;
  } finally {
    await sink?.close();
    if (await part.exists()) await part.delete();
  }
}

Future<String> launchAppInstaller(
  String path,
  PairedAppRelease release,
) async =>
    await _installer.invokeMethod<String>('install', {
      'path': path,
      'versionCode': release.build,
      'versionName': release.version,
      'sha256': release.hash,
      'size': release.size,
      'certificate': release.certificate,
    }) ??
    'installer-unavailable';

String updateMessage(Object? code) => switch (code) {
  'checking-selected-source' => '正在检查所选更新源',
  'update-available' => '发现新版本',
  'already-current' => '当前已是最新版本',
  'downloading-paired-artifacts' => '正在下载插件与配对 App',
  'paired-artifacts-verified' => '更新包校验通过',
  'update-prepared-restart-required' => '更新已准备，请重新启动电脑端 DSH',
  'artifact-hash-mismatch' || 'artifact-size-mismatch' => '更新包不完整或校验不符，请重新下载。',
  'manifest-signature-invalid' => '更新清单签名不可信，已停止更新。',
  'release-version-content-changed' => '同一版本的发布内容发生变化，请联系维护者。',
  'update-source-unavailable' || 'npm-command-failed' => '所选更新源暂不可用，请稍后重试。',
  'release-manifest-missing' => '当前发行版还没有更新清单，请使用 GitHub Releases。',
  'official-npm-package-unconfigured' => '官方 npm 更新源尚未配置。',
  'running-tasks-present' => '电脑仍有任务运行，请等待任务结束后再安装插件。',
  'manual-plugin-install-required' ||
  'npm-lockfile-required-for-update' ||
  'pnpm-profile-requires-manual-update' => '更新包已准备，请在电脑端按当前安装方式更新插件。',
  'plugin-version-not-active' ||
  'paired-app-not-ready' => '请先让电脑端配对插件生效，再下载 App。',
  'permission-required' => '请允许安装此来源的应用，然后再次点击安装。',
  'installer-started' => '已交给系统安装器，请在系统界面确认。',
  'certificate-mismatch' => '安装包签名与当前 App 不一致，无法覆盖安装。',
  'failed' => '更新失败，可查看下方记录后重试。',
  _ => code is String && code.startsWith('{') ? '更新暂不可用，请重试。' : '${code ?? ''}',
};
