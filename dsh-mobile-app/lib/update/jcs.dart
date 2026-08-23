// RFC 8785 JSON Canonicalization Scheme（JCS）——Dart 实现。
// 与 tools/publish-update.mjs 的 JS 实现逐字节一致（同一金样本验证）。
// 语义要点：
// - 对象键按 UTF-16 码元升序排序；
// - 字符串转义采用 ES6 JSON.stringify 规则：\" \\ \b \t \n \f \r 短转义，其余 <0x20 用 \u00xx（小写）；
// - 数字采用 ECMAScript Number::toString 语义（最短往返表示）；整数值的 double 输出为 int 形式（1.0 → "1"）；
// - 范围限制：manifest 仅含小整数/短字符串/布尔，超出 JS 安全整数（2^53）的数字不做跨语言保证。
library;

String jcsString(String s) {
  final sb = StringBuffer('"');
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '"') {
      sb.write(r'\"');
    } else if (ch == '\\') {
      sb.write(r'\\');
    } else if (ch == '\b') {
      sb.write(r'\b');
    } else if (ch == '\t') {
      sb.write(r'\t');
    } else if (ch == '\n') {
      sb.write(r'\n');
    } else if (ch == '\f') {
      sb.write(r'\f');
    } else if (ch == '\r') {
      sb.write(r'\r');
    } else if (rune < 0x20) {
      sb.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
    } else {
      sb.write(ch);
    }
  }
  sb.write('"');
  return sb.toString();
}

String jcs(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) {
    if (value.isNaN || value.isInfinite) {
      throw const FormatException('JCS: non-finite number');
    }
    if (value is int) return value.toString();
    final d = value as double;
    if (d == 0) return '0'; // -0 → "0"（与 ES6 Number::toString 一致）
    var s = d.toString();
    // ES6 语义：无指数形式的整数值输出 int 形式（1.0 → "1"）；
    // 有指数（如 1e30 → "1e+30"）保持原样——不能盲目 toInt()（超出 int64 会饱和截断）。
    if (!s.contains('e') && !s.contains('E') && d == d.roundToDouble()) {
      s = d.toInt().toString();
    }
    return s;
  }
  if (value is String) return jcsString(value);
  if (value is List) return '[${value.map(jcs).join(',')}]';
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jcsString(k)}:${jcs(value[k])}').join(',')}}';
  }
  throw FormatException('JCS: unsupported type ${value.runtimeType}');
}
