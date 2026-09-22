import 'l10n.dart';
import 'models.dart';

enum TimelineMode { ordinary, debug }

/// 内核 `SessionEventMap` 中属于「请求快照 / 事件重建 / 生命周期」的记录：
/// 任何模式都不进时间线，也不允许经详情端点回到 UI。
/// 服务端 `REPLAY_IGNORED_TYPES` 是权威过滤（lib/index.js），这里是纵深防御——
/// 旧版或异常服务端不得把系统提示词、请求头、压缩摘要（替换后的上下文快照）
/// 或重试流记录带进移动端。
/// 注意：token 级 `assistant/chunk` / `assistant/live-chunk` 不在此列——
/// 它们是流式草稿，由渲染分支显式消费。
const hiddenTimelineTypes = <String>{
  'request/header',
  'request/context',
  // LLM 请求快照：data 里带 system（系统提示词）与 messages（对话正文），
  // 与 request/header 同类 —— 任何模式都不进时间线，也不允许经详情端点回到 UI。
  'session/title-llm-request',
  'web/deepseek-search-llm-request',
  'session/end-seed',
  'step/start',
  'step/end',
  'system/message',
  'compaction/end',
  'compaction/start',
  // summary 的正文就是替换 shadowed 区间后的上下文快照（含 rawOutput），永不呈现。
  'compaction/summary',
  'compaction/prune',
  // 重试/中断时落盘的一次尝试的原始 stream 记录（事件重建元数据）。
  'assistant/attempt',
  // 队列投影，单独经 mobile/queue 帧承载。
  'agent/inbox/spliced',
};

/// 协议/运行时 bookkeeping：仍保留在时间线模型中（seq 游标、去重、详情指针、
/// 调试审阅都不丢），但普通模式不渲染——默认视图只呈现有阅读价值的事件，
/// 避免 `session/title`、`feedback/record` 这类原始类型名铺屏。
/// 真正未知的新事件类型**不在**此列：事件保真契约要求保留而不是静默丢弃。
const debugOnlyTimelineTypes = <String>{
  'session/title',
  'model/selection',
  'sandbox/mode',
  'agent-preset/selected',
  'subagent/descriptor',
  'subagent/catalog',
  'goal/change',
  'feedback/record',
  'feedback/message-put',
  'feedback/message-delete',
  'team/member',
  'team/task',
  'team/message/queued',
  'team/message/delivered',
  'command/run',
  'command/done',
  'approval/policy',
  'tool/ptc-dispatch-start',
  'tool/ptc-dispatch',
  // 与内核 KNOWN_SESSION_EVENT_TYPES 对差补齐（此前遗漏 → 普通模式会显示裸类型名）：
  'deliverables/presented',
  'hook/invoked',
  'hook/result',
  'llm/retry',
  'llm/retry-started',
  'plan/mode',
  'permission/preset',
  'schedule/change',
  'session-log-deepseek/delivery-accepted',
  'subagent/model-selection-policy',
  'tool-workflow/agent-start',
  'tool-workflow/agent-end',
  'tool-workflow/run-start',
  'tool-workflow/run-end',
};

/// LLM 请求快照的段边界匹配（与服务端 `LLM_REQUEST_TYPE_PATTERN` 同规则）：
/// 匹配 `session/title-llm-request`、`web/deepseek-search-llm-request`、
/// `web/<provider>-llm-request`、`future/llm-request`；不误伤 `future/llm-request-note`。
final RegExp llmRequestTypePattern = RegExp(r'(?:^|[/-])llm-request$');

/// 事件可见性的唯一实现：TimelineReducer 与 ChatScreen 共用，避免两处规则分叉。
bool timelineTypeVisibleIn(TimelineMode mode, String type) {
  if (hiddenTimelineTypes.contains(type) || llmRequestTypePattern.hasMatch(type)) return false;
  return mode == TimelineMode.debug || !debugOnlyTimelineTypes.contains(type);
}

