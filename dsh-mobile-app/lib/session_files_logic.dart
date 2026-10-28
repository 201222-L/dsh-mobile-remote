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

/// 文本编码判定结果。
enum PreviewEncoding { utf8, utf16le, utf16be, gb18030, binary }

/// 二进制判定：出现 NUL 字节即视为二进制。
///
/// 只扫描给定范围（截断后的前缀），因为超过上限的内容本来就不会展示。
/// 注意：`buildPreview` 会先识别 UTF-16（BOM 或稳定的奇数/偶数 NUL 模式），
/// 再退回这个函数，避免把 UTF-16 文本误判成二进制。
bool looksBinary(List<int> bytes) {
  for (final b in bytes) {
    if (b == 0) return true;
  }
  return false;
}

/// 判定文本编码。顺序是「先证伪、再判定」，每一步都不靠单个阈值赌：
///
/// 1. BOM（UTF-8 / UTF-16LE / UTF-16BE）——确定无疑；
/// 2. 含 NUL 字节 → 按 UTF-16 试解打分（无 BOM 的 UTF-16 读写的是 16 位码元，
///    只要出现 ASCII 就一定带 NUL）；两个方向都不像文本才算二进制；
/// 3. 不含 NUL → **严格** UTF-8 解码，且容忍样本末尾被切开的多字节字符；
/// 4. 不是 UTF-8 → GB18030（由上层用原生解码，失败再降级为"无法预览"）。
///
/// 曾经的实现用 `allowMalformed: true` 找 `U+FFFD` 来判断"不是 UTF-8"，
/// 但 4096 字节采样一旦切在汉字中间就会产生 `U+FFFD`，于是整篇 UTF-8 中文
/// 被误判成 GB18030 → 满屏乱码（真机 123KB 的 md 就是这样）。
PreviewEncoding detectPreviewEncoding(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return PreviewEncoding.utf8;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return PreviewEncoding.utf16le;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return PreviewEncoding.utf16be;
  }

  final sample = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;

  // 2. 含 NUL：要么是无 BOM 的 UTF-16，要么真是二进制
  if (looksBinary(sample)) {
    return _detectUtf16WithoutBom(sample) ?? PreviewEncoding.binary;
  }

  // 3. 严格 UTF-8（末尾截断不算错）
  if (_decodesAsUtf8(sample)) return PreviewEncoding.utf8;

  // 4. 退 GB18030
  return PreviewEncoding.gb18030;
}

/// 严格 UTF-8 判定；样本末尾被截断的**多字节字符**不算错误。
///
/// 采样是按字节切的，切点落在汉字（3 字节）/ emoji（4 字节）中间很常见，
/// 此时严格解码会在末尾抛 `FormatException`。做法是：整段解不通时，依次丢掉
/// 末尾 1–3 个字节再严格解一次——只要去掉那条被切断的尾巴就通，说明原文是
/// 合法 UTF-8。中途就坏（例如真 GBK 字节）时，丢尾巴救不回来。
bool _decodesAsUtf8(List<int> sample) {
  try {
    utf8.decode(sample);
    return true;
  } on FormatException {
    for (var cut = 1; cut <= 3 && sample.length - cut > 0; cut++) {
      try {
        utf8.decode(sample.sublist(0, sample.length - cut));
        return true;
      } on FormatException {
        continue;
      }
    }
    return false;
  }
}

/// 无 BOM 的 UTF-16：LE / BE 各试解一遍，比较"像文本"的程度。
///
/// 判定依据不是 NUL 比例（那只对 ASCII 为主的内容成立），而是解出来的码元：
/// - `goodRatio`：可打印码元（排除控制字符、孤立代理、U+FFFD）的比例；
/// - `structureRatio`：落在"常见文本区段"的比例（ASCII、CJK、假名、谚文、
///   Latin-1、全角标点……）。随机字节能解码成泰米尔文/西里尔文之类，看起来
///   可打印，但落在这些区段之外，所以这一步能把二进制挡掉。
///
/// 两个方向都像文本时取 ASCII 更多的那个：真正的编码方向会保留原文里的
/// 英文与标点，反方向通常整片变成生僻字。
PreviewEncoding? _detectUtf16WithoutBom(List<int> sample) {
  final usable = sample.length - (sample.length % 2);
  if (usable < 8) return null; // 太短：可能是图片头之类的二进制

  final le = _scoreUtf16Endian(sample, usable, little: true);
  final be = _scoreUtf16Endian(sample, usable, little: false);
  bool ok(_Score s) => s.goodRatio >= 0.95 && s.structureRatio >= 0.85;
  final leOk = ok(le);
  final beOk = ok(be);
  if (!leOk && !beOk) return null;
  if (leOk && !beOk) return PreviewEncoding.utf16le;
  if (beOk && !leOk) return PreviewEncoding.utf16be;
  return be.asciiCount > le.asciiCount
      ? PreviewEncoding.utf16be
      : PreviewEncoding.utf16le;
}

