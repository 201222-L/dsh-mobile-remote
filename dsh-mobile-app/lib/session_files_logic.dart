// 会话文件浏览的纯逻辑：路径拼接、二进制/文本判定、预览截断与行号切分。
//
// 这里刻意不含任何 Flutter / HTTP 依赖，便于单测覆盖边界（见
// test/session_files_logic_test.dart）。页面与控制器只调用这些函数。

import 'dart:convert';

/// 单个目录一次最多渲染的条目数；超出部分由 UI 提示总数。
const int kDirEntryRenderLimit = 500;

/// 文件内容预览的最大字节数；超出即截断并标注。
const int kPreviewByteLimit = 256 * 1024;

/// 预览判定结果：要么是可展示的文本（可能被截断），要么是明确不可预览的原因。
sealed class PreviewVerdict {
  const PreviewVerdict();
}

/// 可展示的文本预览。
class PreviewText extends PreviewVerdict {
  const PreviewText({required this.text, required this.truncated, required this.bytesShown});

  /// 已解码的文本（可能只是前缀）。
  final String text;

  /// 是否因超出上限被截断。
  final bool truncated;

  /// 实际参与解码的字节数。
  final int bytesShown;
}

/// 不可预览，附人类可读原因。
class PreviewUnavailable extends PreviewVerdict {
  const PreviewUnavailable(this.reason);
  final String reason;
}

/// 二进制判定：出现 NUL 字节即视为二进制。
///
/// 只扫描给定范围（截断后的前缀），因为超过上限的内容本来就不会展示。
bool looksBinary(List<int> bytes) {
  for (final b in bytes) {
    if (b == 0) return true;
  }
  return false;
}

/// 把字节解码为预览文本，并给出截断信息。
///
/// 顺序很重要：先按上限切片，再判二进制，再解码。这样超大的二进制文件
/// 不会因为要先整体解码而拖慢界面。
PreviewVerdict buildPreview(List<int> bytes) {
  final truncated = bytes.length > kPreviewByteLimit;
  final slice = truncated ? bytes.sublist(0, kPreviewByteLimit) : bytes;
  if (looksBinary(slice)) {
    return const PreviewUnavailable('二进制文件，无法以文本预览');
  }
  // allowMalformed：截断处可能切开一个 UTF-8 字符，用替换字符兜底，
  // 而不是因为这个字符丢掉整个预览。解码交给标准库，避免自己实现出错。
  return PreviewText(
    text: utf8.decode(slice, allowMalformed: true),
    truncated: truncated,
    bytesShown: slice.length,
  );
}

/// 行号切分：返回每一行的文本，至少一行（空文件 → 一个空行）。
///
/// 统一 CRLF / CR 为 LF，避免预览里出现多余的 `\r`。
List<String> previewLines(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return normalized.split('\n');
}

/// 把父路径与子项拼成新路径，尊重服务端分隔符。
///
/// 与目录选择器同款语义：父为空时直接返回子项（根视图下钻）。
String joinBrowsePath(String parent, String name, String sep) {
  if (parent.isEmpty) return name;
  if (parent.endsWith(sep)) return '$parent$name';
  return '$parent$sep$name';
}

/// 去掉路径最后一段，用于「上级」。已经是根（无分隔符）时返回空串。
String parentBrowsePath(String path, String sep) {
  if (path.isEmpty) return '';
  var p = path;
  if (p.endsWith(sep)) p = p.substring(0, p.length - sep.length);
  final idx = p.lastIndexOf(sep);
  if (idx < 0) return '';
  if (idx == 0) return sep; // POSIX 根的上级仍是根
  return p.substring(0, idx);
}

/// 面包屑：从根到当前的逐级 (显示名, 路径) 列表。
///
/// 服务端在 Linux 下返回 POSIX 路径，首段为空串（`/home/x` 切分后首项是 ''），
/// 需要合并成根显示为 `/`。
List<({String label, String path})> browseBreadcrumbs(String path, String sep) {
  if (path.isEmpty) return const [];
  final parts = path.split(sep).where((e) => e.isNotEmpty).toList();
  final crumbs = <({String label, String path})>[];
  final isAbsolute = path.startsWith(sep);
  var acc = isAbsolute ? sep : '';
  if (isAbsolute) {
    crumbs.add((label: sep, path: sep));
  }
  for (var i = 0; i < parts.length; i++) {
    acc = acc == sep ? '$sep${parts[i]}' : (acc.isEmpty ? parts[i] : '$acc$sep${parts[i]}');
    crumbs.add((label: parts[i], path: acc));
  }
  return crumbs;
}

/// 判断 `child` 是否就是 `root` 或位于其下（用于把浏览夹在会话工作目录内）。
///
/// 只做字符串前缀判定，不做 realpath 解析：服务端返回的路径已经是它自己
/// 规范化后的形式，这里的目的是挡住 UI 层的向上越界，不是安全边界。
bool isWithinRoot(String root, String child) {
  if (root.isEmpty) return true;
  if (child == root) return true;
  final r = root.endsWith('/') ? root : '$root/';
  return child.startsWith(r);
}

/// 目录条目在渲染上限内的切分结果。
({List<String> dirs, List<String> files, int hiddenCount, int total})
    limitDirEntries(List<String> dirs, List<String> files) {
  final total = dirs.length + files.length;
  if (total <= kDirEntryRenderLimit) {
    return (dirs: dirs, files: files, hiddenCount: 0, total: total);
  }
  // 目录优先展示：目录是导航骨架，文件是叶子。
  final keptDirs = dirs.length <= kDirEntryRenderLimit
      ? dirs
      : dirs.sublist(0, kDirEntryRenderLimit);
  final remaining = kDirEntryRenderLimit - keptDirs.length;
  final keptFiles = files.length <= remaining ? files : files.sublist(0, remaining < 0 ? 0 : remaining);
  return (
    dirs: keptDirs,
    files: keptFiles,
    hiddenCount: total - keptDirs.length - keptFiles.length,
    total: total,
  );
}
