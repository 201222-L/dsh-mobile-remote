// 全局轻提示：短滞留 + 悬浮样式，不遮挡底部输入区、不阻塞后续操作。
// 长消息自动延长（错误详情需要阅读时间），短提示 1.6 秒即消失。
import 'package:flutter/material.dart';

void showToast(BuildContext context, String msg) {
  final ms = msg.length > 50 ? 3000 : 1600;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      duration: Duration(milliseconds: ms),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
}