/// 工具调用关联 id 的唯一实现。
/// 内核实参缺 callId 时退化为显式不完整的 id（而不是把不同调用并成一张卡）。
String timelineCallIdOf(Map<String, dynamic>? data, int? seq, [int fallback = 0]) {
  final id = (data?['callId'] ?? data?['toolCallId'] ?? data?['id'])?.toString();
  if (id != null && id.isNotEmpty) return id;
  return 'unavailable-${seq ?? fallback}';
}

/// 详情正文上限：摘要被服务端 clamp，但**详情返回的是原始事件**（上限 8 MiB），
/// 直接进 markdown 解析 / 文本布局会造成卡顿与内存尖峰 —— 统一在渲染前截断。
const timelineDetailTextMax = 20000;

String clampTimelineDetailText(String text, {int max = timelineDetailTextMax}) => text.length <= max
    ? text
    : '${text.substring(0, max)}\n…（详情已截断：共 ${text.length} 字，上方为前 $max 字）';

/// 已知事件的可读标题；未知类型原样返回类型名（事件保真契约：不静默丢弃）。
String timelineTitleFor(String type) {
  switch (type) {
    case 'todo/write':
      return L10n.t('任务清单已更新', 'Task list updated');
    case 'question/requested':
      return L10n.t('等待回答', 'Question requested');
    case 'question/resolved':
      return L10n.t('问询已处理', 'Question resolved');
    case 'approval/requested':
      return L10n.t('等待审批', 'Approval requested');
    case 'approval/resolved':
      return L10n.t('审批已处理', 'Approval resolved');
    // 内核 durable 审批事件（历史回放权威源，瞬态 mobile/frame 只覆盖实时）。
    case 'approval/asked':
      return L10n.t('等待审批', 'Approval requested');
    case 'approval/decided':
      return L10n.t('审批已处理', 'Approval decided');
    case 'session/jobs':
      return L10n.t('后台任务状态', 'Background jobs');
    case 'turn/start':
      return L10n.t('轮次开始', 'Turn started');
    case 'turn/end':
      return L10n.t('轮次结束', 'Turn ended');
    default:
      return type;
  }
}

/// 系统注入的噪声文本判定（上下文快照 / 后台任务通知）——PC 端 GUI 也不显示。
/// 模型侧与渲染侧共用同一份关键词，避免两边判据漂移。
bool timelineIsInjectedNoise(String text) =>
    text.contains('Current runtime context') ||
    text.contains('This snapshot supersedes') ||
    text.startsWith('background job ');

/// 详情正文：**只认服务端给出的规范化 `text`**（与事件摘要同一个 `blocksToText` 口径，
/// 已跳过 `reasoning` 与内部块）；字段缺失时返回 null。
///
/// 客户端**不得**自行递归拼接 `message.content` 兜底——那会把 `reasoning` 块并进正文，
/// 使思维链在折叠块之外重复出现（issue #1 需求变更记录）。
String? timelineDetailText(Map<String, dynamic> eventData) {
  final text = eventData['text'];
  return text is String ? text : null;
}

/// 详情是否带来正文增量：服务端 `detail.textChars`（未截断正文长度）大于当前可见正文长度。
/// 普通模式据此只在确有增量时才显示加载入口；调试模式提供原始事件入口，不受此限。
bool timelineHasTextIncrement(int? detailTextChars, int visibleChars) =>
    detailTextChars != null && detailTextChars > visibleChars;

enum TimelineItemKind { message, tool, divider, event }

class TimelineItem {
  final TimelineItemKind kind;
  final String id;
  final String type;
  final int? seq;
  final String title;
  final String text;
  final Map<String, dynamic> data;
  final String? callId;
  final String? toolName;
  final String status;
  final bool isError;
  final bool detailAvailable;
  final bool filteredInOrdinary;
  /// 详情正文长度提示（`detail.textChars`）：与摘要同口径的未截断正文长度。
  final int? detailTextChars;

  const TimelineItem({
    required this.kind,
    required this.id,
    required this.type,
    this.seq,
    this.title = '',
    this.text = '',
    this.data = const {},
    this.callId,
    this.toolName,
    this.status = 'complete',
    this.isError = false,
    this.detailAvailable = false,
    this.filteredInOrdinary = false,
    this.detailTextChars,
  });

  bool visibleIn(TimelineMode mode) => mode == TimelineMode.debug || !filteredInOrdinary;
}

