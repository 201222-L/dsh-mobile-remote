import 'package:flutter/material.dart';

import '../l10n.dart';
import '../resumable_download.dart';

/// 返回空串表示选择新文件；null 表示关闭。
Future<String?> showDownloadResumePicker(
  BuildContext context,
  ResumableDownloads downloads,
  List<PendingDownload> pending,
) => showDialog<String>(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, update) => AlertDialog(
      title: Text(L10n.t('继续未完成的下载', 'Resume a download')),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in pending)
              ListTile(
                title: Text(item.name),
                subtitle: Text(
                  L10n.t(
                    '已保留 ${(item.bytes / 1024).ceil()} KB',
                    '${(item.bytes / 1024).ceil()} KB saved',
                  ),
                ),
                onTap: () => Navigator.of(context).pop(item.remotePath),
                trailing: IconButton(
                  tooltip: L10n.t('删除断点', 'Discard download'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await downloads.discard(item.remotePath);
                    if (context.mounted) update(() => pending.remove(item));
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('关闭', 'Close')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: Text(L10n.t('选择其他文件', 'Choose another file')),
        ),
      ],
    ),
  ),
);
