// issue #15：整段对话复制（导出为纯文本）。
//
// 抽成无 Flutter 依赖的纯函数，便于单测覆盖「顺序 / 跳过空行 / 标签」这些容易写错的细节。

/// 把按**时间正序**排列的对话行拼成可复制的纯文本。
///
/// - 正文为空白的行为跳过（图像占位、轮次分隔条等不导出）
/// - 每行输出「标签：正文」，行间留空行；末尾不留多余空行
/// - 标签由调用方决定（例如「你」/「助手」/「系统注入」）
String conversationText(List<(String label, String text)> lines) {
  final sb = StringBuffer();
  for (final (label, text) in lines) {
    final body = text.trim();
    if (body.isEmpty) continue;
    sb.writeln('$label：$body');
    sb.writeln();
  }
  return sb.toString().trimRight();
}
