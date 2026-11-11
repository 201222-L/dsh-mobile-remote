// issue #54（M3 Batch 1、note 1761）：工具卡结构化投影的纯逻辑层。
// issue #66（M3 Batch 2-A）：追加 todo_write / ask_user_question / skill 三种专用行。
//
// 服务端只负责从原始工具参数里派生安全字段（路径已用 mobileDisplayPath 去主机前缀）；
// App 侧在这里做 wire 模型解析、字段级降级与折叠行文案，不依赖 Flutter，便于单元测试。
//
// fail-open：任何字段缺省/类型不符都退化为 null，由调用方回退现有通用卡；绝不因摘要
// 异常让时间线整卡失败。

import 'l10n.dart';
import 'session_files_logic.dart';

/// 工具卡类型（与服务端 `summary.kind` 对齐）。
enum ToolCardKind { command, file, search, web, image, todo, question, skill }

ToolCardKind? _kindOf(Object? value) => switch (value) {
  'command' => ToolCardKind.command,
  'file' => ToolCardKind.file,
  'search' => ToolCardKind.search,
  'web' => ToolCardKind.web,
  'image' => ToolCardKind.image,
  'todo' => ToolCardKind.todo,
  'question' => ToolCardKind.question,
  'skill' => ToolCardKind.skill,
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

/// 稳定关联键（question/answer 的 id）：只做"字符串且 trim 后非空"的合法性判定，
/// **返回原始值不 trim** —— 必须与 `question/requested` 帧里的 `AskQuestion.id` 精确匹配
/// （models.dart 对该字段同样不 trim），否则带首尾空白的 id 永远命中不了「打开问询」。
String? _rawIdOf(Object? value) {
  if (value is! String) return null;
  return value.trim().isEmpty ? null : value;
}

/// issue #66：`todo_write` 的单条任务（status 保留 wire 原值，展示层再归一）。
class TodoCardItem {
  final String content;
  final String status;

  const TodoCardItem({required this.content, this.status = 'pending'});
}

/// issue #66：`ask_user_question` 的单个选项（只读回放用）。
class QuestionCardOption {
  final String label;
  final String? description;

  const QuestionCardOption({required this.label, this.description});
}

/// issue #66：`ask_user_question` 的单个问题（`id` 是关联"待答"的唯一依据）。
class QuestionCardItem {
  final String? id;
  final String? header;
  final String question;
  final List<QuestionCardOption> options;
  final bool multiSelect;

  const QuestionCardItem({
    this.id,
    this.header,
    required this.question,
    this.options = const <QuestionCardOption>[],
    this.multiSelect = false,
  });
}

/// issue #66：`ask_user_question` 结果里的单题答案（只读回放）。
class QuestionAnswerItem {
  final String questionId;
  final List<String> values;

  const QuestionAnswerItem({required this.questionId, required this.values});
}

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

  // issue #67（M3 Batch 2-B）：路径可点预览（服务端 cwd 相对路径 + 同现标记）。
  // 两者严格同现：任一不成立即都当缺省，`canPreviewFile` 是唯一判据。
  final String? relativePath;
  final bool previewable;

  // issue #66：todo_write / ask_user_question / skill 的专用字段（全部可空 = 缺省）。
  final List<TodoCardItem>? todoItems;
  final int? todoPending;
  final int? todoInProgress;
  final int? todoCompleted;
  final List<QuestionCardItem>? questions;
  final String? skillName;

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
    this.relativePath,
    this.previewable = false,
    this.todoItems,
    this.todoPending,
    this.todoInProgress,
    this.todoCompleted,
    this.questions,
    this.skillName,
  });

  bool get isCommand => kind == ToolCardKind.command;
  bool get isFile => kind == ToolCardKind.file;
  bool get isSearch => kind == ToolCardKind.search;
  bool get isWeb => kind == ToolCardKind.web;
  bool get isImage => kind == ToolCardKind.image;
  bool get isTodo => kind == ToolCardKind.todo;
  bool get isQuestion => kind == ToolCardKind.question;
  bool get isSkill => kind == ToolCardKind.skill;

  /// issue #67：该工具卡的路径是否可点开预览（**唯一判据**）。
  /// 服务端只在"目标完整验证通过"时同时下发 `relative` + `previewable:true`；
  /// 客户端再对 relative 做一次词法校验（二次夹取），任一不成立都不可点。
  bool get canPreviewFile => previewable && relativePath != null;

  /// 是否具备折叠行所需的最少信息；缺 summary 时调用方回退通用卡。
  bool get renderable => switch (kind) {
    ToolCardKind.command => command != null,
    ToolCardKind.file => filePath != null,
    ToolCardKind.search => pattern != null,
    ToolCardKind.web => url != null || query != null,
    ToolCardKind.image => filePath != null,
    ToolCardKind.todo => todoItems != null,
    ToolCardKind.question => questions != null && questions!.isNotEmpty,
    ToolCardKind.skill => skillName != null,
  };

  static ToolCallSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = _kindOf(json['kind']);
    final tool = _textOf(json['tool']);
    if (kind == null || tool == null) return null;
    final counts = _todoCountsOf(json['counts']);
    // issue #67：两字段严格同现——previewable 必须为 true 且 relative 通过客户端词法校验；
    // 任一不成立都按不可点处理（fail-closed），旧插件无字段时天然为 false。
    final relative = normalizeSessionRelativePath(json['relative']);
    final previewable = json['previewable'] == true && relative != null;
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
      relativePath: previewable ? relative : null,
      previewable: previewable,
      todoItems: _todoItemsOf(json['items']),
      todoPending: counts?.pending,
      todoInProgress: counts?.inProgress,
      todoCompleted: counts?.completed,
      questions: _questionsOf(json['questions']),
      // 服务端 skill 摘要是 `{kind, tool, name}`；`skillName` 兼容字段名变体。
      skillName: _textOf(json['name']) ?? _textOf(json['skillName']),
    );
  }
}

