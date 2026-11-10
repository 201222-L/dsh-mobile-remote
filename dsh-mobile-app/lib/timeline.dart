import 'dart:convert';

import 'l10n.dart';
import 'models.dart';
import 'tool_cards.dart';

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
  // issue #53：`deliverables/presented` 由轮末卡片专用渲染收口（_buildInto 显式分支）；
  // 旧插件没有该投影 data 时退回调试可见，普通模式不显示裸事件卡。
  'deliverables/presented',
  // issue #53 / ADR 0027 §4：新插件已把它移出移动时间线；旧插件仍会下发，
  // 归入调试可见（普通模式不出现裸 `workspace/changes` 空卡）。
  'workspace/changes',
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
  // issue #61：协议生命周期事件不构成对话内容——后台任务在会话头部呈现、问询/审批在
  // 弹卡与工具行内呈现，独立成卡会与 `ask_user_question` 工具卡重复。普通模式不渲染
  // 裸协议卡；调试模式仍可审阅（事件仍保留在时间线模型与详情指针里）。
  // 注意：待答/审批弹卡来自 store 的 pending 快照与 `mobile/frame` 帧（chat_screen
  // 的 `_question`/`_approval`），不依赖这些历史事件卡，因此归入调试不影响待答能力。
  'job/registered',
  'job/settled',
  'session/jobs',
  'question/requested',
  'question/resolved',
  'approval/requested',
  'approval/resolved',
  'approval/asked',
  'approval/decided',
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

/// 工具名解析：**调用 id 不是工具名**（v3.1.5 修复）。
///
/// 症状：历史回放里已结束的工具卡标题显示裸 `call_00_...`，而进行中的那张正常显示
/// `pwsh`。根因是服务端 `tool/result` 摘要在拿不到工具名时用 callId 兜底写进 `name`，
/// 而合并规则 `data['name'] ?? … ?? current?.name` 让结果事件覆盖了 `tool/call` 学到的
/// 真名——只有成功的调用在历史里才带结果事件，所以恰好「历史=裸 id、实时=真名」。
///
/// 服务端已停止该兜底；此处再把「name == callId」一律视为未知，形成双保险：
/// [fallback] 传上一次已知的工具名，即可让结果事件永不夺走真名。
String timelineToolNameOf(
  Map<String, dynamic>? data, {
  required String callId,
  required String fallback,
}) {
  for (final candidate in <Object?>[data?['name'], data?['toolCall']]) {
    final text = candidate is String ? candidate : candidate?.toString();
    if (text != null && text.isNotEmpty && text != callId) return text;
  }
  return fallback;
}

/// 详情正文上限：摘要被服务端 clamp，但**详情返回的是原始事件**（上限 8 MiB），
/// 直接进 markdown 解析 / 文本布局会造成卡顿与内存尖峰 —— 统一在渲染前截断。
const timelineDetailTextMax = 20000;

String clampTimelineDetailText(String text, {int max = timelineDetailTextMax}) => text.length <= max
    ? text
    : '${text.substring(0, max)}\n…（详情已截断：共 ${text.length} 字，上方为前 $max 字）';

/// 调试模式「原始事件」JSON 预览上限（v3.1.6，app-audit ①3）。
///
/// 详情端点返回的是**原始事件**（服务端上限 8 MiB），调试模式把它缩进美化后塞进
/// `SelectableText`：此前上限 240000 字符 —— 单段 24 万字符的文本布局足以卡住主线程
/// （掉帧甚至 ANR），且每次 build 都要重新 `JsonEncoder.withIndent` 编码一次。
/// 预览是给人肉眼扫一眼的，4000 字符足够；超长时明确标注已截断。
const timelineDebugPreviewMax = 4000;

