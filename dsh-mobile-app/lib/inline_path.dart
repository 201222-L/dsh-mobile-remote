/// issue #83：正文行内代码里的**绝对文件路径**识别（纯函数，无 Flutter 依赖）。
///
/// 只识别绝对路径：POSIX `/...` 与 Windows `C:\...` / `C:/...`。
/// 不识别相对路径、URL、`~/...`（服务端不展开 home，贸然链接会变成死入口）。
/// 识别只代表“可点 + 需用户确认”，不代表文件存在；是否可读由 `/m/api/files` 判定。
library;

const int inlinePathMaxLength = 4096;

final RegExp _windowsDrive = RegExp(r'^[A-Za-z]:[\\/]');
final RegExp _control = RegExp(r'[\u0000-\u001f\u007f]');

/// 行内代码是否像一个可让用户确认打开的绝对文件路径。
bool looksLikeInlineFilePath(String code) {
  final text = code.trim();
  if (text.isEmpty || text.length > inlinePathMaxLength) return false;
  if (_control.hasMatch(text)) return false;
  // 空白/换行容易把代码片段误判成路径；路径中含空格时保持纯文本。
  if (RegExp(r'\s').hasMatch(text)) return false;
  if (text.contains('://')) return false; // URL，不是本地路径
  if (text.startsWith('~/') || text == '~') return false;

  final isPosix = text.startsWith('/') && !text.startsWith('//');
  final isWindows = _windowsDrive.hasMatch(text);
  if (!isPosix && !isWindows) return false;

  // 目录/根路径/空 basename 不做文件预览入口。
  if (text.endsWith('/') || text.endsWith('\\')) return false;
  final base = text.split(RegExp(r'[/\\]')).last;
  if (base.isEmpty || base == '.' || base == '..') return false;
  return true;
}

/// 路径展示用文件名（仅取 basename，不泄露/拼接其它目录）。
String inlinePathBasename(String code) {
  final text = code.trim();
  final parts = text.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? text : parts.last;
}