class _TodoCounts {
  final int pending;
  final int inProgress;
  final int completed;
  const _TodoCounts(this.pending, this.inProgress, this.completed);
}

/// counts 三键必须都是整数才采纳（缺一即整体缺省，避免展示半份计数）。
_TodoCounts? _todoCountsOf(Object? value) {
  if (value is! Map) return null;
  final pending = _intOf(value['pending']);
  final inProgress = _intOf(value['inProgress']);
  final completed = _intOf(value['completed']);
  if (pending == null || inProgress == null || completed == null) return null;
  return _TodoCounts(pending, inProgress, completed);
}

/// `items`：只接受 `{content: String, status?: String}`；空数组是合法值（!= null）。
List<TodoCardItem>? _todoItemsOf(Object? value) {
  if (value is! List) return null;
  final items = <TodoCardItem>[];
  for (final raw in value) {
    if (raw is! Map) continue;
    final content = raw['content'];
    if (content is! String) continue;
    final status = raw['status'];
    items.add(TodoCardItem(
      content: content,
      status: status is String ? status : 'pending',
    ));
  }
  return items;
}

/// `questions`：非 Map / 缺非空 `question` 的题逐题丢弃；其余字段逐项降级。
List<QuestionCardItem>? _questionsOf(Object? value) {
  if (value is! List) return null;
  final questions = <QuestionCardItem>[];
  for (final raw in value) {
    if (raw is! Map) continue;
    final question = _textOf(raw['question']);
    if (question == null) continue;
    final options = <QuestionCardOption>[];
    final rawOptions = raw['options'];
    if (rawOptions is List) {
      for (final option in rawOptions) {
        if (option is! Map) continue;
        final label = _textOf(option['label']);
        if (label == null) continue;
        options.add(QuestionCardOption(
          label: label,
          description: _textOf(option['description']),
        ));
      }
    }
    questions.add(QuestionCardItem(
      id: _rawIdOf(raw['id']),
      header: _textOf(raw['header']),
      question: question,
      options: options,
      multiSelect: _boolOf(raw['multiSelect']),
    ));
  }
  return questions;
}

/// `answers`：只接受 `{questionId: String, values: List<String>}`；其余逐项丢弃。
/// 与 §1.3 同口径：最终没有任何有效答案项 → 缺省（null），绝不从其它字段猜。
/// 注意：questionId 与题目 id 同规则原样保留（服务端 echo 的是原始 id），否则无法与题目配对。
List<QuestionAnswerItem>? _answersOf(Object? value) {
  if (value is! List) return null;
  final answers = <QuestionAnswerItem>[];
  for (final raw in value) {
    if (raw is! Map) continue;
    final questionId = _rawIdOf(raw['questionId']);
    if (questionId == null) continue;
    final rawValues = raw['values'];
    if (rawValues is! List) continue;
    final values = <String>[];
    for (final value in rawValues) {
      final text = _textOf(value);
      if (text != null) values.add(text);
    }
    answers.add(QuestionAnswerItem(questionId: questionId, values: values));
  }
  return answers.isEmpty ? null : answers;
}

/// `tool/result` 的结构化摘要（§3）：退出码/信号/搜索命中数 + issue #66 问询答案。
class ToolResultSummary {
  final int? exitCode;
  final String? signal;
  final String? stopped;
  final int? resultCount;

  /// issue #66：`ask_user_question` 的只读回放答案；缺失/不可解析即 null（绝不猜）。
  final List<QuestionAnswerItem>? answers;

  const ToolResultSummary({
    this.exitCode,
    this.signal,
    this.stopped,
    this.resultCount,
    this.answers,
  });

