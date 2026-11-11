// issue #74：工具结果图片的折叠态入口（纯聚合规则，供工具卡 / 过程组 / 摘要 / 分批行共用）。

/// 单张图片的去重键：优先 `attachmentId`（手机端按它拉字节），其次 `path`，最后 `name`。
///
/// 同一张图可能在多个工具结果里出现（或同一事件内重复 present），聚合计数必须去重；
/// 缺少任何标识的图片元数据视为不可用（fail-open：不制造死入口）。
String? toolImageDedupKey(Map<String, dynamic> image) {
  final attachmentId = image['attachmentId']?.toString();
  if (attachmentId != null && attachmentId.isNotEmpty) {
    return 'attachment:$attachmentId';
  }
  final path = image['path']?.toString();
  if (path != null && path.isNotEmpty) return 'path:$path';
  final name = image['name']?.toString();
  if (name != null && name.isNotEmpty) return 'name:$name';
  return null;
}

/// 聚合「若干工具结果各自的 images」为一组去重后的图片（保持首次出现顺序）。
///
/// 入参是 `callId → images` 的具象化：调用方按过程行/工具卡把自己的图片列出来，
/// 这里只负责去重与顺序，不关心来源层（过程组/摘要/单卡/分批隐藏区）。
List<Map<String, dynamic>> collectToolImages(
  Iterable<List<Map<String, dynamic>>> sources,
) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final source in sources) {
    for (final image in source) {
      final key = toolImageDedupKey(image);
      if (key == null) continue;
      if (seen.add(key)) out.add(image);
    }
  }
  return out;
}

/// 聚合后的图片张数（入口 chip 的 N）。
int countToolImages(Iterable<List<Map<String, dynamic>>> sources) =>
    collectToolImages(sources).length;