/// Tool activity 的合并结果（callId → 生命周期）。
/// 只存「合并后的规范值」，不再保留 delta 中间态——参数以 `arguments` 为唯一事实，
/// 避免出现两份可漂移的参数文本。
class ToolLifecycle {
  final String id;
  final String name;
  /// 规范参数文本：流式期间为已累积的 delta，`tool/call` 到达后被整串替换。
  final String arguments;
  final String result;
  final bool isError;
  final String status;
  /// 锚点 seq = 调用事件所在位置（历史与实时收敛到同一处）。
  final int? seq;
  /// 该卡已吸收的最大 seq（快照对账/列表排序判定用）。
  final int? latestSeq;
  /// 详情指针：优先指向结果事件，其次调用事件；不指向历史里不存在的 delta seq。
  final int? detailSeq;
  final bool detailAvailable;
  final List<Map<String, dynamic>> images;
  final List<Map<String, dynamic>> files;

  const ToolLifecycle({
    required this.id,
    required this.name,
    this.arguments = '',
    this.result = '',
    this.isError = false,
    this.status = 'running',
    this.seq,
    this.latestSeq,
    this.detailSeq,
    this.detailAvailable = false,
    this.images = const [],
    this.files = const [],
  });
}

/// Pure, fixture-friendly projection shared by historical and live event delivery.
///
/// 这里是**规则**的唯一实现：[tools] 保存合并后的 Tool activity（ChatScreen 只做
/// Flutter 侧投影）、[items] 保存纯模型顺序、可见性/标题/关联 id 由本文件的
/// 顶层函数提供。渲染层不再复刻这些判据，避免「模型说 A、界面显示 B」。
/// 可见性以 `TimelineItem.filteredInOrdinary` 表达（而非构造时固定模式），
/// 因此同一份投影可同时回答普通/调试两种模式的呈现问题。
class TimelineReducer {
  final List<TimelineItem> items = [];
  final Map<String, ToolLifecycle> tools = {};
  final Set<int> _seenSeq = {};
  int _fallbackId = 0;
  int _identity = 0;

  void reset() {
    items.clear();
    tools.clear();
    _seenSeq.clear();
  }

  bool apply(ChatEvent event) {
    final seq = event.seq;
    if (seq != null && !_seenSeq.add(seq)) return false;
    if (hiddenTimelineTypes.contains(event.type)) return true;
    final data = event.data ?? const <String, dynamic>{};
    switch (event.type) {
      case 'tool/call':
        // tool/call 携带完整 arguments，必须替换而不是追加。
        _mergeTool(event, data, replaceArguments: true);
        return true;
      case 'assistant/chunk':
      case 'assistant/live-chunk':
        if (data['toolCall'] != null || data['argumentsDelta'] != null) {
          _mergeTool(event, data);
        }
        return true;
      case 'tool/result':
        _mergeTool(event, data);
        return true;
      default:
        _appendNonTool(event, data);
    }
    return true;
  }

