// issue #54（M3 Batch 1、note 1761）：工具卡结构化投影的纯逻辑层。
//
// 服务端只负责从原始工具参数里派生安全字段（路径已用 mobileDisplayPath 去主机前缀）；
// App 侧在这里做 wire 模型解析、字段级降级与折叠行文案，不依赖 Flutter，便于单元测试。
//
// fail-open：任何字段缺省/类型不符都退化为 null，由调用方回退现有通用卡；绝不因摘要
// 异常让时间线整卡失败。

/// 工具卡类型（与服务端 `summary.kind` 对齐）。
enum ToolCardKind { command, file, search, web, image }

ToolCardKind? _kindOf(Object? value) => switch (value) {
  'command' => ToolCardKind.command,
  'file' => ToolCardKind.file,
  'search' => ToolCardKind.search,
  'web' => ToolCardKind.web,
  'image' => ToolCardKind.image,
  _ => null,
};

int? _intOf(Object? value) =>
    value is num && value.isFinite ? value.toInt() : null;

String? _textOf(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

bool _boolOf(Object? value) => value == true;

/// `tool/call` 的结构化摘要（服务端已派生 display 路径，见 §2）。
class ToolCallSummary {
  final ToolCardKind kind;
  final String tool;
  final String? command;
  final String? workdir;
  final bool background;
  final String? description;
  final String? filePath;
  final int? offset;
  final int? limit;
  final int? sizeKb;
  final int? added;
  final int? deleted;
  final String? diff;
  final bool diffTruncated;
  final String? pattern;
  final String? path;
  final String? include;
  final String? url;
  final String? query;

  const ToolCallSummary({
    required this.kind,
    required this.tool,
    this.command,
    this.workdir,
    this.background = false,
    this.description,
    this.filePath,
    this.offset,
    this.limit,
    this.sizeKb,
    this.added,
    this.deleted,
    this.diff,
    this.diffTruncated = false,
    this.pattern,
    this.path,
    this.include,
    this.url,
    this.query,
  });

  bool get isCommand => kind == ToolCardKind.command;
  bool get isFile => kind == ToolCardKind.file;
  bool get isSearch => kind == ToolCardKind.search;
  bool get isWeb => kind == ToolCardKind.web;
  bool get isImage => kind == ToolCardKind.image;

  /// 是否具备折叠行所需的最少信息；缺 summary 时调用方回退通用卡。
  bool get renderable => switch (kind) {
    ToolCardKind.command => command != null,
    ToolCardKind.file => filePath != null,
    ToolCardKind.search => pattern != null,
    ToolCardKind.web => url != null || query != null,
    ToolCardKind.image => filePath != null,
  };

  static ToolCallSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = _kindOf(json['kind']);
    final tool = _textOf(json['tool']);
    if (kind == null || tool == null) return null;
    return ToolCallSummary(
      kind: kind,
      tool: tool,
      command: _textOf(json['command']),
      workdir: _textOf(json['workdir']),
      background: _boolOf(json['background']),
      description: _textOf(json['description']),
      filePath: _textOf(json['filePath']),
      offset: _intOf(json['offset']),
      limit: _intOf(json['limit']),
      sizeKb: _intOf(json['sizeKb']),
      added: _intOf(json['added']),
      deleted: _intOf(json['deleted']),
      diff: json['diff'] is String ? json['diff'] as String : null,
      diffTruncated: _boolOf(json['diffTruncated']),
      pattern: _textOf(json['pattern']),
      path: _textOf(json['path']),
      include: _textOf(json['include']),
      url: _textOf(json['url']),
      query: _textOf(json['query']),
    );
  }
}

/// `tool/result` 的结构化摘要（§3）：退出码/信号/搜索命中数，解析不到即缺省。
class ToolResultSummary {
  final int? exitCode;
  final String? signal;
  final String? stopped;
  final int? resultCount;

  const ToolResultSummary({
    this.exitCode,
    this.signal,
    this.stopped,
    this.resultCount,
  });

  static ToolResultSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final exitCode = _intOf(json['exitCode']);
    final signal = _textOf(json['signal']);
    final stopped = _textOf(json['stopped']);
    final resultCount = _intOf(json['resultCount']);
    if (exitCode == null &&
        signal == null &&
        stopped == null &&
        resultCount == null) {
      return null;
    }
    return ToolResultSummary(
      exitCode: exitCode,
      signal: signal,
      stopped: stopped,
      resultCount: resultCount,
    );
  }
}

/// 折叠行主文案（命令/路径/模式/URL）；信息不足返回 null → 调用方回退通用卡。
String? toolFoldText(ToolCallSummary summary) {
  switch (summary.kind) {
    case ToolCardKind.command:
      final command = summary.command;
      return command == null ? null : '\$ $command';
    case ToolCardKind.file:
      final path = summary.filePath;
      if (path == null) return null;
      if (summary.tool == 'read') {
        final offset = summary.offset;
        final limit = summary.limit;
        if (offset != null && limit != null) {
          return '$path · 行 $offset–${offset + limit - 1}';
        }
        if (offset != null) return '$path · 从第 $offset 行';
        if (limit != null) return '$path · 前 $limit 行';
      }
      return path;
    case ToolCardKind.search:
      final pattern = summary.pattern;
      if (pattern == null) return null;
      final scope = summary.path;
      final include = summary.include;
      final suffix = [
        if (scope != null) scope,
        if (include != null) include,
      ].join(' · ');
      return suffix.isEmpty ? pattern : '$pattern · $suffix';
    case ToolCardKind.web:
      return summary.url ?? summary.query;
    case ToolCardKind.image:
      return summary.filePath;
  }
}

/// 折叠行文件统计（`NKB` / `+x −y`）；无该信息返回 null。
String? toolFileStats(ToolCallSummary summary) {
  if (summary.kind != ToolCardKind.file) return null;
  final parts = <String>[];
  final sizeKb = summary.sizeKb;
  if (sizeKb != null && sizeKb >= 0) parts.add('${sizeKb}KB');
  final added = summary.added;
  final deleted = summary.deleted;
  if (added != null || deleted != null) {
    parts.add('+${added ?? 0} −${deleted ?? 0}');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 命令退出状态胶囊：非零退出码 / 信号 / 停止；正常结束（0/null）不显示。
String? toolExitBadge(ToolResultSummary? result) {
  if (result == null) return null;
  final signal = result.signal;
  if (signal != null) return 'signal: $signal';
  final stopped = result.stopped;
  if (stopped != null) return '已停止';
  final exitCode = result.exitCode;
  if (exitCode != null && exitCode != 0) return 'exit $exitCode';
  return null;
}

/// 搜索命中数文案（有则显示）。
String? toolResultCountBadge(ToolCallSummary summary, ToolResultSummary? result) {
  final count = result?.resultCount;
  if (count == null || !summary.isSearch) return null;
  return summary.tool == 'grep' ? '$count 个匹配' : '$count 个结果';
}

/// 是否内联展示 diff：服务端给了 diff 且未标截断。
bool toolHasInlineDiff(ToolCallSummary summary) =>
    summary.kind == ToolCardKind.file && summary.diff != null && summary.diff!.isNotEmpty;