/// 原始事件 → 调试预览文本（纯函数，便于单测）。
/// 缩进美化后按 [max] 截断；非 JSON 可编码的值退化为 `toString()`。
String timelineDebugPreview(Object? value, {int max = timelineDebugPreviewMax}) {
  if (value == null) return '';
  String text;
  try {
    text = JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    text = value.toString();
  }
  if (text.length <= max) return text;
  return '${text.substring(0, max)}\n… (debug preview truncated: ${text.length} chars total)';
}

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

  /// issue #68（M3 Batch 2-C）：PTC 子调用树（DFS 先序扁平列表；根下第 1 层 depth=1）。
  final List<ToolSubCall> subCalls;
  /// 子调用树是否因服务端 50 上限 / 深度 16 / App 50 上限而截断。
  final bool subCallsTruncated;

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
    this.subCalls = const [],
    this.subCallsTruncated = false,
  });

  ToolLifecycle copyWith({
    String? id,
    String? name,
    String? arguments,
    String? result,
    bool? isError,
    String? status,
    int? seq,
    int? latestSeq,
    int? detailSeq,
    bool? detailAvailable,
    List<Map<String, dynamic>>? images,
    List<Map<String, dynamic>>? files,
    List<ToolSubCall>? subCalls,
    bool? subCallsTruncated,
  }) => ToolLifecycle(
    id: id ?? this.id,
    name: name ?? this.name,
    arguments: arguments ?? this.arguments,
    result: result ?? this.result,
    isError: isError ?? this.isError,
    status: status ?? this.status,
    seq: seq ?? this.seq,
    latestSeq: latestSeq ?? this.latestSeq,
    detailSeq: detailSeq ?? this.detailSeq,
    detailAvailable: detailAvailable ?? this.detailAvailable,
    images: images ?? this.images,
    files: files ?? this.files,
    subCalls: subCalls ?? this.subCalls,
    subCallsTruncated: subCallsTruncated ?? this.subCallsTruncated,
  );
}

/// issue #68（M3 Batch 2-C）：根工具卡内的一个 PTC 子调用（App 内部模型）。
///
/// wire 字段与服务端 `tool/ptc-dispatch*` 投影一致（docs/03-api.md §6.24.1）：
/// `callId` 即内核 `subCallId`；`parentCallId` 指根工具或另一子调用；`status` 为
/// `running` / `success` / `failed`；`summary` 是折叠行安全摘要；`text` 仅失败安全错误码。
class ToolSubCall {
  final String callId;
  final String parentCallId;
  final String rootCallId;
  final String name;
  final String status;
  final ToolCallSummary? summary;
  final String? text;
  final bool isError;

  /// 首个事件的 seq（排序锚点；同父按首次出现顺序）。
  final int seq;

  /// 物化时计算：根下第 1 层 = 1（1..16 才渲染）。
  final int depth;

  const ToolSubCall({
    required this.callId,
    required this.parentCallId,
    this.rootCallId = '',
    this.name = '',
    this.status = 'running',
    this.summary,
    this.text,
    this.isError = false,
    this.seq = 0,
    this.depth = 1,
  });
}