  /// Tool activity 合并规则的唯一实现。
  ///
  /// - 只有 `assistant/chunk` 的 tool-call-delta 做**增量拼接**；`tool/call` 携带的是内核实参
  ///   `block.arguments` 整串（`appendToolCall`），若也拼接会把参数重复一遍。
  /// - 锚点 seq 取调用事件：历史只含 `tool/call`，实时先 delta 后 call，两者必须落在同一位置。
  /// - `detailSeq` 只指向 durable 事件（result / call）——delta 的 seq 不落历史，指向它必然 404。
  void _mergeTool(ChatEvent event, Map<String, dynamic> data, {bool replaceArguments = false}) {
    final seq = event.seq;
    final isResult = event.type == 'tool/result';
    final callId = timelineCallIdOf(data, seq, _fallbackId++);
    final current = tools[callId];
    final delta = _string(data['argumentsDelta']) ?? '';
    final settled = current?.status == 'success' || current?.status == 'failed';
    final isCall = event.type == 'tool/call';
    // 详情指针取「信息量最大的 durable 事件」：有结果就指向结果，
    // 否则指向调用事件；仅 delta 存在时先沿用（那时还没有 durable 记录）。
    final hasResult = current != null && current.result.isNotEmpty;
    final next = ToolLifecycle(
      id: callId,
      name: _string(data['name']) ?? _string(data['toolCall']) ?? current?.name ?? L10n.t('工具', 'Tool'),
      arguments: replaceArguments ? (_string(data['arguments']) ?? current?.arguments ?? '') : '${current?.arguments ?? ''}$delta',
      result: isResult ? (_string(data['text']) ?? _string(data['result']) ?? '') : (current?.result ?? ''),
      isError: isResult ? data['isError'] == true : (current?.isError ?? false),
      status: isResult
          ? (data['isError'] == true ? 'failed' : 'success')
          : (settled ? current!.status : 'running'),
      seq: isCall && seq != null ? seq : (current?.seq ?? seq),
      latestSeq: _maxSeq(_maxSeq(current?.latestSeq, current?.seq), seq),
      detailSeq: isResult && seq != null
          ? seq
          : (isCall && seq != null && !hasResult ? seq : (current?.detailSeq ?? seq)),
      detailAvailable: event.detailAvailable || (current?.detailAvailable ?? false),
      images: isResult ? _maps(data['images']) : (current?.images ?? const []),
      files: isResult ? _maps(data['files']) : (current?.files ?? const []),
    );
    tools[callId] = next;
    _upsertTool(next, event);
  }

  void _appendNonTool(ChatEvent event, Map<String, dynamic> data) {
    final sourceKind = _string(data['sourceKind']);
    final text = _string(data['text']) ?? '';
    final injected = event.type == 'user/message' &&
        ((sourceKind != null && sourceKind != 'user') || timelineIsInjectedNoise(text));
    final kind = event.type == 'user/message' || event.type == 'assistant/message'
        ? TimelineItemKind.message
        : event.type == 'turn/start' || event.type == 'turn/end'
            ? TimelineItemKind.divider
            : TimelineItemKind.event;
    items.add(TimelineItem(
      kind: kind,
      id: '${event.type}:${event.seq ?? _identity++}',
      type: event.type,
      seq: event.seq,
      title: timelineTitleFor(event.type),
      text: text,
      data: data,
      status: 'complete',
      // 失败判定只认结构化字段（不按事件名里的 error/fail 关键词猜）。
      isError: data['isError'] == true,
      detailAvailable: event.detailAvailable,
      detailTextChars: event.detailTextChars,
      // 注入噪声 + 普通模式折叠的协议元数据都不进默认视图；调试模式仍可审阅。
      filteredInOrdinary: injected || !timelineTypeVisibleIn(TimelineMode.ordinary, event.type),
    ));
  }

  void _upsertTool(ToolLifecycle tool, ChatEvent event) {
    final index = items.indexWhere((item) => item.kind == TimelineItemKind.tool && item.callId == tool.id);
    final item = TimelineItem(
      kind: TimelineItemKind.tool,
      id: 'tool:${tool.id}',
      type: 'tool/activity',
      seq: tool.seq,
      title: tool.name,
      text: tool.result.isNotEmpty ? tool.result : tool.arguments,
      data: {
        'callId': tool.id,
        'name': tool.name,
        'arguments': tool.arguments,
        'result': tool.result,
        'status': tool.status,
        'isError': tool.isError,
        'images': tool.images,
        'files': tool.files,
      },
      callId: tool.id,
      toolName: tool.name,
      status: tool.status,
      isError: tool.isError,
      detailAvailable: tool.detailAvailable,
    );
    if (index >= 0) {
      final existing = items[index];
      final existingSettled = existing.status == 'success' || existing.status == 'failed';
      if (existingSettled && event.type == 'tool/call' && item.seq != existing.seq) {
        // History is fed newest-first by the Flutter adapter; when the invocation
        // arrives after its result, anchor the grouped card at invocation position.
        items.removeAt(index);
        items.add(item);
      } else {
        items[index] = item;
      }
    } else {
      items.add(item);
    }
  }

  static String? _string(Object? value) => value is String ? value : value?.toString();
  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const [];
}

int? _maxSeq(int? a, int? b) => a == null ? b : (b == null || a >= b ? a : b);
