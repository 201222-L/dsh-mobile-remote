// issue #53（issue 正文 §4）：交付文件行的「⋮」操作——用其他应用打开 / 分享 / 保存到手机。
//
// 复用现有 `dsh/files` 原生通道与流式下载能力（downloadFileToFile 同族），
// 下载目标始终是**轮末记录坐标**（不提交路径）；原生侧只接受 content:// URI。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../l10n.dart';
import '../toast.dart';
import '../turn_tail.dart';

const MethodChannel _filesChannel = MethodChannel('dsh/files');

/// 交付文件 MIME（原生打开/分享需要；未知按二进制处理）。
String mimeOfTurnFileName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'md' => 'text/markdown',
    'txt' => 'text/plain',
    'json' => 'application/json',
    'csv' => 'text/csv',
    'html' || 'htm' => 'text/html',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

/// 打开「⋮」操作面板。返回时页面可能已经切换（下载期间），调用方无需处理返回值。
Future<void> showTurnFileActions(
  BuildContext context, {
  required Api api,
  required TurnFileCoordinate coordinate,
  required String name,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.open_in_new, size: 20),
            title: Text(L10n.t('用其他应用打开', 'Open with another app')),
            onTap: () => Navigator.of(ctx).pop('open'),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.share_outlined, size: 20),
            title: Text(L10n.t('分享', 'Share')),
            onTap: () => Navigator.of(ctx).pop('share'),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.download_outlined, size: 20),
            title: Text(L10n.t('保存到手机', 'Save to phone')),
            onTap: () => Navigator.of(ctx).pop('save'),
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final mime = mimeOfTurnFileName(name);
  try {
    final saved = await _downloadAndSave(api, coordinate, name);
    if (!context.mounted) return;
    if (action == 'save') {
      showToast(
        context,
        saved == null
            ? L10n.t('已保存到手机', 'Saved to phone')
            : L10n.t('已保存到手机：$saved', 'Saved to phone: $saved'),
      );
      return;
    }
    if (saved == null || !saved.startsWith('content://')) {
      // Android 9 及以下保存为应用私有路径，原生 open/share 只接受 content://。
      showToast(
        context,
        L10n.t('已保存到手机（该 Android 版本不支持直接打开/分享）', 'Saved (open/share unavailable on this Android version)'),
      );
      return;
    }
    final method = action == 'open' ? 'openFile' : 'shareFile';
    await _filesChannel.invokeMethod<dynamic>(method, {'uri': saved, 'mime': mime});
  } catch (e) {
    if (messenger != null && context.mounted) {
      showToast(context, L10n.t('操作失败：$e', 'Action failed: $e'));
    }
  }
}

/// 下载到临时文件并交给原生「保存到手机」；返回 saved（Android 10+ 为 content:// URI）。
Future<String?> _downloadAndSave(
  Api api,
  TurnFileCoordinate coordinate,
  String name,
) async {
  Directory tempDir;
  try {
    tempDir = await getTemporaryDirectory();
  } catch (_) {
    rethrow;
  }
  final safeName = name.isEmpty ? 'file' : name;
  final target = File(
    '${tempDir.path}/dsh-tail-${DateTime.now().microsecondsSinceEpoch}-$safeName',
  );
  try {
    await api.turnFileToFile(coordinate, target);
    return await _filesChannel.invokeMethod<String>('saveFileFromPath', {
      'path': target.path,
      'name': safeName,
    });
  } finally {
    try {
      await target.delete();
    } catch (_) {}
  }
}
