// issue #90：斜杠输入识别（纯函数，DSH 兼容）。
//
// 触发规则（对齐 DSH）：
// - `/` 出现在开头，或空白/标点之后才触发；前面是字母/数字/下划线（词内）不触发；
// - `//`、`https:/` 等 URL/路径斜杠豁免；
// - 光标向左扫到最近空白/标点得到 query；
// - 开头（leading）展示「命令 + 技能」；行内（inline）只展示技能。

/// 菜单允许的来源范围。
enum SlashMenuScope {
  /// 输入框开头：命令 + 技能。
  leading,

  /// 行内（空白/标点后）：仅技能。
  inline,
}

/// 当前光标处 `/` token。（[start] 指向 `/`，[query] 为 `/` 后的已输入部分。）
class SlashToken {
  final int start;

  /// 光标位置（query 右端）。
  final int end;

  /// 整个 token 的右端（含光标右侧同一 token 的剩余字符）；替换/高亮用。
  final int rightEnd;
  final String query;
  final SlashMenuScope scope;

  const SlashToken({
    required this.start,
    required this.end,
    required this.rightEnd,
    required this.query,
    required this.scope,
  });

  @override
  String toString() =>
      'SlashToken(start: $start, end: $end, query: "$query", scope: $scope)';
}

/// 已发消息文本中的斜杠 token（供用户气泡高亮；不做目录匹配）。
class SlashTextToken {
  final int start;
  final int end;
  final String name;
  final SlashMenuScope scope;

  const SlashTextToken({
    required this.start,
    required this.end,
    required this.name,
    required this.scope,
  });
}

// issue #95：按 DSH 把 Unicode 字母/数字视为 word char（CJK/重音字母等）；
// 否则 `你好/plan` 会被误判为行内技能。emoji 不是 word char，仍算边界。
const _tokenChar = r'[\p{L}\p{N}_-]';
final RegExp _tokenCharRe = RegExp(_tokenChar, unicode: true);
final RegExp _nameRe = RegExp('^$_tokenChar*\$', unicode: true);

bool _isWordChar(String ch) => ch.isNotEmpty && _tokenCharRe.hasMatch(ch);

bool _isWhitespaceOrPunctuation(String ch) {
  if (ch.isEmpty) return false;
  if (ch.trim().isEmpty) return true;
  // 与 DSH 一致：常见句读/括号等算边界；字母、数字、下划线不算。
  return !_isWordChar(ch) && ch != '_';
}

/// 判断 [slashIndex] 处的 `/` 是否满足 DSH 触发边界（不含 URL 豁免）。
bool _isSlashBoundary(String text, int slashIndex) {
  if (slashIndex <= 0) return true;
  final prev = text[slashIndex - 1];
  if (!_isWhitespaceOrPunctuation(prev)) return false;
  // `//`：前一个字符仍是 `/` 视为双斜杠（URL/路径），豁免。
  if (prev == '/') return false;
  // `https:/`、`x:/`：冒号前的 scheme 是 ASCII 字母/数字/+.- → 视为 URL/协议。
  // `https:/`、`x:/`：冒号后的斜杠按 URL/协议豁免（DSH 行为）。
  if (prev == ':') return false;
  return true;
}

/// 当前光标处的 `/` token；无触发返回 null。
///
/// [cursor] 省略时取文本末尾。光标可以停在 token 中间（query 取 `/` 到光标）。
SlashToken? slashTokenAt(String text, [int? cursor]) {
  final at = (cursor ?? text.length).clamp(0, text.length);
  var slash = -1;
  for (var i = at - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '/') {
      slash = i;
      break;
    }
    if (!_isWordChar(ch)) break; // 最近分隔符不是 `/`：当前不在斜杠 token 内
  }
  if (slash < 0) return null;
  if (!_isSlashBoundary(text, slash)) return null;
  final query = text.substring(slash + 1, at);
  if (!_nameRe.hasMatch(query)) return null;
  var rightEnd = at;
  while (rightEnd < text.length && _isWordChar(text[rightEnd])) {
    rightEnd++;
  }
  return SlashToken(
    start: slash,
    end: at,
    rightEnd: rightEnd,
    query: query,
    scope: slash == 0 ? SlashMenuScope.leading : SlashMenuScope.inline,
  );
}

/// 提取文本中所有可高亮的斜杠 token（DSH 边界 + 词尾空白/结束 + URL/词内豁免）。
///
/// 只做语法识别，是否命中命令/技能目录由调用方决定。
List<SlashTextToken> slashTextTokens(String text) {
  final tokens = <SlashTextToken>[];
  var i = 0;
  while (i < text.length) {
    if (text[i] != '/') {
      i++;
      continue;
    }
    if (!_isSlashBoundary(text, i)) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < text.length && _isWordChar(text[j])) {
      j++;
    }
    final name = text.substring(i + 1, j);
    if (name.isEmpty) {
      i = j + 1;
      continue;
    }
    // token 之后必须是空白/结束（DSH 词边界）；`/tmp/foo`、`x/name` 不成立。
    if (j < text.length) {
      final next = text[j];
      // issue #97 P2：`/compact.md`、`/compact.txt` 是绝对文件名/路径前缀，不是命令；
      // 点后接扩展名字符（或路径分隔符）一律按路径处理，不生成 token。
      if (next == '\\' ||
          next == '/' ||
          (next == '.' &&
              j + 1 < text.length &&
              _isWordChar(text[j + 1]))) {
        i = j + 1;
        continue;
      }
      // `.` 后无扩展名（句号收尾）仍算标点边界；其余标点也允许命令收尾，
      // 只有字母/数字等词内字符才不是 token 边界。
      if (next != '.' && !_isWhitespaceOrPunctuation(next)) {
        i = j;
        continue;
      }
    }
    tokens.add(SlashTextToken(
      start: i,
      end: j,
      name: name,
      scope: i == 0 ? SlashMenuScope.leading : SlashMenuScope.inline,
    ));
    i = j;
  }
  return tokens;
}

/// 菜单项过滤：名称/描述大小写不敏感子串匹配。
bool slashItemMatches(String query, String name, String? description) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return name.toLowerCase().contains(q) ||
      (description ?? '').toLowerCase().contains(q);
}