  static ToolResultSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final exitCode = _intOf(json['exitCode']);
    final signal = _textOf(json['signal']);
    final stopped = _textOf(json['stopped']);
    final resultCount = _intOf(json['resultCount']);
    final answers = _answersOf(json['answers']);
    if (exitCode == null &&
        signal == null &&
        stopped == null &&
        resultCount == null &&
        answers == null) {
      return null;
    }
    return ToolResultSummary(
      exitCode: exitCode,
      signal: signal,
      stopped: stopped,
      resultCount: resultCount,
      answers: answers,
    );
  }
}

/// 折叠行主文案（命令/路径/模式/URL/任务计数/问题数/skill 名）；信息不足返回 null
/// → 调用方回退通用卡。
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
    case ToolCardKind.todo:
      final items = summary.todoItems;
      if (items == null) return null;
      // M 优先用服务端 counts.completed；缺失时按归一后的 items 自行统计。
      final completed =
          summary.todoCompleted ??
          items.where((item) => item.status == 'completed').length;
      return L10n.t(
        '${items.length} 项任务 · $completed 完成',
        '${items.length} tasks · $completed done',
      );
    case ToolCardKind.question:
      final questions = summary.questions;
      if (questions == null) return null;
      return L10n.t('${questions.length} 个问题', '${questions.length} questions');
    case ToolCardKind.skill:
      final name = summary.skillName;
      // 前缀固定为 `skill`，不翻译工具/skill 名。
      return name == null ? null : 'skill · $name';
  }
}

/// issue #67：折叠行里可点的「路径段 + 其余文案」拆分。
///
/// 只在 file/image 卡、服务端两字段同现且 `relative` 通过客户端词法校验时返回。
/// `path` 是**显示用** `filePath`（点击目标用 `relative`，二者不互为推导——display
/// 可能被 clamp 或为 `~/…`/basename）；`suffix` 是折叠行文案去掉路径前缀后的部分
/// （含前导 ` · `，如 ` · 行 2–5`），保持既有 ink3 样式。
({String path, String suffix})? toolFoldPathParts(ToolCallSummary summary) {
  if (!summary.isFile && !summary.isImage) return null;
  if (!summary.canPreviewFile) return null;
  final path = summary.filePath;
  if (path == null) return null;
  final text = toolFoldText(summary) ?? '';
  if (!text.startsWith(path)) return null;
  return (path: path, suffix: text.substring(path.length));
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

/// issue #66：问询卡里带稳定 id 的题目 id 集合（缺 id 的题跳过——无法关联待答）。
Set<String> questionIdsOf(ToolCallSummary call) =>
    (call.questions ?? const <QuestionCardItem>[])
        .map((question) => question.id)
        .whereType<String>()
        .toSet();

/// issue #66：该工具行是否仍有待回答的问题（任一带 id 的题命中当前会话待答集合）。
bool questionCallPending(
  ToolCallSummary call,
  Set<String> pendingQuestionIds,
) => call.isQuestion && questionIdsOf(call).any(pendingQuestionIds.contains);

/// issue #66：某题答案文案（values 以 `、` 连接）；无答案项或 values 为空 → null。
String? answerTextOf(ToolResultSummary? result, String? questionId) {
  if (result == null || questionId == null) return null;
  for (final answer in result.answers ?? const <QuestionAnswerItem>[]) {
    if (answer.questionId != questionId) continue;
    return answer.values.isEmpty ? null : answer.values.join('、');
  }
  return null;
}

// ── issue #68（M3 Batch 2-C）：PTC 子调用行的展示纯函数 ─────────────────────

/// 子调用状态文案（与根工具卡 `_status()` 用词一致）。
String toolSubCallStatusLabel(String status) => switch (status) {
  'success' => L10n.t('成功', 'Succeeded'),
  'failed' => L10n.t('失败', 'Failed'),
  _ => L10n.t('运行中', 'Running'),
};

/// 根工具卡折叠行的子调用计数文案；[truncated] 时追加截断提示。
String toolSubCallCountLabel(int count, {bool truncated = false}) {
  final base = L10n.t('$count 个子调用', '$count sub-call${count == 1 ? '' : 's'}');
  return truncated ? '$base${L10n.t('（已截断）', ' (truncated)')}' : base;
}

/// 子调用行安全摘要：优先复用 `summary` 的折叠行文案；失败时追加安全错误码
/// （服务端 `text`，只含 `error.code`/`error.name`）。两者相同则去重；
/// 都不可用 → null（行只显示名称 + 状态）。
String? toolSubCallFoldText(
  ToolCallSummary? summary, {
  String? text,
  bool isError = false,
}) {
  final fold = summary == null ? null : toolFoldText(summary);
  final reason = isError ? _firstLineOf(text) : null;
  if (reason == null || reason == fold) return fold;
  return fold == null ? reason : '$fold · $reason';
}

String? _firstLineOf(String? text) {
  if (text == null) return null;
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return null;
  return collapsed.length <= 120
      ? collapsed
      : '${collapsed.substring(0, 119)}…';
}