typedef _Score = ({double goodRatio, double structureRatio, int asciiCount});

/// 常见文本区段（用于把"可打印但其实是乱码"的二进制挡掉）。
bool _isCommonTextUnit(int unit) {
  if (unit == 0x09 || unit == 0x0A || unit == 0x0D) return true;
  if (unit >= 0x20 && unit <= 0x7E) return true; // ASCII
  if (unit >= 0xA0 && unit <= 0x24F) return true; // Latin-1 / 扩展
  if (unit >= 0x300 && unit <= 0x36F) return true; // 组合附加符号
  if (unit >= 0x370 && unit <= 0x4FF) return true; // 希腊/西里尔
  if (unit >= 0x2000 && unit <= 0x206F) return true; // 通用标点
  if (unit >= 0x3000 && unit <= 0x30FF) return true; // CJK 标点 + 假名
  if (unit >= 0x4E00 && unit <= 0x9FFF) return true; // CJK 统一表意
  if (unit >= 0xAC00 && unit <= 0xD7AF) return true; // 谚文
  if (unit >= 0xF900 && unit <= 0xFAFF) return true; // CJK 兼容
  if (unit >= 0xFE30 && unit <= 0xFE4F) return true; // CJK 兼容标点
  if (unit >= 0xFF00 && unit <= 0xFFEF) return true; // 全角
  return false;
}

_Score _scoreUtf16Endian(
  List<int> bytes,
  int usable, {
  required bool little,
}) {
  final units = <int>[];
  for (var i = 0; i + 1 < usable; i += 2) {
    units.add(
      little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  var total = 0;
  var good = 0;
  var structured = 0;
  var ascii = 0;
  var i = 0;
  while (i < units.length) {
    final unit = units[i];
    total++;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      // 高代理：必须紧跟低代理；配对成功两个码元都算好
      if (i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        total++;
        good += 2;
        structured += 2;
        i += 2;
        continue;
      }
      i++;
      continue; // 孤立高代理
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
      i++;
      continue; // 孤立低代理
    }
    if (unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) {
      i++;
      continue; // 控制字符
    }
    if (unit == 0xFFFD) {
      i++;
      continue;
    }
    good++;
    if (_isCommonTextUnit(unit)) structured++;
    if (unit >= 0x20 && unit <= 0x7E) ascii++;
    i++;
  }
  final t = total == 0 ? 1 : total;
  return (
    goodRatio: good / t,
    structureRatio: structured / t,
    asciiCount: ascii,
  );
}

/// 按编码解码预览文本；GB18030 需由平台通道处理，这里不支持。
String decodePreviewText(List<int> bytes, PreviewEncoding encoding) {
  switch (encoding) {
    case PreviewEncoding.utf8:
      final start = bytes.length >= 3 &&
              bytes[0] == 0xEF &&
              bytes[1] == 0xBB &&
              bytes[2] == 0xBF
          ? 3
          : 0;
      return utf8.decode(bytes.sublist(start), allowMalformed: true);
    case PreviewEncoding.utf16le:
    case PreviewEncoding.utf16be:
      final start = bytes.length >= 2 &&
              ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
                  (bytes[0] == 0xFE && bytes[1] == 0xFF))
          ? 2
          : 0;
      final units = <int>[];
      for (var i = start; i + 1 < bytes.length; i += 2) {
        units.add(
          encoding == PreviewEncoding.utf16le
              ? bytes[i] | (bytes[i + 1] << 8)
              : (bytes[i] << 8) | bytes[i + 1],
        );
      }
      return String.fromCharCodes(units);
    case PreviewEncoding.gb18030:
      throw UnsupportedError('GB18030 需要平台解码');
    case PreviewEncoding.binary:
      throw UnsupportedError('二进制');
  }
}

