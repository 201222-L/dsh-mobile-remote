// Phase 2 反馈修复：下载失败要说人话。
//
// 断言外部可观察行为：给定异常，用户看到哪一句结论、有没有下一步建议、
// 原始信息还在不在（折叠详情里要能复制给开发者）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/download_error.dart';

void main() {
  test('口令失效（401）：提示重新扫码，不是一堆状态码', () {
    final f = describeDownloadError(
      ApiException('HTTP 401', code: 'auth-required', status: 401),
    );
    expect(f.summary, contains('口令'));
    expect(f.hint, contains('扫码'));
    // 原始信息不丢，留给「技术详情」
    expect(f.detail, contains('401'));
  });

  test('文件不存在（404）：告诉用户去刷新列表', () {
    final f = describeDownloadError(
      ApiException('file-not-found', status: 404),
    );
    expect(f.summary, contains('找不到'));
    expect(f.hint, contains('刷新'));
  });

  test('服务端 5xx：指向电脑端插件，而不是让用户怀疑手机', () {
    final f = describeDownloadError(ApiException('boom', status: 500));
    expect(f.summary, contains('电脑端'));
    expect(f.detail, contains('boom'));
  });

  test('连不上电脑（SocketException）', () {
    final f = describeDownloadError(
      const SocketException('Failed host lookup'),
    );
    expect(f.summary, contains('连不上'));
    expect(f.hint, contains('局域网'));
  });

  test('超时（TimeoutException）', () {
    final f = describeDownloadError(TimeoutException('idle'));
    expect(f.summary, contains('超时'));
    expect(f.hint, isNotNull);
  });

  test('连接中断（http.ClientException）', () {
    final f = describeDownloadError(http.ClientException('connection closed'));
    expect(f.summary, contains('断'));
  });

  test('保存失败（PlatformException）：说明是"已下载但存不下"', () {
    final f = describeDownloadError(
      PlatformException(code: 'save-failed', message: 'no space'),
    );
    expect(f.summary, contains('保存'));
    expect(f.detail, contains('no space'));
  });

  test('未知异常兜底：也有人话和建议，不再直接抛 bytestream 之类的原文', () {
    final f = describeDownloadError(StateError('weird'));
    expect(f.summary, isNotEmpty);
    expect(f.hint, isNotNull);
    expect(f.detail, contains('weird'));
  });

  test('详情过长会被截断，避免把整段堆栈糊在屏幕上', () {
    final f = describeDownloadError(StateError('x' * 5000));
    expect(f.detail.length, lessThan(900));
    expect(f.detail.endsWith('…'), isTrue);
  });
}