/// issue #68：PTC 事件是否可被 reducer 消费（服务端契约的必填 id）。
/// data 缺失/非法 → 不消费，保持既有 debug-only 裸事件卡行为（旧插件/坏数据可调试）。
bool ptcEventConsumable(Map<String, dynamic>? data) {
  final callId = data?['callId'];
  final parentCallId = data?['parentCallId'];
  return callId is String &&
      callId.isNotEmpty &&
      parentCallId is String &&
      parentCallId.isNotEmpty;
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

  // issue #68（M3 Batch 2-C）：PTC 子调用树状态。
  // - `_ptcNodes`：全部已知子调用（含尚未挂到根的 orphan）；`_ptcParent` 只记录**已接受**的边；
  // - `_ptcTruncatedRoots`：已确定的根截断标志；`_ptcPendingTruncated`：父未到时的截断通知暂存；
  // - `_ptcRootsTouched`：本次 apply 影响到的根（渲染层据此原地刷新根卡，不新增条目）。
  final Map<String, _PtcNode> _ptcNodes = {};
  final Map<String, String> _ptcParent = {};
  final Set<String> _ptcTruncatedRoots = {};
  final Set<String> _ptcPendingTruncated = {};
  final Set<String> _ptcRootsTouched = {};

  /// 本次 apply 影响到的根工具 callId（只读快照，供 ChatScreen 原地刷新）。
  Set<String> get lastTouchedToolRoots => Set.unmodifiable(_ptcRootsTouched);

  void reset() {
    items.clear();
    tools.clear();
    _seenSeq.clear();
    _ptcNodes.clear();
    _ptcParent.clear();
    _ptcTruncatedRoots.clear();
    _ptcPendingTruncated.clear();
    _ptcRootsTouched.clear();
  }

  bool apply(ChatEvent event) {
    final seq = event.seq;
    if (seq != null && !_seenSeq.add(seq)) return false;
    _ptcRootsTouched.clear();
    if (hiddenTimelineTypes.contains(event.type)) return true;
    final data = event.data ?? const <String, dynamic>{};
    // issue #68：合法 PTC 事件只更新子调用树、不生成时间线条目（普通/调试都没有裸事件卡）；
    // data 缺失/非法 → 落回 default（旧插件/坏数据仍按 debug-only 事件卡呈现，可调试）。
    if (event.type == 'tool/ptc-dispatch-start' ||
        event.type == 'tool/ptc-dispatch') {
      if (ptcEventConsumable(data)) {
        _applyPtc(event, data);
        return true;
      }
      _appendNonTool(event, data);
      return true;
    }
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
      name: timelineToolNameOf(data, callId: callId, fallback: current?.name ?? L10n.t('工具', 'Tool')),
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
      // issue #68：根工具卡的子调用树随生命周期保留（PTC 事件不重建根卡）。
      subCalls: current?.subCalls ?? const <ToolSubCall>[],
      subCallsTruncated: current?.subCallsTruncated ?? false,
    );
    tools[callId] = next;
    // issue #68：新根/新结果到达后，把等待该父的 PTC orphan 挂回并物化子树；
    // 物化后的 lifecycle 才是渲染层要的版本（不能再用未带子树的 next）。
    _retryPtcOrphans();
    _upsertTool(tools[callId] ?? next, event);
  }

  // ── issue #68（M3 Batch 2-C）：PTC 子调用树 reducer ─────────────────────
  //
  // 语义与桌面 `updateDispatch`/`acceptsEdge` 等价（仅深度阈值 16）：
  // - 节点按 callId 去重，`firstSeq` 只在首次创建时写入（排序锚点）；
  // - start/result 任意顺序到达都不降级：result 先行时 status 保持 settled，
  //   start 只补缺失的 name/summary；重复 result 原地 last-write-wins；
  // - 父未知 → 节点保持 orphan（不渲染、不伪造根），父到达后逐层挂回；
  // - 自环/祖先环/重复父静默忽略；深度超 16 → 对应根 subCallsTruncated=true。

  void _applyPtc(ChatEvent event, Map<String, dynamic> data) {
    final callId = data['callId'] as String;
    // 根/子身份冲突：callId 已是根工具调用 → 拒绝该节点（契约 §3.3）。
    if (tools.containsKey(callId)) return;
    final parentCallId = data['parentCallId'] as String;
    final rootCallId = data['rootCallId'] is String
        ? data['rootCallId'] as String
        : '';
    final seq = event.seq ?? 0;
    final isStart = event.type == 'tool/ptc-dispatch-start';
    final wireName = data['name'] is String ? data['name'] as String : '';
    final isError = data['isError'] == true;
    final status = isStart ? 'running' : (isError ? 'failed' : 'success');
    final summary = ToolCallSummary.fromJson(data['summary']);
    final text = data['text'] is String ? data['text'] as String : null;

    // 服务端 50 截断通知：不建节点；父已知 → 标记根截断，父未知 → 暂存待挂回。
    if (data['truncated'] == true) {
      final root = _rootOf(parentCallId);
      if (root != null) {
        _ptcTruncatedRoots.add(root);
        _materializePtcRoot(root);
      } else {
        _ptcPendingTruncated.add(parentCallId);
      }
      return;
    }

    final existing = _ptcNodes[callId];
    if (existing == null) {
      final node = _PtcNode(
        callId: callId,
        parentCallId: parentCallId,
        rootCallId: rootCallId,
        firstSeq: seq,
      )
        ..name = wireName
        ..status = status
        ..summary = summary
        ..text = text
        ..isError = isError;
      _ptcNodes[callId] = node;
      final decision = _edgeDecision(parentCallId, callId);
      if (decision == 'ok') {
        _ptcParent[callId] = parentCallId;
      } else if (decision == 'depth') {
        _markDepthTruncated(parentCallId);
      }
    } else if (isStart) {
      // start 重复/晚到：不降级、不覆盖 settled 状态；只补缺失字段。
      if (existing.name.isEmpty && wireName.isNotEmpty) existing.name = wireName;
      if (existing.summary == null && summary != null) {
        existing.summary = summary;
      }
    } else {
      // result（含重复 result）：last-write-wins；name 非空才覆盖，空 name 保留 start 名。
      existing.status = status;
      existing.isError = isError;
      existing.text = text;
      if (wireName.isNotEmpty) existing.name = wireName;
      if (summary != null) existing.summary = summary;
    }
    // 新节点/新父链：尝试把等待该父的 orphan 逐层挂回，并物化受影响根。
    _retryPtcOrphans();
    _touchRootOf(callId);
    // 本条节点的父可能正是另一 orphan；重试后它自身也可能刚被挂上，再刷一次根。
    _touchRootOf(parentCallId);
  }

  /// 接边判定：`ok` / `defer`（父未到）/ `reject`（自环/重复父/祖先环）/ `depth`。
  String _edgeDecision(String parent, String child) {
    if (parent == child) return 'reject'; // 自环
    final acceptedParent = _ptcParent[child];
    if (acceptedParent != null && acceptedParent != parent) {
      return 'reject'; // 重复父：首次父胜出
    }
    // 祖先环：从 parent 沿已接受边/根工具上溯。
    final visited = <String>{};
    String? cursor = parent;
    while (cursor != null) {
      if (cursor == child) return 'reject';
      if (!visited.add(cursor)) return 'reject'; // 已有数据损坏环
      if (tools.containsKey(cursor)) break; // 到达根工具
      cursor = _ptcParent[cursor];
    }
    final chain = _ancestorChain(parent);
    if (chain == null) return 'defer'; // 父未到：暂存 orphan
    final depth = chain.length; // 父是根 → 0
    if (depth + _subtreeHeight(child) > 16) return 'depth';
    return 'ok';
  }

  /// parent 到根的已接受子调用链（不含根）；父未到/链断 → null。
  List<String>? _ancestorChain(String parent) {
    final chain = <String>[];
    final visited = <String>{};
    String? cursor = parent;
    while (cursor != null) {
      if (tools.containsKey(cursor)) return chain; // cursor 是根工具
      if (!_ptcNodes.containsKey(cursor)) return null; // 父未到
      if (!visited.add(cursor)) return null; // 损坏环
      chain.add(cursor);
      cursor = _ptcParent[cursor];
    }
    return null;
  }

  /// 子树高度（自身算 1 + 已接受后代最大高度）。
  int _subtreeHeight(String callId) {
    var maxChild = 0;
    for (final node in _ptcNodes.values) {
      if (_ptcParent[node.callId] != callId) continue;
      final height = _subtreeHeight(node.callId);
      if (height > maxChild) maxChild = height;
    }
    return 1 + maxChild;
  }

  /// 节点沿已接受边走到根工具 callId；orphan/断链 → null。
  String? _rootOf(String callId) {
    final visited = <String>{};
    String? cursor = callId;
    while (cursor != null) {
      if (tools.containsKey(cursor)) return cursor;
      if (!visited.add(cursor)) return null;
      cursor = _ptcParent[cursor];
    }
    return null;
  }

  /// 深度越界：父链已知根 → 置根 truncated；否则暂存，等父链到根后补记。
  void _markDepthTruncated(String parent) {
    final root = _rootOf(parent);
    if (root != null) {
      _ptcTruncatedRoots.add(root);
      _materializePtcRoot(root);
      return;
    }
    _ptcPendingTruncated.add(parent);
  }

  /// 把全部 orphan 逐层重试接边（父到达/历史乱序时挂回）；遍历有界（200）。
  void _retryPtcOrphans() {
    var progress = true;
    var guard = 0;
    while (progress && guard++ < 200) {
      progress = false;
      for (final node in _ptcNodes.values.toList(growable: false)) {
        if (_ptcParent.containsKey(node.callId)) continue;
        final decision = _edgeDecision(node.parentCallId, node.callId);
        if (decision == 'ok') {
          _ptcParent[node.callId] = node.parentCallId;
          progress = true;
          final root = _rootOf(node.callId);
          if (root != null) _materializePtcRoot(root);
        } else if (decision == 'depth') {
          _markDepthTruncated(node.parentCallId);
        }
      }
    }
    // 暂存的截断通知：父链到根后补记。
    for (final parent in _ptcPendingTruncated.toList(growable: false)) {
      final root = _rootOf(parent);
      if (root == null) continue;
      _ptcTruncatedRoots.add(root);
      _ptcPendingTruncated.remove(parent);
      _materializePtcRoot(root);
    }
    // 防御：坏数据导致无界增长时丢弃最旧未挂节点（契约 §3.5 SHOULD）。
    while (_ptcNodes.length > 200) {
      String? orphanId;
      for (final node in _ptcNodes.values) {
        if (!_ptcParent.containsKey(node.callId)) {
          orphanId = node.callId;
          break;
        }
      }
      if (orphanId == null) break;
      _ptcNodes.remove(orphanId);
    }
  }

  void _touchRootOf(String callId) {
    final root = _rootOf(callId);
    if (root != null) _materializePtcRoot(root);
  }

  /// 物化某根的子调用树（DFS 先序扁平列表；depth 1..16；App 侧 50 二次上限）。
  void _materializePtcRoot(String rootId) {
    final lifecycle = tools[rootId];
    // 根工具卡尚未到达：等 tool/call 到达时由 _mergeTool 统一物化。
    if (lifecycle == null) return;
    final out = <ToolSubCall>[];
    var truncated = _ptcTruncatedRoots.contains(rootId);
    final visited = <String>{rootId};
    void dfs(String parentId, int depth) {
      final kids = _childrenOf(parentId);
      // 叶子提前返回：恰好 16 层的叶子/恰好 50 条时不得误报 truncated。
      if (kids.isEmpty) return;
      if (depth > 16) {
        // 还有孩子但层级已到 17：确实被深度上限截断。
        truncated = true;
        return;
      }
      for (final kidId in kids) {
        if (out.length >= 50) {
          // 还有孩子但已满 50：确实被数量上限截断。
          truncated = true;
          return;
        }
        if (!visited.add(kidId)) continue; // 深度/环双保险
        final node = _ptcNodes[kidId];
        if (node == null) continue;
        out.add(ToolSubCall(
          callId: node.callId,
          parentCallId: node.parentCallId,
          rootCallId: node.rootCallId,
          name: node.name,
          status: node.status,
          summary: node.summary,
          text: node.text,
          isError: node.isError,
          seq: node.firstSeq,
          depth: depth,
        ));
        dfs(kidId, depth + 1);
      }
    }

    dfs(rootId, 1);
    tools[rootId] = lifecycle.copyWith(
      subCalls: List<ToolSubCall>.unmodifiable(out),
      subCallsTruncated: truncated,
    );
    _ptcRootsTouched.add(rootId);
  }

  /// 某父下已接受子节点（按首次出现 seq 升序，同 seq 按 callId 稳定）。
  List<String> _childrenOf(String parentId) {
    final kids = <_PtcNode>[];
    for (final node in _ptcNodes.values) {
      if (_ptcParent[node.callId] == parentId) kids.add(node);
    }
    kids.sort((a, b) {
      final bySeq = a.firstSeq.compareTo(b.firstSeq);
      return bySeq != 0 ? bySeq : a.callId.compareTo(b.callId);
    });
    return [for (final kid in kids) kid.callId];
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

/// issue #68：reducer 内部的 PTC 子调用节点（可变合并态；wire 见 ToolSubCall）。
class _PtcNode {
  _PtcNode({
    required this.callId,
    required this.parentCallId,
    required this.rootCallId,
    required this.firstSeq,
  });

  final String callId;

  /// 首次事件声明的父；同一 callId 不重挂（重复父静默忽略）。
  final String parentCallId;
  final String rootCallId;
  final int firstSeq;
  String name = '';
  String status = 'running';
  ToolCallSummary? summary;
  String? text;
  bool isError = false;
}

int? _maxSeq(int? a, int? b) => a == null ? b : (b == null || a >= b ? a : b);