/// 把字节解码为预览文本，并给出截断信息。
///
/// 顺序：先按上限切片，再识别编码（UTF-16 优先），最后解码。超大的二进制
/// 不会因为要先整体解码而拖慢界面；GB18030 由控制器走平台通道。
PreviewVerdict buildPreview(
  List<int> bytes, {
  PreviewEncoding? encoding,
  bool truncated = false,
}) {
  final cut = truncated || bytes.length > kPreviewByteLimit;
  final slice = bytes.length > kPreviewByteLimit
      ? bytes.sublist(0, kPreviewByteLimit)
      : bytes;
  final detected = encoding ?? detectPreviewEncoding(slice);
  if (detected == PreviewEncoding.binary) {
    return const PreviewUnavailable('二进制文件，无法以文本预览');
  }
  if (detected == PreviewEncoding.gb18030) {
    return const PreviewUnavailable('GB18030 文件：需要平台解码');
  }
  return PreviewText(
    text: decodePreviewText(slice, detected),
    truncated: cut,
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
///
/// 分隔符要归一：Windows 服务端返回 `\`，POSIX 返回 `/`。旧实现把 `/` 写死，
/// 于是 Windows 下 `root\sub` 永远比不上 `root/` → 进任何子目录都被判成越界
/// （真机 bug：点子目录弹"已到达工作目录"）。盘符路径还要大小写不敏感。
bool isWithinRoot(String root, String child) {
  if (root.isEmpty) return true;
  final r = normalizeBrowsePath(root);
  final c = normalizeBrowsePath(child);
  final isWindowsDrive = RegExp(r'^[a-zA-Z]:').hasMatch(r);
  final rr = isWindowsDrive ? r.toLowerCase() : r;
  final cc = isWindowsDrive ? c.toLowerCase() : c;
  if (cc == rr) return true;
  final prefix = rr.endsWith('/') ? rr : '$rr/';
  return cc.startsWith(prefix);
}

/// 路径归一：`\` → `/`，折叠重复分隔符。只用于比较，不用于拼路径。
String normalizeBrowsePath(String path) {
  var s = path.replaceAll('\\', '/');
  while (s.contains('//')) {
    s = s.replaceAll('//', '/');
  }
  return s;
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

/// 是否为可渲染的 Markdown 文件（按扩展名判定，大小写不敏感）。
bool isMarkdownPath(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.md') || p.endsWith('.markdown');
}

/// 把 Markdown 文本切成可直接喂给 `renderMarkdownBlocks` 的分片。
///
/// 为什么要切：`renderMarkdownBlocks` 一次性返回整段文本的 Widget 列表，
/// 256KB 的 md（6 万行）会在一次 build 里建出上万个 Widget，直接卡死/爆内存。
/// 切成片之后配 `ListView.builder`，只有可见的分片才真正建树。
///
/// 切分规则（尽量不破坏语义）：
/// - 只在**块边界**切，即空行且不在围栏代码块内；
/// - 单片字符数达到 [maxChars] 才切，避免碎片过多；
/// - 单个超长块（没有空行）到 [maxChars] * 4 时强行切，防止一片撑爆。
List<String> chunkMarkdownText(String text, {int maxChars = 4000}) {
  if (text.isEmpty) return const [];
  final limit = maxChars <= 0 ? 1 : maxChars;
  final hardLimit = limit * 4;
  final lines = text.split('\n');
  final chunks = <String>[];
  final buf = <String>[];
  var size = 0;
  var fenceTicks = 0; // >0 表示在围栏代码块内（存开启围栏的反引号数）

  void flush() {
    if (buf.isEmpty) return;
    chunks.add(buf.join('\n'));
    buf.clear();
    size = 0;
  }

  for (final line in lines) {
    final trimmed = line.trim();
    // 围栏开关：只认 ≥3 个反引号开头、且其后没有反引号的行（与 md.dart 同规则）
    if (trimmed.startsWith('```')) {
      var ticks = 0;
      while (ticks < trimmed.length && trimmed.codeUnitAt(ticks) == 0x60) {
        ticks++;
      }
      if (ticks >= 3 && !trimmed.substring(ticks).contains('`')) {
        if (fenceTicks == 0) {
          fenceTicks = ticks;
        } else if (ticks >= fenceTicks &&
            trimmed.substring(ticks).trim().isEmpty) {
          fenceTicks = 0;
        }
      }
    }
    buf.add(line);
    size += line.length + 1;
    if (fenceTicks > 0) continue; // 围栏内部绝不切
    if (size >= hardLimit) {
      flush();
    } else if (size >= limit && trimmed.isEmpty) {
      flush();
    }
  }
  flush();
  return chunks;
}

