// 下载失败的「人话」说明。
//
// 真机反馈：失败时直接把异常字符串丢进 Toast，用户看到的是
// "ApiException: HTTP 500 (code=files-read-failed)" 之类，既不知道发生了什么、
// 也不知道该做什么。这里统一把异常翻译成「结论 + 下一步建议」，原始信息
// 留在 detail 里供折叠查看/复制给开发者。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'l10n.dart';

/// 一次失败的友好表述。
class DownloadFailure {
  const DownloadFailure({
    required this.summary,
    required this.detail,
    this.hint,
  });

  /// 一句话结论（发生了什么）。
  final String summary;

  /// 下一步建议（用户能做什么）。可能为空。
  final String? hint;

  /// 原始异常信息（折叠展示，可复制）。
  final String detail;
}

/// 把下载过程中的任意异常翻译成人话。
///
/// 判定顺序按"具体 → 笼统"：先认自家的 [ApiException]（有 HTTP 状态码和内核
/// 错误码），再认网络/平台异常，最后兜底。
DownloadFailure describeDownloadError(Object error) {
  String detailOf(Object e) {
    final text = e.toString();
    if (text.length <= 800) return text;
    return '${text.substring(0, 800)}…';
  }

  if (error is ApiException) {
    final status = error.status;
    final code = error.code;
    if (status == 401 || status == 403) {
      return DownloadFailure(
        summary: L10n.t('电脑端拒绝了这次访问（口令不对或已失效）', 'The computer rejected this request (bad or expired token)'),
        hint: L10n.t(
          '在电脑上打开连接页，用二维码重新扫码连接一次。',
          'Open the connect page on the computer and scan the QR code again.',
        ),
        detail: detailOf(error),
      );
    }
    if (status == 404) {
      return DownloadFailure(
        summary: L10n.t('电脑上找不到这个文件', 'The file no longer exists on the computer'),
        hint: L10n.t('可能已被移动或删除，回到文件列表刷新后重试。', 'It may have been moved or deleted. Refresh the file list and retry.'),
        detail: detailOf(error),
      );
    }
    if (status != null && status >= 500) {
      return DownloadFailure(
        summary: L10n.t('电脑端插件出错了', 'The computer-side plugin failed'),
        hint: L10n.t('稍后重试；若持续失败，看电脑端插件日志。', 'Retry in a moment; if it keeps failing, check the plugin log on the computer.'),
        detail: detailOf(error),
      );
    }
    if (code == 'file-too-large') {
      return DownloadFailure(
        summary: L10n.t('文件太大，电脑端拒绝发送', 'The file is too large for the plugin to send'),
        hint: L10n.t('换小一点的文件，或让电脑端先压缩。', 'Try a smaller file, or compress it on the computer first.'),
        detail: detailOf(error),
      );
    }
    return DownloadFailure(
      summary: L10n.t('电脑端返回了错误', 'The computer returned an error'),
      hint: L10n.t('可以重试一次；不行就把详情发给开发者。', 'Retry once; if it persists, share the details with the developer.'),
      detail: detailOf(error),
    );
  }

  if (error is TimeoutException) {
    return DownloadFailure(
      summary: L10n.t('下载超时：电脑长时间没有响应', 'Download timed out: the computer stopped responding'),
      hint: L10n.t(
        '确认电脑没休眠、插件还在运行；网络不稳时重试。',
        'Make sure the computer is awake and the plugin is running, then retry.',
      ),
      detail: detailOf(error),
    );
  }

  if (error is SocketException) {
    return DownloadFailure(
      summary: L10n.t('连不上电脑', 'Cannot reach the computer'),
      hint: L10n.t(
        '确认手机和电脑在同一个局域网、电脑端插件在运行；换回家里 WiFi 或重新扫码。',
        'Check that phone and computer share a network and the plugin is running; switch Wi-Fi or rescan the QR code.',
      ),
      detail: detailOf(error),
    );
  }

  if (error is http.ClientException) {
    return DownloadFailure(
      summary: L10n.t('连接中途断了', 'The connection dropped mid-transfer'),
      hint: L10n.t('重试即可；大文件请保持手机不要锁屏切换网络。', 'Retry; for large files keep the phone awake and on the same network.'),
      detail: detailOf(error),
    );
  }

  if (error is HandshakeException) {
    return DownloadFailure(
      summary: L10n.t('安全连接建立失败', 'Secure connection failed'),
      hint: L10n.t('如果用反代 HTTPS，检查电脑端证书是否有效。', 'If you use an HTTPS reverse proxy, check the certificate.'),
      detail: detailOf(error),
    );
  }

  if (error is PlatformException) {
    return DownloadFailure(
      summary: L10n.t('文件已经下载，但保存到手机失败', 'Downloaded, but saving to the phone failed'),
      hint: L10n.t('检查存储空间是否够用，或稍后重试。', 'Check free storage space and retry.'),
      detail: detailOf(error),
    );
  }

  return DownloadFailure(
    summary: L10n.t('下载失败', 'Download failed'),
    hint: L10n.t('可以重试一次；不行就把详情发给开发者。', 'Retry once; if it persists, share the details with the developer.'),
    detail: detailOf(error),
  );
}
