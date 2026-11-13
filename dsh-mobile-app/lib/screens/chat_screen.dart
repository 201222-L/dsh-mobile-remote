// 对话页：消息流（Markdown/流式/工具折叠/token 用量）+ 上翻加载 + 快捷动作 + composer
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderSliver, RenderSliverMultiBoxAdaptor, SliverMultiBoxAdaptorParentData;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../toast.dart';
import '../api.dart';
import '../chat_copy.dart';
import '../download.dart';
import '../download_error.dart';
import '../download_foreground.dart';
import '../resumable_download.dart';
import 'download_resume_picker.dart';
import '../scroll_follow.dart';
import '../logger.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import '../timeline.dart';
import '../theme.dart';
import '../turn_navigation.dart';
import '../turn_process.dart';
import '../inline_path.dart';
import '../turn_outline.dart';
import '../turn_tail.dart';
import '../turn_file_actions.dart';
import '../md.dart';
import '../workspace_image_cache.dart';
import '../fmt.dart';
import '../image_gallery.dart';
import '../git_browser_controller.dart';
import '../local_notifications.dart';
import 'git_browser_sheet.dart';
import '../tool_cards.dart';
import '../tool_images.dart';
import '../widgets/git_file_viewer.dart';
import '../widgets/git_logo.dart';
import '../widgets/turn_navigator_rail.dart';
import '../widgets/turn_tail_cards.dart';
import 'sheets.dart';
import 'session_files_screen.dart';
import 'session_tools_sheet.dart';
import 'turn_changes_diff_screen.dart';
import 'turn_file_preview_screen.dart';

/// v3.0.0(热修 07)：服务端"明确拒绝"的错误码白名单——这些代表消息**未被投递且服务端无回执**，
/// 可直接判失败；其余（`bridge-unavailable`、`receipt-pending`、传输层 reset/超时等）一律走回执
/// 对账——因为服务端可能已接收（响应在回程被切断时，桥把它翻译成 502 `bridge-unavailable` 返回，
/// 此时消息已投递，须靠回执确认送达，不能误报失败）。
bool isDefinitiveSendRejection(String? code) => switch (code) {
  'empty-text' ||
  'payload-too-large' ||
  'invalid-requestId' ||
  'session-not-found' ||
  'no-live-agent' ||
  'agents-unavailable' ||
  'attachment-error' ||
  'send-failed' ||
  'bad-request' ||
  'not-found' ||
  'auth-required' ||
  'rate-limited' ||
  'host-not-allowed' ||
  'loopback-only' ||
  'method-not-allowed' => true,
  _ => false,
};

/// v3.0.0(热修 07)：发送异常后的草稿恢复决策——仅当输入框仍为空（本次发送清空后的预期
/// 状态）才回填旧草稿；发送期间用户输入的新内容一律保留（绝不覆盖，见 Codex review）。
String draftAfterFailure(String current, String fallback) =>
    current.trim().isEmpty ? fallback : current;

/// v3.0.0(热修 07)：草稿签名——会话 + 最终生效模式 + 文本 + 图片路径；任一变化即换新
/// requestId（例：排队发送结果未知后改用插队 → 新 requestId → 插队真正执行而非回放旧结果）。
String composerSignature(
  String sessionId,
  String mode,
  String text,
  List<String> imagePaths,
) => '$sessionId|$mode|$text|${imagePaths.join(',')}';

/// issue #25：内核命令行语法的**唯一**判定式（与内核 `parseCommandLine` 同形）——
/// 首字符 `/`，随后是小写命令名 `[a-z][a-z0-9_-]*`，名字之后必须是空白或行尾。
final RegExp _commandLinePattern = RegExp(r'^/([a-z][a-z0-9_-]*)(?:\s|$)');

/// issue #25：这一行是不是斜杠命令行（纯判定，便于单测）。
/// 提交时由它决定"执行命令"还是"当普通消息发给模型"——`/compact` 曾被当成用户消息喂给模型，
/// 用户看不到任何报错（issue #25 主诉）。
///
/// 语法后果（有意，非疏漏）：`/m/api/send 是什么` **不是**命令（`m` 之后是 `/` 而不是空白），
/// 因此这类路径样式的消息照旧原样发给模型；而 `/tmp` 这类单段文本**是**命令——语法上无法与
/// 命令名区分，由"目录里查不到该名字 → 提示一次未知命令后照常发送"兜底（见 `_tryRunCommandLine`）。
bool isCommandLine(String text) => _commandLinePattern.hasMatch(text.trim());

/// issue #25：命令行里的命令名（不是命令行时 null）。入参内部先 trim，与 [isCommandLine] 同口径。
String? commandLineName(String text) =>
    _commandLinePattern.firstMatch(text.trim())?.group(1);

/// issue #25：⊕ 命令菜单某一行的副标题——内核声明了 `input.hint`（参数用法）就优先显示它，
/// 否则回退 `description`（旧行为）。
String? commandMenuSubtitle(Map<String, dynamic> command) {
  final input = command['input'];
  final hint = input is Map ? input['hint'] : null;
  if (hint is String && hint.isNotEmpty) return hint;
  final description = command['description'];
  return description is String && description.isNotEmpty ? description : null;
}

/// issue #25：命令执行失败的错误码 → 用户提示（失败一律保留草稿，用户可改参数重发）。
String commandExecuteErrorToast(ApiException e) {
  // 结果未知优先判定：服务端 180s `AbortSignal` 中止时 rpcError 把 TimeoutError/AbortError 映射成
  // 504 `commands-execute-failed`（见 lib/index.js）——命令可能已经跑完，**绝不能断言失败**。
  // status 缺失时同样按未知处理（宁可不肯定，也不谎报失败）。
  if (e.code == 'commands-execute-failed' &&
      (e.status == null || e.status == 504)) {
    return L10n.t(
      '命令已提交，但结果未知：请在对话里确认结果，不要盲目重发',
      'Command submitted but the outcome is unknown — check the conversation before resending',
    );
  }
  return switch (e.code) {
    'command-not-found' => L10n.t(
      '未知命令（命令目录已过期）：草稿已保留',
      'Unknown command (stale catalog) — your draft was kept',
    ),
    'commands-unavailable' => L10n.t(
      '当前 DSH 未提供命令服务：草稿已保留',
      'Command service is unavailable — your draft was kept',
    ),
    'session-not-found' => L10n.t(
      '该会话已休眠：请先发一条消息唤醒它，再执行命令（草稿已保留）',
      'Session is dormant — send a message first to wake it, then run the command (draft kept)',
    ),
    _ => '${L10n.t('命令执行失败：', 'Command failed: ')}$e',
  };
}

/// v3.1.4（issue #13 排查建议 3）：轮次结束时是否需要**兜底补拉**——
/// 本轮出现过真人提问（lastUserSeq 非空），但没有渲染出更晚的回复条目
/// （lastAssistantSeq 为空或早于提问）→ 判定内容被静默吞掉，补拉一次历史。
/// 纯函数便于单测：见 test/issue13_logic_test.dart。
bool needsTurnEndResync({int? lastUserSeq, int? lastAssistantSeq}) =>
    lastUserSeq != null &&
    (lastAssistantSeq == null || lastAssistantSeq <= lastUserSeq);

/// 是否应由本次滚动通知触发“加载更早”。抽出为纯判定，避免 ScrollStart/ScrollEnd
/// 在列表已位于顶部时重复触发异步分页。
bool shouldLoadOlderFromScroll(
  ScrollNotification notification, {
  required bool infiniteMode,
}) {
  if (!infiniteMode || !notification.metrics.hasContentDimensions) return false;
  if (notification.depth != 0) return false;
  if (notification.metrics.axis != Axis.vertical) return false;
  // ScrollStart/ScrollEnd/UserScroll 在 pixels=0 时也会冒泡；异步分页若在 start 时
  // 启动、在 end 前完成，end 会立刻再触发一页。只响应真正向顶部发生的位移更新。
  final distanceToLeadingEdge =
      notification.metrics.pixels - notification.metrics.minScrollExtent;
  if (notification is ScrollUpdateNotification) {
    final delta = notification.scrollDelta;
    return delta != null && delta < 0 && distanceToLeadingEdge < 80;
  }
  // Android 顶部下拉没有 ScrollUpdate，只有负向 overscroll；接受它以便用户
  // 在已到顶部或上一页加载失败后可以重试，但仍拒绝 start/end 空通知。
  if (notification is OverscrollNotification) {
    return notification.overscroll < 0 && distanceToLeadingEdge <= 80;
  }
  return false;
}

/// Phase 2(A4)：统一「打开会话页」流程——切换会话 + 刷新会话配置 + 推入 ChatScreen。
/// 返回后执行 [onReturn]（各调用点差异：刷新列表 / 恢复原会话）。
/// [apiClient] 仅供测试注入（与 `ChatScreen.apiClient` 同款）；生产路径传 null 即用全局 `api`。
Future<void> openChat(
  BuildContext context,
  AppStore store,
  String sessionId, {
  VoidCallback? onTitleChanged,
  Future<void> Function()? onReturn,
  Api? apiClient,
}) async {
  await store.setSession(sessionId);
  store.refreshSessionConfig();
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ChatScreen(
        store: store,
        onTitleChanged: onTitleChanged ?? () {},
        apiClient: apiClient,
      ),
    ),
  );
  if (onReturn != null) await onReturn();
}

typedef GitBrowserControllerFactory = GitBrowserController Function(
  GitReadApi api,
);

class _ConversationActionRail extends StatefulWidget {
  final List<String> initialOrder;
  final ValueChanged<List<String>> onOrderChanged;

  const _ConversationActionRail({
    required this.initialOrder,
    required this.onOrderChanged,
  });

  @override
  State<_ConversationActionRail> createState() =>
      _ConversationActionRailState();
}

class _ConversationActionRailState extends State<_ConversationActionRail> {
  late final List<String> _order = List.of(widget.initialOrder);

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final action = _order.removeAt(oldIndex);
      _order.insert(newIndex, action);
    });
    widget.onOrderChanged(List.unmodifiable(_order));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        // 位置：右上角顶部——与触发它的「对话操作」按钮同侧、同一高度带。
        // 2026-10-07 真机反馈：垂直居中（Alignment.centerRight）与触发按钮脱节，观感突兀。
        alignment: Alignment.topRight,
        child: Material(
          elevation: 12,
          color: Theme.of(context).colorScheme.surface,
          // 高度贴合内容后它是一条"浮动短条"，左侧圆角让它与右边缘的贴合看起来是有意的
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 56,
            // 修复：原为 height: double.infinity —— 白条会撑满整屏，而 4 个动作只有 224dp，
            // 下面一大片空白（用户反馈"白条太长"）。改为按动作数取高。
            height: 56.0 * _order.length,
            child: ReorderableListView(
              buildDefaultDragHandles: false,
              padding: EdgeInsets.zero,
              onReorderItem: _onReorder,
              children: [
                for (var index = 0; index < _order.length; index++)
                  SizedBox(
                    key: ValueKey(_order[index]),
                    width: 56,
                    height: 56,
                    child: ReorderableDelayedDragStartListener(
                      index: index,
                      child: _actionButton(context, _order[index]),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton(BuildContext context, String id) {
    final (icon, label) = switch (id) {
      'git' => (const GitLogo(size: 22), 'Git'),
      'files' => (
        const Icon(Icons.folder_outlined, size: 20),
        L10n.t('文件', 'Files'),
      ),
      'session_tools' => (
        const Icon(Icons.assignment_outlined, size: 20),
        L10n.t('任务 / 子代理 / 目标', 'Tasks / Subagents / Goals'),
      ),
      'copy' => (
        const Icon(Icons.copy_all, size: 20),
        L10n.t('复制当前已加载的对话', 'Copy loaded conversation'),
      ),
      _ => throw StateError('Unknown conversation action: $id'),
    };
    return Tooltip(
      message: label,
      triggerMode: TooltipTriggerMode.manual,
      child: IconButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(id),
        icon: icon,
      ),
    );
  }
}

// 轮次导航 action gutter：轨道 28 + 右留白 8；回到底部圆钮 38 也占用同一 gutter。
const double turnRailWidth = 28;
const double turnRailRightGutter = 8;
const double turnRailRightPadding = turnRailWidth + turnRailRightGutter; // 36
const double jumpButtonRightPadding = 38;
// issue #81：圆钮尺寸与右 padding（与 #80 的 action gutter 同帧计算）。
const double jumpToLatestSize = 38;
const double jumpToLatestRightPadding = jumpToLatestSize;
const double chatMessageDefaultRightPadding = 16;
const double turnRailBottomReserve = 62;

/// 消息列表右侧留白：圆钮可见优先 38，其次轨道 36，都隐藏恢复 16。
double listRightPaddingFor({
  required bool jumpVisible,
  required bool railVisible,
}) {
  if (jumpVisible) return jumpButtonRightPadding;
  if (railVisible) return turnRailRightPadding;
  return chatMessageDefaultRightPadding;
}

/// issue #98：本会话内的工作区外图片授权记录（不持久化）。
class _WorkspaceImageConsent {
  const _WorkspaceImageConsent({
    required this.consentId,
    required this.scope,
    required this.requestPath,
    required this.requestDir,
    required this.expiresAt,
  });

  final String consentId;
  final String scope;
  final String requestPath;
  final String requestDir;
  final DateTime? expiresAt;

  bool get expired =>
      expiresAt != null && !DateTime.now().isBefore(expiresAt!);
}

class ChatScreen extends StatefulWidget {
  final AppStore store;
  final String? initialSend; // 首页直达发送
  final VoidCallback onTitleChanged;
  final Api? apiClient;
  final GitReadApi? gitReadApi;
  final GitBrowserControllerFactory? gitControllerFactory;

  /// issue #60 R06：仅测试注入（TTL 行为需要可控时钟/短 TTL）；生产用默认缓存。
  final TurnTailSummaryCache? changedSummaryCache;
  const ChatScreen({
    super.key,
    required this.store,
    this.initialSend,
    required this.onTitleChanged,
    this.apiClient,
    this.gitReadApi,
    this.gitControllerFactory,
    this.changedSummaryCache,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// issue #95：200 `unavailable:true` 的短 TTL（默认 30s；测试可注入更短值验证重试）。
/// 不用永久空缓存，避免旧宿主/临时故障导致技能菜单一直缺失。
Duration slashSkillsUnavailableTtl = const Duration(seconds: 30);

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = _SlashHighlightController();
  // issue #97：菜单在输入框上方/composer 外；用 composer 位置计算可用最大高度。
  final _composerKey = GlobalKey();
  double? _bodyMaxHeight;
  final _bottomControlsKey = GlobalKey();
  final _slashScroll = ScrollController();
  int _slashRemaining = 0;
  bool _slashOverflow = false;
  bool _slashAtBottom = true;
  String _slashMenuSignature = '';
  int _slashScrollCheckTries = 0;
  final _scrollCtrl = ScrollController();
  static const _liveCenterKey = ValueKey<String>('chat-live-center');
  // live 视图：最新在前（普通列表渲染时倒序，最新位于列表底部）
  final List<_MsgItem> _items = [];
  // 无限上翻时放在 center 之前的旧消息，按“距 center 近→远”排列（新→旧）。
  // 新分页追加到尾部，已有 child index 不变，CustomScrollView.center 可保持锚点。
  final List<_MsgItem> _olderItems = [];
  // 活动条状态：执行中的工具（callId -> 工具名）+ 思考累积文本
  final Map<String, String> _activeTools = {};
  // ── issue #61：工具名兜底映射（session 级 callId → toolName） ───────────
  // 历史分页截断/流式增量缺 `name` 时，用本会话此前事件里学到的工具名补名。
  // 与 [_activeTools]（活动条瞬时态，结果到达即删）不同：这里保留整会话，
  // 因为历史重建（_load 重放）可能只剩 result、没有 call。会话切换时清空。
  final Map<String, String> _toolNamesByCallId = {};
  String? _toolNamesSessionId;
  // Shared pure projection owns seq de-duplication/call correlation for both live and history paths;
  // _MsgItem remains the richer Flutter rendering adapter.
  final TimelineReducer _timelineReducer = TimelineReducer();
  final Map<String, bool> _failureExpansionOverrides = {};
  final Set<String> _failureDetailRequests = {};
  // ── issue #52（ADR 0027 §2）：轮次过程折叠 ─────────────────────────────
  // 过程结构由纯投影 [TurnProcessTracker] 折叠（turn → 过程组(step) → 过程行），
  // 本页只持有渲染必需的三层手动状态（只存内存，离开会话即失）与分批上限。
  final TurnProcessTracker _turnProcess = TurnProcessTracker();
  List<TurnProcess> _processTurns = const [];
  Map<int, TurnProcess> _processTurnMap = const {};
  int _processVersion = 0; // 观察到的进化版本
  int _processBuiltVersion = -1; // 已折叠的版本
  final Map<String, bool> _turnExpansions = {}; // 过程段手动展开/收起（turn:segment）
  final Map<String, bool> _groupExpansions = {}; // 过程组手动展开（turn:segment:step）
  final Map<String, bool> _reasoningRowExpansions = {}; // 思考行手动展开（turn:seq）
  final Map<int, int> _processRowLimits = {}; // 分批展示：turn → 已展示行数
  // ── issue #53（ADR 0027 §3）：轮末产出物（两卡 + 按坐标预览） ─────────
  final Map<int, TurnTail> _turnTails = {}; // 轮号 → turnTails/tail 信号
  final Map<int, List<DeliverableFile>> _deliverablesByTurn = {};
  late final TurnTailSummaryCache _changedSummaryCache =
      widget.changedSummaryCache ?? TurnTailSummaryCache();
  /// 只表示 **in-flight**：完成/失败后移除，TTL 到期可重新拉取（issue #60 R06）。
  final Set<int> _changedSummaryRequested = {};
  /// issue #60 recheck-11：reset/重同步会清空门闩与缓存；旧请求完成必须按代际丢弃，
  /// 不得回填缓存或移除新请求的门闩。
  int _tailLoadGeneration = 0;
  /// 失败退避：避免完成后立刻被重建无限重试；仅抑制一段时间，不阻止 TTL 恢复。
  final Map<int, DateTime> _changedSummaryRetryAfter = {};
  final Map<int, String> _changedSummaryErrors = {};
  final Map<int, ({int version, TurnFileLinkResolver resolver})> _linkResolvers = {};
  int _turnTailVersion = 0;
  // ── issue #70（ADR 0027 §2 实时态）：运行中思考（provisional）──────────
  // 流式 reasoning 按 (turn, step) 缓冲在纯模型 [LiveReasoningBuffer]，活动条与
  // 过程块 provisional 行读同一份快照；文本增长只通知 ValueNotifier（行级重建），
  // 只有结构变化（首现/切换/落定/清理）才重建过程计划。
  final LiveReasoningBuffer _liveReasoning = LiveReasoningBuffer();
  final ValueNotifier<int> _liveReasoningRevision = ValueNotifier<int>(0);
  // provisional 行的展开状态（turn:step，跨 delta 保留；落定/轮末清理）。
  final Map<String, bool> _provisionalExpansions = {};
  bool _reasoningExpanded = false;
  Timer? _activityTimer;
  String _draft = '';
  bool _streaming = false;
  int _lastSeq = 0;
  // v3.1.4（issue #13）：轮次兜底同步——最近一条已渲染的真人提问 / 回复的 seq，
  // 用于判断"本轮有提问却没有回复条目"（内容被静默吞掉）时补拉一次历史。
  int? _lastUserSeq;
  int? _lastAssistantSeq;
  DateTime? _lastResyncAt; // 兜底补拉节流（10s）
  int _loadGeneration = 0; // 丢弃跨越 reset/会话切换的旧 history 响应
  // v2.7.2 review(M1)：本页绑定的会话（initState 时捕获）——事件按它过滤，叠层页面互不污染
  String? _mySessionId;
  // issue #94/#95：Markdown 本地图片 loader；缓存/并发/会话隔离由本页 LRU 负责。
  late final MarkdownImageLoader _markdownImageLoader =
      (source) => _loadMarkdownImage(source);
  late final MarkdownImageUserAction _markdownImageUserAction =
      (source) => _loadMarkdownImage(source, userInitiated: true);
  late final WorkspaceImageCache _workspaceImageCache = WorkspaceImageCache();
  final List<_WorkspaceImageConsent> _imageConsents = [];
  final Map<String, Future<String?>> _imageConsentPrompts = {};
  // issue #98 review P2：取消/失效过的 source 不再自动弹窗，只显示卡片入口；
  // 用户主动点「授权读取」才清标记并重新弹。
  final Set<String> _imageConsentDeclined = {};
  bool _imageConsentDialogOpen = false;

  Future<MarkdownImageData> _loadMarkdownImage(
    String source, {
    bool userInitiated = false,
  }) async {
    final id = _mySessionId;
    if (id == null || id.isEmpty) {
      throw ApiException('no-session', code: 'session-not-found');
    }
    var consentId = _imageConsentIdFor(source);
    Future<Uint8List> fetch() async {
      final data = await _api.workspaceImage(
        id,
        source,
        consentId: consentId,
      );
      // 服务端 8MiB + 客户端二次校验（防旧宿主/中间层异常大响应）。
      if (data.bytes.length > 8 * 1024 * 1024) {
        throw ApiException(
          'image too large',
          code: 'image-too-large',
          status: 413,
        );
      }
      return data.bytes;
    }

    final key = _imageConsentKey(id, source);
    if (userInitiated) _imageConsentDeclined.remove(key);
    try {
      final bytes = await _workspaceImageCache.load(
        key,
        fetch,
        stillWanted: () => mounted && _mySessionId == id,
      );
      _imageConsentDeclined.remove(key);
      return MarkdownImageData(bytes: bytes);
    } on ApiException catch (error) {
      if (error.code != 'consent-required' && error.code != 'consent-invalid') {
        rethrow;
      }
      if (consentId.isNotEmpty) _removeImageConsent(consentId);
      // 服务端持续 invalid：自动路径必须先标记 declined，再抛给卡片；
      // 否则重建会再次自动弹，形成循环。只有手动 action 才清 declined。
      if (!userInitiated && error.code == 'consent-invalid') {
        _imageConsentDeclined.add(key);
      }
      // 取消/失效后组件重建：不再自动弹，只让卡片显示「授权读取」。
      if (!userInitiated && _imageConsentDeclined.contains(key)) rethrow;
      final issued = await _ensureImageConsent(id, source);
      if (issued == null) {
        _imageConsentDeclined.add(key);
        rethrow;
      }
      consentId = issued;
      final bytes = await _workspaceImageCache.load(
        key,
        fetch,
        stillWanted: () => mounted && _mySessionId == id,
      );
      _imageConsentDeclined.remove(key);
      return MarkdownImageData(bytes: bytes);
    }
  }

  String _imageConsentKey(String sessionId, String source) =>
      '$sessionId|$source';

  String _requestDir(String source) {
    final normalized = source.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index <= 0 ? '' : normalized.substring(0, index);
  }

  String _imageConsentIdFor(String source) {
    final dir = _requestDir(source);
    for (final consent in _imageConsents.reversed) {
      if (consent.expired) continue;
      if (consent.scope == 'once' && consent.requestPath == source) {
        return consent.consentId;
      }
      if (consent.scope == 'session-directory' &&
          consent.requestDir.isNotEmpty &&
          consent.requestDir == dir) {
        return consent.consentId;
      }
    }
    return '';
  }

  void _removeImageConsent(String consentId) {
    _imageConsents.removeWhere((consent) => consent.consentId == consentId);
  }

  Future<String?> _ensureImageConsent(String id, String source) {
    final key = '$id|$source';
    return _imageConsentPrompts.putIfAbsent(key, () async {
      try {
        return await _promptImageConsent(id, source);
      } finally {
        _imageConsentPrompts.remove(key);
      }
    });
  }

  String _imageDisplayPath(String source) {
    final normalized = source.replaceAll('\\', '/');
    final segments = normalized.split('/').where((part) => part.isNotEmpty).toList();
    if (segments.isEmpty) return source;
    if (segments.length == 1) return segments.single;
    return '…/${segments[segments.length - 2]}/${segments.last}';
  }

  Future<String?> _promptImageConsent(String id, String source) async {
    if (!mounted || _imageConsentDialogOpen) return null;
    _imageConsentDialogOpen = true;
    try {
      final file = _imageDisplayPath(source);
      final choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('image-consent-dialog'),
          title: Text(L10n.t('授权读取图片', 'Authorize image access')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file),
              const SizedBox(height: 6),
              Text(
                L10n.t(
                  '该图片在工作区外。授权后本次读取仍受类型/大小/路径校验限制。',
                  'This image is outside the workspace. Authorization still keeps type/size/path checks.',
                ),
                style: const TextStyle(fontSize: 12.5),
              ),
            ],
          ),
          actions: [
            TextButton(
              key: const Key('image-consent-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop('cancel'),
              child: Text(L10n.t('取消', 'Cancel')),
            ),
            TextButton(
              key: const Key('image-consent-once'),
              onPressed: () => Navigator.of(dialogContext).pop('once'),
              child: Text(L10n.t('仅此次', 'This time')),
            ),
            FilledButton(
              key: const Key('image-consent-directory'),
              onPressed: () => Navigator.of(dialogContext).pop('session-directory'),
              child: Text(L10n.t('本会话允许此目录', 'Allow this directory')),
            ),
          ],
        ),
      );
      if (!mounted || choice == null || choice == 'cancel') return null;
      try {
        final issued = await _api.createWorkspaceImageConsent(
          sessionId: id,
          path: source,
          scope: choice,
        );
        final consentId = (issued['consentId'] ?? '').toString();
        if (consentId.isEmpty) return null;
        final expiresAt = DateTime.tryParse((issued['expiresAt'] ?? '').toString());
        _imageConsentDeclined.remove(_imageConsentKey(id, source));
        _imageConsents.add(_WorkspaceImageConsent(
          consentId: consentId,
          scope: (issued['scope'] ?? choice).toString(),
          requestPath: source,
          requestDir: _requestDir(source),
          expiresAt: expiresAt,
        ));
        if (mounted) setState(() {});
        return consentId;
      } on ApiException catch (error) {
        if (mounted) {
          showToast(
            context,
            '${L10n.t('无法授权读取图片：', 'Could not authorize image: ')}${error.code ?? error.message}',
          );
        }
        return null;
      }
    } finally {
      _imageConsentDialogOpen = false;
    }
  }
  Api get _api => widget.apiClient ?? api;
  String get _pageAgentStatus =>
      widget.store.agentStatusForSession(_mySessionId);
  // v2.7.2：排队消息停靠区（对齐 PC 端 Queue Dock）——可见、自解释，无需操作手册
  List<Map<String, dynamic>> _queue = [];
  bool _queueCollapsed = true; // 多条时折叠成计数头
  // v3.1.4（issue #12 姊妹需求）：会话任务清单（内核 dsh-tool-todo 投影同源）——
  // todo/write 整份覆盖、turn/start 清空；面板默认折叠成一行计数（对齐 PC 端任务面板）
  List<Map<String, dynamic>> _todos = [];
  bool _todosCollapsed = true;
  int _todoProjectionVersion = 0;
  int _todoRefreshRequest = 0;
  String? _editingQueueId;
  final _queueEditCtrl = TextEditingController();
  Timer? _queueRefreshTimer;
  Timer? _queuePollTimer; // v2.7.2 review：dock 可见时的周期兜底刷新
  bool _queueBusy = false; // v2.7.2 review：队列操作忙碌锁（防连点双发）
  int _earliestSeq = 0; // live 窗口最旧条目的 seq（"查看更早"分页起点）
  bool _historyDegraded = false; // 休眠会话降级读取（current surface）：持续提示"部分历史"
  bool _configDegraded = false; // 休眠会话配置已回退默认（服务端 configDegraded）：持续提示
  bool _loadingMore = false;
  bool _noMoreHistory = false; // 已到会话最顶端（无更早消息），停止再查询
  bool _showJumpToLatest = false; // 上翻后显示"回到底部"浮钮（派生展示，不反写意图）
  bool _turnRailVisible = false; // 本帧轨道可见性（列表 padding 与轨道共用 gate）
  // ── issue #114（§5.2）：跟随意图/拖拽/世代/待执行校正的唯一 owner ──────────
  // 生产只负责把 ScrollMetrics/用户手势/布局版本喂给它，并执行它给出的有界校正；
  // 意图判定、合并、预算、执行时守卫都在 ScrollFollowCoordinator 内（可单测）。
  late final ScrollFollowCoordinator _scrollFollow;
  bool _scrollFollowFrameBooked = false;
  // ── issue #77：活跃会话滚动贴底 ────────────────────────────────────
  // 内容短于视口时用顶部占位把消息列表底部对齐视口底部（否则 center 布局会顶对齐、
  // 下方留大片空白）；内容增长不算「上翻」（只有用户拖动才停止跟随）。
  double _liveBottomGap = 0;
  bool _liveGapMeasureScheduled = false;
  double _lastGapContentExtent = 0;
  // issue #89：活动条显隐/视口高度变化后必须重测底部占位；记录可见态与上次实测高度。
  bool _activityBarShown = false;
  double _lastGapViewportHeight = 0;
  bool _suppressOlderPaging = false; // 占位调整帧内：位置修正不得触发「上翻加载更早」
  // issue #81：本帧消息列右 padding；宽度变化必须让依赖宽度的尺寸/内容偏移缓存失效。
  double _lastLiveRightPadding = -1;
  // issue #89：右 padding 同帧变化会导致正文重排/max 收缩；帧后 clamp 越界。
  int _paddingReconcileAttempts = 0;

  // ── issue #114：A1 测量层（保持只读；状态已收口到 ScrollFollowCoordinator） ──
  @visibleForTesting
  bool get debugPinnedToBottom => _scrollFollow.isFollowing;

  @visibleForTesting
  bool get debugUserDragActive => _scrollFollow.isDragging;

  @visibleForTesting
  bool get debugFollowBottomScheduled => _scrollFollow.hasPendingCorrection;

  @visibleForTesting
  bool get debugSettledFollowScheduled => _scrollFollow.hasPendingCorrection;

  @visibleForTesting
  double get debugLiveBottomGap => _liveBottomGap;

  /// 派生展示：回底按钮/刻度轨是否可见（只读探针，供需求用例断言）。
  @visibleForTesting
  bool get debugShowJumpToLatest => _showJumpToLatest;

  /// 调度契约探针：owner 的 ensureFrame → 生产实现必须自己调度一帧
  /// （post-frame 回调本身不调度帧，必须 ensureVisualUpdate）。
  @visibleForTesting
  void debugEnsureScrollFollowFrame() => _ensureScrollFollowFrame();

  /// 实际执行过的程序性校正次数与最后一次目标（issue §6.2「校正次数」）。
  @visibleForTesting
  int debugFollowJumps = 0;

  @visibleForTesting
  double? debugLastFollowTarget;

  @visibleForTesting
  int debugScrollToBottomCallbacks = 0;

  ScrollGeometry _geometryOfMetrics(ScrollMetrics metrics) => ScrollGeometry(
        pixels: metrics.pixels,
        minExtent: metrics.minScrollExtent,
        maxExtent: metrics.maxScrollExtent,
        viewportDimension: metrics.viewportDimension,
      );

  ScrollGeometry _geometryOfPosition(ScrollPosition position) => ScrollGeometry(
        pixels: position.pixels,
        minExtent: position.minScrollExtent,
        maxExtent: position.maxScrollExtent,
        viewportDimension: position.viewportDimension,
      );

  /// owner 的唯一帧调度出口：注册帧后执行器，并**确保下一帧被调度**。
  /// `addPostFrameCallback` 本身不调度帧——这正是 #114 A2 实测到的校正饿死根因。
  void _ensureScrollFollowFrame() {
    if (_scrollFollowFrameBooked) return;
    _scrollFollowFrameBooked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollFollowFrameBooked = false;
      if (!mounted || _inHistory || !_scrollCtrl.hasClients) {
        _scrollFollow.cancelPending();
        return;
      }
      final position = _scrollCtrl.position;
      if (!position.hasContentDimensions) {
        _scrollFollow.cancelPending();
        return;
      }
      final correction = _scrollFollow.takeCorrection(
        _geometryOfPosition(position),
      );
      if (correction == null) return;
      _applyScrollCorrection(correction);
    });
    // 帧后相位（postFrameCallbacks）里注册的回调不会自动带来新帧；这里显式补一帧。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 执行 owner 给出的一次有界校正（帧后测量或显式回底的同步路径共用）。
  void _applyScrollCorrection(ScrollCorrection correction) {
    if (!mounted || _inHistory || !_scrollCtrl.hasClients) return;
    final position = _scrollCtrl.position;
    debugScrollToBottomCallbacks += 1;
    debugLastFollowTarget = correction.targetPixels;
    if (!_scrolledLogged) {
      _scrolledLogged = true;
      AppLog.instance.log(
        'Chat: 跟随校正(${correction.reason.name}) '
        'pixels=${position.pixels.toStringAsFixed(0)} '
        'target=${correction.targetPixels.toStringAsFixed(0)} '
        'attempt=${correction.attempt + 1}/${correction.budget}',
      );
    }
    debugFollowJumps += 1;
    _scrollFollow.beginProgrammaticScroll();
    try {
      position.jumpTo(correction.targetPixels);
    } finally {
      _scrollFollow.endProgrammaticScroll();
    }
    _scrollFollow.noteCorrectionApplied(correction);
    _syncScrollFollowDisplay();
  }

  /// 显式回底：取一次即时校正并同步执行，保证「点按钮→下一帧 padding/按钮同帧变化」
  /// 的既有契约（帧后路径会晚一帧）。仍走 owner 的同一决策 seam。
  void _applyScrollCorrectionImmediately() {
    if (!mounted || _inHistory || !_scrollCtrl.hasClients) return;
    final position = _scrollCtrl.position;
    if (!position.hasContentDimensions) return;
    final correction = _scrollFollow.takeCorrection(
      _geometryOfPosition(position),
    );
    if (correction != null) _applyScrollCorrection(correction);
  }

  /// 把 owner 的派生展示同步到 build 需要的字段（只有变化时才 setState）。
  void _syncScrollFollowDisplay() {
    if (!mounted) return;
    final show = _scrollFollow.showJumpToLatest;
    if (show != _showJumpToLatest) {
      setState(() => _showJumpToLatest = show);
    }
  }

  /// 统一请求入口：内容/布局变化跟随；[forced] 用于初始打开/回 live/发送/显式回底。
  void _requestScrollFollow({
    bool forced = false,
    CorrectionReason reason = CorrectionReason.contentLayout,
    int? budget,
  }) {
    if (!mounted) return;
    final geometry = _scrollCtrl.hasClients &&
            _scrollCtrl.position.hasContentDimensions
        ? _geometryOfPosition(_scrollCtrl.position)
        : null;
    if (forced) {
      _scrollFollow.requestForcedFollow(
        reason: reason,
        budget: budget,
        geometry: geometry,
      );
    } else {
      _scrollFollow.requestFollowOnLayout(geometry);
    }
    _syncScrollFollowDisplay();
  }

  /// 程序性滚动统一包一层：它们的 ScrollEnd 不得被当成用户手势结束。
  void _runProgrammaticScroll(void Function() action) {
    _scrollFollow.beginProgrammaticScroll();
    try {
      action();
    } finally {
      _scrollFollow.endProgrammaticScroll();
    }
  }

  /// issue #89：padding 38/36/16 同帧切换后，宽度变化会清高度缓存并重排；
  /// 帧后把滚动位置 clamp 到新范围，重测底部占位，必要时有限帧收敛。
  /// 拖拽中只 clamp，不抢手势；松手（ScrollEnd）再触发一次收敛。
  void _reconcileAfterPaddingChange() {
    if (!mounted || _inHistory || !_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (!pos.hasContentDimensions) return;
    final clamped = pos.pixels.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((clamped - pos.pixels).abs() > 0.5) {
      _runProgrammaticScroll(() => _scrollCtrl.jumpTo(clamped));
    }
    // padding 38/36/16 只影响正文宽度与 extent；这里仅把越界的 pixels 夹回新范围。
    // 不重测底部占位、不回底，避免与用户滚动/手势抢方向（issue #81 契约）。
    if (_scrollFollow.isDragging && _paddingReconcileAttempts < 4) {
      _paddingReconcileAttempts++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reconcileAfterPaddingChange();
      });
    } else {
      _paddingReconcileAttempts = 0;
    }
  }

  // ── issue #24：轮次导航（ADR 0018）──────────────────────────────────
  // 轮次索引是**派生结构**：turn/start 的持久序号 → 轮次号。此前轮次号只用
  // 来拼一行显示字符串，事后再也取不回来，因此无法按轮次定位。这里只留存，
  // 不写入任何持久状态。
  final Map<int, int> _turnOfStartSeq = {};
  // 每个轮次边界条目的稳定 key，按**边界持久 seq** 分配：同轮号的重试边界各有其键，
  // 不再共用同一个 GlobalKey（否则真实页面会出现 needsLayout 断言）。定位一律用
  // anchor.seq 查规范边界。
  final Map<int, GlobalKey> _turnKeysBySeq = {};
  // 已构建边界最后一次实测的**内容偏移**（turn → offset）：边界被懒构建回收后，
  // 仍能用它推断阅读线落在哪一轮（长回复场景不再无条件回退到最新轮）。
  final Map<int, double> _turnContentOffset = {};

  /// issue #31（方案 B）：**条目尺寸缓存**——已构建子项的实测高度，按稳定 key
  /// （`seq` 优先，工具卡用 `latestSeq`）记录。定位时用它算"索引 → 偏移"的估算，
  /// 这是本体虚拟化列表 `getOffsetForIndex` 的等价物：长跳一步落到目标附近，
  /// 而不是盲二分十几次（真机上第 2 轮离底部约 2900 个条目）。
  final Map<int, double> _itemHeights = {};
  int? _activeTurn; // 当前阅读的轮次（刻度轨高亮）
  int? _busyTurn; // 跳转进行中的轮次（刻度脉冲）
  // issue #25 二期：宿主轮次大纲（三态 + 读取失败态）。能力缺失/读取失败时退回一期
  // 「只用已加载轮次」，但必须把原因说明白（见 turnOutlineNotice）。
  TurnOutline _turnOutline = const TurnOutline.capabilityMissing();
  // 是否**已经问过**（能力声明到达 / 请求返回）。没问过之前不得给"能力缺失"结论，
  // 否则首帧就会对用户说"这台电脑不支持"（issue #25 评审 P2）。
  bool _turnOutlineResolved = false;
  // 跨页跳转期间：用户主动滚动即取消（故事 18），说明文字只在他能看到刻度轨时给一次。
  bool _turnJumpCancelled = false;
  // 导航世代：连续点选时旧操作不得覆盖新操作的落点 / busy / 提示（issue #25 评审 P2）。
  int _turnNavGeneration = 0;
  // 大纲刷新的请求身份：同一会话/同一历史世代下也会重叠多次刷新，迟到结果不得覆盖新结果。
  int _turnOutlineRefreshId = 0;
  bool _turnOutlineNoticeShown = false;
  bool _activeTurnCalibrationScheduled = false; // 滚动期间合并调度几何校准
  final GlobalKey _liveViewportKey = GlobalKey(); // 阅读线基准：消息流视口
  // re-review P2：过程工具行的真实几何 key（callId → GlobalKey），活动条据此判断
  // 该行是否真的与视口相交，而不是只看「计划里可见 / 已展开」。
  final Map<String, GlobalKey> _processToolRowKeys = {};
  // 首帧几何尚未 layout 完成：安排一次 post-frame 重建，让“行可见→隐藏活动条”生效。
  bool _activityGeometryResolved = false;
  bool _activityGeometryRefreshScheduled = false;
  int _activityGeometryRefreshFrames = 0;
  String _activityGeometryCandidateKey = '';
  // 两条消息流列表（center 前后）的渲染对象：定位时用来遍历**已构建子项**的
  // 真实索引与几何（长回复会挤掉落点附近的轮次边界，只有子项索引是连续可靠的）。
  final GlobalKey _olderSliverKey = GlobalKey(); // center 之前：_olderItems
  final GlobalKey _liveSliverKey = GlobalKey(); // center 之后：_items（+草稿）
  QuestionRequest? _question; // 内核问询弹窗（当前会话，思考中途需要拍板）
  ApprovalRequest? _approval; // 内核权限审批弹窗（当前会话）
  final Set<String> _transientFrameKeys =
      {}; // mobile/frame 无 durable seq，按业务 id 去重
  bool _sending = false;
  String? _title;
  Map<String, dynamic> _usage = {};
  bool _usageLoaded = false;
  int _usageVersion = 0;
  int _usageRequest = 0;
  Timer? _draftTimer; // 流式草稿节流刷新（chunk 合并，避免每帧全量重建）
  int _lastLoggedCount = -1; // 排障：itemCount 变化时打日志
  bool _scrolledLogged = false; // 排障：滚动状态打一次日志
  // v2.8.0 review(P2-2)：反馈提交中集合（按 messageId），防快速连点 toggle 竞态
  final Set<String> _feedbackInFlight = {};
  // v3.0.0 图像链路：待发送图片（XFile 原始文件，不压缩——与 PC 端一致）
  final List<XFile> _pendingImages = [];
  // v3.0.0(热修 05)：待确认发送的 requestId 与草稿签名——内容未变的重试复用同一 id
  // （服务端幂等不重复投递）；内容变化后重新生成。
  String? _pendingRequestId;
  String? _pendingSignature;
  // issue #25：命令目录缓存（提交时判定 `/xxx` 是执行命令还是普通消息用）——每会话一份，
  // ⊕ 菜单取回目录时同步刷新；`command-not-found`（目录过期）时丢弃、下次提交重新拉取。
  List<Map<String, dynamic>>? _commandCatalog;
  String? _commandCatalogSessionId;
  bool _pickingImages = false; // 选图在途锁（相册多选期间防重复触发）
  GitBrowserController? _gitController;

  // ── 分段历史浏览（超长会话的安全阀，仅当无限模式不可用时启用） ──
  static const _liveMax = 50; // 无限模式下不裁剪；分段模式下 live 窗口上限
  static const _infiniteMode = true; // 微信式无限上翻（配合 Impeller 实验）
  static const _histPageSize = 30; // 历史分段每段条数
  static const _catchupMaxPages = 20; // 断线补拉页数上限（20×100 条），超出由下次补拉收敛
  bool _inHistory = false;
  List<_MsgItem> _histItems = []; // 当前历史段：旧→新顺序（普通列表，最旧在顶部）
  int _histOldestSeq = 0;
  int _histNewestSeq = 0;
  bool _histHasOlder = false;
  bool _histHasNewer = false;
  bool _pendingNew = false; // 历史浏览期间收到新消息

  @override
  void initState() {
    super.initState();
    for (final s in widget.store.sessions) {
      if (s.id == widget.store.sessionId) {
        _title = s.label;
        break;
      }
    }
    // 进入会话时恢复挂起的问询/审批（例如从"需要你回答"通知点进来）
    _mySessionId = widget.store.sessionId; // v2.7.2 review(M1)：绑定本页会话
    // v3.3.1：告诉通知层「用户正看着这个会话」——此时不再弹系统通知（应用内已有卡片）。
    LocalNotifier.instance.visibleSession = _mySessionId;
    // S1：进入会话即收起横幅，并把该会话的未读通知标为已读（否则未读会积到几十条）。
    unawaited(widget.store.notifyChatOpened(_mySessionId ?? ''));
    _question = widget.store.questionForSession(_mySessionId);
    _approval = widget.store.approvalForSession(_mySessionId);
    _queue = widget.store.queueOf(_mySessionId ?? ''); // v3.0.0：初始即取镜像快照（帧/缓存）
    widget.store.addChatListener(
      _handleEvent,
    ); // v2.7.2 review(M1)：监听器列表，叠层页面互不覆盖
    // issue #52：展示模式/收起时机改动要即时重算（设置页返回后无需重进会话）。
    _lastStepDisplayMode = widget.store.stepDisplayMode;
    _lastTurnFoldTiming = widget.store.turnFoldTiming;
    widget.store.addListener(_onStoreChanged);
    _scrollCtrl.addListener(_onScrollTick);
    // issue #114：滚动跟随意图/校正的唯一 owner（生产与测试共用同一 seam）。
    _scrollFollow = ScrollFollowCoordinator(ensureFrame: _ensureScrollFollowFrame);
    _load();
    // v2.7：恢复该会话上次未发送的输入草稿
    final sid = _mySessionId;
    if (sid != null) {
      final draft = widget.store.draftOf(sid);
      if (draft.isNotEmpty) _inputCtrl.text = draft;
    }
    _inputCtrl.addListener(_onDraftChanged);
    _syncSlashHighlightCatalog();
    if (widget.initialSend != null && widget.initialSend!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _send(widget.initialSend!),
      );
    }
  }

  // issue #52：只在「轮次过程」相关的两项偏好真的变化时才重建——store 的通知很频繁
  // （SSE 状态、队列、用量…），无差别 setState 会让整条时间线跟着抖。
  WorkStepDisplayMode? _lastStepDisplayMode;
  TurnFoldTiming? _lastTurnFoldTiming;

  /// issue #52：设置变化（展示模式/收起时机）即时重算时间线。
  void _onStoreChanged() {
    final store = widget.store;
    // issue #98：会话切换时清空本页图片授权与缓存（页面通常会被替换，这里兜底
    // 同一实例被复用时也不串会话）。
    final currentSession = store.sessionId;
    if (currentSession != null &&
        _mySessionId != null &&
        currentSession != _mySessionId) {
      _clearImageConsentState();
    }
    if (_lastStepDisplayMode == store.stepDisplayMode &&
        _lastTurnFoldTiming == store.turnFoldTiming) {
      return;
    }
    _lastStepDisplayMode = store.stepDisplayMode;
    _lastTurnFoldTiming = store.turnFoldTiming;
    _invalidateProcessPlan();
    if (mounted) setState(() {});
    // issue #118：档位/收起时机变化会折叠或展开过程段（高度可能变化数百 px），
    // 与手动展开/收同一口径：清底部占位、重测并请求有界跟随。
    _onContentLayoutChanged();
  }

  /// v2.7：输入变化 → 按会话保存草稿（返回/重进后恢复；清空即移除）。
  /// v2.7.2(B 方案)：输入变化同时刷新「排队发送」胶囊的显隐。
  void _onDraftChanged() {
    _syncSlashHighlightCatalog();
    final sid = _mySessionId;
    if (sid != null) widget.store.saveDraft(sid, _inputCtrl.text);
    final token = slashTokenAt(
      _inputCtrl.text,
      _inputCtrl.selection.baseOffset,
    );
    if (mounted) setState(() => _slashToken = token);
    // 输入 / 时并行取命令+技能目录（失败不阻塞输入；下次输入可重试）。
    // issue #97：光标停在消息尾部（不在 slash token 内）时，只要正文含 token 也要加载目录，
    // 否则编辑态已输入的 `/name` 永远无法高亮。
    final hasSlashText = token != null || slashTextTokens(_inputCtrl.text).isNotEmpty;
    if (hasSlashText && sid != null) unawaited(_ensureSlashCatalog(sid));
  }

  void _clearImageConsentState() {
    _imageConsents.clear();
    _imageConsentPrompts.clear();
    _imageConsentDeclined.clear();
    _workspaceImageCache.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = widget.store.sessionId;
    if (current != null && _mySessionId != null && current != _mySessionId) {
      _mySessionId = current;
      _clearImageConsentState();
    }
  }

  @override
  void dispose() {
    _clearImageConsentState();
    _draftTimer?.cancel();
    _activityTimer?.cancel();
    _queueRefreshTimer?.cancel();
    _queuePollTimer?.cancel();
    _queueEditCtrl.dispose();
    _slashScroll.dispose();
    _inputCtrl.removeListener(_onDraftChanged);
    _scrollCtrl.removeListener(_onScrollTick);
    widget.store.removeChatListener(_handleEvent); // v2.7.2 review(M1)
    widget.store.removeListener(_onStoreChanged);
    // v3.3.1：离开该会话（或页面被回收）后恢复系统通知；只在栈顶仍是自己时清空。
    if (LocalNotifier.instance.visibleSession == _mySessionId) {
      LocalNotifier.instance.visibleSession = null;
    }
    // The modal future owns and disposes its Git controller in _openGit.
    _gitController = null;
    _liveReasoningRevision.dispose(); // issue #70：行级通知器随页面释放
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _scrollFollow.dispose();
    super.dispose();
  }

  /// 滚动监听：几何只喂给 owner 更新派生展示（回底按钮/刻度轨），**不改意图**。
  /// 是否跟随由 ScrollFollowCoordinator 依「用户动作 + 世代」决定（§5.2）。
  void _onScrollTick() {
    if (!mounted || _inHistory) return;
    // re-review P2：滚动后行几何/可见性变化，允许活动条重新做几何判定。
    _activityGeometryResolved = false;
    _activityGeometryRefreshScheduled = false;
    _activityGeometryRefreshFrames = 0;
    final pos = _scrollCtrl.position;
    if (!pos.hasContentDimensions) return;
    _scrollFollow.onMetrics(_geometryOfPosition(pos));
    _syncScrollFollowDisplay();
    // issue #24：持续滚动也要校准当前轮。跨 160px 阈值只覆盖显隐切换，
    // 一直停留在"离开底部"时页面不会重建，高亮就会停在旧值。
    _scheduleActiveTurnCalibration();
  }

  /// 合并调度一次「当前轮」几何校准：同一帧内多次滚动只校准一次。
  void _scheduleActiveTurnCalibration() {
    if (_activeTurnCalibrationScheduled) return;
    _activeTurnCalibrationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeTurnCalibrationScheduled = false;
      if (mounted) _updateActiveTurn();
    });
  }

  /// issue #103/#114：展开/收起（卡/组/轮/显示更多）后统一通知滚动层。
  ///
  /// 旧 `_liveBottomGap` 是按更短内容算出的，必须立即失效；跟随意图下由 owner
  /// 合并排一次有界收敛（单次 jump 会被 lazy extent 修正甩开）。阅读态/拖拽中
  /// owner 不会排队，因此用户位置不被抢走。
  void _onContentLayoutChanged() {
    if (!mounted || _inHistory) return;
    if (_liveBottomGap > 0) {
      setState(() => _liveBottomGap = 0);
    }
    _scheduleLiveBottomGapMeasure();
    _requestScrollFollow();
  }

  /// issue #77：按 live 面板实测高度维护「顶部占位」——内容短于视口时让列表底部
  /// 对齐视口底部（center 布局默认顶对齐会在下方留大片空白）。
  ///
  /// 占位单独作为 center 之后的 SliverToBoxAdapter，不改 `_liveSliverKey` 的子项
  /// 索引（轮次导航/尺寸缓存不受影响）。
  void _scheduleLiveBottomGapMeasure() {
    if (_liveGapMeasureScheduled) return;
    _liveGapMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveGapMeasureScheduled = false;
      if (!mounted || _inHistory) return;
      final viewport =
          _liveViewportKey.currentContext?.findRenderObject() as RenderBox?;
      final liveSliver = _liveSliverKey.currentContext?.findRenderObject();
      if (viewport == null || !viewport.hasSize) return;
      if (liveSliver is! RenderSliver) return;
      final geometry = liveSliver.geometry;
      if (geometry == null) return;
      // SliverList 的 scrollExtent 不含外层 SliverPadding 的 6px 底部内边距。
      // 没有任何消息/草稿时不加占位：否则「历史还在加载」的首帧会把空列表测成
      // 满屏占位，内容到达后（下一帧才重测）会被推到视口外——真机首屏与测试都会闪。
      final hasContent = _items.isNotEmpty ||
          _olderItems.isNotEmpty ||
          _draft.isNotEmpty;
      final contentExtent = hasContent ? geometry.scrollExtent + 6 : 0.0;
      // issue #77：分页加载过更早消息后不做短内容底部占位（会与位置修正互相拉扯）。
      final paged = _olderItems.isNotEmpty;
      final desired = hasContent
          ? math.max(0.0, viewport.size.height - contentExtent)
          : 0.0;
      final viewportHeight = viewport.size.height;
      final viewportChanged =
          (viewportHeight - _lastGapViewportHeight).abs() > 0.5;
      _lastGapViewportHeight = viewportHeight;
      // 收敛策略（避免每个 delta 都重建）：内容增长时保留旧占位（内容仍贴底，多出的
      // 空白在视口上方、用户不可见）；内容超过视口时清零；内容明显变短时再补足。
      // 只在「明显短于视口」（还会留下 >80px 空白）时启用底部占位：接近一屏的
      // 内容保持既有顶部对齐，避免与过程行位置/懒构建估算互相干扰。
      // issue #103：lazy SliverList 的 scrollExtent 会随子项构建/展开大幅修正。
      // 内容刚增长时旧的正 gap 一定是按更短内容算出的，先局部清零（避免旧占位
      // 把内容推到视口外/制造空白），再按本帧实测重算。
      final contentGrew =
          hasContent && contentExtent > _lastGapContentExtent + 1;
      _lastGapContentExtent = contentExtent;
      var currentGap = _liveBottomGap;
      if (contentGrew && currentGap > 0) {
        currentGap = 0;
        _liveBottomGap = 0;
        setState(() {});
      }
      // gap 只在「短内容且真实不可滚动」时启用：maxScrollExtent<=1 说明布局完成后
      // 内容确实没有超出视口；只看 lazy scrollExtent 会把估算锯齿当成短内容。
      final actualMax = _scrollCtrl.hasClients
          ? _scrollCtrl.position.maxScrollExtent
          : double.infinity;
      final shortEnough =
          !paged && actualMax <= 1.0 && contentExtent < viewport.size.height - 80;
      // issue #89：占位与内容之和不得超过视口（否则会制造可滚动空白 + 回底按钮）；
      // 视口高度变化（活动条显隐/键盘）必须立即按新高度收敛，不能沿用旧占位。
      final overflowBlank =
          hasContent && contentExtent + currentGap > viewportHeight + 0.5;
      double next = currentGap;
      if (!shortEnough || desired <= 0.5) {
        next = 0;
      } else if (currentGap <= 0.5 ||
          desired > currentGap + 24 ||
          viewportChanged ||
          overflowBlank) {
        next = desired;
      }
      if ((next - _liveBottomGap).abs() > 0.5) {
        _suppressOlderPaging = true;
        setState(() => _liveBottomGap = next);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _suppressOlderPaging = false;
        });
        // 占位变化本身会改变 extent；跟随意图下交给 owner 合并排一次收敛。
        _requestScrollFollow();
      }
      // 注意：这里**不**无条件请求跟随。#114 A3 实测：每次 build 都排队会让
      // 程序性定位（例如测试/导航/用户手势把视口放在 160px 内）被下一帧拉回底部，
      // 违反「位置移动来自用户动作才恢复/保持跟随」；内容/布局变化由事件入口
      // (`_handleEvent` / `_onContentLayoutChanged` / 活动条显隐) 显式请求。
    });
  }

  /// 一键回到最新消息：显式进入跟随，由 owner 做有界收敛。
  ///
  /// 不做“近距平滑/远距直接跳”的分支：lazy SliverList 的 max 是估值，动画/单跳到
  /// 估值上都会被后续布局修正甩开（#77/#103 教训）；统一走帧后校正 + 有界复核。
  void _jumpToLatest() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    AppLog.instance.log(
      'Chat: 回到底部(显式) pixels=${pos.pixels.toStringAsFixed(0)} '
      'max=${pos.maxScrollExtent.toStringAsFixed(0)}',
    );
    _requestScrollFollow(
      forced: true,
      reason: CorrectionReason.explicitBackToBottom,
    );
    // 既有同帧契约：点按钮后本帧就完成跳转（后续帧仍由 owner 复核收敛）。
    _applyScrollCorrectionImmediately();
  }

  // ── issue #24：轮次导航（ADR 0018）──────────────────────────────────

  /// 已加载窗口里的轮次锚点（按轮次号升序）。
  ///
  /// 两条列表的物理顺序都不是时间序：`_olderItems` 靠近 center 的在前面（远→近），
  /// `_items` 最新在前。折叠要求时间正序，所以两者都反转后拼接。
  List<TurnAnchor> get _turnAnchors {
    final rows = <TurnRow>[];
    void addItem(_MsgItem item) {
      final seq = item.seq;
      final boundary = seq == null ? null : _turnOfStartSeq[seq];
      if (boundary != null && item.kind == _MsgKind.divider) {
        rows.add(TurnRow(boundaryTurn: boundary, seq: seq));
        return;
      }
      switch (item.kind) {
        case _MsgKind.user:
          // 只有**真人来源**的 user 消息才算提示词：显式非 user 来源
          // （agent-instructions / plugin / tool…）与旧内核的注入噪声都不占用 prompt，
          // 判据复用时间线既有的一份（`_MsgItem.injected` + `timelineIsInjectedNoise`），
          // 不在这里另起一套，也不因普通/调试模式而分叉。
          final human = !item.injected && !timelineIsInjectedNoise(item.text);
          rows.add(
            TurnRow(
              role: human ? TurnRowRole.user : TurnRowRole.other,
              text: item.text,
            ),
          );
        case _MsgKind.assistant:
          rows.add(TurnRow(role: TurnRowRole.assistant, text: item.text));
        default:
          rows.add(const TurnRow());
      }
    }

    for (final item in _olderItems.reversed) {
      addItem(item);
    }
    for (final item in _items.reversed) {
      addItem(item);
    }
    return foldTurnAnchors(rows);
  }

  /// 给轮次边界条目挂稳定 key，供定位与"当前轮"判定读取真实几何。
  /// 非边界条目原样构建（不引入额外包装）。
  ///
  /// 键身份是**边界持久 seq**，不是轮次号：同一轮号可以有多个相邻的 `turn/start`
  /// （重试边界），按轮号分配会让它们共用同一个 GlobalKey。
  Widget _buildItemWithTurnKey(_MsgItem item, {bool historyView = false}) {
    final seq = item.seq;
    final child = _buildItemWithTurnKeyBody(item, historyView: historyView);
    // 过程块锚在该轮过程行实际出现的位置（提示词之后），而不是 turn/start 分隔条。
    final blocks = seq == null
        ? null
        : _planFor(history: historyView).hostsBySeq[seq];
    if (blocks == null || blocks.isEmpty) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final plan in blocks) _buildProcessBlockPlan(plan),
        child,
      ],
    );
  }

  Widget _buildItemWithTurnKeyBody(
    _MsgItem item, {
    required bool historyView,
  }) {
    final seq = item.seq;
    final turn = seq == null ? null : _turnOfStartSeq[seq];
    if (turn == null || seq == null || item.kind != _MsgKind.divider) {
      return _buildItem(item, historyView: historyView);
    }
    final key = _turnKeysBySeq.putIfAbsent(seq, () => GlobalKey());
    return KeyedSubtree(
      key: key,
      child: _buildItem(item, historyView: historyView),
    );
  }

  /// 当前阅读的轮次。
  ///
  /// 懒构建下屏幕外的条目没有渲染对象，因此只用**已构建**的边界几何做选择：
  /// 取起点不晚于阅读线的最后一个刻度；边界恰好被回收（长回复）时，用阅读线的
  /// 内容偏移与最后一次实测缓存推断；再不行就**保留上一次判定**，绝不无条件跳最新。
  void _updateActiveTurn() {
    if (!mounted) return;
    final anchors = _turnAnchors;
    int? next;
    if (anchors.isNotEmpty) {
      if (_scrollFollow.isFollowing) {
        next = anchors.last.turn;
      } else {
        final viewport =
            _liveViewportKey.currentContext?.findRenderObject() as RenderBox?;
        if (viewport != null && viewport.hasSize) {
          final viewportTop = viewport.localToGlobal(Offset.zero).dy;
          final lineOffset = _readingLineOffset(viewport);
          final line = viewportTop + lineOffset;
          final pixels = _scrollCtrl.hasClients
              ? _scrollCtrl.position.pixels
              : 0.0;
          final mountedTurns = <({int turn, double top})>[];
          for (final anchor in anchors) {
            final box =
                _turnKeysBySeq[anchor.seq]?.currentContext?.findRenderObject()
                    as RenderBox?;
            if (box == null || !box.hasSize) continue;
            final top = box.localToGlobal(Offset.zero).dy;
            mountedTurns.add((turn: anchor.turn, top: top));
            // 顺手刷新内容偏移缓存——边界一旦被回收就再也量不到了。
            _turnContentOffset[anchor.turn] = pixels + (top - viewportTop);
          }
          if (mountedTurns.isEmpty) {
            // 目标轮起始边界未构建：用阅读线的内容偏移 + 缓存反查所属轮次。
            next = _turnAtContentOffset(pixels + lineOffset);
          } else {
            next = activeTurnFromMounted(mountedTurns, readingLine: line);
          }
        }
        next ??= _activeTurn;
        next ??= anchors.last.turn;
      }
    }
    if (next != _activeTurn) setState(() => _activeTurn = next);
    _pruneTurnOffsets(anchors);
  }

  /// 阅读线落在哪一轮：取内容偏移不晚于 [contentOffset] 的最大已实测轮次。
  int? _turnAtContentOffset(double contentOffset) {
    int? best;
    var bestOffset = double.negativeInfinity;
    _turnContentOffset.forEach((turn, offset) {
      if (offset <= contentOffset && offset > bestOffset) {
        bestOffset = offset;
        best = turn;
      }
    });
    return best;
  }

  /// 丢弃已不在窗口内的轮次缓存，避免陈旧偏移把高亮拉回旧轮。
  void _pruneTurnOffsets(List<TurnAnchor> anchors) {
    if (_turnContentOffset.isEmpty) return;
    final live = anchors.map((a) => a.turn).toSet();
    _turnContentOffset.removeWhere((turn, _) => !live.contains(turn));
  }

  /// 已构建轮次边界的实测几何（内容坐标），供定位循环逐帧校正。
  List<TurnMeasurement> _measureTurnBoundaries() {
    final viewport =
        _liveViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return const [];
    final viewTop = viewport.localToGlobal(Offset.zero).dy;
    final pixels = _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : 0.0;
    final out = <TurnMeasurement>[];
    for (final anchor in _turnAnchors) {
      final box =
          _turnKeysBySeq[anchor.seq]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final offset = pixels + (box.localToGlobal(Offset.zero).dy - viewTop);
      _turnContentOffset[anchor.turn] = offset;
      out.add(TurnMeasurement(turn: anchor.turn, offset: offset));
    }
    return out;
  }

  /// 目标边界是否与消息流视口相交（"已构建"不等于"看得见"）。
  bool _turnKeyInViewport(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    final viewport =
        _liveViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || viewport == null || !viewport.hasSize) {
      return false;
    }
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final viewTop = viewport.localToGlobal(Offset.zero).dy;
    final viewBottom = viewTop + viewport.size.height;
    return bottom > viewTop && top < viewBottom;
  }

  /// 目标持久 seq 在**内容顺序**里的位置（定位的索引坐标；-1 表示找不到）。
  ///
  /// 注意不能用"sliver 内的子项序号"：消息流是 `center` 锚点的 `CustomScrollView`，
  /// center **之前**那条列表的子项 0 紧贴 center、序号越大越靠**上**（内容偏移越小），
  /// 与内容顺序正好相反。定位区间必须建立在内容顺序上（索引越大、内容偏移越大），
  /// 否则"目标在落点之前还是之后"会判反——prepend 后的早期目标正是踩在这个反向上
  /// （实测：目标被两个实测点夹成 `[0, 0]`，每次落点都被夹回 0，完全不滚动）。
  ///
  /// 内容顺序：`_olderItems` 最新在前（`[0]` 紧贴 center），因此内容序号倒序；
  /// center 之后是「更早」按钮 / 加载条（若有）→ `_items`（最新在前）→ 草稿。
  int _contentIndexOfSeq(int seq) {
    for (var i = 0; i < _olderItems.length; i++) {
      if (_olderItems[i].seq == seq) return _olderItems.length - 1 - i;
    }
    final base = _olderItems.length + (_olderButtonVisible ? 1 : 0);
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].seq == seq) {
        return base + (_items.length - 1 - i);
      }
    }
    return -1;
  }

  /// 内容顺序下的子项总数（比例兜底用）。
  int get _contentChildCount =>
      _olderItems.length + (_olderButtonVisible ? 1 : 0) + _items.length;

  /// center 之后那条列表的首项是否为「更早」按钮 / 加载条（与 `_buildChatView` 一致）。
  bool get _olderButtonVisible =>
      (!_infiniteMode && _earliestSeq > 0) ||
      (_infiniteMode && _loadingMore && _earliestSeq > 0);

  /// 已构建**子项**的实测几何（内容顺序索引 + 内容偏移 + 高度），供定位循环判断目标
  /// 在当前落点的**之前还是之后**并收窄搜索区间。
  ///
  /// 为什么不用轮次边界：边界只在恰好被构建时才有 key，长回复会把落点前后变成
  /// 一大片"没有边界"的区域（复审轨迹里 `measure()` 连续两轮为空）；而 `SliverList`
  /// 的每个已构建子项都带真实索引与高度，据此维护的上下界收得拢，也能用
  /// `offset + height` 得到"长回复之后"的有效下界。
  List<BuiltChildMeasurement> _measureBuiltChildren() {
    final viewport =
        _liveViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return const [];
    final viewTop = viewport.localToGlobal(Offset.zero).dy;
    final pixels = _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : 0.0;
    final out = <BuiltChildMeasurement>[];
    void collect(
      GlobalKey key,
      int base, {
      required int count,
      required bool contentOrderReversed,
    }) {
      final sliver = key.currentContext?.findRenderObject();
      if (sliver is! RenderSliverMultiBoxAdaptor) return;
      for (
        var child = sliver.firstChild;
        child != null;
        child = sliver.childAfter(child)
      ) {
        final parentData = child.parentData;
        if (parentData is! SliverMultiBoxAdaptorParentData) continue;
        final local = parentData.index;
        if (local == null || !child.hasSize) continue;
        final contentIndex = contentOrderReversed ? count - 1 - local : local;
        final offset = pixels + (child.localToGlobal(Offset.zero).dy - viewTop);
        final index = base + contentIndex;
        final height = child.size.height;
        out.add(
          BuiltChildMeasurement(index: index, offset: offset, height: height),
        );
        // issue #31（方案 B）：顺手把实测高度回填进尺寸缓存（key 稳定，prepend/
        // 加载条出现都不会错位）。缓存只增不改，超过上限时整体清空重建。
        final stableKey = _itemKeyAtIndex(index);
        if (stableKey != null && height > 0) {
          if (_itemHeights.length > 6000) _itemHeights.clear();
          _itemHeights[stableKey] = height;
        }
      }
    }

    // center 之前：`_olderItems` 最新在前，内容顺序与子项序号相反。
    collect(
      _olderSliverKey,
      0,
      count: _olderItems.length,
      contentOrderReversed: true,
    );
    // center 之后：`SliverMultiBoxAdaptorParentData.index` **已经包含**首项
    // 「更早」按钮 / 加载条，所以基准只加前一条 sliver 的长度，不能再加一次首项偏移——
    // 否则加载条显示期间消息的实测 index 会比目标坐标系大 1，定位器把前一条消息当成目标
    // （第二轮评审 note 1080 的对照复现：同样数据，仅"上翻在途"这一项不同就跳不到）。
    collect(
      _liveSliverKey,
      _olderItems.length,
      count: _items.length,
      contentOrderReversed: false,
    );
    return out;
  }

  /// 内容索引 → 该子项的**稳定尺寸缓存 key**（`seq` 优先，工具卡用 `latestSeq`）。
  ///
  /// 「更早」按钮 / 加载条 / 草稿不是消息，返回 null（它们不参与尺寸缓存）。
  int? _itemKeyAtIndex(int index) {
    if (index < 0) return null;
    _MsgItem? item;
    if (index < _olderItems.length) {
      item = _olderItems[_olderItems.length - 1 - index];
    } else {
      final base = _olderItems.length + (_olderButtonVisible ? 1 : 0);
      final local = index - base;
      if (local < 0) return null; // 首项按钮 / 加载条
      final i = _items.length - 1 - local;
      if (i >= 0 && i < _items.length) item = _items[i];
    }
    return item == null ? null : (item.seq ?? item.latestSeq);
  }

  /// 内容索引 → 该子项**顶部的内容偏移估算**（issue #31 方案 B）。
  ///
  /// 本体虚拟化列表用 `itemSizeCache + estimateSize` 做 `getOffsetForIndex`；这里用
  /// 等价的两段式估算：
  ///   `已缓存条目的实测高度和 + 平均高度 × 未缓存条目数`
  /// 平均高度优先取缓存实测均值（热缓存下很准），冷缓存退化为
  /// `(maxScrollExtent - minScrollExtent) / childCount` 的比例估算——**仍远优于盲二分**
  /// （目标在 20% 处就估 20%，而不是先跳 50%）。返回 null 表示无法估算，定位器会退回
  /// 区间二分/割线估算。
  double? _estimateOffsetForIndex(int targetIndex) {
    if (!_scrollCtrl.hasClients) return null;
    final childCount = _contentChildCount;
    if (childCount <= 0) return null;

    // 回退均值：优先用缓存实测均值，冷缓存退化为 extent / childCount 的比例估算。
    var average = 0.0;
    if (_itemHeights.isNotEmpty) {
      var total = 0.0;
      var count = 0;
      for (final height in _itemHeights.values) {
        if (height > 0) {
          total += height;
          count += 1;
        }
      }
      if (count > 0) average = total / count;
    }
    if (average <= 0) {
      final extent =
          _scrollCtrl.position.maxScrollExtent -
          _scrollCtrl.position.minScrollExtent;
      if (extent <= 0) return null;
      average = extent / childCount;
    }
    if (!average.isFinite || average <= 0) return null;

    // **有符号**：相对 `CustomScrollView.center` 的坐标（older 侧为负、live 侧为正），
    // 与定位器实测的 measureBuilt 偏移同一坐标系（复审 P2：非负前缀会整体平移，
    // 估算永远通不过 (lo, hi) 判据）。center 处的内容索引 = 内容子项数 − live 条数。
    double? heightOf(int index) {
      final key = _itemKeyAtIndex(index);
      final height = key == null ? null : _itemHeights[key];
      return (height != null && height > 0) ? height : null;
    }

    final centerIndex = childCount - _items.length;
    final raw = estimateSignedContentOffset(
      targetIndex: targetIndex,
      centerIndex: centerIndex,
      childCount: childCount,
      cachedHeight: heightOf,
      averageHeight: average,
    );
    if (raw == null) return null;
    // **归一化到真实 extent**（复审二轮修订）：未缓存区间用平均高度时，权重总和与真实
    // 内容高度未必同尺度——实测里热跳的首个估算因此偏小近 2 倍，逼出 3–4 步二分。
    // 把"已缓存实测高度 + 未缓存均值"的总权重映射到布局给出的真实 extent，缓存只影响
    // **相对权重**，估算随实际高度分布伸缩而不是随样本均值漂移。
    final extent =
        _scrollCtrl.position.maxScrollExtent -
        _scrollCtrl.position.minScrollExtent;
    if (extent <= 0) return null;
    final total = estimateSignedContentOffset(
      targetIndex: childCount,
      centerIndex: 0,
      childCount: childCount,
      cachedHeight: heightOf,
      averageHeight: average,
    );
    if (total == null || total <= 0) return null;
    return raw * extent / total;
  }

  /// 跳转到某一轮：**按实测几何校正的有界迭代定位**。
  ///
  /// `Scrollable.ensureVisible` 只能作用于已构建的渲染对象，而消息流是懒构建的
  /// `SliverList`——屏幕外的轮次根本没有 element。所以先按目标真实子项序号做比例
  /// 兜底，再用已构建边界的**实测内容偏移**插值/割线外推逐帧校正；重试有界且受
  /// `kTurnLocateHardCapMs` 绝对安全网，最终必须让目标**与视口相交**才算成功。
  ///
  /// [token] 是这次导航的世代（issue #25 评审 P2）：跨页跳转定位到目标、或被新选择
  /// 取代时旧的定位不得再滚动视口 / 弹提示 / 清 busy。
  Future<void> _jumpToTurn(TurnAnchor anchor, {int? token}) async {
    if (!_scrollCtrl.hasClients) return;
    final generation = token ?? _turnNavGeneration;
    bool current() => mounted && generation == _turnNavGeneration;
    // 统一走有界迭代定位：即使边界已构建也由定位器按实测几何落点，并以
    // "目标与视口相交"复核。此前"已构建就先走 ensureVisible 并直接 return"会在
    // prepend 等场景下静默不滚动（目标在缓存区、`ensureVisible` 未改变偏移），
    // 也不复核最终是否真的可见。
    setState(() => _busyTurn = anchor.turn);
    try {
      final childCount = _contentChildCount;
      final childIndex = _contentIndexOfSeq(anchor.seq);
      final locator = TurnLocator(
        scrollTo: (offset) {
          // 世代失效后一律不得再滚动：这是"旧操作抢落点"的最后一道闸。
          if (current() && _scrollCtrl.hasClients) {
            _runProgrammaticScroll(() => _scrollCtrl.jumpTo(offset));
          }
        },
        minScrollExtent: () =>
            _scrollCtrl.hasClients ? _scrollCtrl.position.minScrollExtent : 0,
        maxScrollExtent: () =>
            _scrollCtrl.hasClients ? _scrollCtrl.position.maxScrollExtent : 0,
        currentOffset: () =>
            _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : 0,
        viewportExtent: () =>
            _scrollCtrl.hasClients ? _scrollCtrl.position.viewportDimension : 0,
        // 目标一律按**边界持久 seq** 绑定：同轮号的重试边界不会误伤规范边界。
        isTargetLoaded: () => _turnAnchors.any((a) => a.seq == anchor.seq),
        isTargetBuilt: () => _turnKeysBySeq[anchor.seq]?.currentContext != null,
        isTargetInView: () => _turnKeyInViewport(_turnKeysBySeq[anchor.seq]),
        reveal: () => _revealTurnKey(_turnKeysBySeq[anchor.seq]),
        measure: _measureTurnBoundaries,
        measureBuilt: _measureBuiltChildren,
        // issue #31（方案 B）：尺寸缓存给出的"索引 → 偏移"估算（本体 getOffsetForIndex 的等价物）。
        estimateOffsetForIndex: _estimateOffsetForIndex,
        settle: () => WidgetsBinding.instance.endOfFrame,
      );
      final outcome = await locator.locate(
        targetTurn: anchor.turn,
        targetIndex: childIndex < 0 ? childCount - 1 : childIndex,
        childCount: childCount,
      );
      if (!current()) return;
      if (outcome.ok) {
        // issue #81：正文宽度受 action gutter 影响（16/36/38），定位器只保证目标
        // 「与视口相交」；若目标边界落在阅读线下方，高亮会停留在上一轮。落到目标后
        // 把边界对齐到阅读线附近，保证「点了第 N 轮 → 高亮第 N 轮」。
        await _alignTargetToReadingLine(anchor.seq);
        return;
      }
      if (!mounted) return; // 让分析器认得 context 守卫（current() 已含 mounted）
      final message = switch (outcome.failure) {
        TurnLocateFailure.notInWindow => L10n.t(
          '未能定位到第 ${anchor.turn} 轮：它不在当前已加载范围内',
          'Could not locate turn ${anchor.turn}: it is outside the loaded range',
        ),
        _ => L10n.t(
          '未能定位到第 ${anchor.turn} 轮：多次尝试后仍未进入视图',
          'Could not locate turn ${anchor.turn}: still out of view after several attempts',
        ),
      };
      showToast(context, message);
    } finally {
      if (current()) setState(() => _busyTurn = null);
    }
  }

  /// 阅读线相对视口顶部的偏移（`_updateActiveTurn` 与定位落点复核共用同一公式）。
  double _readingLineOffset(RenderBox viewport) =>
      math.min(96.0, viewport.size.height * 0.2);

  /// 精调：把已构建的目标边界带进视口（不负责判定成功）。
  Future<void> _revealTurnKey(GlobalKey? key) async {
    final ctx = key?.currentContext;
    if (ctx == null) return;
    _scrollFollow.beginProgrammaticScroll();
    try {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _scrollFollow.endProgrammaticScroll();
    }
  }

  /// issue #81：定位成功后把目标轮起始边界对齐到阅读线附近（仅在落在阅读线下方时），
  /// 让「当前轮高亮」与实际跳转目标一致（不受 action gutter 宽度变化影响）。
  Future<void> _alignTargetToReadingLine(int seq) async {
    final box = _turnKeysBySeq[seq]?.currentContext?.findRenderObject() as RenderBox?;
    final viewport =
        _liveViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || viewport == null || !viewport.hasSize) {
      return;
    }
    final lineOffset = math.min(96.0, viewport.size.height * 0.2);
    final top = box.localToGlobal(Offset.zero).dy;
    final viewTop = viewport.localToGlobal(Offset.zero).dy;
    if (top - viewTop <= lineOffset) return;
    await _revealTurnKey(_turnKeysBySeq[seq]);
  }

  /// 提交问询答案（answers 顺序与提问一致），失败时弹窗保留可重试。
  Future<void> _submitQuestion(List<Map<String, dynamic>> answers) async {
    final q = _question;
    if (q == null) return;
    AppLog.instance.log('Chat: 回答问询 ${q.rpcId}（${answers.length} 问）');
    final err = await widget.store.answerQuestion(
      q.rpcId,
      q.sessionId,
      answers,
    );
    if (!mounted) return;
    if (err != null) {
      showToast(context, err);
    } else {
      setState(() => _question = null);
    }
  }

  /// 审批工具权限：outcome = allowed-once | rejected。
  Future<void> _decideApproval(String outcome) async {
    final a = _approval;
    if (a == null) return;
    AppLog.instance.log('Chat: 审批 ${a.toolName} → $outcome');
    final err = await widget.store.answerApproval(
      a.rpcId,
      a.sessionId,
      a.approvalId,
      outcome,
    );
    if (!mounted) return;
    if (err != null) {
      showToast(context, err);
    } else {
      setState(() => _approval = null);
    }
  }

  /// 取消（跳过）挂起的问询/审批：卡片已乐观收起，这里只负责把取消送到内核。
  /// v3.1.6（app-audit ①6）：显式带本页会话 id（本地挂起表可能已被对端先答清空），
  /// 失败不再静默——离线时明确告诉用户"取消失败"，而不是让他以为已经取消。
  Future<void> _cancelPending(String rpcId) async {
    final err = await widget.store.cancelRespond(
      rpcId,
      sessionId: _mySessionId,
    );
    if (!mounted || err == null) return;
    showToast(context, err);
  }

  /// issue #66（M3 Batch 2-A）：工具行尾「打开问询」入口——用 modal bottom sheet 复用
  /// 既有 [_QuestionCard] 作答，**不在工具行内**放任何作答控件，也不改 attention//respond
  /// 流程（取消/提交仍走 [_cancelPending] / [_submitQuestion]）。
  Future<void> _openPendingQuestion() async {
    final q = _question ?? widget.store.questionForSession(_mySessionId);
    if (q == null) {
      if (!mounted) return;
      showToast(context, L10n.t('问询已结束', 'Question is no longer pending'));
      return;
    }
    // _submitQuestion 读取页面状态：store 已同步而页面尚未同步的极小窗口里先对齐，
    // 避免弹层里提交后静默无回写。
    if (_question == null) setState(() => _question = q);
    late BuildContext sheetContext;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        sheetContext = ctx;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: _QuestionCard(
                key: ValueKey<String>('question-sheet:${q.rpcId}'),
                request: q,
                onCancel: () {
                  final rpc = q.rpcId;
                  // 先收起弹层；取消语义与 composer 卡片一致（乐观收起 + 送内核）。
                  if (sheetContext.mounted &&
                      ModalRoute.of(sheetContext)?.isCurrent == true) {
                    Navigator.of(sheetContext).maybePop();
                  }
                  if (mounted && _question?.rpcId == rpc) {
                    setState(() => _question = null);
                  }
                  unawaited(_cancelPending(rpc));
                },
                onSubmitted: (answers) async {
                  await _submitQuestion(answers);
                  // R6（issue #66 评审）：await 期间用户可能已手动关掉弹层——pop 前确认
                  // 上下文仍 mounted 且弹层仍是当前路由，否则会误 pop 聊天页。
                  if (sheetContext.mounted &&
                      ModalRoute.of(sheetContext)?.isCurrent == true) {
                    Navigator.of(sheetContext).maybePop();
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// 流式草稿节流：chunk 到达只累加文本，定时（~80ms）合并刷新一次。
  void _scheduleDraftFlush() {
    _streaming = true;
    _draftTimer ??= Timer(const Duration(milliseconds: 80), () {
      _draftTimer = null;
      // issue #77：草稿增长会改变内容高度；先撤销短内容占位，下一帧重测。
      if (_liveBottomGap > 0) _liveBottomGap = 0;
      if (mounted) setState(() {});
      _requestScrollFollow();
    });
  }

  /// 活动条节流：思考/工具状态变化定时合并刷新（不滚动）。
  void _scheduleActivityFlush() {
    _activityTimer ??= Timer(const Duration(milliseconds: 80), () {
      _activityTimer = null;
      if (mounted) setState(() {});
    });
  }

  /// [reset] = true：按**当前会话表面**重建（`/compact` 改写了表面、或轮次兜底补拉）——
  /// 丢弃现有条目并从历史重建，`_lastSeq` 以历史末条为准。默认 false：打开会话时带并发保护
  /// （保留历史请求期间 SSE 已入列的新条目）。
  Future<void> _load({bool reset = false}) async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final generation = ++_loadGeneration;
    AppLog.instance.log(reset ? 'Chat: 重同步会话（按新表面重载）$id' : 'Chat: 打开会话 $id');
    try {
      final page = await _api.historyPage(id, limit: _liveMax);
      _absorbTurnTails(page.turnTails);
      final events = page.events;
      AppLog.instance.log(
        'Chat: 历史加载成功 ${events.length} 条${reset ? '（重同步）' : ''}',
      );
      // v3.1.6（app-audit ②）：守卫之后才写降级标记——过期响应（会话切换/重同步重叠）此前
      // 也会改写横幅状态：`_historyDegraded` 是赋值语义，过期页能把已置位的提示抹回 false。
      if (!mounted || generation != _loadGeneration || id != _mySessionId) {
        return;
      }
      setState(() {
        // 打开/重同步会话时以本次响应为准（赋值，而非 |=）：避免上一条会话的「仅部分历史」
        // 横幅残留到正常会话。后续增量分页（after/before）仍用 |=：任一页降级即持续提示。
        _historyDegraded = page.degraded;
        // 并发保护：历史请求期间 SSE 可能已把更新的事件入列（位于 _items 头部）。
        // 先收集保留项，再重建其余部分，不回退 _lastSeq。
        final fetchedLast = events.isNotEmpty ? (events.last.seq ?? 0) : 0;
        final keep = <_MsgItem>[];
        // _items is newest-first. Rebuild every load from this durable snapshot,
        // then replay the post-snapshot cursor below; this avoids split tool cards
        // when a live result merged into a call card anchored at an older seq.
        for (final m in _items) {
          final cardSeq = m.latestSeq ?? m.seq;
          if (cardSeq != null) {
            if (cardSeq > fetchedLast) {
              // Durable replay below reconstitutes these records into the same
              // grouped card; do not insert the old rendered projection directly.
              continue;
            }
            if (cardSeq <= fetchedLast) {
              // 列表按 seq 从新到旧排列，遇到快照内事件即可停止。
              break;
            }
            // reset=true：跳过请求期间的 SSE 条目，稍后从 durable cursor 重放。
            continue;
          }
          if (m.kind == _MsgKind.user) {
            // 无 seq 的乐观消息（刚发送尚未回显）也保留，避免重建后短暂消失。
            keep.add(m);
          }
          // 无 seq 的非用户条目（如发送失败提示）跳过。
        }
        _noMoreHistory = false;
        _items.clear();
        _olderItems.clear();
        _histItems.clear();
        _turnOfStartSeq.clear(); // issue #24：条目重建后轮次索引一并失效
        _turnKeysBySeq.clear();
        _turnContentOffset.clear();
        // issue #25 二期：大纲同属"这一条会话"，重建/切换后一并失效，
        // 否则旧会话的未加载刻度会短暂挂到新会话的刻度轨上（串台）。
        _turnOutline = const TurnOutline.capabilityMissing();
        _turnOutlineResolved = false; // 还没问过新会话：不得据此给"能力缺失"结论
        _turnOutlineNoticeShown = false;
        // 历史重建作废进行中的跳转：其落点/提示/busy 清理都不再对当前列表有效；
        // 已在 setState 内，这里直接清 busy（旧 finally 已因世代失效不再收尾）。
        _turnNavGeneration += 1;
        _busyTurn = null;
        // issue #31：条目重建（会话切换/重同步）后尺寸缓存一并失效——同一 seq 的高度
        // 在新一轮渲染里可能不同（流式结束、折叠状态变化），留着会给出错的估算。
        _itemHeights.clear();
        _timelineReducer.reset();
        // issue #52：条目按新表面重建时，轮次过程结构与会话内手动折叠状态一并失效
        // （「离开会话即失」——重建等价于重新进入）。
        _turnProcess.reset();
        _turnTails.clear();
        _deliverablesByTurn.clear();
        _changedSummaryCache.clear();
        _changedSummaryRequested.clear();
        _changedSummaryRetryAfter.clear();
        _changedSummaryErrors.clear();
        _linkResolvers.clear();
        _tailLoadGeneration++;
        _turnTailVersion++;
        _processTurns = const [];
        _processTurnMap = const {};
        _processVersion++;
        _processBuiltVersion = -1;
        _turnExpansions.clear();
        _groupExpansions.clear();
        _reasoningRowExpansions.clear();
        _processRowLimits.clear();
        _livePlanCache = null;
        _histPlanCache = null;
        _invalidateProcessPlan();
        _transientFrameKeys.clear();
        _debugPreviewCache.clear(); // 重建后 rawData 全变，旧预览缓存无意义
        _activeTools.clear();
        // issue #70：按新表面重建 = 重新进入会话，流式思考缓冲与 provisional 展开态一并失效。
        _liveReasoning.clear();
        _liveReasoningRevision.value++;
        _provisionalExpansions.clear();
        _reasoningExpanded = false;
        _draft = '';
        _streaming = false;
        // v3.1.4（issue #12 姊妹需求）：任务清单按**时间正序**折叠一次（最新覆盖、turn/start 清空），
        // 与内核投影一致——历史事件在下面按倒序入列渲染，顺序敏感的状态必须单独折叠。
        var foldedTodos = <Map<String, dynamic>>[];
        for (final ev in events) {
          if (ev.type == 'turn/start') {
            foldedTodos = [];
          } else if (ev.type == 'todo/write') {
            foldedTodos = ((ev.data?['todos'] as List?) ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList();
          }
        }
        _todos = foldedTodos;
        // 最新在前（渲染时倒序，最新位于列表底部）
        for (final ev in events.reversed) {
          if (ev.seq != null && ev.seq! > fetchedLast) continue;
          _appendEvent(ev, history: true, tail: true);
        }
        _rebuildActiveToolsFromHistory(events);
        // v3.1.4（issue #13）：跟踪字段按**时间正序**重算——历史是倒序入列的，
        // 沿用循环里的赋值会得到"最旧一条"，导致轮次兜底误判。
        // 条件与渲染保持一致：真人 user 消息（含旧内核无 sourceKind 的）+ 非空文本的回复。
        if (reset) {
          _lastUserSeq = null;
          _lastAssistantSeq = null;
        }
        for (final ev in events) {
          if (ev.seq == null) continue;
          if (ev.type == 'user/message') {
            final kind = ev.data?['sourceKind'] as String?;
            if (kind == null || kind == 'user') _lastUserSeq = ev.seq;
          } else if (ev.type == 'assistant/message' &&
              ((ev.data?['text'] as String?) ?? '').trim().isNotEmpty) {
            _lastAssistantSeq = ev.seq;
          }
        }
        final durableUsers = _items
            .where((m) => m.kind == _MsgKind.user)
            .toList();
        final keepWithoutEcho = keep.where((m) {
          final duplicate = durableUsers.any((d) {
            if (m.messageId != null && d.messageId != null) {
              return m.messageId == d.messageId;
            }
            return m.messageId == null &&
                d.messageId == null &&
                m.text.trim().isNotEmpty &&
                m.text == d.text;
          });
          return !duplicate;
        }).toList();
        _items.insertAll(0, keepWithoutEcho); // SSE 期间的新事件放回头部
        if (events.isNotEmpty) _earliestSeq = events.first.seq ?? 0;
        // All durable events newer than this snapshot are replayed below,
        // including an in-flight tool result whose card had an older anchor seq.
        _lastSeq = fetchedLast;
      });
      unawaited(_catchup(force: true));
      // v2.7.2 review：队列同步移到 setState 之外（避免误导为嵌套 setState）
      _refreshQueue();
      // v3.1.4：任务清单权威读法（内核投影同源）——历史折叠只在最近窗口内有效，
      // 这里再对一次，保证打开会话即看到当前清单（休眠/旧内核返回 null 则保持历史折叠结果）
      _refreshTodos();
      AppLog.instance.log(
        'Chat: 已入列 ${_items.length} 条（历史 ${events.length} 条）lastSeq=$_lastSeq firstSeq=$_earliestSeq',
      );
      // issue #114：强制定位统一走 owner 的有界收敛（跳到 lazy 估值后必须布局后再校）。
      _requestScrollFollow(forced: true, reason: CorrectionReason.forcedPosition);
      _refreshUsage();
      widget.store.refreshSessionConfig();
      // issue #25 二期：会话打开后拉一次轮次大纲（能力缺失/读取失败都退回一期行为）。
      unawaited(_refreshTurnOutline());
    } catch (e) {
      if (!mounted || generation != _loadGeneration || id != _mySessionId) {
        return;
      }
      AppLog.instance.log('Chat: 历史加载失败 $id → $e');
      if (mounted) {
        if (_items.isNotEmpty || _olderItems.isNotEmpty) {
          showToast(
            context,
            L10n.t(
              '连接不可用，已保留当前时间线；稍后可重试详情',
              'Connection unavailable; cached timeline kept, retry details later',
            ),
          );
        } else {
          showToast(
            context,
            '${L10n.t('该会话暂不可用：', 'This session is unavailable: ')}$e',
          );
          Navigator.of(context).pop();
        }
      }
    }
  }

  // ── 无限上翻（微信式） ──
  /// 上翻一页的**共用实现**：页大小由调用方给——滚动上翻用 `_histPageSize`（30），
  /// 轮次跨页跳转用 `kTurnJumpPageSize`（200，issue #25 要求不改动既有 30 条/页）。
  Future<_PrependOutcome> _prependOlderPage({required int limit}) async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _loadingMore || _earliestSeq <= 0 || _noMoreHistory) {
      return _PrependOutcome.skipped;
    }
    _loadingMore = true;
    final generation = _loadGeneration;
    AppLog.instance.log('Chat: 上翻一页 before=$_earliestSeq limit=$limit');
    try {
      final page = await _api.historyPage(
        id,
        before: _earliestSeq,
        limit: limit,
      );
      _absorbTurnTails(page.turnTails);
      final events = page.events;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) {
        return _PrependOutcome.skipped;
      }
      // v3.1.6（app-audit ②）：降级标记在守卫之后才写——过期响应不得改写横幅状态
      if (page.degraded) _historyDegraded = true;
      if (events.isEmpty) {
        _noMoreHistory = true;
        return _PrependOutcome.exhausted;
      }
      final pageItems = <_MsgItem>[];
      for (final ev in events) {
        _buildInto(pageItems, ev, history: true);
      }
      setState(() {
        // center 之前的 sliver 按距 center 近→远排列；新取到的一页更早，
        // 反转后追加到尾部，已有 child index 与屏幕位置保持不变。
        _olderItems.addAll(pageItems.reversed);
        _earliestSeq = events.first.seq ?? _earliestSeq;
      });
      AppLog.instance.log(
        'Chat: 上翻完成 items=${_items.length + _olderItems.length} firstSeq=$_earliestSeq',
      );
      return _PrependOutcome.loaded;
    } catch (e) {
      AppLog.instance.log('Chat: 上翻失败 $e');
      return _PrependOutcome.failed;
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  /// 滑到 live 顶部时静默加载更早一页：追加到 center 之前的旧消息 sliver。
  /// center 让顶部增长不会改变当前 viewport 锚点，视觉连续无缝（最新在底部）。
  Future<void> _loadMoreInfinite() async {
    final outcome = await _prependOlderPage(limit: _histPageSize);
    if (!mounted || outcome != _PrependOutcome.exhausted) return;
    showToast(
      context,
      L10n.t(
        _historyDegraded ? '更早历史不可恢复' : '没有更早的消息了',
        _historyDegraded
            ? 'Earlier history unavailable'
            : 'No earlier messages',
      ),
    );
  }

  /// 跨页跳转专用上翻：页大小 200，且**不弹**"没有更早消息"——
  /// 终止说明统一由 `turnJumpOutcomeMessage` 给出，避免两处口径。
  Future<TurnPageLoad> _loadOlderForTurnJump() async {
    // 滚动上翻可能正在加载同一页：先等它结束，避免两次 prepend 竞争同一游标。
    var waited = 0;
    while (_loadingMore && waited < 120 && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      waited += 1;
    }
    final outcome = await _prependOlderPage(limit: kTurnJumpPageSize);
    // 到顶（exhausted）不是失败：如实回报"没有更早历史"，由跳转结果统一说明**不可达**。
    // 但请求失败或没有取得任何进展（仍在加载）必须**显式失败**——否则跳转循环会
    // 对着不变的 earliestSeq 一直空转到页数上限（最坏 32 次 × 等待）。
    if (outcome == _PrependOutcome.failed ||
        outcome == _PrependOutcome.skipped) {
      throw StateError(L10n.t('未能继续加载更早历史', 'Could not load earlier history'));
    }
    return TurnPageLoad(earliestSeq: _earliestSeq, hasMore: !_noMoreHistory);
  }

  /// 无限模式滚动监测：距视觉顶部 80px 内触发加载更早。
  /// v2.8.0：live 视图统一普通（非 reverse）列表，视觉顶部是 pixels≈0。
  /// issue #103：内容 extent 变化（展开/收起/懒构建修正）不会经过 ScrollNotification
  /// 的 drag 路径；单独监听 ScrollMetricsNotification，避免 pinned/回底按钮 stale。
  bool _onLiveScrollMetrics(ScrollMetricsNotification n) {
    if (!mounted || _inHistory) return false;
    // issue #114 task-11：只接受**外层**消息列表的 metrics。工具卡/注入块等内层
    // SingleChildScrollView 的 metrics 冒泡上来（depth>0）时不得污染 owner 几何快照。
    if (n.depth != 0) return false;
    // 几何只作为事实喂给 owner：更新派生展示（回底按钮/刻度轨），不改意图。
    _scrollFollow.onMetrics(_geometryOfMetrics(n.metrics));
    _syncScrollFollowDisplay();
    return false;
  }

  bool _onLiveScroll(ScrollNotification n) {
    // issue #114 task-11：内层滚动（工具卡详情/注入块里的 SingleChildScrollView）
    // 的通知会冒泡到这里；depth>0 一律忽略——否则用户只是滚内层内容，主对话就
    // 被当成“用户手势结束”改写意图（违反“拉到最底部就钉住”）。
    if (n.depth != 0) return false;
    // issue #77/#114：只有带 dragDetails 的真实手势才改变拖拽意图；程序性
    // jump/animate 的 ScrollStart/End 一律不参与（避免“僵尸守卫”与误判上翻）。
    // 用户手势（含松手后的惯性）结束由 owner 按最终几何恢复/保持意图；只有
    // 当前确实处于用户拖拽状态时才把 ScrollEnd 当成用户手势结束。
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _scrollFollow.onUserScrollStart(_geometryOfMetrics(n.metrics));
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _scrollFollow.onUserScrollUpdate(_geometryOfMetrics(n.metrics));
    } else if (n is ScrollEndNotification && _scrollFollow.isDragging) {
      // 只有「当前确实处于用户拖拽/惯性」时的滚动结束才允许改写意图：
      // - 程序性 jump/ensureVisible 的 ScrollEnd：isDragging 为 false（begin 时已清）；
      // - 校正后的异步 ballistic（如下标越界回弹）也没有用户拖拽态；
      // 两者都不会把阅读/跟随意图改错。用户拖拽的惯性结束仍由 owner 按最终几何判定。
      _scrollFollow.onUserScrollEnd(_geometryOfMetrics(n.metrics));
    }
    _syncScrollFollowDisplay();
    // issue #25 二期：跨页跳转进行中，用户主动滚动 = 取消本次跳转（故事 18）——
    // 只有带 dragDetails 的通知才是用户手势，自动滚动不受影响。
    // 同时作废导航世代：旧的落点/提示/清理一律不得再动（第二轮评审 P2）。
    if (_busyTurn != null &&
        ((n is ScrollStartNotification && n.dragDetails != null) ||
            (n is ScrollUpdateNotification && n.dragDetails != null))) {
      _turnJumpCancelled = true;
      _cancelTurnJumpVisual();
    }
    // issue #77：短内容底部占位的调整会改变 extent，由此产生的位置修正
    // （dragDetails=null 的 ScrollUpdate）不得被当成用户上翻去拉更早历史——
    // 该帧内直接跳过；真实手势不受影响。
    // issue #114：程序性校正后的回弹（dragDetails=null 的位移）不是「用户上翻」，
    // 不得触发更早历史分页（否则短内容首屏校正会把同一页重复 prepend）。
    final programmaticUpdate =
        n is ScrollUpdateNotification && n.dragDetails == null;
    final suppressForCorrection =
        programmaticUpdate && _scrollFollow.hasPendingCorrection;
    if (!_suppressOlderPaging &&
        !suppressForCorrection &&
        shouldLoadOlderFromScroll(n, infiniteMode: _infiniteMode)) {
      _loadMoreInfinite();
    }
    return false;
  }

  /// 作废当前导航世代并**主动清掉它自己的"跳转中"视觉状态**。
  ///
  /// 世代守卫保证旧操作不再改落点，但正因为世代失效，旧操作的 `finally` 也不会再清
  /// `_busyTurn`——取消入口必须自己收尾，否则该齿会一直脉冲（第二轮评审 P2）。
  void _cancelTurnJumpVisual() {
    _turnNavGeneration += 1;
    if (_busyTurn != null) {
      setState(() => _busyTurn = null);
    }
  }

  // ── issue #25 二期：宿主轮次大纲 ───────────────────────────────────

  /// 拉取宿主轮次大纲。**先读能力声明**：声明不支持就不发请求，直接保留"能力缺失"态
  /// （退回一期行为），而不是把"能力缺失"和"这个会话没有轮次"混成一件事。
  ///
  /// 能力是**后到**的（首连/重连时序不定），所以会话打开、能力事件到达、历史重建后
  /// 都会调用一次；**大纲刷新有独立请求身份**：同一会话、同一历史世代也会重叠多次
  /// （能力事件与初始刷新并发），迟到的旧响应——无论成功还是失败——都不得覆盖新结果
  /// （第二轮评审 P2）。历史世代/会话身份仍是第一道守卫。
  Future<void> _refreshTurnOutline() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final requestId = ++_turnOutlineRefreshId;
    if (!_api.turnOutlineCapabilities.supported) {
      if (!mounted || requestId != _turnOutlineRefreshId) return;
      setState(() {
        _turnOutline = const TurnOutline.capabilityMissing();
        _turnOutlineResolved = true;
      });
      return;
    }
    final generation = _loadGeneration;
    final outline = await _api.turnOutline(id);
    if (!mounted ||
        generation != _loadGeneration ||
        id != _mySessionId ||
        requestId != _turnOutlineRefreshId) {
      return; // 已有更新的刷新：旧结果（含失败）一律丢弃
    }
    setState(() {
      _turnOutline = outline;
      _turnOutlineResolved = true;
      _turnOutlineNoticeShown = false; // 新大纲：允许再说明一次
    });
  }

  /// 刻度轨条目 = 已加载轮次 ∪ 宿主大纲（issue #25 两路合并）。
  ///
  /// 合并前先看**最新能力声明**：能力被撤销（换宿主 / 宿主降级）时旧大纲必须立刻失效，
  /// 不能继续把上次连接拿到的大纲当成本机能力（issue #25 评审 P2）。
  List<TurnTick> get _turnTicks => mergeTurnTicks(
    loaded: _turnAnchors,
    outline: _api.turnOutlineCapabilities.supported
        ? _turnOutline.turns
        : const [],
  );

  /// 选中某一轮：已加载的直接定位（一期）；未加载的先跨页加载再定位（二期）。
  ///
  /// 每次选择都创建一个**导航世代**（issue #25 评审 P2）：连续点选时，旧操作的
  /// 完成 / 提示 / 清理不得覆盖新操作的落点与 busy 状态；用户主动滚动与历史重建也会作废它。
  Future<void> _navigateToTurn(TurnAnchor anchor) async {
    final token = ++_turnNavGeneration;
    _turnJumpCancelled = false;
    // issue #114：显式轮次定位暂停自动跟随并作废旧校正（§5.1 导航优先级）。
    _scrollFollow.onNavigationStarted();
    final loaded =
        _turnAnchors.any((a) => a.turn == anchor.turn && a.seq == anchor.seq);
    if (loaded) {
      // 一条路径到底：已加载轮次也走同一个世代守卫（#24 修复后 `_jumpToTurn` 支持 token），
      // 连续点选时旧定位不得再把视口搬走。
      await _jumpToTurn(anchor, token: token);
      return;
    }
    await _jumpToUnloadedTurn(anchor, token);
  }

  /// 该导航世代是否仍有效（旧操作一律不得再改落点、状态或弹提示）。
  bool _turnNavCurrent(int token) => mounted && token == _turnNavGeneration;

  /// 跳到"还没加载"的轮次：按 200 条/页**有界**地向前翻，直到覆盖该轮起始序号，
  /// 再走一期定位。翻页期间该齿脉冲；到顶/超预算/取消都**明确说明**。
  Future<void> _jumpToUnloadedTurn(TurnAnchor anchor, int token) async {
    setState(() => _busyTurn = anchor.turn);
    try {
      final pager = TurnPager(
        loadOlder: _loadOlderForTurnJump,
        snapshot: () =>
            TurnPageLoad(earliestSeq: _earliestSeq, hasMore: !_noMoreHistory),
        // 用户主动滚动，或这次操作已被新选择/历史重建作废 → 取消。
        isCancelled: () => _turnJumpCancelled || !_turnNavCurrent(token),
      );
      final outcome = await pager.jumpTo(targetSeq: anchor.seq);
      if (!_turnNavCurrent(token) || !mounted) return;
      if (outcome == TurnJumpOutcome.covered) {
        final match = _turnAnchors.where((a) => a.turn == anchor.turn);
        if (match.isNotEmpty) {
          // 分页刚把更早历史 prepend 进来：先等一帧让布局/极值稳定（`minScrollExtent`
          // 会向负方向扩展），并复核导航 token，然后才进入定位（issue #31 复审 P1）。
          await WidgetsBinding.instance.endOfFrame;
          if (!_turnNavCurrent(token)) return;
          await _jumpToTurn(match.first, token: token);
          return;
        }
        // 序号已覆盖却取不到该轮边界（历史表面不连续）：如实说明，不静默。
        showToast(
          context,
          L10n.t(
            '已加载到第 ${anchor.turn} 轮附近，但未能定位到该轮',
            'Loaded near turn ${anchor.turn} but could not locate it',
          ),
        );
        return;
      }
      final message = turnJumpOutcomeMessage(outcome, anchor.turn);
      if (message != null) {
        showToast(context, message);
      }
    } catch (e) {
      if (mounted && _turnNavCurrent(token)) {
        showToast(context, '${L10n.t('跳转失败：', 'Jump failed: ')}$e');
      }
    } finally {
      // 只有仍是当前操作才清 busy：旧操作的 finally 不得清掉新操作的脉冲。
      if (mounted && _turnNavCurrent(token)) {
        setState(() => _busyTurn = null);
      }
    }
  }

  /// 历史分段浏览 ──
  /// 进入"查看更早"：加载 live 窗口之前的一页（旧→新顺序），普通列表从顶部展示。
  Future<void> _openHistory() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _loadingMore || _earliestSeq <= 0) return;
    _loadingMore = true;
    final generation = _loadGeneration;
    AppLog.instance.log('Chat: 查看更早 before=$_earliestSeq');
    try {
      final page = await _api.historyPage(
        id,
        before: _earliestSeq,
        limit: _histPageSize,
      );
      _absorbTurnTails(page.turnTails);
      final events = page.events;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) {
        return;
      }
      // v3.1.6（app-audit ②）：降级标记在守卫之后才写——过期响应不得改写横幅状态
      if (page.degraded) _historyDegraded = true;
      if (events.isEmpty) {
        showToast(
          context,
          L10n.t(
            _historyDegraded ? '更早历史不可恢复' : '没有更早的消息了',
            _historyDegraded
                ? 'Earlier history unavailable'
                : 'No earlier messages',
          ),
        );
        return;
      }
      setState(() {
        _histItems = _segmentFrom(events);
        _histOldestSeq = events.first.seq ?? 0;
        _histNewestSeq = events.last.seq ?? 0;
        _histHasOlder = events.length >= _histPageSize;
        _histHasNewer = _histNewestSeq < _earliestSeq;
        _inHistory = true;
        _pendingNew = false;
      });
      _scrollToTopOfHistory();
    } catch (e) {
      AppLog.instance.log('Chat: 查看更早失败 $e');
    } finally {
      _loadingMore = false;
    }
  }

  /// 历史分段翻页：更早一段（替换式，列表高度恒定，绕开设备绘制上限）。
  Future<void> _histOlder() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _loadingMore || !_histHasOlder) return;
    _loadingMore = true;
    final generation = _loadGeneration;
    AppLog.instance.log('Chat: 历史更早 before=$_histOldestSeq');
    try {
      final page = await _api.historyPage(
        id,
        before: _histOldestSeq,
        limit: _histPageSize,
      );
      _absorbTurnTails(page.turnTails);
      final events = page.events;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) {
        return;
      }
      // v3.1.6（app-audit ②）：降级标记在守卫之后才写——过期响应不得改写横幅状态
      if (page.degraded) _historyDegraded = true;
      if (events.isEmpty) {
        setState(() => _histHasOlder = false);
        return;
      }
      setState(() {
        _histItems = _segmentFrom(events);
        _histOldestSeq = events.first.seq ?? 0;
        _histNewestSeq = events.last.seq ?? 0;
        _histHasOlder = events.length >= _histPageSize;
        _histHasNewer = _histNewestSeq < _earliestSeq;
      });
      _scrollToTopOfHistory();
    } catch (e) {
      AppLog.instance.log('Chat: 历史更早失败 $e');
    } finally {
      _loadingMore = false;
    }
  }

  /// 历史分段翻页：更新一段（更接近 live 窗口）。
  Future<void> _histNewer() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _loadingMore || !_histHasNewer) return;
    _loadingMore = true;
    final generation = _loadGeneration;
    AppLog.instance.log('Chat: 历史更新 after=$_histNewestSeq');
    try {
      final page = await _api.historyPage(
        id,
        after: _histNewestSeq,
        limit: _histPageSize,
      );
      _absorbTurnTails(page.turnTails);
      final events = page.events;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) {
        return;
      }
      // v3.1.6（app-audit ②）：降级标记在守卫之后才写——过期响应不得改写横幅状态
      if (page.degraded) _historyDegraded = true;
      if (events.isEmpty) {
        setState(() => _histHasNewer = false);
        return;
      }
      setState(() {
        _histItems = _segmentFrom(events);
        _histOldestSeq = events.first.seq ?? 0;
        _histNewestSeq = events.last.seq ?? 0;
        _histHasOlder = events.length >= _histPageSize;
        _histHasNewer = _histNewestSeq < _earliestSeq;
      });
      _scrollToTopOfHistory();
    } catch (e) {
      AppLog.instance.log('Chat: 历史更新失败 $e');
    } finally {
      _loadingMore = false;
    }
  }

  /// 历史事件 → 消息条目（旧→新顺序，独立于 live 列表）。
  List<_MsgItem> _segmentFrom(List<ChatEvent> events) {
    final out = <_MsgItem>[];
    for (final ev in events) {
      _buildInto(out, ev, history: true);
    }
    return out;
  }

  void _scrollToTopOfHistory() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _runProgrammaticScroll(() => _scrollCtrl.jumpTo(0));
    });
  }

  /// 回到最新视图。
  void _backToLive() {
    setState(() {
      _inHistory = false;
      _pendingNew = false;
    });
    _scrollFollow.bumpGeneration(intent: FollowIntent.followLatest);
    _requestScrollFollow(forced: true, reason: CorrectionReason.forcedPosition);
  }

  /// live 视图：普通列表（非 reverse，最旧在顶、最新在底、草稿末尾），
  /// 列表占满高度、可正常滚动、内容贴顶——无"下半空白死区 + 滑动消息消失"问题（v2.8.0）。
  /// 统一单一方向（不再按条数切换 reverse）：根治 50/51 条边界翻转导致滚动位置跳变
  /// （review P1-1）；无限模式上翻加载更早时新数据出现在视觉顶部，阅读位置不跳动。
  Widget _buildLiveView() {
    // issue #80/#81：右侧 action gutter 占位者取最大——圆钮可见 38、仅轨道 36、都无 16。
    final rightPadding = listRightPaddingFor(
      jumpVisible: _showJumpToLatest,
      railVisible: _turnRailVisible,
    );
    if (_lastLiveRightPadding != rightPadding) {
      _lastLiveRightPadding = rightPadding;
      // 正文可用宽度变化 → 已测高度失效（issue #81：38/36/16 切换）。
      _itemHeights.clear();
      // issue #89（B/C 折中）：保持 padding 同帧契约，但帧后把 pixels clamp 到新
      // [min,max]、重测短内容占位；钉住且非拖拽时才有限帧收敛到底部。
      _paddingReconcileAttempts = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reconcileAfterPaddingChange();
      });
    }
    final hasDraft = _streaming || _draft.isNotEmpty;
    final topButton = !_infiniteMode && _earliestSeq > 0;
    final loadingTail = _infiniteMode && _loadingMore && _earliestSeq > 0;
    final currentExtra =
        (hasDraft ? 1 : 0) + (topButton ? 1 : 0) + (loadingTail ? 1 : 0);
    final itemCount = _olderItems.length + _items.length + currentExtra;
    if (itemCount != _lastLoggedCount) {
      _lastLoggedCount = itemCount;
      AppLog.instance.log(
        'Chat: build itemCount=$itemCount streaming=$_streaming draftLen=${_draft.length} items=${_items.length + _olderItems.length}',
      );
    }
    // v3.1.5（issue #15）：整条消息流包一层 SelectionArea —— 普通 Text 也能长按选中复制，
    // 且不引入 SelectableText（后者在部分 Android 设备上长文本换行/重叠渲染异常，见 md.dart 注释）。
    return SelectionArea(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onLiveScroll,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: _onLiveScrollMetrics,
          child: CustomScrollView(
          key: _liveViewportKey,
          controller: _scrollCtrl,
          center: _liveCenterKey,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 10, rightPadding, 0),
              sliver: SliverList(
                key: _olderSliverKey,
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildItemWithTurnKey(
                    _olderItems[index],
                    historyView: false,
                  ),
                  childCount: _olderItems.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(
              key: _liveCenterKey,
              child: SizedBox.shrink(),
            ),
            // issue #77：内容短于视口时，顶部占位把消息列表推到底部（贴在输入框上方），
            // 而不是顶对齐、下方留白。高度由 `_scheduleLiveBottomGapMeasure` 实测维护。
            if (_liveBottomGap > 0)
              SliverToBoxAdapter(
                child: SizedBox(height: _liveBottomGap),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 0, rightPadding, 6),
              sliver: SliverList(
                key: _liveSliverKey,
                delegate: SliverChildBuilderDelegate((context, index) {
                  // center 之后：加载条/按钮 → 当前窗口消息（最旧→最新）→ 草稿。
                  if ((topButton || loadingTail) && index == 0) {
                    if (topButton) {
                      return _OlderButton(
                        busy: _loadingMore,
                        onTap: _openHistory,
                      );
                    }
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  final dataIndex = index - (topButton || loadingTail ? 1 : 0);
                  if (dataIndex < _items.length) {
                    return _buildItemWithTurnKey(
                      _items[_items.length - 1 - dataIndex],
                      historyView: false,
                    );
                  }
                  if (hasDraft) {
                    return _AssistantBubble(
                      text: _draft,
                      streaming: true,
                      api: _api,
                      imageLoader: _markdownImageLoader,
              imageUserAction: _markdownImageUserAction,
                    );
                  }
                  return const SizedBox.shrink();
                }, childCount: _items.length + currentExtra),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// 历史分段浏览：普通列表（最旧在顶部，offset 0 安全），顶部翻页控制条。
  Widget _buildHistoryView() {
    final ink2 = DshColors.ink2(context);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: DshColors.surface(context),
            border: Border(bottom: BorderSide(color: DshColors.line(context))),
          ),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _histHasOlder && !_loadingMore ? _histOlder : null,
                icon: const Icon(Icons.arrow_upward, size: 15),
                label: Text(
                  L10n.t('更早', 'Older'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _histHasNewer && !_loadingMore ? _histNewer : null,
                icon: const Icon(Icons.arrow_downward, size: 15),
                label: Text(
                  L10n.t('更新', 'Newer'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _backToLive,
                icon: const Icon(Icons.subdirectory_arrow_right, size: 15),
                label: Text(
                  _pendingNew
                      ? L10n.t('回到最新 · 有新消息', 'Back to latest · New messages')
                      : L10n.t('回到最新', 'Back to latest'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _pendingNew ? DshColors.brand(context) : ink2,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _histItems.isEmpty
              ? Center(
                  child: Text(
                    L10n.t(
                      _historyDegraded ? '更早历史不可恢复' : '没有更早的消息',
                      _historyDegraded
                          ? 'Earlier history unavailable'
                          : 'No earlier messages',
                    ),
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                    itemCount: _histItems.length,
                    itemBuilder: (context, index) => _buildItemWithTurnKey(
                      _histItems[index],
                      historyView: true,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// v3.1.5（issue #15）：已加载消息 → 可复制的纯文本（时间正序）。
  /// - live 视图用 `_items`（**最新在前**，需 reversed）
  /// - 历史浏览视图用 `_histItems`（**旧→新**，已是正序）——复制当前正在看的那一段
  /// 轮次分隔条不导出；工具活动卡/未知可见事件只在有文本摘要时导出（正文为空的行由
  /// conversationText 跳过，避免把超长工具结果灌进剪贴板）。
  ///
  /// v3.1.6（app-audit ②）：导出范围与**渲染口径**对齐——`_isNoiseText` 噪声（PC 端也不显示）
  /// 与普通模式隐藏的系统注入消息都不进剪贴板：此前它们界面上看不见、却被"复制整段"带出去。
  /// 另注意范围是**当前已加载**的消息（长会话只含最近若干页），文案据此表述。
  String _conversationText() {
    final inHistory = _inHistory && _histItems.isNotEmpty;
    final ordered = inHistory ? _histItems : _items.reversed.toList();
    final debug = widget.store.timelineDebug;
    final mode = debug ? TimelineMode.debug : TimelineMode.ordinary;
    return conversationText([
      for (final m in ordered)
        if (m.kind != _MsgKind.divider &&
            !_isNoiseText(m.text) &&
            !(m.injected && !debug) &&
            // issue #119：与渲染口径对齐——普通模式隐藏的调试专属事件卡
            // （todo/write、session/jobs、question/* 等）不得从「复制整段」泄漏。
            !(m.kind == _MsgKind.event &&
                !timelineTypeVisibleIn(mode, m.eventType ?? '')))
          switch (m.kind) {
            _MsgKind.user => (m.injected ? '系统注入' : '你', m.text),
            _MsgKind.assistant => ('助手', m.text),
            _MsgKind.tool => ('工具', m.text),
            _MsgKind.event => ('事件', m.text),
            _MsgKind.divider => ('', ''),
          },
    ]);
  }

  /// v3.1.5（issue #15）：复制当前已加载的对话（含角色标注）到剪贴板。
  Future<void> _copyConversation() async {
    final text = _conversationText();
    if (text.isEmpty) {
      showToast(context, L10n.t('当前没有可复制的对话内容', 'Nothing to copy'));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showToast(context, L10n.t('已复制当前已加载的对话', 'Loaded conversation copied'));
  }

  Future<void> _refreshUsage() async {
    // v2.9.0 review(HIGH)：页级动作绑定本页会话，叠层聊天不回退时发错会话
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final request = ++_usageRequest;
    final version = _usageVersion;
    final generation = _loadGeneration;
    try {
      final u = await _api.usage(id);
      if (mounted &&
          request == _usageRequest &&
          version == _usageVersion &&
          generation == _loadGeneration &&
          id == _mySessionId) {
        setState(() {
          _usage = u;
          _usageLoaded = true;
        });
      }
    } catch (_) {}
  }

  // ── 事件处理（对齐网页端 handleEvent） ──
  //
  // issue #118：SSE 事件的**统一跟随出口**。
  //
  // 旧实现把 `_requestScrollFollow()` 写在每个分支（或忘记写）——#114 只覆盖到过程行/
  // 工具增量/异步详情/活动条，`session/jobs`（顶部 JobCard 显隐改变消息区视口高度）
  // 就漏了：内容被裁到视口下方 35px，且之后不再自动校正。这里把「处理事件」与
  // 「布局变化后跟随」拆开：`_handleEventInner` 返回本次处理**是否改变了消息区布局/
  // 视口高度**，统一出口只在为真时重测短内容占位并请求有界收敛。新增事件类型必须
  // 显式声明，避免再次漏挂（也覆盖 question/approval 卡片、队列 dock、turn/end 自动折叠）。
  void _handleEvent(ChatEvent ev) {
    if (!mounted) return;
    if (!_handleEventInner(ev)) return;
    _onEventLayoutChanged();
  }

  /// 事件处理导致消息区布局/视口高度变化后的统一收口（与渲染层同一 owner 口径）：
  /// 先重测短内容底部占位，再请求有界收敛（阅读态/拖拽中由 owner 拒绝，不抢位置）。
  void _onEventLayoutChanged() {
    if (!mounted) return;
    _scheduleLiveBottomGapMeasure();
    _requestScrollFollow();
    _clampOverscrollAfterShrink();
  }

  /// issue #118：内容因**布局变化**变短后，把越界的滚动位置拉回合法范围。
  ///
  /// 复现（详细档 + paged 会话，实测 `tailResidual=+526`、`max=0`、`px=-40`）：
  /// 用户上翻加载过更早历史后 `paged=true`，#77 短内容底部占位被
  /// `shortEnough = !paged && ...` 永久停用；随后本轮 `turn/end` 自动折叠把
  /// live 内容从 1018dp 压到 100dp，`maxScrollExtent` 变成 0，而 `pixels`
  /// 仍停在旧值 → 内容顶边被推到视口上方、下方留出大段空白，且阅读态恒显回底按钮。
  ///
  /// 这里**不启用底部占位**（维护者决定，避免重现 issue #76 的「占位与位置修正
  /// 互相拉扯」），只把**越界**的 pixels 拉回 `[0, max]`。内容变短是布局变化导致、
  /// 不是用户滚动，因此不违反「不抢用户位置」：用户看到的仍是同一段内容。
  void _clampOverscrollAfterShrink() {
    if (!mounted || _inHistory) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollCtrl.hasClients) return;
      final position = _scrollCtrl.position;
      if (!position.hasContentDimensions) return;
      final max = position.maxScrollExtent;
      final pixels = position.pixels;
      // 只在「不可滚动 + 越界」这一确定异常态纠正；可滚动时的越界由
      // BallisticScrollActivity 自行回弹，不在这里抢。
      if (max > 0.5 || pixels >= -0.5) return;
      _runProgrammaticScroll(() {
        _scrollCtrl.jumpTo(0);
      });
      _syncScrollFollowDisplay();
    });
  }

  /// 返回 `true` = 本次处理改变了消息区布局或视口高度（需要 [_onEventLayoutChanged]）。
  bool _handleEventInner(ChatEvent ev) {
    // bridge 事件兼容旧 store：若 sessionId 只存在 data 中也必须按页面绑定过滤。
    final eventSessionId = ev.sessionId ?? ev.data?['sessionId']?.toString();
    if (eventSessionId != null && eventSessionId != _mySessionId) {
      // issue #120：问询/审批帧被页面 session 过滤时也必须留痕——真机日志据此判断
      // 是「帧归属错」还是「页面绑定错」。
      if (ev.type == 'question/requested' ||
          ev.type == 'question/resolved' ||
          ev.type == 'approval/requested' ||
          ev.type == 'approval/resolved') {
        AppLog.instance.log(
          '[120-debug] ${ev.type} dropped by page filter: '
          'frameSessionId=$eventSessionId mySessionId=${_mySessionId ?? ''} '
          'storeSessionId=${widget.store.sessionId ?? ''} rpcId=${ev.data?['rpcId'] ?? ''}',
        );
      }
      return false;
    }
    if (ev.type == 'git/changed') {
      final controller = _gitController;
      if (controller != null) {
        final changedRepository = ev.data?['repositoryId']?.toString();
        final openRepository = controller.state.repository?.repositoryId;
        if (changedRepository == null || changedRepository == openRepository) {
          if (ev.data?['changeKind']?.toString() == 'worktree') {
            controller.markWorktreeStale();
          } else {
            controller.markStale();
          }
        }
      }
      return false; // 只标记 Git 数据过期，不改变消息区布局。
    }
    // 所有带 durable seq 的事件先去重，再更新任何投影（todo/jobs/tool card）。
    // 否则 SSE 重复帧与 catch-up 会各自追加一张 timeline card。
    if (ev.seq != null) {
      if (ev.seq! <= _lastSeq) return false;
      _lastSeq = ev.seq!;
    }
    if (ev.type == 'compaction/end') {
      _resyncAfterCompaction(); // 重载会话（forced 定位自行收口）
      return false;
    }
    if (hiddenTimelineTypes.contains(ev.type)) {
      // Consume its cursor without retaining sensitive payloads.
      return false; // 永不渲染，零高度。
    }
    if (ev.type == '_capabilities') {
      // Bootstrap/SSE hello can arrive after history; rebuild detail affordances.
      setState(() {});
      // issue #25 评审 P2：能力是**后到**的（首连/重连时序不定）。能力声明到达后补拉一次
      // 大纲，否则"历史先完成、supported 稍后才变 true"就永远只有本地刻度。
      unawaited(_refreshTurnOutline());
      return false; // 只刷新能力位/大纲（详情按钮的显隐不改变已渲染高度）。
    }
    if (ev.type == '_catchup') {
      _catchup(); // 补拉本身在追加事件后统一请求跟随（见 _catchup 末尾）
      _refreshTodos(); // v3.1.4：重连/唤醒后任务清单也对齐一次
      return false;
    }
    if (ev.type == 'agent/status') {
      setState(() {});
      return false; // 只更新状态点/按钮，不改变消息区视口高度。
    }
    // 内核问询/审批弹窗帧（store 已按 sessionId 分发，这里只认当前会话）
    if (ev.type == 'question/requested') {
      final q = widget.store.questionForSession(_mySessionId);
      var changed = false;
      if (q != null && q.sessionId == _mySessionId) {
        final key = 'question:${q.rpcId}:requested';
        setState(() {
          _question = q;
          changed = true; // 底部问询卡出现 → 消息视口变矮。
          if (_transientFrameKeys.add(key)) _appendEvent(ev);
        });
      }
      // issue #120：真机定位日志（只观测，不改变行为）。回答三件事：
      // 帧挂到哪个 session、本页绑定哪个 session、两者是否一致（matched）。
      AppLog.instance.log(
        '[120-debug] question frame: '
        'frameSessionId=${eventSessionId ?? ''} '
        'mySessionId=${_mySessionId ?? ''} '
        'storeSessionId=${widget.store.sessionId ?? ''} '
        'rpcId=${ev.data?['rpcId'] ?? ''} matched=$changed',
      );
      return changed;
    }
    if (ev.type == 'question/resolved') {
      final rid = ev.data?['rpcId'];
      if (eventSessionId != _mySessionId) return false;
      final key = 'question:${rid ?? 'unknown'}:resolved';
      var changed = false;
      setState(() {
        if (rid != null && _question?.rpcId == rid) {
          _question = null;
          changed = true; // 底部问询卡收起 → 消息视口变高。
        }
        if (_transientFrameKeys.add(key)) _appendEvent(ev);
      });
      // issue #120：结算路径同样留痕（#120 要求覆盖 resolved 分支）。
      AppLog.instance.log(
        '[120-debug] question resolved: '
        'frameSessionId=${eventSessionId ?? ''} '
        'mySessionId=${_mySessionId ?? ''} '
        'storeSessionId=${widget.store.sessionId ?? ''} '
        'rpcId=${rid ?? ''} matched=$changed',
      );
      return changed;
    }
    if (ev.type == 'approval/requested') {
      final a = widget.store.approvalForSession(_mySessionId);
      var changed = false;
      if (a != null && a.sessionId == _mySessionId) {
        final key = 'approval:${a.approvalId}:requested';
        setState(() {
          _approval = a;
          changed = true; // 底部审批卡出现 → 消息视口变矮。
          if (_transientFrameKeys.add(key)) _appendEvent(ev);
        });
      }
      return changed;
    }
    if (ev.type == 'approval/resolved') {
      final aid = ev.data?['approvalId'];
      if (eventSessionId != _mySessionId) return false;
      final key = 'approval:${aid ?? 'unknown'}:resolved';
      var changed = false;
      setState(() {
        if (aid != null && _approval?.approvalId == aid) {
          _approval = null;
          changed = true; // 底部审批卡收起 → 消息视口变高。
        }
        if (_transientFrameKeys.add(key)) _appendEvent(ev);
      });
      return changed;
    }
    // 上下文窗口实时帧：更新圆环数据（无需重进会话）
    if (ev.type == 'session/context') {
      final window = (ev.data?['contextWindow'] as num?)?.toInt();
      if (window != null && window > 0) {
        _usageVersion++;
        _usage['contextWindow'] = window;
        setState(() {});
      }
      return false; // 只更新用量圆环/文字，不改变消息区视口高度。
    }
    // v2.7：会话任务视图更新（后台任务卡片/工具弹层刷新）
    if (ev.type == 'session/jobs') {
      // jobs is a non-durable projection rendered by the top JobCard; do not
      // turn every reconnect snapshot into another timeline event.
      //
      // issue #118：JobCard 位于消息区上方，显隐会改变消息视口高度；本帧无法预知
      // 下一帧是否真的换行，因此如实声明为「可能改变布局」——已收敛时 owner 的
      // takeCorrection 会判 converged/no-op，不会产生空闲自激。
      if (mounted) setState(() {});
      return true;
    }
    // v3.1.4（issue #12 姊妹需求）：任务清单实时折叠——与内核 dsh-tool-todo 的会话投影
    // 完全同语义（最新 todo/write 覆盖整份、turn/start 清空）。
    // 这里是实时 SSE 路径；历史/回放由 _loadInitial 按**时间正序**折叠后再存状态
    // （历史事件是倒序入列的，顺序折叠会得到旧状态）。
    if (ev.type == 'todo/write') {
      _todoProjectionVersion++;
      _todos = ((ev.data?['todos'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      // issue #119：任务清单面板是唯一展示入口；时间线卡仅在调试模式保留
      // （`debugOnlyTimelineTypes`，推翻 v3.1.4「任务面板与时间线同时更新」的决策）。
      // 事件本身仍消费：上面的 `_todos` 投影必须在实时、历史回放、catch-up 三处一致更新。
    }
    if (ev.type == 'turn/start') {
      _todoProjectionVersion++;
      _todos = []; // 新一轮开始清空清单（继续走下方渲染，保留"轮次 N 开始"分隔条）
      final startedTurn = (ev.data?['turn'] as num?)?.toInt();
      // issue #70：关闭集合有界——只保留最近两轮（迟到 chunk 的 tombstone 不无界增长）。
      if (startedTurn != null) _liveReasoning.trimClosedTurns(startedTurn);
    }
    // v3.0.0：队列快照帧（认领/删除/编辑即时反映）→ 本页 dock 即时同步
    if (ev.type == 'mobile/queue') {
      final sid = ev.data?['sessionId'] as String?;
      var changed = false;
      if (sid != null && sid == _mySessionId) {
        setState(() {
          _queue = widget.store.queueOf(sid);
          if (_queue.isEmpty) _queueCollapsed = true;
          changed = true; // 队列 dock 在 composer 上方，显隐改变消息视口高度。
        });
      }
      return changed;
    }
    // 关键事件日志（排除高频 chunk，便于排障）
    if (ev.type != 'assistant/chunk' &&
        ev.type != 'assistant/live-chunk' &&
        ev.type != 'tool/call' &&
        ev.type != 'tool/result') {
      AppLog.instance.log('Chat: SSE 事件 ${ev.type} seq=${ev.seq}');
    }
    if (ev.type == 'assistant/chunk' || ev.type == 'assistant/live-chunk') {
      final text = ev.data?['text'] as String? ?? '';
      final reasoning = ev.data?['reasoning'] == true;
      var layoutChanged = false;
      if (text.isNotEmpty && !reasoning) {
        _draft += text;
        // 草稿增长由 80ms 节流统一重建并请求跟随（见 _scheduleDraftFlush）。
        _scheduleDraftFlush();
      } else if (text.isNotEmpty && reasoning) {
        // issue #70：流式思考按 (turn, step) 进缓冲（活动条与 provisional 行同源）。
        // 每个 delta 只做 O(1) 追加 + 行级通知；只有结构变化（首现/切 step）才重建计划，
        // 避免「每 delta 全量 setState」（issue 性能条款）。
        final turn = (ev.data?['turn'] as num?)?.toInt();
        final step = (ev.data?['step'] as num?)?.toInt();
        if (turn != null) {
          // issue #70（复审 P1 配套）：durable 回放不再为历史轮次写 tombstone（见
          // `_buildInto` 的 history 隔离）。迟到 chunk 改用**只读**持久投影判定并丢弃：
          // - 该轮已结束（turn/end 已到）→ 丢弃（中断轮不残留）；
          // - 该 (turn, step) 已有落定 assistant/message 水位（含无 reasoning 的 message，
          //   由 tracker 在 observe 时登记）→ 丢弃：reset/reload 后回放不会写 step tombstone，
          //   若不判定会让已落定 step 的迟到 chunk 复活 provisional，与持久行重复。
          // 判定不触碰 live 缓冲/tombstone，也不跨 step 泛化（null-step 只匹配 null 键）。
          final ended = _ensureProcessTurnMap()[turn]?.ended ?? false;
          final settled = _turnProcess.hasSettledReasoning(turn, step);
          if (!ended && !settled) {
            if (_liveReasoning.firstSeqOf(turn, step) == null) {
              AppLog.instance.log('Chat: 思考开始（首个 reasoning chunk）');
            }
            final structural =
                _liveReasoning.append(turn, step, text, seq: ev.seq);
            _liveReasoningRevision.value++;
            if (structural) {
              _invalidateProcessPlan();
              setState(() {});
              // issue #114：结构性思考行出现/切换 = 真实内容布局变化；由统一出口
              // 排队有界收敛（不依赖“下一帧恰好事先有帧”）。
              layoutChanged = true;
            }
          }
        }
        // 迟到/已结束轮次的 reasoning chunk 一律丢弃、不增长文本。
      }
      if (ev.data?['toolCall'] != null || ev.data?['argumentsDelta'] != null) {
        final data = ev.data ?? const <String, dynamic>{};
        _activeTools[_toolActivityKey(data, ev.seq, _items.length)] =
            ev.data?['toolCall']?.toString() ?? L10n.t('工具', 'Tool');
        // 参数 delta 可达数百上千条：只更新模型，交给 80ms 节流统一重建
        // （与正文草稿 _scheduleDraftFlush 同口径），避免每个 delta 触发一次全量 setState。
        _appendEvent(ev);
        _scheduleActivityFlush();
        layoutChanged = true;
      }
      return layoutChanged;
    }
    if (ev.type == 'assistant/message' || ev.type == 'turn/end') {
      _draftTimer?.cancel();
      _draftTimer = null;
      _activityTimer?.cancel();
      _activityTimer = null;
      // issue #70：缓冲的关闭/通知统一在 _buildInto 漏斗里做（覆盖 SSE/catch-up/历史回放）。
      final reasoningChars = _liveReasoning.current?.text.length ?? 0;
      if (ev.type == 'assistant/message') {
        // 正文到达：工具阶段结束（思考文本由过程行或活动条按同源快照呈现）
        _activeTools.clear();
        AppLog.instance.log('Chat: 活动条-正文到达（思考 $reasoningChars 字）');
      } else {
        // 轮次结束：清空活动条与思考草稿（provisional 由 _buildInto 的 closeTurn 清理）
        _activeTools.clear();
        if (reasoningChars > 0) {
          AppLog.instance.log('Chat: 活动条-轮次结束清理（思考 $reasoningChars 字）');
        }
        _reasoningExpanded = false;
      }
    }
    // 每轮完成：用该轮的 usage 样本更新上下文压力（PC 端同口径）与累计用量条
    if (ev.type == 'assistant/message') {
      final u = ev.data?['usage'] as Map<String, dynamic>?;
      if (u != null) {
        _usageVersion++;
        final input = (u['inputTokens'] as num?) ?? 0;
        final read = (u['cacheReadTokens'] as num?) ?? 0;
        final write = (u['cacheWriteTokens'] as num?) ?? 0;
        _usage['pressureTokens'] = input + read + write;
        for (final key in [
          'inputTokens',
          'outputTokens',
          'cacheReadTokens',
          'cacheWriteTokens',
          'reasoningTokens',
        ]) {
          _usage[key] = ((_usage[key] as num?) ?? 0) + ((u[key] as num?) ?? 0);
        }
        _usageLoaded = true;
      }
    }
    setState(() => _appendEvent(ev));
    // 历史浏览期间收到新消息：live 列表已更新，标记"有新消息"提示
    if (_inHistory) _pendingNew = true;
    // v2.7.2：事件驱动队列刷新（认领类事件前置立即刷新，其余节流）
    _onQueueAffectingEvent(ev.type);
    // v3.1.4（issue #13 排查建议 3）：轮次结束但本轮渲染不出任何回复条目 → 兜底补拉一次。
    // 触发场景：事件被任何一层（过滤/竞态/脏 seq）静默吞掉时，避免"只剩一条轮次结束分隔条"。
    if (ev.type == 'turn/end') _maybeResyncAfterTurn();
    // 跟随态才收敛；阅读态/拖拽中由 owner 拒绝（§5.1/§5.2）。
    // 注意：turn/end 还会触发下一帧的「过程段自动收起」，同样算布局变化。
    return true;
  }

  /// v3.1.4（issue #13）：会话表面被内核重写（`/compact` 的 surfaceOp=replace）后，
  /// 按**新表面**重载一次——否则手机继续显示已被 shadow 的旧消息，与桌面端视图分叉。
  void _resyncAfterCompaction() {
    AppLog.instance.log('Chat: 压缩完成 → 按新表面重载会话（对齐桌面端视图）');
    _load(reset: true);
  }

  /// v3.1.4（issue #13 排查建议 3）：本轮出现过真人提问、但没有渲染出更晚的回复条目
  /// → 说明有内容被静默吞掉，补拉一次历史（10s 节流，避免抖动时反复拉取）。
  void _maybeResyncAfterTurn() {
    if (!needsTurnEndResync(
      lastUserSeq: _lastUserSeq,
      lastAssistantSeq: _lastAssistantSeq,
    )) {
      return;
    }
    final now = DateTime.now();
    if (_lastResyncAt != null &&
        now.difference(_lastResyncAt!) < const Duration(seconds: 10)) {
      return;
    }
    _lastResyncAt = now;
    AppLog.instance.log(
      'Chat: 轮次结束但无回复条目（lastUser=$_lastUserSeq lastAssistant=$_lastAssistantSeq）→ 兜底补拉',
    );
    _load(reset: true);
  }

  /// v3.1.4（issue #12 姊妹需求）：任务清单权威补拉（内核 todo 投影）——
  /// SSE 的 `todo/write` 帧负责实时，本方法负责"打开会话/断线重连后对齐一次"。
  Future<void> _refreshTodos() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final request = ++_todoRefreshRequest;
    final version = _todoProjectionVersion;
    final generation = _loadGeneration;
    try {
      final list = await _api.todos(id);
      if (!mounted ||
          request != _todoRefreshRequest ||
          version != _todoProjectionVersion ||
          generation != _loadGeneration ||
          id != _mySessionId ||
          list == null) {
        return;
      }
      setState(() => _todos = list);
      // issue #118：任务面板在 composer 上方，高度变化会改变消息视口。
      _onEventLayoutChanged();
    } catch (e) {
      AppLog.instance.log('Chat: 任务清单拉取失败 $id → $e');
    }
  }

  Future<void> _catchup({bool force = false}) async {
    // v2.7.2 review(M1)：按本页绑定的会话补拉（此前用全局 sessionId，叠层时旧页会拉到新会话的增量）。
    // 新服务端通过 hasMore 声明 durable cursor 后仍有下一页；每页立即上屏（长间隔不必等全部读完），
    // 同时设页数上限——长时间离线后不能变成无界的请求风暴（剩余缺口由下次补拉继续收敛）。
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || (!force && _lastSeq <= 0)) return;
    final generation = _loadGeneration;
    try {
      var cursor = _lastSeq;
      var pageNo = 0;
      var truncated = false;
      var appended = false;
      while (pageNo < _catchupMaxPages) {
        pageNo++;
        final page = await _api.historyPage(id, after: cursor, limit: 100);
        if (!mounted || generation != _loadGeneration || id != _mySessionId) {
          return;
        }
        _absorbTurnTails(page.turnTails);
        // v3.1.6（app-audit ②）：守卫之后才写降级标记（过期响应不得改写横幅）
        if (page.degraded) _historyDegraded = true;
        final fresh = <ChatEvent>[];
        for (final ev in page.events) {
          if (ev.seq != null && ev.seq! <= cursor) continue;
          fresh.add(ev);
          if (ev.seq != null && ev.seq! > cursor) cursor = ev.seq!;
        }
        if (fresh.isEmpty) break;
        if (fresh.any((ev) => ev.type == 'compaction/end')) {
          _resyncAfterCompaction();
          return;
        }
        setState(() {
          for (final ev in fresh) {
            if (ev.seq != null && ev.seq! <= _lastSeq) continue;
            if (ev.seq != null) _lastSeq = ev.seq!;
            if (ev.type == 'turn/start') {
              _todoProjectionVersion++;
              _todos = [];
            } else if (ev.type == 'todo/write') {
              _todoProjectionVersion++;
              _todos = ((ev.data?['todos'] as List?) ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
            }
            _appendEvent(ev);
          }
        });
        appended = appended || fresh.isNotEmpty;
        if (!page.hasMore) break;
        truncated = pageNo >= _catchupMaxPages;
      }
      // issue #118：补拉追加了新事件 = 消息区布局变化；统一出口请求跟随，
      // 避免重连补拉后视口停在旧末端（阅读态由 owner 拒绝，不抢位置）。
      if (appended && mounted) _onEventLayoutChanged();
      if (truncated) {
        AppLog.instance.log(
          'Chat: catch-up 截断于 $_catchupMaxPages 页（cursor=$cursor），剩余由下次补拉收敛',
        );
      }
    } catch (e) {
      AppLog.instance.log('Chat: catch-up failed $e');
    }
  }

  /// v2.7.2：拉取本会话排队消息（对齐 PC 端 Queue Dock 数据源 agent.inbox）。
  /// 代数守卫：只应用最新一次请求的结果，防止重叠请求乱序覆盖。
  int _queueRefreshSeq = 0;
  Future<void> _refreshQueue() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final seq = ++_queueRefreshSeq;
    try {
      final q = await _api.queue(id);
      if (!mounted || seq != _queueRefreshSeq) return;
      // v3.0.0：统一经 store 镜像——帧为权威源（认领/删除即时反映且不落后）；
      // 无帧可依时（SSE 断线等）REST 结果兜底生效，任务栏即时收敛
      widget.store.applyQueue(id, q, fromFrame: false);
      // v2.7.2 review：dock 可见时周期兜底刷新（PC 端改动/无本会话事件帧时不过期）
      _queuePollTimer?.cancel();
      if (q.isNotEmpty) {
        _queuePollTimer = Timer(const Duration(seconds: 20), () {
          _queuePollTimer = null;
          _refreshQueue();
        });
      }
    } catch (e) {
      AppLog.instance.log('Chat: 队列刷新失败: $e');
    }
  }

  /// 事件驱动的队列刷新（节流：chunk 高频期间 timer 持续重置，流结束后才拉一次）。
  void _scheduleQueueRefresh() {
    _queueRefreshTimer?.cancel();
    _queueRefreshTimer = Timer(const Duration(milliseconds: 400), () {
      _queueRefreshTimer = null;
      _refreshQueue();
    });
  }

  /// v2.7.2 review：认领类事件且 dock 非空时前置立即刷新——
  /// 避免"消息已被 agent 取走但 dock 在整段流式期间一直显示"。
  void _onQueueAffectingEvent(String type) {
    final affects =
        type == 'turn/start' ||
        type == 'tool/call' ||
        type == 'user/message' ||
        type == 'assistant/message';
    if (affects && _queue.isNotEmpty) {
      _queueRefreshTimer?.cancel();
      _queueRefreshTimer = null;
      _refreshQueue();
    } else {
      _scheduleQueueRefresh();
    }
  }

  /// 编辑排队消息（对齐 PC 端 Queue Dock 的 edit）。
  Future<void> _queueEdit(String itemId) async {
    if (_queueBusy) return;
    final text = _queueEditCtrl.text.trim();
    if (text.isEmpty) {
      showToast(context, L10n.t('内容不能为空', 'Content cannot be empty'));
      return;
    }
    // v2.7.2 review：与本页绑定会话一致（叠层场景不误操作新会话队列）
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    _queueBusy = true;
    try {
      await _api.updateQueueMessage(id, itemId, {
        'kind': 'edit',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
      if (mounted) setState(() => _editingQueueId = null);
      _refreshQueue();
    } catch (e) {
      if (!mounted) return;
      setState(() => _editingQueueId = null);
      if (e is ApiException && e.code == 'queue-item-not-found') {
        // v3.0.0：已被 agent 认领（正在执行）——语义化提示，行由帧/REST 刷新移除
        showToast(
          context,
          L10n.t(
            '该消息已被 agent 处理，无法编辑',
            'The agent already picked it up — cannot edit',
          ),
        );
      } else {
        showToast(context, '${L10n.t('编辑失败：', 'Edit failed: ')}$e');
      }
      _refreshQueue(); // 失败通常=消息已被处理,刷新队列同步真实状态
    } finally {
      _queueBusy = false;
    }
  }

  /// 删除排队消息（对齐 PC 端 Queue Dock 的 remove）。
  Future<void> _queueRemove(String itemId) async {
    if (_queueBusy) return;
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('删除这条排队消息？', 'Remove this queued message?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L10n.t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L10n.t('删除', 'Remove')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _queueBusy = true;
    try {
      await _api.updateQueueMessage(id, itemId, {'kind': 'remove'});
      // v2.7.2 review：内核 remove 不校验结果——若消息已被 agent 认领（正在执行），
      // 仍返回 accepted:true 但实际没删掉。删除后立即复查队列，还在则明确提示。
      final q = await _api.queue(id);
      if (mounted && q.any((r) => r['id'] == itemId)) {
        showToast(
          context,
          L10n.t(
            '该消息已被 agent 开始处理，未能删除',
            'The agent already picked it up — could not remove',
          ),
        );
      }
      _refreshQueue();
    } catch (e) {
      if (mounted) {
        if (e is ApiException && e.code == 'queue-item-not-found') {
          // v3.0.0：已被 agent 认领（正在执行）——内核返回 queue-item-not-found，
          // 语义化提示 + 即时刷新（帧/REST 会移除该行，不再残留陈旧行）
          showToast(
            context,
            L10n.t(
              '该消息已被 agent 开始处理，未能删除',
              'The agent already picked it up — could not remove',
            ),
          );
        } else {
          showToast(context, '${L10n.t('删除失败：', 'Remove failed: ')}$e');
        }
        _refreshQueue();
      }
    } finally {
      _queueBusy = false;
    }
  }

  /// 插话：把排队消息插到 agent 下一步执行（对齐 PC 端 Queue Dock 的 steer）。
  Future<void> _queueSteer(String itemId) async {
    if (_queueBusy) return;
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    _queueBusy = true;
    try {
      await _api.updateQueueMessage(id, itemId, {'kind': 'steer'});
      _refreshQueue();
    } catch (e) {
      if (mounted) {
        if (e is ApiException &&
            (e.code == 'queue-item-not-found' ||
                e.code == 'steer-unavailable')) {
          // v3.0.0：已被处理/当前轮不再接受插话——语义化提示
          showToast(
            context,
            L10n.t(
              '该消息已被 agent 处理，无法插话',
              'The agent already picked it up — cannot steer',
            ),
          );
        } else {
          showToast(context, '${L10n.t('插话失败：', 'Steer failed: ')}$e');
        }
        _refreshQueue();
      }
    } finally {
      _queueBusy = false;
    }
  }

  /// 队列停靠区（composer 顶部，对齐 PC 端 Queue Dock）：空队列不渲染。
  /// v2.7.2 review：只显示可操作的 queued 行（对齐 PC 端 QueueDock 的
  /// `placement === "queued"` 过滤）——steering 行是"插话中"消息、即将执行，
  /// 显示并允许操作会误导（删除大概率来不及，插话按钮也被隐藏）。
  /// v3.1.4（issue #12 姊妹需求）：任务清单面板（对齐 PC 端「任务」面板）——
  /// 折叠态只占一行计数（如「1 进行中 · 6 待处理」），点按展开完整清单。
  /// 数据与内核 `dsh-tool-todo` 的会话投影同源（`todo/write` 整份覆盖、`turn/start` 清空）。
  Widget _buildTodoPanel() {
    if (_todos.isEmpty) return const SizedBox.shrink();
    var inProgress = 0;
    var pending = 0;
    var completed = 0;
    for (final todo in _todos) {
      switch (todo['status']) {
        case 'in_progress':
          inProgress++;
        case 'completed':
          completed++;
        default:
          pending++;
      }
    }
    return _TodoPanel(
      todos: _todos,
      collapsed: _todosCollapsed,
      inProgress: inProgress,
      pending: pending,
      completed: completed,
      onToggle: () => setState(() => _todosCollapsed = !_todosCollapsed),
    );
  }

  Widget _buildQueueDock() {
    // v2.7.2：只显示可操作的 queued 行（对齐 PC 端 QueueDock）；
    // steering/context（插话中/上下文注入）不可操作,不显示
    final rows = _queue.where((r) => r['placement'] == 'queued').toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final collapsed = _queueCollapsed && rows.length > 1;
    final visible = collapsed ? rows.take(1).toList() : rows;
    final ink3 = DshColors.ink3(context);
    // v2.7.2：独立于输入框的轻量条——无背景块、不与消息/输入框挤压，
    // 多条时标题行可点击折叠；单条直接显示内容行
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.length > 1)
            InkWell(
              onTap: () => setState(() => _queueCollapsed = !_queueCollapsed),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // v2.7.2：图标统一灰色系（与模型/权限 pill 同风格，去蓝色）
                    Icon(Icons.schedule_send, size: 13, color: ink3),
                    const SizedBox(width: 5),
                    Text(
                      L10n.t('${rows.length} 条排队消息', '${rows.length} queued'),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ink3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      _queueCollapsed
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up,
                      size: 15,
                      color: ink3,
                    ),
                  ],
                ),
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [for (final row in visible) _buildQueueRow(row)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueRow(Map<String, dynamic> row) {
    final id = row['id'] as String? ?? '';
    final rawText = row['text'] as String? ?? '';
    // v2.7.2 review：steering 行（next-step）不可插话；非文本消息显示占位、不可编辑但可删除
    final steerable = row['placement'] != 'steering';
    final hasText = rawText.isNotEmpty;
    final text = hasText ? rawText : L10n.t('(非文本消息)', '(non-text message)');
    final ink3 = DshColors.ink3(context);
    final brand = DshColors.brand(context);
    final editing = _editingQueueId == id;
    if (editing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _queueEditCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _queueEdit(id),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.check, size: 17),
              color: brand,
              visualDensity: VisualDensity.compact,
              onPressed: _queueBusy ? null : () => _queueEdit(id),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 17),
              color: ink3,
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _editingQueueId = null),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // v2.7.2：图标统一灰色系、尺寸缩小（与模型/权限 pill 同风格，去蓝色）
          Icon(Icons.schedule_send, size: 13, color: ink3),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontStyle: hasText ? FontStyle.normal : FontStyle.italic,
                color: hasText ? null : ink3,
              ),
            ),
          ),
          if (hasText)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 15),
              color: ink3,
              visualDensity: VisualDensity.compact,
              tooltip: L10n.t('编辑', 'Edit'),
              // v2.7.2 review：操作忙碌锁——连点/并发操作期间禁用按钮
              onPressed: _queueBusy
                  ? null
                  : () {
                      _queueEditCtrl.text = rawText;
                      setState(() => _editingQueueId = id);
                    },
            ),
          if (steerable)
            IconButton(
              // v2.8.0：插队图标 = 向上小箭头（语义=插到 agent 下一步执行，区别于发送的向上箭头尺寸更小）
              icon: const Icon(Icons.arrow_upward, size: 15),
              color: ink3,
              visualDensity: VisualDensity.compact,
              tooltip: L10n.t('插话', 'Steer'),
              onPressed: _queueBusy ? null : () => _queueSteer(id),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 15),
            color: ink3,
            visualDensity: VisualDensity.compact,
            tooltip: L10n.t('删除', 'Remove'),
            onPressed: _queueBusy ? null : () => _queueRemove(id),
          ),
        ],
      ),
    );
  }

  /// live 列表追加一条事件（最新在前：insert 头部）。
  /// 无限模式只增不减（微信式上翻）；分段模式裁剪到窗口上限并推进分页起点。
  /// [tail] 表示“最新一页初始加载”：允许 chunk 进草稿/重置草稿；
  /// 更早的历史页（tail=false）绝不触碰 live 流式草稿。
  void _appendEvent(ChatEvent ev, {bool history = false, bool tail = false}) {
    // issue #77：内容变化时先撤销短内容底部占位（本帧按真实布局渲染），下一帧再按
    // 实测高度决定是否补回——避免“占位仍按旧短内容计算、新内容被推到视口外”。
    if (_liveBottomGap > 0) _liveBottomGap = 0;
    _buildInto(_items, ev, history: history, tail: tail);
    if (!_infiniteMode) {
      // 裁剪：live 列表最多保留 _liveMax 条，超出丢弃最旧（尾部），
      // 同时推进"查看更早"的分页起点，保证翻页无缝隙。
      while (_items.length > _liveMax) {
        _items.removeLast();
      }
      if (_items.isNotEmpty) {
        final oldest = _items.last.seq;
        if (oldest != null) {
          _earliestSeq = oldest;
          // issue #52：live 窗口裁剪后同步丢弃更早轮次的过程结构，避免无界增长。
          _turnProcess.pruneBefore(oldest);
          // issue #70：被裁轮次的 provisional 不得残留。
          _liveReasoning.pruneBefore(oldest);
          _processVersion++;
        }
      }
    }
  }

  /// issue #70：`assistant/message` / `turn/end` 到达时关闭流式思考缓冲。
  ///
  /// - `assistant/message`：把该 (turn, step) 首个 delta seq 交给 tracker（持久行继承
  ///   同一排序键 → 落定零位移），随后关闭对应 provisional（迟到 chunk 进 tombstone）；
  /// - `turn/end`（completed/aborted/interrupted/error）：整轮关闭并丢弃首 delta 记录，
  ///   中断轮不残留；
  /// - 无 `turn` 字段的事件不做缓冲处理（无键可归，走 tracker 既有归属规则）。
  void _closeLiveReasoningFor(ChatEvent ev) {
    final turn = (ev.data?['turn'] as num?)?.toInt();
    if (turn == null) return;
    final step = (ev.data?['step'] as num?)?.toInt();
    var changed = false;
    if (ev.type == 'turn/end') {
      changed = _liveReasoning.closeTurn(turn);
      _turnProcess.dropReasoningStart(turn);
      _provisionalExpansions.removeWhere((key, _) => key.startsWith('$turn:'));
    } else {
      final first = _liveReasoning.firstSeqOf(turn, step);
      if (first != null) _turnProcess.noteReasoningStart(turn, step, first);
      changed = _liveReasoning.closeStep(turn, step);
      _provisionalExpansions.remove('$turn:${step ?? 'null'}');
    }
    if (!changed) return;
    // 结构变化（可见行消失）：通知行级监听者并重建过程计划。
    _liveReasoningRevision.value++;
    _invalidateProcessPlan();
  }

  /// issue #70（审查 P1-2）：工具类事件把 step **推进**时，旧 step 的 provisional 必须关闭。
  ///
  /// 真实序列可能「reasoning(step1) 还没有 assistant/message 落定，下一个 step 先到的是
  /// tool/call / tool/result / 带 toolCall·argumentsDelta 的 chunk」——这些事件同样携带
  /// `(turn, step)`，是 step 前进的可靠信号。这里只在统一漏斗 `_buildInto` 判定（覆盖
  /// SSE 与 catch-up；历史回放 buffer 为空 → 幂等）：
  /// - 同 turn 且事件 step > 当前 provisional step → `closeStep(turn, step-1)`，并在关闭集合
  ///   记上限，阻止迟到的旧 step chunk 复活；
  /// - 同 step / 更小 step / 事件缺 step → 一律不关闭（避免把正常流误关）。
  void _advanceLiveReasoningStep(ChatEvent ev) {
    final data = ev.data;
    if (data == null) return;
    final isToolEvent = ev.type == 'tool/call' ||
        ev.type == 'tool/result' ||
        ((ev.type == 'assistant/chunk' || ev.type == 'assistant/live-chunk') &&
            (data['toolCall'] != null || data['argumentsDelta'] != null));
    if (!isToolEvent) return;
    final turn = (data['turn'] as num?)?.toInt();
    final step = (data['step'] as num?)?.toInt();
    if (turn == null || step == null) return;
    final live = _liveReasoning.current;
    if (live == null || live.turn != turn || live.step == null) return;
    if (step <= live.step!) return;
    final changed = _liveReasoning.closeStep(turn, step - 1);
    if (!changed) return;
    _provisionalExpansions.removeWhere((key, _) => key.startsWith('$turn:'));
    // 结构变化：行级通知 + 计划失效（外层调用方负责 setState / 80ms 节流刷新）。
    _liveReasoningRevision.value++;
    _invalidateProcessPlan();
  }

  /// 系统注入的噪声消息判定（PC 端 GUI 也不显示）：
  /// 上下文快照 / 后台任务通知。判据与模型侧共用同一实现。
  bool _isNoiseText(String text) => timelineIsInjectedNoise(text);

  /// 工具关联 id 与模型侧共用同一实现（避免两处规则分叉）。
  String _toolActivityKey(Map<String, dynamic> data, int? seq, int fallback) =>
      timelineCallIdOf(data, seq, fallback);

  /// issue #61：记录本会话已知的工具名（`tool/call` 与带 toolCall 的流式增量）。
  ///
  /// 与 [TimelineReducer] 的合并状态不同，这份映射**只增不减**、且跨 `_load` 重建保留
  /// （同一会话内历史重放可能只剩 `tool/result`，那时 reducer 已重置、拿不到 call 的 name）。
  /// 会话变化（页面重绑/切会话）时整体清空，不跨会话串名。
  void _recordToolName(ChatEvent ev) {
    final type = ev.type;
    if (type != 'tool/call' &&
        type != 'assistant/chunk' &&
        type != 'assistant/live-chunk') {
      return;
    }
    final data = ev.data ?? const <String, dynamic>{};
    if (type != 'tool/call' &&
        data['toolCall'] == null &&
        data['argumentsDelta'] == null) {
      return;
    }
    if (_toolNamesSessionId != _mySessionId) {
      _toolNamesSessionId = _mySessionId;
      _toolNamesByCallId.clear();
    }
    final callId = timelineCallIdOf(data, ev.seq, _toolNamesByCallId.length);
    final name = timelineToolNameOf(data, callId: callId, fallback: '');
    if (name.isNotEmpty) _toolNamesByCallId[callId] = name;
  }

  void _rebuildActiveToolsFromHistory(List<ChatEvent> events) {
    _activeTools.clear();
    for (final ev in events) {
      final data = ev.data ?? const <String, dynamic>{};
      if (ev.type == 'tool/call') {
        final callId = _toolActivityKey(data, ev.seq, _activeTools.length);
        _activeTools[callId] = timelineToolNameOf(
          data,
          callId: callId,
          fallback: L10n.t('工具', 'Tool'),
        );
      } else if (ev.type == 'tool/result') {
        _activeTools.remove(
          _toolActivityKey(data, ev.seq, _activeTools.length),
        );
      } else if (ev.type == 'assistant/message' || ev.type == 'turn/end') {
        _activeTools.clear();
      }
    }
  }

  /// Tool activity 的 Flutter 侧投影：**合并规则由 [TimelineReducer] 单点实现**
  /// （参数替换/追加、status、anchor/detail seq、关联 id、images/files），
  /// 这里只负责放置位置与携带 UI 专属状态（rawData / detailLoading）。
  /// 曾经在此复刻合并规则，导致 tool/call 的整串参数被拼在 delta 之后（参数重复）。
  void _upsertToolItem(
    List<_MsgItem> out,
    ChatEvent ev, {
    required bool history,
  }) {
    final d = ev.data ?? const <String, dynamic>{};
    final callId = timelineCallIdOf(d, ev.seq, out.length);
    final isResult = ev.type == 'tool/result';
    var owner = out;
    var index = out.indexWhere(
      (m) => m.kind == _MsgKind.tool && m.toolCallId == callId,
    );
    if (index < 0) {
      for (final candidate in <List<_MsgItem>>[
        _items,
        _olderItems,
        _histItems,
      ]) {
        if (identical(candidate, out)) continue;
        final found = candidate.indexWhere(
          (m) => m.kind == _MsgKind.tool && m.toolCallId == callId,
        );
        if (found >= 0) {
          owner = candidate;
          index = found;
          break;
        }
      }
    }
    final old = index >= 0 ? owner[index] : null;
    // issue #99（reviewer P1）：surface replace replay 不能新建独立工具卡。
    // reducer 已把替代内容合并进同一 callId 生命周期；这里若列表里找不到原卡，
    // 说明这是“旧事件被替换”而非新的工具调用（原始事件不在当前窗口），不渲染。
    // 原始 tool/call 随后到达时会走非 replay 分支，从生命周期带出合并后的结果并生成一张卡。
    if (ev.isSurfaceReplace && old == null) return;
    // apply() 已在 _buildInto 入口执行，故 tools[callId] 已是合并后的权威生命周期。
    final lifecycle =
        _timelineReducer.tools[callId] ??
        ToolLifecycle(
          id: callId,
          name: timelineToolNameOf(
            d,
            callId: callId,
            fallback: L10n.t('工具', 'Tool'),
          ),
          seq: ev.seq,
        );
    // issue #61：工具名解析顺序——事件 name → 现有条目 name → session 映射 → 合并态 name
    // → 「工具调用」占位。缺 call 事件的历史/流式事件因此仍有可读标题。
    final eventName = timelineToolNameOf(d, callId: callId, fallback: '');
    final previousName = old?.toolName;
    final mappedName = _toolNamesByCallId[callId];
    final resolvedName = eventName.isNotEmpty
        ? eventName
        : !_isPlaceholderToolName(previousName)
        ? previousName!
        : !_isPlaceholderToolName(mappedName)
        ? mappedName!
        : !_isPlaceholderToolName(lifecycle.name)
        ? lifecycle.name
        : L10n.t('工具调用', 'Tool call');
    final item = _MsgItem.tool(
      toolCallId: lifecycle.id,
      toolName: resolvedName,
      toolArguments: lifecycle.arguments,
      toolResult: lifecycle.result,
      toolStatus: lifecycle.status,
      toolError: lifecycle.isError,
      seq: lifecycle.seq,
      latestSeq: lifecycle.latestSeq ?? lifecycle.seq,
      detailSeq: lifecycle.detailSeq ?? lifecycle.seq,
      files: lifecycle.files,
      images: lifecycle.images,
      detailAvailable: lifecycle.detailAvailable,
      rawData: old?.rawData,
      detailLoading: isResult ? false : (old?.detailLoading ?? false),
      // issue #54：结构化摘要随 call/result 事件合并；缺失保持上一次（旧插件恒 null）。
      callSummary: ev.type == 'tool/call'
          ? (ev.callSummary ?? old?.callSummary)
          : old?.callSummary,
      resultSummary: ev.type == 'tool/result'
          ? (ev.resultSummary ?? old?.resultSummary)
          : old?.resultSummary,
      // issue #68：PTC 子调用树随生命周期携带（PTC 事件只刷新根卡，不新建条目）。
      subCalls: lifecycle.subCalls,
      subCallsTruncated: lifecycle.subCallsTruncated,
    );
    if (index >= 0) {
      final settled =
          old?.toolStatus == 'success' || old?.toolStatus == 'failed';
      if (history && !isResult && settled) {
        owner.removeAt(index);
        owner.add(item);
      } else {
        owner[index] = item;
      }
    } else if (history) {
      out.add(item);
    } else {
      out.insert(0, item);
    }
  }

  /// issue #68（M3 Batch 2-C）：PTC 事件到达后，按 reducer 标出的受影响根**原地**
  /// 刷新已存在的根工具卡（不新增条目、不改锚点/位置）；根条目尚未到达时 no-op
  /// （随后 `tool/call` 的 `_upsertToolItem` 会从 lifecycle 带出完整子树）。
  void _refreshToolItemsForPtc([List<_MsgItem>? current]) {
    // A2：历史分段/上翻页构建中的局部列表（`out`/`pageItems`）不在三个持久列表里，
    // 必须一并原地刷新，否则「同页含根 call + PTC 事件但无根 result」时根卡缺子调用。
    final lists = <List<_MsgItem>>[_items, _olderItems, _histItems];
    if (current != null && !lists.any((list) => identical(list, current))) {
      lists.add(current);
    }
    for (final rootId in List<String>.from(
      _timelineReducer.lastTouchedToolRoots,
    )) {
      final lifecycle = _timelineReducer.tools[rootId];
      if (lifecycle == null) continue;
      for (final list in lists) {
        final index = list.indexWhere(
          (item) => item.kind == _MsgKind.tool && item.toolCallId == rootId,
        );
        if (index < 0) continue;
        list[index] = list[index].copyTool(
          subCalls: lifecycle.subCalls,
          subCallsTruncated: lifecycle.subCallsTruncated,
        );
      }
    }
  }

  void _appendVisibleEvent(
    List<_MsgItem> out,
    ChatEvent ev, {
    required bool history,
  }) {
    final d = ev.data ?? const <String, dynamic>{};
    // 标题映射与模型侧共用（timeline.dart）：未知类型原样显示类型名，不静默丢弃。
    final title = timelineTitleFor(ev.type);
    final text = (d['text'] ?? d['detail'] ?? d['reason'] ?? '').toString();
    final item = _MsgItem.event(
      eventType: ev.type,
      text: text.isEmpty ? title : '$title\n$text',
      seq: ev.seq,
      rawData: ev.detailAvailable ? d : null,
      detailAvailable: ev.detailAvailable,
      toolError:
          d['isError'] == true || d['error'] == true || d['status'] == 'failed',
    );
    if (history) {
      out.add(item);
    } else {
      out.insert(0, item);
    }
  }

  /// 将事件构建为消息条目并插入 out（live 语义：最新在前，insert(0)；
  /// 历史分段：旧→新顺序，追加到末尾）。
  /// [tail] 见 [_appendEvent]：历史页（history=true, tail=false）跳过 chunk、
  /// 不重置 [_draft]/[_streaming]，避免污染正在进行的流式回复。
  void _buildInto(
    List<_MsgItem> out,
    ChatEvent ev, {
    bool history = false,
    bool tail = false,
  }) {
    final d = ev.data;
    if (hiddenTimelineTypes.contains(ev.type)) return;
    // issue #70（复审 P1）：live 思考缓冲的关闭/推进**只能**由实时/补拉路径触发。
    //
    // `history:true` 是本页的 durable 回放（初始 tail、`_prependOlderPage` 上翻更早页、
    // `_segmentFrom` 历史跳转段）：流式期间用户上翻时，旧历史里可能有**同 turn 的无 step
    // assistant/message**（会 closeStep(turn, null) 误关当前任意 step 并写 tombstone，
    // 之后 chunk 永久丢弃）或**同 turn 更大 step 的 tool 事件**（durable step 与实时游标
    // 不保证单调，会误推进）。因此历史路径一律不触碰 `_liveReasoning` / tombstone /
    // `_provisionalExpansions` / `_liveReasoningRevision`；`_catchup` 走 history:false，
    // 只处理 seq > _lastSeq 的真实增量，保留关闭语义。
    if (!history) {
      if (ev.type == 'assistant/message' || ev.type == 'turn/end') {
        _closeLiveReasoningFor(ev);
      } else {
        // issue #70（审查 P1-2）：工具类事件推进 step 时关闭旧 step 的 provisional。
        _advanceLiveReasoningStep(ev);
      }
    }
    // issue #99（reviewer P1）：surface replace 的 shadow 判定必须先于所有投影生效。
    // reducer 先登记 source seq；tracker/UI 不得再消费后到的旧 source 事件，
    // 否则会清掉 surfaceReplay 标记并生成 turn148 partial 历史组。
    final accepted = _timelineReducer.apply(ev);
    if (_timelineReducer.isShadowedSeq(ev.seq)) {
      // 替换事件可能先于旧 source 到达（历史倒序/翻旧页）。旧 source 本身不再进
      // tracker/过程组，但若 reducer 已有同 callId 的替代生命周期，则把工具卡
      // **物化在原 source 位置**（有原事件 → 一张卡；replay-only 永远不会走到这里）。
      if (ev.type == 'tool/call' ||
          ev.type == 'tool/result' ||
          (ev.type == 'assistant/chunk' || ev.type == 'assistant/live-chunk') &&
              (ev.data?['toolCall'] != null || ev.data?['argumentsDelta'] != null)) {
        _upsertToolItem(out, ev, history: history);
      }
      return;
    }
    // Historical reconstruction must still render a record even when the same seq
    // arrived via SSE while the REST request was in flight. Live ingestion can
    // discard the duplicate because _handleEvent already owns the visible stream.
    if (!accepted && !history) return;
    // issue #61：先记 tool 名再合并，保证没有 name 的后续事件（result/增量）能补名。
    _recordToolName(ev);
    // issue #52：轮次过程投影与时间线条目同步观察（历史/实时/分页重叠都收敛到同一结构）。
    _turnProcess.observe(ev);
    _processVersion++;
    switch (ev.type) {
      case 'deliverables/presented':
        // issue #53（§6.20）：交付文件声明收进轮末交付卡，不生成通用事件卡；
        // 旧插件没有投影 data 时退回 default（调试可见），普通模式不出现空白卡。
        final deliveredTurn = (d?['turn'] as num?)?.toInt();
        final deliveredFiles = deliverableFilesOf(ev.seq, d);
        if (deliveredTurn != null && deliveredFiles.isNotEmpty) {
          _absorbDeliverables(deliveredTurn, deliveredFiles);
          return;
        }
        _appendVisibleEvent(out, ev, history: history);
      case 'user/message':
        final text = d?['text'] as String? ?? '';
        // 已知 runtime context 噪声保留 seq/model 对账，但系统提示词与上下文快照在所有模式均隐藏。
        final mid = d?['messageId'] as String?;
        // v3.1.4（issue #12）：内核来源标记——非 "user" 即系统注入（plugin/agent-instructions/tool…），
        // 渲染成可折叠块；缺字段（旧内核）时为 null，退回关键词启发式。
        final sourceKind = d?['sourceKind'] as String?;
        // v3.1.4（issue #13）：只有**真人提问**参与"本轮是否缺回复"的兜底判定
        // （注入消息不是提问，不该因它触发补拉）
        if ((!history || tail) &&
            (sourceKind == null || sourceKind == 'user')) {
          if (ev.seq != null) _lastUserSeq = ev.seq;
        }
        // 去重（SSE 回显 vs 本地乐观添加）：
        // 1) 已有同 messageId 的消息 → 直接跳过（回显已完成渲染，同文本连发也不误并）
        if (mid != null &&
            out.any((m) => m.kind == _MsgKind.user && m.messageId == mid)) {
          return;
        }
        // 2) 列表中已存在本地乐观添加（messageId 尚未赋值）且文本一致的消息 → 合并。
        //    全列表查找而非只看 out.first：turn/start 等事件可能先于回显插入，
        //    把乐观消息挤到非首位（否则会出现"同一条消息显示两次"）。
        if (!history) {
          // v2.7.2 乱序排查：合并到"最旧"的未回显乐观消息（lastIndexWhere）——
          // 同文本连发时回显按发送顺序到达，合并顺序必须与发送顺序一致；
          // 此前 indexWhere 从头部（最新）找，先到的回显会合并到最新一条，
          // 造成 seq 与视觉顺序错配（后续重建时可能乱序）。
          final idx = out.lastIndexWhere(
            (m) =>
                m.kind == _MsgKind.user &&
                m.messageId == null &&
                m.text.trim() == text.trim(),
          );
          if (idx != -1) {
            out[idx] = out[idx].copyWith(seq: ev.seq, messageId: mid);
            return;
          }
        }
        if (history) {
          out.add(
            _MsgItem.user(
              text,
              seq: ev.seq,
              messageId: mid,
              images: _imagesOf(d),
              files: _filesOf(d),
              sourceKind: sourceKind,
            ),
          );
        } else {
          out.insert(
            0,
            _MsgItem.user(
              text,
              seq: ev.seq,
              messageId: mid,
              images: _imagesOf(d),
              files: _filesOf(d),
              sourceKind: sourceKind,
            ),
          );
        }
      case 'assistant/message':
        var body = d?['text'] as String? ?? '';
        // 噪声 assistant 记录保留在模型中，但系统提示词与上下文快照在所有模式均隐藏。
        // 工具阶段中间产物（正文为空的多步消息）：不渲染空气泡，过程由活动条呈现
        if (body.trim().isEmpty) {
          if (!history || tail) {
            _draft = '';
            _streaming = false;
          }
          return;
        }
        final reasoningChars = (d?['reasoningChars'] as num?)?.toInt() ?? 0;
        final reasoningText = (d?['reasoning'] as String?) ?? '';
        // 有思维链正文时：正文里不再重复「（思考 N 字）」占位（思维链作为可折叠块单独呈现）；
        // 无正文（旧数据）时回退旧占位。
        final prefix = reasoningText.isNotEmpty
            ? ''
            : (reasoningChars > 0
                  ? L10n.t(
                      '（思考 $reasoningChars 字）\n',
                      '(Thought: $reasoningChars chars)\n',
                    )
                  : '');
        final item = _MsgItem.assistant(
          prefix + body,
          usage: d?['usage'] as Map<String, dynamic>?,
          seq: ev.seq,
          messageId: d?['messageId'] as String?,
          images: _imagesOf(d),
          files: _filesOf(d),
          reasoning: reasoningText.isEmpty ? null : reasoningText,
          detailAvailable: ev.detailAvailable,
          detailTextChars: ev.detailTextChars,
        );
        // v3.1.4（issue #13）：记录最近一条**会渲染出来**的回复，供轮次兜底判定
        // （注入的上下文快照虽然进模型但界面隐藏，不能算作本轮已有回复）。
        if ((!history || tail) &&
            ev.seq != null &&
            !timelineIsInjectedNoise(body)) {
          _lastAssistantSeq = ev.seq;
        }
        if (history) {
          out.add(item);
        } else {
          out.insert(0, item);
        }
        if (!history || tail) {
          _draft = '';
          _streaming = false;
        }
      case 'assistant/chunk':
      case 'assistant/live-chunk':
        if (history && !tail) break; // 历史页不渲染 chunk：完整文本由 assistant/message 呈现
        final text = d?['text'] as String? ?? '';
        final reasoning = d?['reasoning'] == true;
        if (text.isNotEmpty && !reasoning) {
          _draft += text;
          _streaming = true;
        }
        if (d?['toolCall'] != null || d?['argumentsDelta'] != null) {
          _upsertToolItem(out, ev, history: history);
        }
      case 'tool/call':
        final callId = _toolActivityKey(d ?? const <String, dynamic>{}, ev.seq, out.length);
        final name = timelineToolNameOf(d, callId: callId, fallback: L10n.t('工具', 'Tool'));
        if (!history && !ev.isSurfaceReplace) {
          _activeTools[callId] = name;
          _scheduleActivityFlush();
        }
        _upsertToolItem(out, ev, history: history);
      case 'tool/result':
        if (!history && !ev.isSurfaceReplace) {
          _activeTools.remove(
            _toolActivityKey(
              d ?? const <String, dynamic>{},
              ev.seq,
              out.length,
            ),
          );
          _scheduleActivityFlush();
        }
        _upsertToolItem(out, ev, history: history);
      case 'tool/ptc-dispatch-start':
      case 'tool/ptc-dispatch':
        // issue #68：合法 PTC data → 只刷新根工具卡内的子调用树（普通/调试都不新建
        // 裸事件卡）；data 缺失/非法 → 保持既有 debug-only 事件卡行为（可调试）。
        if (!ptcEventConsumable(d)) {
          _appendVisibleEvent(out, ev, history: history);
        } else {
          _refreshToolItemsForPtc(out);
        }
      case 'todo/write':
        _appendVisibleEvent(out, ev, history: history);
      case 'turn/start':
        // issue #24：轮次索引的唯一写点（实时与历史回放共用本函数）。
        final startTurn = d?['turn'];
        if (startTurn is num && ev.seq != null) {
          _turnOfStartSeq[ev.seq!] = startTurn.toInt();
        }
        if (history) {
          out.add(
            _MsgItem.divider(
              L10n.t('轮次 ${d?['turn']} 开始', 'Turn ${d?['turn']} started'),
              seq: ev.seq,
            ),
          );
        } else {
          out.insert(
            0,
            _MsgItem.divider(
              L10n.t('轮次 ${d?['turn']} 开始', 'Turn ${d?['turn']} started'),
              seq: ev.seq,
            ),
          );
        }
      case 'turn/end':
        if (!history || tail) {
          _draft = '';
          _streaming = false;
        }
        final reason = (d?['reason'] as Map<String, dynamic>?)?['kind'];
        final item = _MsgItem.divider(
          L10n.t(
            '轮次 ${d?['turn']} 结束${reason != null ? '（$reason）' : ''}',
            'Turn ${d?['turn']} ended${reason != null ? ' ($reason)' : ''}',
          ),
          seq: ev.seq,
        );
        if (history) {
          out.add(item);
        } else {
          out.insert(0, item);
        }
        // issue #53（§6.20）：实时轮末信号 `tail` 由服务端随 turn/end 摘要下发。
        final endedTurn = (d?['turn'] as num?)?.toInt();
        final endedTail = ev.tail ?? TurnTail.fromJson(d?['tail']);
        if (endedTurn != null && endedTail != null) {
          _absorbTurnTail(endedTurn, endedTail);
        }
      default:
        // 未知 Visible event 不再静默丢弃；普通模式显示类型摘要，调试模式可展开原始详情。
        _appendVisibleEvent(out, ev, history: history);
    }
  }

  /// v3.0.0(热修 05)：草稿签名（文本+待发图片路径）——签名变化才换新 requestId。
  /// v3.0.0(热修 07)：发送异常后恢复草稿——只在输入框仍为空时回填（见 draftAfterFailure）。
  void _restoreDraftIfUntouched(String fallback) {
    final restored = draftAfterFailure(_inputCtrl.text, fallback);
    if (restored == _inputCtrl.text) return;
    _inputCtrl.text = restored;
    _inputCtrl.selection = TextSelection.collapsed(offset: restored.length);
  }

  /// v3.0.0(热修 05)：发送结果未知（reset/超时/409）后的回执查询——有界轮询。
  /// 返回 null＝未确认（保守）；非 null＝服务端回执 { status: done|error, result }。
  /// 「已送达」的判据改为服务端 requestId 回执（幂等），替代热修 04 的启发式对账
  /// （后者会把空文本图片/同文本旧消息误判为已送达 → 静默丢草稿）。
  Future<Map<String, dynamic>?> _resolveUnknownSend(
    String sessionId,
    String requestId,
  ) async {
    for (var i = 0; i < 4; i++) {
      try {
        final receipt = await _api.sendReceipt(
          sessionId,
          requestId,
          timeout: const Duration(seconds: 3),
        );
        final status = receipt['status'] as String?;
        if (status == 'done' || status == 'error') return receipt;
        // in-progress：稍后再查
      } catch (_) {
        // receipt-not-found（第一次请求根本没到服务端）或网络再失败 → 保守未确认
        return null;
      }
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    return null;
  }

  /// issue #25：本会话的命令目录（判定 `/xxx` 是不是已注册命令）。命中缓存即用，否则取一次
  /// （`GET /api/commands`）并缓存——目录在会话生命周期内基本不变，没必要每条命令消息都多一次往返。
  /// 服务未提供时得到空目录（等同于"所有名字都未注册"，照常按普通消息发送，不阻塞）。
  Future<List<Map<String, dynamic>>> _commandCatalogFor(String id) async {
    final cached = _commandCatalog;
    if (cached != null && _commandCatalogSessionId == id) return cached;
    final (cmds, unavailable) = await _api.commands(id);
    final list = unavailable ? <Map<String, dynamic>>[] : cmds;
    _commandCatalog = list;
    _commandCatalogSessionId = id;
    return list;
  }

  /// issue #90/#95：按会话并行取命令+技能目录（菜单/高亮/提交共用）。
  ///
  /// - 同会话 in-flight 复用同一个 Future（命令先回、技能延迟时提交等待，不误报未知）；
  /// - 会话代际/加载代际变化时旧响应丢弃，不串会话；
  /// - 200 `unavailable:true` 只短 TTL 缓存空（30s），到期重试；网络失败不缓存；
  /// - 失败/超限不缓存，输入下一次可重试；in-flight 去重防风暴。
  Future<void> _ensureSlashCatalog(String id) async {
    if (id.isEmpty) return;
    final now = DateTime.now();
    // 空列表也可能是 unavailable 的 TTL 缓存；可用仅当「有真实技能列表」或
    // 「unavailable TTL 尚未到期」，到期后必须重试。
    final skillsUsable = (_slashSkills != null && !_slashSkillsUnavailable) ||
        (_slashSkillsUnavailable &&
            _slashSkillsUnavailableUntil != null &&
            now.isBefore(_slashSkillsUnavailableUntil!));
    final cached = _slashCatalogSessionId == id;
    if (cached && _slashCommands != null && skillsUsable) return;
    final inFlight = _slashCatalogInFlight;
    if (_slashCatalogInFlightId == id && inFlight != null) {
      await inFlight;
      return;
    }
    final generation = ++_slashCatalogGeneration;
    _slashCatalogLoading = true;
    final future = _loadSlashCatalog(id, generation);
    _slashCatalogInFlightId = id;
    _slashCatalogInFlight = future;
    try {
      await future;
    } finally {
      if (_slashCatalogInFlightId == id) _slashCatalogInFlight = null;
      if (generation == _slashCatalogGeneration) _slashCatalogLoading = false;
    }
  }

  Future<void> _loadSlashCatalog(String id, int generation) async {
    final commandFuture = _slashCatalogSessionId == id && _slashCommands != null
        ? Future.value((_slashCommands!, false))
        : _api.commands(id);
    final skillsFuture = _api.skills(id);
    List<Map<String, dynamic>>? commands;
    List<Map<String, dynamic>>? skills;
    var skillsUnavailable = false;
    var commandsUnavailable = false;
    try {
      final (list, unavailable) = await commandFuture;
      commands = unavailable ? <Map<String, dynamic>>[] : list;
    } catch (_) {
      commands = <Map<String, dynamic>>[];
      commandsUnavailable = true;
    }
    try {
      final (list, unavailable) = await skillsFuture;
      if (unavailable) {
        skills = <Map<String, dynamic>>[];
        skillsUnavailable = true;
      } else {
        skills = list;
      }
    } catch (_) {
      skills = null; // 网络失败可重试
    }
    if (!mounted || generation != _slashCatalogGeneration) return;
    final current = _mySessionId ?? widget.store.sessionId;
    if (current != id) return;
    _slashCatalogSessionId = id;
    setState(() {
      _slashCommands = commands;
      _slashSkills = skills;
      _slashSkillsUnavailable = skillsUnavailable;
      _slashSkillsUnavailableUntil = skillsUnavailable
          ? DateTime.now().add(slashSkillsUnavailableTtl)
          : null;
      _slashCommandsUnavailable = commandsUnavailable;
      if (commands != null) {
        _commandCatalog = commands;
        _commandCatalogSessionId = id;
      }
    });
    _syncSlashHighlightCatalog();
  }

  /// 当前会话技能名（不可用/未加载时返回 null）。
  Future<List<Map<String, dynamic>>?> _skillCatalogFor(String id) async {
    await _ensureSlashCatalog(id);
    return _slashSkills;
  }

  /// issue #90：菜单条目（命令组前、技能组后；命令同名优先）。
  List<({String name, String? description, String? hint, bool skill, bool userOnly})>
      _slashMenuEntries() {
    final token = _slashToken;
    if (token == null) return const [];
    final commands = token.scope == SlashMenuScope.leading
        ? (_slashCommands ?? const <Map<String, dynamic>>[])
        : const <Map<String, dynamic>>[];
    final commandNames = {
      for (final c in commands)
        if (c['name'] is String) c['name'] as String,
    };
    final entries = <({String name, String? description, String? hint, bool skill, bool userOnly})>[];
    for (final c in commands) {
      final name = c['name'];
      if (name is! String || !slashItemMatches(token.query, name, c['description']?.toString())) continue;
      entries.add((
        name: name,
        description: c['description']?.toString(),
        hint: commandMenuSubtitle(c),
        skill: false,
        userOnly: false,
      ));
    }
    for (final skill in _slashSkills ?? const <Map<String, dynamic>>[]) {
      final name = skill['name'];
      if (name is! String || commandNames.contains(name)) continue;
      if (!slashItemMatches(token.query, name, skill['description']?.toString())) continue;
      entries.add((
        name: name,
        description: skill['description']?.toString(),
        hint: skill['whenToUse']?.toString(),
        skill: true,
        userOnly: skill['modelInvocable'] == false,
      ));
    }
    return entries;
  }

  /// issue #90：点选只插入 `/name `（不自动发送/执行）。
  void _insertSlash(String name) {
    final token = _slashToken;
    if (token == null) return;
    final text = _inputCtrl.text;
    // issue #95：替换到 token 右端（保留光标右侧同 token 文本之后的内容），
    // 而不是只替换到光标，避免 `/gr|ill-me rest` 变成 `/grill-me ill-me rest`。
    // 若 token 后已紧跟空白，不再额外补空格（避免出现双空格）。
    final tail = token.rightEnd < text.length ? text[token.rightEnd] : '';
    final replacement = tail.isNotEmpty && tail.trim().isEmpty ? '/$name' : '/$name ';
    final updated = text.replaceRange(token.start, token.rightEnd, replacement);
    _inputCtrl.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: token.start + replacement.length),
    );
    setState(() => _slashToken = null);
  }

  /// issue #97：目录加载/会话切换后同步输入框高亮用的已知命令/技能集合。
  /// 只更新显示样式集合，不改写输入原文；目录晚到也无需用户再输入即可刷新高亮。
  void _syncSlashHighlightCatalog() {
    _inputCtrl.setCatalogs(
      {
        for (final c in _slashCommands ?? const <Map<String, dynamic>>[])
          if (c['name'] is String) c['name'] as String,
      },
      {
        for (final s in _slashSkills ?? const <Map<String, dynamic>>[])
          if (s['name'] is String) s['name'] as String,
      },
    );
  }

  void _refreshSlashToken() {
    final token = slashTokenAt(
      _inputCtrl.text,
      _inputCtrl.selection.baseOffset,
    );
    if (mounted) setState(() => _slashToken = token);
  }

  /// issue #97：菜单可用高度 = min(360, 键盘上沿 − 输入区 − 16dp)。
  ///
  /// 键盘上沿与 composer 顶部（Scaffold 已随 viewInsets 上移）共同决定可用空间；
  /// composer 尚未布局时保守回退 240，避免首帧菜单溢出。
  double _slashMenuMaxHeight(BuildContext context) {
    final media = MediaQuery.of(context);
    // Scaffold 内容区高度（已扣除 AppBar/键盘/安全区）；不能用全屏高度−inset，
    // 否则 320×640 会多算 56px AppBar，菜单把底部 Column 撑溢出。
    final bodyHeight = _bodyMaxHeight ??
        (media.size.height - media.viewInsets.bottom - media.padding.top - 56);
    // 只测量独立 composer 卡片（不能量包含菜单的外层 Padding，否则菜单一出现
    // composer 高度就把它算进去，形成循环并算出负可用空间）。
    final composerBox =
        _composerKey.currentContext?.findRenderObject() as RenderBox?;
    final composerHeight = (composerBox != null && composerBox.hasSize
            ? composerBox.size.height
            : 102.0) +
        14.0 +
        media.padding.bottom;
    final controlsBox =
        _bottomControlsKey.currentContext?.findRenderObject() as RenderBox?;
    final controlsHeight = controlsBox != null && controlsBox.hasSize
        ? controlsBox.size.height
        : 0.0;
    // 菜单在 composer 上方，与输入区间隔 8；再留 8 安全余量。
    final available = bodyHeight - controlsHeight - composerHeight - 16;
    return math.min(360.0, math.max(0.0, available));
  }

  /// issue #97：菜单独立滚动到底时收起“上滑查看更多”，最多展示剩余项数。
  void _updateSlashMenuScroll(int totalEntries) {
    if (!mounted || !_slashScroll.hasClients) return;
    final position = _slashScroll.position;
    final atBottom =
        position.maxScrollExtent <= 0 ||
        position.pixels >= position.maxScrollExtent - 24;
    final remaining = atBottom
        ? 0
        : math.max(
            0,
            ((position.maxScrollExtent - position.pixels) / 46.0).ceil(),
          ).clamp(0, totalEntries);
    final overflow = position.maxScrollExtent > 0;
    if (remaining != _slashRemaining ||
        overflow != _slashOverflow ||
        atBottom != _slashAtBottom) {
      setState(() {
        _slashRemaining = remaining;
        _slashOverflow = overflow;
        _slashAtBottom = atBottom;
      });
    }
  }

  /// issue #90/#97：输入框上方菜单（composer 外）。命令组前、技能组后；
  /// 独立滚动 + 滚动条 + 底部渐隐/“上滑查看更多 · 还有 N 项”；点选只插入不发送。
  Widget _buildSlashMenu(BuildContext pageContext) {
    final entries = _slashMenuEntries();
    final commands = entries.where((e) => !e.skill).toList(growable: false);
    final skills = entries.where((e) => e.skill).toList(growable: false);
    final surface = DshColors.surface(pageContext);
    final line = DshColors.line(pageContext);
    final ink2 = DshColors.ink2(pageContext);
    final commandColor = _SlashPalette.commandText(pageContext);
    final skillColor = _SlashPalette.skillText(pageContext);
    final maxHeight = _slashMenuMaxHeight(pageContext);
    if (maxHeight < 48) return const SizedBox.shrink();
    Widget header(String label, int count, Color dot) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                '$label $count',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: ink2,
                ),
              ),
            ],
          ),
        );
    Widget item(({String name, String? description, String? hint, bool skill, bool userOnly}) entry) {
      final color = entry.skill ? skillColor : commandColor;
      return Semantics(
        button: true,
        label: '/${entry.name}',
        hint: entry.hint ?? entry.description,
        child: InkWell(
          key: Key('slash-menu-${entry.skill ? 'skill' : 'command'}-${entry.name}'),
          onTap: () => _insertSlash(entry.name),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 46),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    entry.skill ? Icons.auto_awesome : Icons.terminal,
                    size: 16,
                    color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '/${entry.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: color,
                                ),
                              ),
                            ),
                            if (entry.userOnly)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Text(
                                  L10n.t('仅手动', 'manual only'),
                                  style: TextStyle(fontSize: 10, color: ink2),
                                ),
                              ),
                          ],
                        ),
                        if ((entry.hint ?? entry.description ?? '').isNotEmpty)
                          Text(
                            entry.hint ?? entry.description!,
                            maxLines: entry.skill ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: ink2),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final listChildren = <Widget>[
      if (commands.isNotEmpty) header(L10n.t('命令', 'Commands'), commands.length, commandColor),
      for (final entry in commands) item(entry),
      if (skills.isNotEmpty) header(L10n.t('技能', 'Skills'), skills.length, skillColor),
      for (final entry in skills) item(entry),
      if (_slashCatalogLoading && _slashSkills == null)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
    ];
    // 条目/过滤变化后必须重算 overflow：先复位旧提示与滚动位置，避免只剩 1 项时
    // 仍显示“Scroll for more · 23 left”；过滤后仍溢出则从顶部重新计算。
    final signature = entries
        .map((entry) => '${entry.skill ? 1 : 0}:${entry.name}')
        .join('\u0001');
    if (signature != _slashMenuSignature) {
      _slashMenuSignature = signature;
      _slashRemaining = 0;
      _slashOverflow = false;
      _slashAtBottom = true;
      if (_slashScroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _slashScroll.hasClients) _slashScroll.jumpTo(0);
        });
      }
    }
    _slashScrollCheckTries = 0;
    void scheduleScrollCheck() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_slashScroll.hasClients && _slashScroll.position.maxScrollExtent > 0) {
          _slashScrollCheckTries = 0;
          _updateSlashMenuScroll(entries.length);
          return;
        }
        // 列表可完整放下（maxScrollExtent==0）：必须显式清掉旧 overflow/remaining，
        // 否则过滤到 1 项后仍残留 “Scroll for more”。
        if (_slashScroll.hasClients) {
          _slashScrollCheckTries = 0;
          if (_slashOverflow || _slashRemaining != 0 || !_slashAtBottom) {
            setState(() {
              _slashOverflow = false;
              _slashRemaining = 0;
              _slashAtBottom = true;
            });
          }
          return;
        }
        if (_slashScrollCheckTries < 3) {
          _slashScrollCheckTries += 1;
          scheduleScrollCheck();
        }
      });
    }
    scheduleScrollCheck();
    final showMore = entries.isNotEmpty && _slashOverflow && !_slashAtBottom;
    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      child: Container(
        key: const Key('slash-menu'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: line),
        ),
        clipBehavior: Clip.antiAlias,
        child: entries.isEmpty
            ? Padding(
                key: const Key('slash-menu-empty'),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                child: Text(
                  L10n.t('无匹配命令或技能', 'No matching commands or skills'),
                  style: TextStyle(fontSize: 12.5, color: ink2),
                ),
              )
            : Stack(
                children: [
                  Scrollbar(
                    controller: _slashScroll,
                    thumbVisibility: true,
                    thickness: 2,
                    radius: const Radius.circular(2),
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (_) {
                        _updateSlashMenuScroll(entries.length);
                        return false;
                      },
                      child: ListView(
                        key: const Key('slash-menu-list'),
                        controller: _slashScroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(4, 2, 10, 30),
                        children: listChildren,
                      ),
                    ),
                  ),
                  if (showMore)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                surface.withValues(alpha: 0),
                                surface,
                              ],
                            ),
                          ),
                          child: Text(
                            L10n.t(
                              '上滑查看更多 · 还有 $_slashRemaining 项',
                              'Scroll for more · $_slashRemaining left',
                            ),
                            key: const Key('slash-menu-more'),
                            style: TextStyle(fontSize: 10.5, color: ink2),
                          ),
                        ),
                      ),
                    )
                  else if (entries.isNotEmpty && _slashOverflow && (_slashAtBottom || _slashRemaining == 0))
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          height: 24,
                          alignment: Alignment.center,
                          color: surface,
                          child: Text(
                            L10n.t('已到底', 'End of list'),
                            key: const Key('slash-menu-bottom'),
                            style: TextStyle(fontSize: 10, color: ink2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  /// issue #90：用户消息气泡内联斜杠高亮（命令/技能不同图标+颜色；不可点）。
  Widget _buildUserMessageText(String text) {
    const base = TextStyle(fontSize: 15, height: 1.5);
    final tokens = slashTextTokens(text);
    if (tokens.isEmpty) return Text(text, style: base);
    final commandNames = {
      for (final c in _slashCommands ?? const <Map<String, dynamic>>[])
        if (c['name'] is String) c['name'] as String,
    };
    final skillNames = {
      for (final s in _slashSkills ?? const <Map<String, dynamic>>[])
        if (s['name'] is String) s['name'] as String,
    };
    if (commandNames.isEmpty && skillNames.isEmpty) return Text(text, style: base);
    final spans = <InlineSpan>[];
    var cursor = 0;
    var changed = false;
    for (final token in tokens) {
      final isCommand = commandNames.contains(token.name);
      final isSkill = !isCommand && skillNames.contains(token.name);
      if (!isCommand && !isSkill) continue;
      if (token.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, token.start)));
      }
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _SlashInlineChip(name: token.name, skill: isSkill),
      ));
      cursor = token.end;
      changed = true;
    }
    if (!changed) return Text(text, style: base);
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(TextSpan(style: base, children: spans));
  }

  /// issue #25：提交时把"形如命令行"的一行交给内核。
  /// 返回 true = 已按命令处理（调用方必须放弃普通发送路径）；false = 放行给普通发送路径。
  Future<bool> _tryRunCommandLine(String id, String line) async {
    final name = commandLineName(line);
    if (name == null) return false;
    List<Map<String, dynamic>> catalog;
    try {
      catalog = await _commandCatalogFor(id);
    } catch (e) {
      // 目录取不到（休眠/未挂载会话的 404 session-not-found、网络故障、旧服务端无此接口）：
      // 无法判定这行是不是命令 → **绝不阻塞**，按普通消息发送（与今日行为一致；
      // 消息还能顺带唤醒休眠会话，正是本条命令之后需要的）。
      AppLog.instance.log('Chat: 命令目录取回失败，按普通消息发送 → $e');
      return false;
    }
    if (catalog.any((c) => c['name'] == name)) {
      await _executeCommandLine(id, line, draft: line);
      return true;
    }
    if (!mounted) return true; // 页面已销毁：不提示，也不能落回普通发送路径去碰 context
    // 名字未注册 → **不阻塞**（刻意与 issue #25 原文的"提示 + 保留草稿"不同）：拦截会让 `/tmp`
    // 这类合法普通消息永远发不出去（单段文本在语法上与命令名无法区分，见 [isCommandLine]），
    // 而 PC 端对无法解析的名字同样下沉成普通发送。这里只给一次非阻塞提示，随后照旧发给模型。
    showToast(
      context,
      L10n.t(
        '未知命令 /$name：将作为普通消息发送',
        'Unknown command /$name — sending it as a normal message',
      ),
    );
    return false;
  }

  /// issue #25：真正执行一条命令（提交路径与 ⊕ 菜单里的裸命令共用）。
  /// [draft] 非空 = 该行来自输入框提交：提交成功后仅在草稿**仍等于该行**时清空（执行期间用户新
  /// 输入的内容绝不覆盖）；任何异常都保留草稿。菜单来的裸命令传 null（不碰草稿）。
  Future<void> _executeCommandLine(
    String id,
    String line, {
    String? draft,
  }) async {
    // 旗标归属：已有普通发送在途时不抢 _sending，否则 finally 会提前解锁别人的发送
    final acquired = !_sending;
    if (acquired) setState(() => _sending = true);
    AppLog.instance.log('Chat: 执行命令 → $id : $line');
    try {
      final r = await _api.runCommand(id, line);
      if (!mounted) return;
      // 提交成功（HTTP 200）才清草稿；内核 settle kind=error 也算"已受理并给出了明确答复"，
      // 用户看到提示后可重新输入。
      if (draft != null && _inputCtrl.text.trim() == draft) _inputCtrl.clear();
      final inner = r?['result']; // 服务端信封 { ok, result: { commandId, result: {kind,text} } }
      final settle = inner is Map ? inner['result'] : null;
      final data = settle is Map ? settle : const <dynamic, dynamic>{};
      final text = data['text'] is String ? data['text'] as String : '';
      if (data['kind'] == 'error') {
        // 命令自身失败（内核 settle kind=error）。移动端时间线在正常模式**不渲染** command/run、
        // command/done（见 timeline.dart 白名单），这里不提示的话用户完全看不到反馈。
        showToast(context, '${L10n.t('命令失败：', 'Command failed: ')}$text');
        return;
      }
      AppLog.instance.log('Chat: 命令完成 → $line');
      showToast(
        context,
        text.isNotEmpty ? text : L10n.t('命令已执行', 'Command executed'),
      );
    } on ApiException catch (e) {
      // 目录过期（名字在 App 目录里、宿主已没有它）→ 丢弃缓存，下次提交重新拉取，
      // 避免这个名字被永久卡在"未知命令"上。
      if (e.code == 'command-not-found') {
        _commandCatalog = null;
        _commandCatalogSessionId = null;
      }
      if (!mounted) return;
      showToast(context, commandExecuteErrorToast(e));
    } on TimeoutException {
      // 客户端 200s 先超时：服务端可能仍在跑（180s 上限 + 响应回程），同样**不断言失败**。
      if (!mounted) return;
      showToast(
        context,
        L10n.t(
          '命令已提交，但结果未知：请在对话里确认结果，不要盲目重发',
          'Command submitted but the outcome is unknown — check the conversation before resending',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${L10n.t('命令执行失败：', 'Command failed: ')}$e');
    } finally {
      if (acquired && mounted) setState(() => _sending = false);
    }
  }

  Future<void> _send([String? preset, String mode = 'followup']) async {
    final text = (preset ?? _inputCtrl.text).trim();
    // v2.9.0 review(HIGH)：页级动作绑定本页会话，叠层聊天不回退时发错会话
    final id = _mySessionId ?? widget.store.sessionId;
    if ((text.isEmpty && _pendingImages.isEmpty) ||
        id == null ||
        _sending ||
        preset != null && _pendingImages.isNotEmpty) {
      return;
    }
    // ── issue #25：斜杠命令必须在**提交时**判定，绝不能当普通消息喂给模型 ──
    // 门控 preset == null（初始自动发送 initialSend 语义不变）且无待发图片（图片只能走 /send）。
    // 位置必须早于 steer 降级提示、_sendImages、requestId 签名与乐观气泡：命令不产生用户气泡、
    // 不拿 requestId（与回执对账无关），也不会弹出「agent 空闲，已按普通消息发送」这类误导提示。
    if (preset == null && _pendingImages.isEmpty && isCommandLine(text)) {
      // true = 已按命令处理（命中目录并执行完/已给出失败提示）；false = 未注册命令的放行，
      // 继续走下面的普通发送路径（见 _tryRunCommandLine 里的取舍说明）。
      final handled = await _tryRunCommandLine(id, text);
      if (!mounted) return; // 取目录/执行期间页面可能已销毁
      if (handled) return;
    }
    // v3.0.0 图像链路：有待发图片 → 走图片通路（原始字节不压缩；成功/失败处理独立）
    if (mode == 'steer' && _pageAgentStatus != 'running') {
      showToast(
        context,
        L10n.t('agent 空闲，已按普通消息发送', 'Agent idle — sent as a normal message'),
      );
      mode = 'followup';
    }
    // v3.0.0(热修 07)：降级提前到分流之前——最终生效模式参与 requestId 签名
    if (_pendingImages.isNotEmpty) {
      await _sendImages(id, text, mode);
      return;
    }
    AppLog.instance.log(
      'Chat: 发送 → $id : ${text.length > 20 ? '${text.substring(0, 20)}…' : text}${mode == 'steer' ? '（插队）' : ''}',
    );
    // v3.0.0：运行中排队（followup）→ 消息**不进对话窗口**（与 PC 端一致：仅进 Queue Dock，
    // 被 agent 认领执行时 user/message 回显才上屏）——乐观气泡只保留给「立即生效」的发送
    final queued = mode != 'steer' && _pageAgentStatus == 'running';
    // v3.0.0(热修 05)：requestId 与草稿内容绑定——内容未变的重试复用同一 id
    // （服务端幂等，重复投递最多一次）；内容变化（文本/图片改动）则换新 id。
    final signature = composerSignature(
      id,
      mode,
      text,
      _pendingImages.map((f) => f.path).toList(),
    );
    if (_pendingRequestId == null || _pendingSignature != signature) {
      _pendingRequestId = genRequestId();
      _pendingSignature = signature;
    }
    final requestId = _pendingRequestId!;
    // 收起键盘，输入框回到原位
    FocusScope.of(context).unfocus();
    // agent 忙时提示（避免用户以为没反应而重复发送）；插队时不提示排队
    if (_pageAgentStatus == 'running' && preset == null && mode != 'steer') {
      showToast(
        context,
        L10n.t(
          'agent 正在处理上一轮，消息会排队等待',
          'The agent is still processing the last turn — your message will be queued',
        ),
      );
    }
    setState(() {
      _sending = true;
      if (!queued) _items.insert(0, _MsgItem.user(text)); // 最新在前：插入头部（视觉底部）
    });
    _inputCtrl.clear();
    _requestScrollFollow(forced: true, reason: CorrectionReason.forcedPosition);
    try {
      final (mid, note, configDegraded) = await _api.send(
        id,
        text,
        mode: mode,
        requestId: requestId,
      );
      _pendingRequestId = null;
      _pendingSignature = null;
      AppLog.instance.log(
        'Chat: 发送成功 mid=$mid${note != null ? ' note=$note' : ''}${configDegraded ? ' configDegraded' : ''}',
      );
      if (!mounted) return;
      // v3.1.5：休眠会话配置折叠失败 → 服务端已用默认模型/权限恢复该会话。必须让用户知道，
      // 否则配置被静默改写（issue #20 验收里「configDegraded 显式标记」在 App 侧的兑现）：
      // 置常驻横幅标记，并首次即时 toast（后续 toast 可能覆盖，横幅仍在）。
      if (configDegraded && !_configDegraded) {
        setState(() => _configDegraded = true);
        showToast(
          context,
          L10n.t('该会话配置已回退默认（模型/权限）', 'Session settings reverted to defaults'),
        );
      }
      // v2.7.2 review：mounted 检查之后才刷新队列（发送成功=新消息入队）
      _scheduleQueueRefresh();
      if (queued) {
        // 排队：无乐观气泡；插件持存（任务结束才释放）时明确提示
        if (note == 'held-until-idle') {
          showToast(
            context,
            L10n.t(
              '已排队：当前任务结束后自动发送',
              'Queued: will send after the current task finishes',
            ),
          );
        } else if (note == 'steer-degraded-held') {
          showToast(
            context,
            L10n.t(
              '已排队（插队不可用）：任务结束后自动发送',
              'Queued (steer unavailable): will send after the task finishes',
            ),
          );
        }
        return;
      }
      // 服务端实际持存但本地状态判断偏差（SSE 断线期间 agentStatus 停滞）：
      // 撤回乐观气泡，保持"排队消息不进对话窗口"一致
      if (note == 'held-until-idle' || note == 'steer-degraded-held') {
        setState(() {
          _items.removeWhere(
            (m) =>
                m.kind == _MsgKind.user &&
                m.messageId == null &&
                m.text == text,
          );
        });
        showToast(
          context,
          L10n.t(
            '已排队：当前任务结束后自动发送',
            'Queued: will send after the current task finishes',
          ),
        );
        return;
      }
      // v2.7.2：插队成功明确提示（否则和普通发送看起来一样，用户会困惑）
      if (mode == 'steer') {
        showToast(
          context,
          L10n.t(
            '已插队：消息将插到 agent 下一步执行',
            'Steered: will run at the agent\'s next step',
          ),
        );
      }
      setState(() {
        // 按文本定位乐观消息补 messageId（可能已被 SSE 回显合并，此时已是同 id，幂等）。
        // v2.7.2 review：与回显合并对称用 lastIndexWhere（合并到最旧未回显）——
        // 同文本多条时 mid 不会挂错条目
        final idx = _items.lastIndexWhere(
          (m) =>
              m.kind == _MsgKind.user && m.messageId == null && m.text == text,
        );
        if (idx != -1) _items[idx] = _items[idx].copyWith(messageId: mid);
      });
    } catch (e) {
      AppLog.instance.log('Chat: 发送异常（$mode）→ $e');
      if (!mounted) return;
      final definitive = e is ApiException && isDefinitiveSendRejection(e.code);
      if (definitive) {
        // v3.0.0(热修 05)：服务端明确拒绝（400/413/404/500…）＝未送达——
        // 重置 requestId（下次点击是全新尝试），恢复草稿供重发。
        _pendingRequestId = null;
        _pendingSignature = null;
        setState(() {
          if (!queued) {
            _items.removeWhere(
              (m) =>
                  m.kind == _MsgKind.user &&
                  m.messageId == null &&
                  m.text == text,
            );
            _items.insert(
              0,
              _MsgItem.divider('⚠ ${L10n.t('发送失败：', 'Send failed: ')}$e'),
            );
          }
        });
        _restoreDraftIfUntouched(text);
        showToast(context, '${L10n.t('发送失败：', 'Send failed: ')}$e');
        return;
      }
      // v3.0.0(热修 05)：结果未知（reset/超时/409）→ 同一 requestId 查回执（幂等），
      // 不再按文本/图片数启发式猜测。
      final receipt = await _resolveUnknownSend(id, requestId);
      if (!mounted) return;
      if (receipt != null && receipt['status'] == 'done') {
        _pendingRequestId = null;
        _pendingSignature = null;
        _scheduleQueueRefresh();
        showToast(
          context,
          L10n.t(
            '已送达：刚才网络波动，请勿重复发送',
            'Delivered despite a network hiccup — do not resend',
          ),
        );
        return;
      }
      if (receipt != null && receipt['status'] == 'error') {
        _pendingRequestId = null;
        _pendingSignature = null;
        final rmap = receipt['result'] is Map
            ? receipt['result'] as Map
            : const {};
        final msg =
            '${L10n.t('发送失败：', 'Send failed: ')}${rmap['detail'] ?? ''}';
        setState(() {
          if (!queued) {
            _items.removeWhere(
              (m) =>
                  m.kind == _MsgKind.user &&
                  m.messageId == null &&
                  m.text == text,
            );
            _items.insert(0, _MsgItem.divider('⚠ $msg'));
          }
        });
        _restoreDraftIfUntouched(text);
        showToast(context, msg);
        return;
      }
      // 未确认：保留 requestId 供幂等重试；撤回乐观气泡、恢复草稿
      setState(() {
        if (!queued) {
          _items.removeWhere(
            (m) =>
                m.kind == _MsgKind.user &&
                m.messageId == null &&
                m.text == text,
          );
          _items.insert(
            0,
            _MsgItem.divider('⚠ ${L10n.t('发送结果未知：', 'Outcome unknown: ')}$e'),
          );
        }
      });
      _restoreDraftIfUntouched(text);
      showToast(
        context,
        L10n.t(
          '发送结果未知：请稍后点重试，重试不会重复发送',
          'Outcome unknown — retry later; retries will not duplicate',
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// v3.0.0 图像链路：发送文本+图片（原始字节不压缩——与 PC 端一致；限额/模型能力前置校验）。
  Future<void> _sendImages(String id, String text, String mode) async {
    if (_pendingImages.isEmpty) return;
    setState(() => _sending = true);
    FocusScope.of(context).unfocus();
    // v3.0.0(热修 05)：requestId 声明在 try 外——catch 需要它判断「是否已发起请求」
    // （发送前校验/读图阶段的异常不能走进回执流程）。
    String? requestId;
    try {
      // 限额（与 PC 端同源数字：内核 imageLimits）
      final limits = widget.store.catalog?.imageLimits ?? const {};
      final maxBytes =
          ((limits['maxImageBytes'] as num?)?.toInt() ?? 20 * 1024 * 1024);
      // v3.0.0：兜底对齐内核默认（DEFAULT_MAX_MESSAGE_IMAGE_BYTES = 200MB；此前误写 20MB，
      // catalog 缺失时总大小被错误限制在单张额度）
      final catalogMax =
          ((limits['maxMessageImageBytes'] as num?)?.toInt() ??
          200 * 1024 * 1024);
      // v3.0.0(热修 05)：客户端传输天花板 40MB——服务端 HTTP body 上限 64MB，
      // base64 膨胀（×4/3）加 JSON 开销后仍有富余；超限在客户端明确提示，
      // 不再落到服务端 413。内核侧 200MB 能力不受影响（PC 端同源）。
      const transportCeiling = 40 * 1024 * 1024;
      final maxTotal = catalogMax > transportCeiling
          ? transportCeiling
          : catalogMax;
      final mediaTypes =
          (limits['mediaTypes'] as List?)?.map((e) => e.toString()).toSet() ??
          {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
      // 模型能力（服务端也会校验，此处前置拦截给用户明确提示）
      if (!_currentModelSupportsImages()) {
        showToast(
          context,
          L10n.t(
            '当前模型不支持图片输入，请先切换模型',
            'The current model does not support images — switch models first',
          ),
        );
        return;
      }
      final images = <Map<String, dynamic>>[];
      var total = 0;
      for (final f in _pendingImages) {
        final b = await f.readAsBytes();
        if (!mounted) return;
        if (b.isEmpty) continue;
        // v3.0.0：按字节魔数嗅探真实类型（微信/浏览器保存的 WebP 常带 .jpg/.png 名字，
        // 扩展名声明与内核字节校验不符会报 "Declared image type does not match its bytes"）；
        // 嗅探失败再退回扩展名。服务端 /send 亦有同款纠正（双保险）。
        final real = _sniffMediaType(b);
        final mediaType = real ?? _mediaTypeOf(f.name);
        if (!mediaTypes.contains(mediaType)) {
          if (real != null) {
            showToast(
              context,
              L10n.t(
                '不支持的图片格式：$mediaType',
                'Unsupported image format: $mediaType',
              ),
            );
          } else {
            showToast(
              context,
              L10n.t(
                '仅支持 PNG/JPEG/WebP/GIF 图片',
                'Only PNG/JPEG/WebP/GIF images are supported',
              ),
            );
          }
          return;
        }
        if (b.length > maxBytes) {
          showToast(
            context,
            L10n.t(
              '单张图片超过 ${_mbOf(maxBytes)}MB 上限',
              'One image exceeds the ${_mbOf(maxBytes)}MB limit',
            ),
          );
          return;
        }
        total += b.length;
        if (total > maxTotal) {
          showToast(
            context,
            L10n.t(
              '图片总大小超过 ${_mbOf(maxTotal)}MB 上限',
              'Images exceed the ${_mbOf(maxTotal)}MB total limit',
            ),
          );
          return;
        }
        images.add({
          'mediaType': mediaType,
          'data': base64Encode(b),
          if (f.name.isNotEmpty) 'name': f.name,
        });
      }
      if (images.isEmpty) {
        showToast(context, L10n.t('没有可发送的图片', 'No image to send'));
        return;
      }
      final signature = composerSignature(
        id,
        mode,
        text,
        _pendingImages.map((f) => f.path).toList(),
      );
      if (_pendingRequestId == null || _pendingSignature != signature) {
        _pendingRequestId = genRequestId();
        _pendingSignature = signature;
      }
      requestId = _pendingRequestId!;
      AppLog.instance.log(
        'Chat: 发送(图) → $id : ${images.length} 张, 共 $total 字节${mode == 'steer' ? '（插队）' : ''}',
      );
      final (accepted, note, configDegraded) = await _api.sendImages(
        id,
        text,
        images,
        mode: mode,
        requestId: requestId,
      );
      _pendingRequestId = null;
      _pendingSignature = null;
      if (!mounted) return;
      // v3.1.5：语义同文本发送——配置回退默认必须显式提示（常驻横幅 + 首次 toast）
      if (configDegraded && !_configDegraded) {
        setState(() => _configDegraded = true);
        showToast(
          context,
          L10n.t('该会话配置已回退默认（模型/权限）', 'Session settings reverted to defaults'),
        );
      }
      _scheduleQueueRefresh();
      if (!accepted) {
        // v3.0.0：先判 accepted，避免与下方 note 提示产生矛盾（不弹"已排队"却弹"未被接受"）
        showToast(context, L10n.t('发送未被接受', 'Send was not accepted'));
        return;
      }
      if (note == 'held-until-idle') {
        showToast(
          context,
          L10n.t(
            '已排队：当前任务结束后自动发送',
            'Queued: will send after the current task finishes',
          ),
        );
      } else if (note == 'steer-degraded-held') {
        showToast(
          context,
          L10n.t(
            '已排队（插队不可用）：任务结束后自动发送',
            'Queued (steer unavailable): will send after the task finishes',
          ),
        );
      } else if (mode == 'steer') {
        showToast(
          context,
          L10n.t(
            '已插队：消息将插到 agent 下一步执行',
            'Steered: will run at the agent\'s next step',
          ),
        );
      }
      setState(() => _pendingImages.clear());
      // v3.0.0：发送成功（含排队持存）即清空输入框——此前文字残留，用户误以为没发出而重复发送
      if (_inputCtrl.text == text) _inputCtrl.clear();
    } catch (e) {
      AppLog.instance.log('Chat: 发送(图)异常 → $e');
      if (!mounted) return;
      if (requestId == null) {
        // 发送前校验/读图阶段异常：未发出任何请求 → 按普通失败处理
        showToast(context, '${L10n.t('发送失败：', 'Send failed: ')}$e');
        return;
      }
      final definitive = e is ApiException && isDefinitiveSendRejection(e.code);
      if (definitive) {
        // v3.0.0(热修 05)：服务端明确拒绝＝未送达——重置 requestId，保留草稿供重发。
        _pendingRequestId = null;
        _pendingSignature = null;
        showToast(context, '${L10n.t('发送失败：', 'Send failed: ')}$e');
        return;
      }
      final receipt = await _resolveUnknownSend(id, requestId);
      if (!mounted) return;
      if (receipt != null && receipt['status'] == 'done') {
        _pendingRequestId = null;
        _pendingSignature = null;
        setState(() => _pendingImages.clear());
        if (_inputCtrl.text == text) _inputCtrl.clear();
        _scheduleQueueRefresh();
        showToast(
          context,
          L10n.t(
            '已送达：刚才网络波动，请勿重复发送',
            'Delivered despite a network hiccup — do not resend',
          ),
        );
        return;
      }
      if (receipt != null && receipt['status'] == 'error') {
        _pendingRequestId = null;
        _pendingSignature = null;
        final rmap = receipt['result'] is Map
            ? receipt['result'] as Map
            : const {};
        showToast(
          context,
          '${L10n.t('发送失败：', 'Send failed: ')}${rmap['detail'] ?? ''}',
        );
        return;
      }
      // 未确认：保留 requestId 与草稿供幂等重试
      showToast(
        context,
        L10n.t(
          '发送结果未知：请稍后点重试，重试不会重复发送',
          'Outcome unknown — retry later; retries will not duplicate',
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// v3.0.0：当前模型是否支持图片（catalog.imageSupported；缺失时交服务端裁决）。
  bool _currentModelSupportsImages() {
    final cat = widget.store.catalog;
    final cfg = widget.store.sessionConfig;
    if (cat == null || cfg.model == null) return true;
    for (final m in cat.models) {
      if (m.id == cfg.model) return m.imageSupported;
    }
    return true;
  }

  static String _mediaTypeOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    return '';
  }

  /// v3.0.0：按字节魔数嗅探图片真实类型（见 [_sendImages] 说明）；无法识别返回 null。
  static String? _sniffMediaType(Uint8List b) {
    if (b.length < 12) return null;
    bool startsWith(List<int> m, [int off = 0]) {
      if (b.length < off + m.length) return false;
      for (var i = 0; i < m.length; i++) {
        if (b[off + i] != m[i]) return false;
      }
      return true;
    }

    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'image/png';
    }
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
        startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
      return 'image/webp';
    }
    if (startsWith(const [0x66, 0x74, 0x79, 0x70], 4)) {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (const ['heic', 'heix', 'hevc', 'mif1'].contains(brand)) {
        return 'image/heic';
      }
    }
    return null;
  }

  static int _mbOf(int bytes) => bytes ~/ (1024 * 1024);

  /// 停止（取消）会话当前运行：对齐 PC 端"停止"按钮。
  Future<void> _stop() async {
    // v2.9.0 review(HIGH)：页级动作绑定本页会话
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _sending) return;
    AppLog.instance.log('Chat: 请求停止会话 $id');
    try {
      await _api.stopSession(id);
      if (mounted) {
        showToast(
          context,
          L10n.t(
            '已请求停止，agent 当前轮次结束后停下',
            'Stop requested — the agent will halt after its current turn',
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          '${L10n.t('停止失败：', 'Stop failed: ')}$e${L10n.t('（桌面端插件需重启生效）', ' (the desktop plugin may need a restart)')}',
        );
      }
    }
  }

  // ── v2.7：任务（jobs） ──
  Future<void> _killJob(String jobId) async {
    // v2.9.0 review(HIGH)：页级动作绑定本页会话
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null) return;
    try {
      await _api.jobKill(sid, jobId);
      if (mounted) showToast(context, L10n.t('已请求取消任务', 'Cancel requested'));
    } catch (e) {
      if (mounted) {
        showToast(context, '${L10n.t('取消失败：', 'Cancel failed: ')}$e');
      }
    }
  }

  void _openTools() {
    // v2.9.0 review：与页级动作一致，绑定本页会话（工具页上下文不能跟随全局切换）
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null) return;
    showSessionToolsSheet(
      context,
      widget.store,
      sid,
      onTitleChanged: widget.onTitleChanged,
    );
  }

  void _openSessionToolsFromActionRail() {
    // Preserve the app-bar action's existing page-session-only behavior.
    final sid = _mySessionId;
    if (sid != null) {
      showSessionToolsSheet(
        context,
        widget.store,
        sid,
        onTitleChanged: widget.onTitleChanged,
      );
    }
  }

  Future<void> _openConversationActionRail() async {
    final action = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: L10n.t('关闭对话操作', 'Dismiss conversation actions'),
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => _ConversationActionRail(
        initialOrder: widget.store.conversationActionOrder,
        onOrderChanged: (order) =>
            unawaited(widget.store.setConversationActionOrder(order)),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'git':
        await _openGit();
      case 'files':
        _openSessionFilesFromActionRail();
      case 'session_tools':
        _openSessionToolsFromActionRail();
      case 'copy':
        await _copyConversation();
    }
  }

  /// 打开会话文件浏览（浏览根 = 本会话工作目录，与 Git 导航同源）。
  void _openSessionFilesFromActionRail() {
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null) return;
    openSessionFiles(
      context,
      widget.store,
      sid,
      gitReadApi: widget.gitReadApi,
      apiClient: _api,
    );
  }

  /// issue #67：工具卡折叠行路径点击 → 直接定位到该文件的预览。
  ///
  /// 只把服务端下发的 `relative` 原样交给页面，**不在卡片/页面里拼绝对路径**；
  /// 拼接与夹取由 [SessionFilesController] 唯一负责。返回时 ChatScreen 未重建，
  /// 滚动位置与展开态天然保持。
  void _openFilePathPreview(String relativePath) {
    if (!mounted) return;
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null) return;
    openSessionFiles(
      context,
      widget.store,
      sid,
      gitReadApi: widget.gitReadApi,
      initialRelativePath: relativePath,
      apiClient: _api,
    );
  }

  Future<void> _openGit() async {
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null || _gitController != null) return;
    final readApi = widget.gitReadApi ?? _api;
    final controller =
        widget.gitControllerFactory?.call(readApi) ??
        GitBrowserController(
          readApi,
          graphPageSize: 16,
          branchLimit: widget.store.gitGraphBranchLimit,
        );
    _gitController = controller;
    unawaited(controller.open(sid));
    final graphScrollController = ScrollController();
    try {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GitBrowserSheet(
            controller: controller,
            scrollController: graphScrollController,
            tabs: widget.store.gitTabs,
            store: widget.store,
          ),
        ),
      );
    } finally {
      graphScrollController.dispose();
      if (identical(_gitController, controller)) _gitController = null;
      controller.dispose();
    }
  }

  /// 执行消息操作（v2.8.0：常驻操作栏入口）：copy / positive / negative / fork。
  /// 反馈支持 toggle：再点已选的评级 = 取消（rating=none，与 PC 端一致），本地图标同步高亮。
  Future<void> _runMessageAction(_MsgItem item, String action) async {
    // v2.9.0 review(HIGH)：页级动作绑定本页会话
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: item.text));
        if (!mounted) return;
        showToast(context, L10n.t('已复制', 'Copied'));
      case 'positive':
      case 'negative':
        final mid = item.messageId;
        if (mid == null) {
          showToast(
            context,
            L10n.t(
              '该消息暂不支持反馈（旧消息无 messageId）',
              'Feedback is not available for this message (older messages lack a message ID)',
            ),
          );
          return;
        }
        // v2.8.0 review(P2-2)：同消息反馈提交中则忽略连点（防 toggle 竞态：服务端与本地状态错乱）
        if (_feedbackInFlight.contains(mid)) return;
        _feedbackInFlight.add(mid);
        // toggle：再点当前已选的评级 → 取消反馈
        final target = item.rating == action ? 'none' : action;
        try {
          await _api.putFeedback(id, mid, target);
          if (!mounted) return;
          // 服务端确认后更新本地状态（驱动操作栏图标高亮/熄灭）。
          // 按 messageId 匹配而非对象引用——SSE 回显合并/重建会产生新对象，引用查找会漏；
          // live 列表 _items 与历史段 _histItems 都同步更新（review P2-1：历史页图标也要变）
          final newRating = target == 'none' ? null : target;
          void updRating(List<_MsgItem> list) {
            final i = list.indexWhere(
              (m) => m.kind == _MsgKind.assistant && m.messageId == mid,
            );
            if (i == -1) return;
            final old = list[i];
            // v3.1.6（app-audit ②）：重建条目必须**带上全部详情字段**——此前漏了
            // detailTextChars/detailDegraded/detailMode/detailErrorCode，点一次 👍/👎
            // 就把「加载完整正文」入口、降级提示与错误重试一起抹掉。
            list[i] = _MsgItem.assistant(
              old.text,
              usage: old.usage,
              seq: old.seq,
              messageId: old.messageId,
              rating: newRating,
              images: old.images,
              files: old.files,
              reasoning: old.reasoning,
              detailAvailable: old.detailAvailable,
              rawData: old.rawData,
              detailLoading: old.detailLoading,
              detailDegraded: old.detailDegraded,
              detailMode: old.detailMode,
              detailErrorCode: old.detailErrorCode,
              detailTextChars: old.detailTextChars,
            );
          }

          setState(() {
            updRating(_items);
            updRating(_histItems);
          });
          showToast(context, switch (target) {
            'positive' => L10n.t('已标记：好的回答 ✓', 'Marked: good answer ✓'),
            'negative' => L10n.t('已标记：有问题的回答 ✓', 'Marked: bad answer ✓'),
            _ => L10n.t('已取消反馈', 'Feedback removed'),
          });
        } catch (e) {
          if (!mounted) return;
          showToast(context, '${L10n.t('反馈失败：', 'Feedback failed: ')}$e');
        } finally {
          _feedbackInFlight.remove(mid);
        }
      case 'fork':
        final seq = item.seq;
        if (seq == null) {
          showToast(
            context,
            L10n.t('该消息暂不支持分支', 'Forking is not available for this message'),
          );
          return;
        }
        try {
          final childId = await _api.forkSession(id, atSeq: seq);
          if (!mounted) return;
          showToast(
            context,
            L10n.t('已分支，正在打开新对话…', 'Forked — opening the new chat…'),
          );
          final prevId = _mySessionId;
          widget.store.refreshSessions();
          // Phase 2(A4)：统一打开会话流程；返回后恢复原会话（分支页不改变主会话）
          await openChat(
            context,
            widget.store,
            childId,
            onTitleChanged: widget.onTitleChanged,
            onReturn: () async {
              if (mounted && prevId != null && prevId != childId) {
                await widget.store.setSession(prevId);
              }
            },
          );
        } catch (e) {
          if (!mounted) return;
          showToast(context, '${L10n.t('分支失败：', 'Fork failed: ')}$e');
        }
    }
  }

  // ── issue #70：活动条与过程行分工（三处不重复）─────────────────────────
  //
  // 判定（issue 预审补充 + 裁决 D3）：
  // - 过程块可见且块内已有 reasoning 行（provisional 或落定）：
  //   有工具 → 只显示工具/状态；无工具 → 整条不渲染（思考已在过程行里）；
  // - 无过程块锚点 → 保留现状思考（`思考中…（N 字）`，正文流式后 `已思考 N 字`）；
  // - 历史视图不渲染活动条；`showReasoning` 仍只控制内容能否展开。
  // 思考文本走 `_liveReasoningRevision` 行级通知（与 provisional 行同源、同一快照）。
  /// re-review P2：运行工具行是否仍在真正视口内。
  ///
  /// 保守策略：key 尚未挂载/视口缺失/尺寸未定 → 视为不可见（活动条显示），
  /// 避免“活动条被过滤但屏幕上看不到”的回归。
  bool _isProcessToolRowInViewport(String callId) {
    final rowContext = _processToolRowKeys[callId]?.currentContext;
    final viewportContext = _liveViewportKey.currentContext;
    if (rowContext == null ||
        viewportContext == null ||
        !rowContext.mounted ||
        !viewportContext.mounted) {
      return false;
    }
    try {
      final rowBox = rowContext.findRenderObject();
      final viewportBox = viewportContext.findRenderObject();
      if (rowBox is! RenderBox || viewportBox is! RenderBox) return false;
      if (!rowBox.attached || !viewportBox.attached) return false;
      if (!rowBox.hasSize || !viewportBox.hasSize) return false;
      final rowRect = rowBox.localToGlobal(Offset.zero) & rowBox.size;
      final viewportRect =
          viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
      _activityGeometryResolved = true;
      return rowRect.overlaps(viewportRect);
    } catch (_) {
      // 布局/语义帧交界上的极端时序：保守视为不可见（活动条显示）。
      return false;
    }
  }

  Widget _buildActivityBar() {
    final policy = _foldPolicy;
    // issue #108 v4：简洁运行中隐藏活动条（摘要承载状态）；其他档保留。
    if (!policy.liveActivityBarVisible) return const SizedBox.shrink();
    final live = _liveReasoning.current;
    final plan = _livePlanCache;
    final inBlock =
        plan != null && (plan.provisionalRendered || plan.reasoningRowVisible);
    final reasoning = inBlock ? '' : (live?.text ?? '');
    // re-review P2：过程行 key 在首帧 layout 后才挂载。用「已解析」状态驱动少量
    // post-frame 重建（而不是固定多帧），避免空转重建影响性能用例。
    // 用「当前可能重复的活动工具集合」判断是否需要重新尝试几何；流式 delta 只改文本，
    // 集合不变 → 不重置，避免每帧都 post-frame 重建（性能用例敏感）。
    final candidateKey = [
      for (final callId in _activeTools.keys)
        if (plan != null && plan.visibleToolCallIds.contains(callId)) callId,
    ]..sort();
    final signature = candidateKey.join('|');
    if (signature != _activityGeometryCandidateKey) {
      _activityGeometryCandidateKey = signature;
      _activityGeometryResolved = false;
      _activityGeometryRefreshScheduled = false;
      _activityGeometryRefreshFrames = 0;
    }
    // 只有「活动条当前可能有重复候选」时才需要几何重建；没有运行中工具不影响活动条。
    final hasGeometryCandidate = plan != null &&
        _scrollFollow.nearBottom &&
        _activeTools.keys.any(plan.visibleToolCallIds.contains);
    if (!_activityGeometryResolved &&
        !_activityGeometryRefreshScheduled &&
        _activityGeometryRefreshFrames < 1 &&
        hasGeometryCandidate) {
      _activityGeometryRefreshFrames++;
      _activityGeometryRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _activityGeometryRefreshScheduled = false;
        if (mounted) setState(() {});
      });
    }
    // issue #83 后续：过程块已展开且钉在底部时，运行中工具行已在对话里可见，
    // 活动条不再重复同一工具；只保留过程块尚未承载的工具（或滚动离开底部时）。
    final tools = [
      for (final entry in _activeTools.entries)
        if (!(plan != null &&
            _scrollFollow.nearBottom &&
            plan.visibleToolCallIds.contains(entry.key) &&
            _isProcessToolRowInViewport(entry.key)))
          entry.value,
    ];
    final shown = reasoning.isNotEmpty || tools.isNotEmpty;
    if (shown != _activityBarShown) {
      _activityBarShown = shown;
      // 活动条显隐会改变消息视口高度；本帧由子 ListenableBuilder 重建，父 build 不会
      // 再跑，必须帧后补一次底部占位实测，否则短内容会留下大块空白（issue #89）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scheduleLiveBottomGapMeasure();
        _requestScrollFollow();
      });
    }
    if (reasoning.isEmpty && tools.isEmpty) return const SizedBox.shrink();
    return _ActivityBar(
      reasoning: reasoning,
      expanded: _reasoningExpanded,
      textStreaming: _streaming,
      // issue #108：隐藏「思考内容」设置后，活动条只显示状态，不显示思考正文。
      showContent: false,
      tools: tools,
      onToggleReasoning: () =>
          setState(() => _reasoningExpanded = !_reasoningExpanded),
    );
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    LiveProcessCounters.pageBuilds++; // issue #70：性能用例的页面重建计数钩子
    final store = widget.store;
    final ink3 = DshColors.ink3(context);
    final brand = DshColors.brand(context);
    final surface = DshColors.surface(context);
    // issue #52：先建立过程块计划（宿主/索引/分批），再决定哪些工具卡已由过程块呈现。
    _planFor(history: false);
    if (_inHistory) _planFor(history: true);

    // issue #24：刻度轨只在"离开底部且有 ≥2 轮"时出现（复用 160px 判据，
    // 与"回到底部"圆钮同进同出；见 ADR 0018）。
    // issue #25 二期：刻度 = 已加载轮次 ∪ 宿主大纲；未加载的刻度短而淡、可跳转。
    final turnTicks = _turnTicks;
    final turnAnchors = [
      for (final tick in turnTicks)
        TurnAnchor(
          turn: tick.turn,
          seq: tick.seq,
          prompt: tick.prompt,
          response: tick.response,
        ),
    ];
    final unloadedTurns = {
      for (final tick in turnTicks)
        if (!tick.loaded) tick.turn,
    };
    final showTurnRail = shouldShowTurnRail(
      nearBottom: _scrollFollow.nearBottom,
      turnCount: turnTicks.length,
    );
    _turnRailVisible = !_inHistory && showTurnRail;
    // 阶梯被截断 / 读取失败 / 能力缺失 / 该会话无大纲：在用户**能看到刻度轨**时
    // 各说明一次（四态文案互不相同，见 `turnOutlineNotice`），绝不静默。
    // 评审 P2 指出：三态"给出不同说明"是正文与 ADR 的验收项，不能因为"退回一期本身
    // 完整正确"就把 empty / capabilityMissing 的说明整个吞掉——用户需要知道为什么阶梯短。
    // 只在**问过之后**才说明：首帧还没拿到能力声明时不得下"能力缺失"结论。
    if (showTurnRail && _turnOutlineResolved && !_turnOutlineNoticeShown) {
      final notice = turnOutlineNotice(_turnOutline);
      if (notice != null) {
        _turnOutlineNoticeShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showToast(context, notice);
        });
      }
    }
    // 条目增删/分页会改变几何：本帧结束后校准"当前轮"。
    // 只在取值变化时 setState，因此会收敛，不会自激。
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateActiveTurn());
    // issue #77：帧后实测 live 内容高度，维护「短内容底部对齐」的顶部占位。
    if (!_inHistory) _scheduleLiveBottomGapMeasure();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                _title ?? L10n.t('会话', 'Session'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _StatusDot(
              status: store.connState == 'connected'
                  ? _pageAgentStatus
                  : 'offline',
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: L10n.t('对话操作', 'Conversation actions'),
            onPressed: _openConversationActionRail,
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        _bodyMaxHeight = constraints.maxHeight;
        return Column(
        children: [
          // 用量条
          if (_usageLoaded && _usage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
              child: Text(
                _fmtUsage(_usage),
                style: TextStyle(fontSize: 11.5, color: ink3),
              ),
            ),
          // v2.8.0：后台任务卡片移到对话框顶部（不再与问询/审批卡堆在底部），可收纳、默认收起
          if (!_inHistory && widget.store.hasRunningJobs(_mySessionId ?? ''))
            _JobCard(
              jobs: widget.store.jobsOf(_mySessionId ?? ''),
              onOpen: _openTools,
              onKill: _killJob,
            ),
          // v3.1.5：休眠会话降级常驻提示——历史只含 current surface / 配置已回退默认
          if (_historyDegraded || _configDegraded)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_historyDegraded)
                    Text(
                      L10n.t(
                        '当前仅能恢复部分历史，更早内容可能不可用',
                        'Only partial history available',
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (_configDegraded)
                    Text(
                      L10n.t(
                        '该会话配置已回退默认（模型/权限/预设）',
                        'Session settings reverted to defaults (model/permissions)',
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          // 消息流：live 视图（普通列表，最新在底部）或历史分段浏览；
          // 上翻时右下角浮出"回到底部"圆钮（位于输入框正上方，不在消息流内）
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _inHistory ? _buildHistoryView() : _buildLiveView(),
                ),
                // issue #24：轮次导航刻度轨。放在消息流之上、右下角圆钮之下；
                // 只占右侧约 28px，空白区域不吸收命中，消息流照常滚动。
                if (!_inHistory && showTurnRail)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    bottom: turnRailBottomReserve,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: turnRailRightGutter),
                        child: TurnNavigatorRail(
                          anchors: turnAnchors,
                          unloadedTurns: unloadedTurns,
                          activeTurn: _activeTurn,
                          busyTurn: _busyTurn,
                          width: turnRailWidth,
                          maxHeight: 420,
                          onNavigate: (anchor) =>
                              unawaited(_navigateToTurn(anchor)),
                        ),
                      ),
                    ),
                  ),
                if (!_inHistory)
                  // issue #81：圆钮移入右侧 action gutter（right 0，38dp），正文右
                  // padding 相应取 38，避免 320+大字时遮挡尾段；动画/点击/语义不变。
                  Positioned(
                    bottom: 12,
                    right: 0,
                    child: _JumpToLatestButton(
                      visible: _showJumpToLatest,
                      onTap: _jumpToLatest,
                    ),
                  ),
              ],
            ),
          ),
          // issue #97 P2：composer 上方的底部控件统一成可测量的一组，
          // 菜单可用高度需扣除它们，避免 320×640 + 键盘时 Column 溢出。
          Column(
            key: _bottomControlsKey,
            mainAxisSize: MainAxisSize.min,
            children: [
          // 活动条：工具状态 / 无过程块时的思考（issue #70：与 provisional 同源、三处不重复）
          if (!_inHistory)
            // re-review P2：随滚动重建，工具行滚出视口时活动条立刻恢复。
            ListenableBuilder(
              listenable: Listenable.merge([_liveReasoningRevision, _scrollCtrl]),
              builder: (context, _) => _buildActivityBar(),
            ),
          // 内核问询/审批弹窗（思考中途需要你拍板，与 PC 端同一 pending 通道）
          if (_question != null)
            _QuestionCard(
              // v3.1.6（app-audit ①5）：按 rpcId 给 key —— 同一会话连续两条问询若中间没有
              // 一帧 `_question == null`（store 的 per-session pending 是覆盖式写入），
              // 无 key 时 Flutter 会复用同一个 State：它按旧问询 id 建的 _selected/_ctrls
              // 找不到新 id → `_selected[q.id]!` 抛 null-check 异常（整页构建失败）。
              key: ValueKey<String>(_question!.rpcId),
              request: _question!,
              onCancel: () {
                // 立即收起卡片（内核 resolved 帧可能因本地状态已清而不再转发）
                final rpc = _question!.rpcId;
                setState(() => _question = null);
                unawaited(_cancelPending(rpc));
              },
              onSubmitted: _submitQuestion,
            ),
          if (_approval != null)
            _ApprovalCard(
              request: _approval!,
              onDecide: _decideApproval,
              onCancel: () {
                final rpc = _approval!.rpcId;
                setState(() => _approval = null);
                unawaited(_cancelPending(rpc));
              },
            ),
          // 快捷动作
          if (store.actions.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final a in store.actions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _ActionChip(
                        action: a,
                        onTap: () => showActionSheet(context, a),
                      ),
                    ),
                ],
              ),
            ),
          // v3.0.0 图像链路：待发送图片缩略图 rail（composer 上方，PC 端 AttachmentRail 同理念）
          _buildImageRail(),
          // v3.1.4：任务清单面板（内核 todo 投影同源，对齐 PC 端「任务」面板）
          if (!_inHistory) _buildTodoPanel(),
          // v2.7.2：队列停靠区（独立于输入框的轻量条，空队列不渲染）
          _buildQueueDock(),
            ],
          ),
          // composer（v2.8.0 重构为两层，对齐 PC 端 InputBar）：
          // 第一层 = [/命令] + 输入框（独占最宽）；第二层 = 模型/权限/排队胶囊 + 上下文圆环 + 发送
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: TapRegion(
                groupId: const ValueKey('slash-composer'),
                onTapOutside: (_) {
                  // issue #97：菜单/composer 内部拖动、点选不视为“外部点击”；
                  // 只有真正点输入区外部才收起菜单（键盘焦点不受影响）。
                  if (_slashToken != null && mounted) {
                    setState(() => _slashToken = null);
                  }
                },
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // issue #97：菜单在 composer 卡片之外、输入框上方（键盘弹出随 composer 上移）。
                  if (!_inHistory && _slashToken != null) ...[
                    _buildSlashMenu(context),
                    const SizedBox(height: 8),
                  ],
                  Container(
                key: _composerKey,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: Theme.of(context).brightness == Brightness.dark
                      ? DshTheme.shadowDark
                      : DshTheme.shadow,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 第一层：输入框（独占最宽）
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputCtrl,
                            minLines: 1,
                            maxLines: 4,
                            style: const TextStyle(fontSize: 14.5),
                            decoration: InputDecoration(
                              hintText: L10n.t('回复 agent…', 'Reply to agent…'),
                              hintStyle: TextStyle(color: ink3),
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 8,
                              ),
                            ),
                            onSubmitted: (_) => _send(),
                            onTap: _refreshSlashToken,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 第二层：⊕命令入口 + 模型/权限胶囊（省略显示）+ 排队发送 + 上下文圆环 + 发送
                    Row(
                      children: [
                        // v2.8.0：命令入口——浅灰圆 +（对齐 PC 端 command）
                        // v3.0.0 图像链路：⊕ = 更多（拍照 / 从相册选择 / 命令）
                        InkWell(
                          onTap: _showComposerMenu,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: DshColors.line(context),
                              shape: BoxShape.circle,
                            ),
                            // v2.8.0 review(P2-3)：图标用 ink3 主题自适应（深色下不再黑压黑）
                            child: Icon(
                              Icons.add,
                              size: 17,
                              color: DshColors.ink3(context),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 左侧弹性组：⊕ + 模型/权限（可收缩省略）+ 排队（固定）——
                        // 整体包 Expanded，剩余空间在组内消化；右侧圆环/发送在组外固定，永不挤出
                        Expanded(
                          child: Row(
                            children: [
                              // 模型胶囊：名称省略；Flexible 空间不足时收缩（省略号），充足时自然宽
                              Flexible(
                                child: _Pill(
                                  label: _shortModel(store.sessionConfig.model),
                                  onTap: () => showModelSheet(context, store),
                                ),
                              ),
                              const SizedBox(width: 6),
                              // 权限胶囊：同上
                              Flexible(
                                child: _Pill(
                                  label: _shortPerm(
                                    _permName(
                                      store.sessionConfig.permissionPreset,
                                    ),
                                  ),
                                  onTap: () => showPermSheet(context, store),
                                ),
                              ),
                              // 运行中且输入非空 → 「排队发送」胶囊（点击=普通发送，运行中自动排队）；
                              // 固定宽度（不参与收缩，始终完整显示）
                              if (_pageAgentStatus == 'running' &&
                                  _inputCtrl.text.trim().isNotEmpty) ...[
                                const SizedBox(width: 6),
                                _Pill(
                                  label: L10n.t('排队发送', 'Queue send'),
                                  onTap: () => _send(),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 上下文窗口占用圆环（对齐 PC 端；数据齐全时才显示）——组外固定
                        if (_contextRatio != null) ...[
                          _ContextRing(ratio: _contextRatio!),
                          const SizedBox(width: 8),
                        ],
                        // v2.7.2：发送按钮恢复原设计——运行中=停止（对齐 PC 端），空闲=发送；
                        // 长按=插队发送；运行中普通发送走「排队发送」胶囊——组外固定
                        GestureDetector(
                          onTap: _sending
                              ? null
                              : (_pageAgentStatus == 'running' ? _stop : _send),
                          onLongPress: _sending
                              ? null
                              : () => _send(null, 'steer'),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: brand,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: _pageAgentStatus == 'running'
                                ? Center(
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: DshColors.onBrand(context),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  )
                                : _sending
                                ? SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: DshColors.onBrand(context),
                                    ),
                                  )
                                : Icon(
                                    Icons.arrow_upward,
                                    size: 17,
                                    color: DshColors.onBrand(context),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                  ),
                ],
              ),
              ),
            ),
          ),
        ],
      );
      }),
    );
  }

  String _fmtUsage(Map<String, dynamic> u) {
    final input = (u['inputTokens'] as num?)?.toInt() ?? 0;
    final read = (u['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final write = (u['cacheWriteTokens'] as num?)?.toInt() ?? 0;
    final out = (u['outputTokens'] as num?)?.toInt() ?? 0;
    final billed = input + read + write;
    final hit = billed > 0 ? ((read / billed) * 100).round() : 0;
    return '${L10n.t('本会话：输入 ', 'This session: in ')}${fmtTokens(input)}${L10n.t(' · 缓存 ', ' · cache ')}${fmtTokens(read)}${L10n.t(' · 输出 ', ' · out ')}${fmtTokens(out)}${L10n.t(' · 命中率 ', ' · hit rate ')}$hit%';
  }

  String _permName(String? id) => permNameOf(id) ?? L10n.t('权限', 'Permission');

  /// v2.8.0：模型名省略显示（胶囊空间有限，截断到 ~10 字符 + …）。
  String _shortModel(String? model) {
    final m = model ?? L10n.t('选择模型', 'Select model');
    return m.length > 10 ? '${m.substring(0, 9)}…' : m;
  }

  /// v2.8.0：权限名省略显示（"Danger Full Access" → "Danger Full…"）。
  String _shortPerm(String perm) =>
      perm.length > 14 ? '${perm.substring(0, 13)}…' : perm;

  /// v2.8.0：斜杠命令菜单（对齐 PC 端 command menu）——列出命令。
  /// issue #25：裸命令（无 input，如 /compact）点选即执行；需要参数的命令仍只填入输入框。
  /// v3.0.0 图像链路：⊕ = 更多菜单（拍照 / 从相册选择 / 命令）。
  Future<void> _showComposerMenu() async {
    if (_pickingImages) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.add_circle_outline,
                    size: 16,
                    color: Color(0xFF426EFE),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    L10n.t('更多', 'More'),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.photo_camera_outlined, size: 20),
              title: Text(
                L10n.t('拍照', 'Take a photo'),
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop('camera'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.photo_library_outlined, size: 20),
              title: Text(
                L10n.t('从相册选择', 'Choose from gallery'),
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop('gallery'),
            ),
            // v3.1.2（csborbbnc 反馈）：文件传输入口（系统选择器/下载保存）
            ListTile(
              dense: true,
              leading: const Icon(Icons.upload_file_outlined, size: 20),
              title: Text(
                L10n.t('上传文件', 'Upload file'),
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop('upload-file'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.download_outlined, size: 20),
              title: Text(
                L10n.t('下载文件', 'Download file'),
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop('download-file'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.code, size: 20),
              title: Text(
                L10n.t('命令', 'Commands'),
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop('commands'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'camera') {
      await _pickImages(fromCamera: true);
      return;
    }
    if (choice == 'gallery') {
      await _pickImages(fromCamera: false);
      return;
    }
    if (choice == 'upload-file') {
      await _uploadFile();
      return;
    }
    if (choice == 'download-file') {
      await _downloadFile();
      return;
    }
    await _showCommandMenu();
  }

  /// v3.1.2（csborbbnc 反馈）：上传文件——系统选择器 → 写入电脑端会话工作目录。
  static const MethodChannel _filesChannel = MethodChannel('dsh/files');

  Future<void> _uploadFile() async {
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null) {
      showToast(context, L10n.t('无当前会话', 'No active session'));
      return;
    }
    try {
      final picked = await _filesChannel.invokeMapMethod<String, dynamic>(
        'pickFile',
      );
      if (picked == null) return; // 取消
      final name = picked['name'] as String? ?? 'file';
      final bytes = picked['bytes'] as Uint8List?;
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showToast(context, L10n.t('读取文件失败', 'Failed to read the file'));
        }
        return;
      }
      final r = await _api.uploadFile(sid, name, bytes);
      if (mounted) {
        showToast(
          context,
          '${L10n.t('已上传到电脑工作目录：', 'Uploaded to PC workspace: ')}${r['path'] ?? name}',
        );
      }
    } catch (e) {
      if (mounted) {
        showToast(context, '${L10n.t('上传失败：', 'Upload failed: ')}$e');
      }
    }
  }

  /// v3.1.2（csborbbnc 反馈）：下载文件——可视化文件选择器（盘符/目录树/点文件）
  /// → 保存到手机「下载」目录。
  /// v3.2.2：流式下载——临时文件 + 原生按路径保存，大文件不再整块进内存。
  Future<void> _downloadFile({String? resumePath}) async {
    late ResumableDownloads downloads;
    String? path = resumePath;
    try {
      final support = await getApplicationSupportDirectory();
      downloads = ResumableDownloads(
        Directory('${support.path}/downloads'),
        _api,
      );
      final pending = await downloads.pending();
      if (!mounted) return;
      if (path == null && pending.isNotEmpty) {
        path = await showDownloadResumePicker(context, downloads, pending);
        if (path == null || !mounted) return;
      }
      if (path == null || path.isEmpty) {
        path = await showFilePicker(context);
      }
    } catch (e) {
      if (mounted) showToast(context, describeDownloadError(e).summary);
      return;
    }
    if (path == null || path.isEmpty || !mounted) return;
    final remotePath = path;
    final name =
        remotePath
            .split(RegExp(r'[\\/]'))
            .where((s) => s.isNotEmpty)
            .lastOrNull ??
        'file';
    final progress = ValueNotifier<DownloadProgress>(
      const DownloadProgress(received: 0),
    );
    final cancel = DownloadCancelToken();
    DownloadForegroundLease? foreground;
    var dialogVisible = true;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text(L10n.t('下载中', 'Downloading')),
          content: ValueListenableBuilder<DownloadProgress>(
            valueListenable: progress,
            builder: (_, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L10n.t(
                    foreground?.backgroundActive == true
                        ? '后台下载已开启，可从通知暂停。系统中断后可从下载入口继续。'
                        : '当前为前台下载；切后台可能暂停，可从下载入口继续。',
                    foreground?.backgroundActive == true
                        ? 'Background download is active. Pause from its notification; resume after interruption from Downloads.'
                        : 'Foreground download. Backgrounding may pause it; resume from Downloads.',
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: p.fraction),
                const SizedBox(height: 10),
                Text(
                  p.total == null
                      ? _formatDownloadBytes(p.received)
                      : '${_formatDownloadBytes(p.received)} / '
                            '${_formatDownloadBytes(p.total!)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: cancel.cancel,
              child: Text(L10n.t('暂停', 'Pause')),
            ),
          ],
        ),
      ).then((_) {
        dialogVisible = false;
      }),
    );

    DownloadResult? result;
    String? saved;
    Object? failure;
    var cancelled = false;
    try {
      foreground = await DownloadForeground.instance.start(cancel);
      if (!foreground.backgroundActive &&
          foreground.unavailableReason != null &&
          mounted) {
        showToast(
          context,
          L10n.t(
            '后台下载不可用，本次保持前台下载',
            'Background download unavailable. Keep the app open.',
          ),
        );
      }
      result = await downloads.download(
        remotePath,
        cancel: cancel,
        onProgress: (p) {
          progress.value = p;
          foreground?.progress(p);
        },
      );
      if (cancel.cancelled) throw const DownloadCancelled();
      saved = await _filesChannel.invokeMethod<String>('saveFileFromPath', {
        'path': result.file.path,
        'name': name,
      });
      // 保存失败时也保留完整私有文件，下次继续入口可直接重试保存。
      try {
        await downloads.discard(remotePath);
      } on FileSystemException {
        // 私有缓存后续按保留期限清理。
      }
    } on DownloadCancelled {
      cancelled = true;
    } catch (e) {
      failure = e;
    } finally {
      await foreground?.close();
      // 先把进度弹窗关掉，再弹结果——否则结果弹窗会盖在"下载中"上面
      if (mounted && dialogVisible) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!mounted) return;
    if (cancelled) {
      showToast(
        context,
        foreground?.pauseReason == 'system-time-limit'
            ? L10n.t(
                '系统后台下载时限已到，进度已保留',
                'The system background limit was reached. Progress is saved.',
              )
            : L10n.t('已暂停，可从下载入口继续', 'Paused. Resume from Downloads'),
      );
      return;
    }
    if (failure != null) {
      await _showDownloadFailure(failure, remotePath: remotePath);
      return;
    }
    final mime = (result?.contentType ?? 'application/octet-stream')
        .split(';')
        .first
        .trim();
    await _showDownloadSaved(saved ?? name, mime: mime, uri: saved);
  }

  /// 下载失败：先给「结论 + 下一步」，原始异常折叠在「技术详情」里。
  ///
  /// 真机反馈：之前直接把异常 toString 丢进 Toast，用户满屏 status/code 看不懂。
  Future<void> _showDownloadFailure(
    Object error, {
    required String remotePath,
  }) async {
    final f = describeDownloadError(error);
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('下载失败', 'Download failed')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(f.summary),
              if (f.hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  f.hint!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: DshColors.ink2(ctx),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  L10n.t('技术详情', 'Technical details'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                children: [
                  SelectableText(
                    '${L10n.t('文件', 'File')}: $remotePath\n${f.detail}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: '$remotePath\n${f.detail}'),
              );
              showToast(ctx, L10n.t('详情已复制', 'Details copied'));
            },
            child: Text(L10n.t('复制详情', 'Copy details')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L10n.t('继续下载', 'Resume download')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.t('关闭', 'Close')),
          ),
        ],
      ),
    );
    if (retry == true && mounted) await _downloadFile(resumePath: remotePath);
  }

  /// 下载完成：告诉用户存到哪了，并给「查看 / 关闭」两个出口。
  ///
  /// 之前用 SnackBar + 单个「打开」按钮，用户反馈"不点它就关不掉"。
  Future<void> _showDownloadSaved(
    String saved, {
    required String mime,
    String? uri,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('下载完成', 'Download complete')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${L10n.t('已保存到手机：', 'Saved on phone: ')}$saved'),
            const SizedBox(height: 8),
            Text(
              L10n.t(
                '可在手机「文件」App 的 下载/DSH-Remote 目录里找到。',
                'Find it in Files › Downloads › DSH-Remote on your phone.',
              ),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: DshColors.ink2(ctx),
              ),
            ),
          ],
        ),
        actions: [
          if (uri != null && uri.startsWith('content://'))
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _filesChannel.invokeMethod<String>('openFile', {
                  'uri': uri,
                  'mime': mime,
                });
              },
              child: Text(L10n.t('查看', 'Open')),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.t('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  static String _formatDownloadBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// v3.0.0 图像链路：选图（原始解析，不压缩）——上限按内核 imageLimits（PC 端同源数字）。
  Future<void> _pickImages({required bool fromCamera}) async {
    if (_pickingImages) return;
    _pickingImages = true;
    try {
      final limits = widget.store.catalog?.imageLimits ?? const {};
      final maxCount = ((limits['maxImagesPerMessage'] as num?)?.toInt() ?? 20)
          .clamp(1, 20)
          .toInt();
      final picker = ImagePicker();
      final picked = fromCamera
          ? [await picker.pickImage(source: ImageSource.camera)]
          : await picker.pickMultiImage(limit: maxCount);
      final files = picked.whereType<XFile>().toList();
      if (files.isEmpty || !mounted) return;
      final room = maxCount - _pendingImages.length;
      if (room <= 0) {
        showToast(
          context,
          L10n.t('已达单条消息的图片数量上限', 'Reached the image count limit per message'),
        );
        return;
      }
      if (files.length > room) {
        showToast(
          context,
          L10n.t('最多还能添加 $room 张图片', 'You can add up to $room more image(s)'),
        );
      }
      setState(() => _pendingImages.addAll(files.take(room)));
      _requestScrollFollow();
    } catch (e) {
      if (mounted) {
        showToast(context, '${L10n.t('无法打开', 'Could not open: ')}$e');
      }
    } finally {
      _pickingImages = false;
    }
  }

  /// v3.0.0 图像链路：待发送图片缩略图 rail（composer 上方，可移除；PC 端 AttachmentRail 同理念）。
  Widget _buildImageRail() {
    if (_pendingImages.isEmpty) return const SizedBox.shrink();
    final line = DshColors.line(context);
    final ink3 = DshColors.ink3(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: SizedBox(
        height: 76,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < _pendingImages.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(_pendingImages[i].path),
                        width: 76,
                        height: 76,
                        fit: BoxFit.cover,
                        // v3.1.6（app-audit ①4）：按显示尺寸解码（2x 供 HiDPI）——
                        // 不给 cacheWidth 时 Flutter 按**原始分辨率**解码，一次选 10-20 张
                        // 12MP 原图（≈48MB/张）直接顶爆内存（低端机闪退）。
                        cacheWidth: 160,
                        errorBuilder: (_, _, _) => Container(
                          width: 76,
                          height: 76,
                          color: line,
                          child: const Icon(
                            Icons.image_outlined,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: InkWell(
                        onTap: () => setState(() => _pendingImages.removeAt(i)),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(
                            Icons.close,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            IconButton(
              onPressed: _pickingImages
                  ? null
                  : () => _pickImages(fromCamera: false),
              icon: Icon(
                Icons.add_photo_alternate_outlined,
                size: 22,
                color: ink3,
              ),
              tooltip: L10n.t('继续添加', 'Add more'),
            ),
          ],
        ),
      ),
    );
  }

  /// issue #25：命令菜单里的一行。副标题优先显示 `input.hint`（内核声明的参数用法），
  /// 没有 hint 时回退 `description`。
  Widget _commandTile(BuildContext ctx, Map<String, dynamic> c) {
    final subtitle = commandMenuSubtitle(c);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.tag, size: 18),
      title: Text('/${c['name']}', style: const TextStyle(fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: DshColors.ink3(ctx)),
            ),
      onTap: () => Navigator.of(ctx).pop(c),
    );
  }

  Future<void> _showCommandMenu() async {
    // v2.9.0 review(HIGH)：页级动作绑定本页会话
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    List<Map<String, dynamic>> cmds;
    var unavailable = false;
    try {
      (cmds, unavailable) = await _api.commands(id);
    } catch (e) {
      if (!mounted) return;
      showToast(
        context,
        '${L10n.t('命令列表加载失败：', 'Failed to load commands: ')}$e',
      );
      return;
    }
    if (!mounted) return;
    // issue #25：顺手把本次取回的目录喂给提交路径的判定缓存（提交 `/xxx` 时不必再多一次往返）
    _commandCatalog = unavailable ? <Map<String, dynamic>>[] : cmds;
    _commandCatalogSessionId = id;
    // v2.9.0 review(LOW#13)：区分"命令服务不可用"与"会话无命令"
    if (unavailable) {
      showToast(
        context,
        L10n.t('当前 DSH 未提供命令服务', 'Command service is unavailable in this DSH'),
      );
      return;
    }
    if (cmds.isEmpty) {
      showToast(
        context,
        L10n.t('当前会话没有可用命令', 'No commands available for this session'),
      );
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  const Icon(Icons.code, size: 15, color: Color(0xFF426EFE)),
                  const SizedBox(width: 6),
                  Text(
                    L10n.t('命令', 'Commands'),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            // v2.8.0 review(P3-6)：过滤无名命令，避免填入 '/null'
            for (final c in cmds.where(
              (c) => c['name'] is String && (c['name'] as String).isNotEmpty,
            ))
              _commandTile(ctx, c),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final name = picked['name'] as String; // 上面已过滤：name 为非空 String
    // issue #25：**裸命令**（无 input，如 /compact）在 PC 端菜单里是"点选即执行"——移动端照搬：
    // 只填输入框会让用户以为命令已经跑了（issue #25 的第二条复现路径）。
    if (picked['input'] is! Map) {
      await _executeCommandLine(id, '/$name');
      return;
    }
    // 需要参数的命令：对齐 PC 端 leadingInput——命令名填入输入框，用户补参数后发送
    _inputCtrl.text = '/$name ';
    _inputCtrl.selection = TextSelection.collapsed(
      offset: _inputCtrl.text.length,
    );
    _onDraftChanged();
    // issue #25 真机反馈（2026-10-07）：6 条命令里只有 /compact、/export 是裸命令（点选即执行），
    // 其余 4 条带参数，点选后仅"填字"。真机实测用户会以为"点了没反应 / 命令不能用"——
    // 这里补一条明确提示：需要补参数后点发送才执行，并带上内核给的参数用法。
    final usage = commandMenuSubtitle(picked);
    showToast(
      context,
      usage == null
          ? L10n.t(
              '已填入输入框：补参数后点发送才会执行',
              'Inserted — add arguments, then send to run',
            )
          : L10n.t(
              '已填入输入框：补参数后点发送才会执行（用法 $usage）',
              'Inserted — add arguments, then send to run (usage: $usage)',
            ),
    );
  }

  /// 上下文占用比例（已用 tokens / 模型上下文窗口），数据缺失时为 null。
  /// 上下文窗口来自服务端 usage 接口（request/context 事件捕获，与 PC 端圆环同源）。
  /// 口径与 PC 端一致：最近一次请求的 prompt 侧 token（pressureTokens），
  /// 而非历史累计总量（旧版服务端无该字段时回退累计和）。
  double? get _contextRatio {
    if (_usage.isEmpty) return null;
    final window = (_usage['contextWindow'] as num?)?.toInt();
    if (window == null || window <= 0) return null;
    final used =
        (_usage['pressureTokens'] as num?)?.toDouble() ??
        ((_usage['inputTokens'] as num?)?.toDouble() ?? 0) +
            ((_usage['cacheReadTokens'] as num?)?.toDouble() ?? 0) +
            ((_usage['cacheWriteTokens'] as num?)?.toDouble() ?? 0);
    if (used <= 0) return null;
    return (used / window).clamp(0.0, 1.0);
  }

  /// v3.0.0 图像链路：事件摘要/无损详情里的图片元数据 [{attachmentId, mediaType, width?, height?}]。
  /// 只保留 attachment 引用，绝不把 raw/base64 image data 带入 Flutter 卡片。
  List<Map<String, dynamic>> _imagesOf(Map<String, dynamic>? d) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    void visit(Object? value, [bool imageContext = false]) {
      if (value is List) {
        for (final entry in value) {
          visit(entry, imageContext);
        }
        return;
      }
      if (value is! Map) return;
      final attachment = value['type'] == 'image' && value['attachment'] is Map
          ? value['attachment']
          : value;
      final attachmentId = attachment is Map
          ? attachment['attachmentId']?.toString()
          : null;
      final mediaType = attachment is Map
          ? attachment['mediaType']?.toString() ?? ''
          : '';
      final isImage =
          imageContext ||
          value['type'] == 'image' ||
          mediaType.startsWith('image/');
      if (isImage &&
          attachmentId != null &&
          attachmentId.isNotEmpty &&
          seen.add(attachmentId)) {
        out.add({
          'attachmentId': attachmentId,
          'mediaType': attachment['mediaType']?.toString() ?? 'image/jpeg',
          if (attachment['width'] is num) 'width': attachment['width'],
          if (attachment['height'] is num) 'height': attachment['height'],
          if (attachment['name'] is String &&
              (attachment['name'] as String).isNotEmpty)
            'name': attachment['name'],
          // issue #69：服务端当前契约不下发字节数；若字段确实存在则原样透传
          // 数字型 size/bytes（展示层只在字段存在时显示，缺失不猜）。
          if (attachment['size'] is num) 'size': attachment['size'],
          if (attachment['bytes'] is num) 'bytes': attachment['bytes'],
        });
      }
      visit(value['images'], true);
      visit(value['content'], imageContext);
      visit(value['message'], imageContext);
    }

    visit(d?['images'], true);
    visit(d?['message']);
    return out;
  }

  List<Map<String, dynamic>> _filesOf(Map<String, dynamic>? d) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    void visit(Object? value) {
      if (value is List) {
        for (final entry in value) {
          visit(entry);
        }
        return;
      }
      if (value is! Map) return;
      final attachment = value['attachment'] is Map
          ? value['attachment'] as Map
          : value;
      final id = (attachment['attachmentId'] ?? attachment['id'])?.toString();
      final mediaType =
          attachment['mediaType']?.toString() ??
          attachment['mimeType']?.toString() ??
          '';
      final isImage =
          value['type'] == 'image' || mediaType.startsWith('image/');
      final path = (attachment['path'] ?? attachment['filePath'])?.toString();
      final name =
          attachment['name']?.toString() ?? path?.split(RegExp(r'[/\\]')).last;
      if (!isImage &&
          (id != null && id.isNotEmpty || path != null && path.isNotEmpty) &&
          seen.add(id ?? path!)) {
        out.add({
          if (id != null && id.isNotEmpty) 'attachmentId': id,
          if (path != null && path.isNotEmpty) 'path': path,
          if (name != null && name.isNotEmpty) 'name': name,
          if (mediaType.isNotEmpty) 'mediaType': mediaType,
          if (attachment['size'] is num) 'size': attachment['size'],
        });
      }
      visit(value['files']);
      visit(value['file']);
      visit(value['attachments']);
      visit(value['content']);
      visit(value['result']);
      visit(value['message']);
    }

    visit(d);
    return out;
  }

  bool _sameTimelineItem(_MsgItem a, _MsgItem b) {
    if (a.kind != b.kind) return false;
    if (a.kind == _MsgKind.tool) {
      return a.toolCallId == b.toolCallId;
    }
    return a.seq == b.seq && a.eventType == b.eventType;
  }

  void _replaceTimelineItem(_MsgItem old, _MsgItem next) {
    for (final list in <List<_MsgItem>>[_items, _olderItems, _histItems]) {
      final i = list.indexWhere((item) => _sameTimelineItem(item, old));
      if (i >= 0) list[i] = next;
    }
  }

  _MsgItem? _currentTimelineItem(_MsgItem original) {
    for (final list in <List<_MsgItem>>[_items, _olderItems, _histItems]) {
      final i = list.indexWhere((item) => _sameTimelineItem(item, original));
      if (i >= 0) return list[i];
    }
    return null;
  }

  /// 原始事件预览缓存（v3.1.6，app-audit ①3）：键含 rawData 的对象身份，避免每次 rebuild
  /// 都重新 `JsonEncoder.withIndent` 编码 8 MiB 级原始事件；值已由 [timelineDebugPreview]
  /// 截断到 4000 字符，条目量级可控（卡数 × 4KB）。
  final Map<String, String> _debugPreviewCache = {};

  String _debugPreviewOf(_MsgItem item) {
    final key =
        '${item.kind}:${item.eventType}:${item.toolCallId ?? item.seq ?? item.text}:'
        '${identityHashCode(item.rawData)}';
    return _debugPreviewCache.putIfAbsent(
      key,
      () => timelineDebugPreview(item.rawData),
    );
  }

  String _failureKey(_MsgItem item) => item.kind == _MsgKind.tool
      ? 'tool:${item.toolCallId ?? item.seq}'
      : 'event:${item.eventType}:${item.seq ?? item.text}';

  void _autoLoadFailureDetail(_MsgItem item) {
    // 只有服务端声明了详情指针（detail.available）的类型才自动拉取：allow-list 之外的
    // 协议元数据/未命名事件没有指针，自动拉只会打出 404 与错误码（debug 模式尤甚）。
    // "自动只拉一次"由卡片自身的 requested 标志承担（见 _ToolActivityCard/_TimelineEventCard）。
    if (!item.detailAvailable) return;
    _loadEventDetail(item);
  }

  Future<void> _loadEventDetail(_MsgItem item) async {
    final id = _mySessionId ?? widget.store.sessionId;
    final detailSeq = item.detailSeq ?? item.seq;
    if (id == null ||
        detailSeq == null ||
        item.detailLoading ||
        !_api.timelineCapabilities.detail) {
      return;
    }
    // 去重登记下沉到唯一入口：手动展开此前不登记，卡片重锚重建后会对同一 (卡, detailSeq)
    // 再发一次 HTTP；失败时移除登记，保证「重试」按钮仍能重新请求。
    final requestKey = '${_failureKey(item)}:$detailSeq';
    if (!_failureDetailRequests.add(requestKey)) return;
    final generation = _loadGeneration;
    final loading = item.kind == _MsgKind.tool
        ? item.copyTool(detailLoading: true, clearDetailError: true)
        : item.kind == _MsgKind.assistant
        ? item.copyAssistant(detailLoading: true, clearDetailError: true)
        : item.copyEvent(detailLoading: true, clearDetailError: true);
    if (mounted) setState(() => _replaceTimelineItem(item, loading));
    try {
      final detail = await _api.eventDetail(id, detailSeq);
      // v3.1.6（app-audit ①2）：**成功路径也必须释放登记**——此前只在 catch 里移除，
      // 于是"成功加载过一次"的 (卡, detailSeq) 键被永久占用：调试模式的「重新加载原始事件」
      // 点了没有任何反应（不请求、不转圈、不提示），`/compact` 触发的 `_load(reset:true)`
      // 重建条目后普通模式的「加载完整正文」同样失效。这里只用于**在途去重**。
      _failureDetailRequests.remove(requestKey);
      final full = detail.event;
      final data = full['data'] is Map
          ? Map<String, dynamic>.from(full['data'] as Map)
          : <String, dynamic>{};
      String textOf(Object? value) {
        if (value is String) return value;
        if (value is List) {
          return value.map(textOf).where((text) => text.isNotEmpty).join();
        }
        if (value is Map) {
          if (value['text'] is String) return value['text'] as String;
          return textOf(value['content']);
        }
        return '';
      }

      if (!mounted || generation != _loadGeneration) return;
      final current = _currentTimelineItem(item);
      if (current == null) return;
      if (current.kind == _MsgKind.tool && current.detailSeq != detailSeq) {
        // A newer result superseded this request; never let an older call
        // response overwrite the result detail. Only clear its spinner.
        setState(
          () => _replaceTimelineItem(
            item,
            current.copyTool(detailLoading: false),
          ),
        );
        return;
      }
      if (current.kind == _MsgKind.tool) {
        // 详情是**原始事件**（服务端上限 8 MiB）——渲染前统一截断，避免超长参数/结果进 markdown。
        final rawArgs = data['arguments'] is String
            ? data['arguments'] as String
            : (data['arguments'] == null
                  ? current.toolArguments
                  : JsonEncoder.withIndent('  ').convert(data['arguments']));
        final args = clampTimelineDetailText(rawArgs);
        final directResult = textOf(data['text']);
        final nestedResult = textOf(data['result']).isNotEmpty
            ? textOf(data['result'])
            : textOf(data['message']);
        final result = clampTimelineDetailText(
          directResult.isNotEmpty
              ? directResult
              : (nestedResult.isNotEmpty ? nestedResult : current.toolResult),
        );
        setState(
          () => _replaceTimelineItem(
            item,
            current.copyTool(
              arguments: args,
              result: result,
              error: data['isError'] == true || current.toolError,
              images: _imagesOf(data).isNotEmpty
                  ? _imagesOf(data)
                  : current.images,
              rawData: full,
              files: _filesOf(data).isNotEmpty ? _filesOf(data) : current.files,
              detailAvailable: true,
              detailLoading: false,
              detailDegraded: detail.degraded,
              detailMode: detail.detailMode,
              clearDetailError: true,
            ),
          ),
        );
      } else if (current.kind == _MsgKind.assistant) {
        // 正文口径（issue #1 需求变更）：只认服务端给出的规范化 text（与摘要同一
        // blocksToText 口径，已跳过 reasoning/内部块）。**不得**递归拼接 message.content
        // ——那会把 reasoning 并进正文，使思维链在折叠块之外重复出现。
        final canonical = timelineDetailText(data);
        final fullText = clampTimelineDetailText(canonical ?? '');
        setState(
          () => _replaceTimelineItem(
            item,
            current.copyAssistant(
              text: fullText.isNotEmpty ? fullText : current.text,
              rawData: full,
              files: _filesOf(data).isNotEmpty ? _filesOf(data) : current.files,
              detailAvailable: true,
              detailLoading: false,
              detailDegraded: detail.degraded,
              detailMode: detail.detailMode,
              clearDetailError: true,
              detailTextChars: fullText.isNotEmpty
                  ? fullText.length
                  : current.detailTextChars,
            ),
          ),
        );
      } else {
        setState(
          () => _replaceTimelineItem(
            item,
            current.copyEvent(
              rawData: full,
              detailLoading: false,
              detailDegraded: detail.degraded,
              detailMode: detail.detailMode,
              clearDetailError: true,
            ),
          ),
        );
      }
      // issue #114：异步详情回填 = 同一条目内部的高度变化，跟随态下收口到 owner。
      _requestScrollFollow();
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      _failureDetailRequests.remove(requestKey); // 允许用户点「重试」重新请求
      final current = _currentTimelineItem(item);
      if (current == null ||
          ((current.kind == _MsgKind.tool ||
                  current.kind == _MsgKind.assistant) &&
              current.detailSeq != detailSeq)) {
        return;
      }
      final code = e is ApiException
          ? (e.code ?? 'event-detail-unavailable')
          : 'event-detail-unavailable';
      final fallback = current.kind == _MsgKind.tool
          ? current.copyTool(detailErrorCode: code, detailLoading: false)
          : current.kind == _MsgKind.assistant
          ? current.copyAssistant(detailErrorCode: code, detailLoading: false)
          : current.copyEvent(detailErrorCode: code, detailLoading: false);
      setState(() => _replaceTimelineItem(item, fallback));
      _requestScrollFollow();
    }
  }

  // ── issue #52（ADR 0027 §2）：轮次过程折叠渲染 ──────────────────────
  //
  // 事件序：`turn/start → 提示词 user/message → 过程（思考/工具）→ 回答 → turn/end`。
  // 过程块因此锚在**过程行实际出现的位置**（提示词之后），而不是 turn/start 分隔条：
  // 否则折叠摘要会跑到用户提问上方。轮内有插话时，过程行按插话切成多段、逐段折叠。
  //
  // 渲染计划（hosts/索引/分批可见集）只在新事件、折叠状态或设置变化时重建，
  // 每帧只做查表，避免逐帧线性扫描与逐 delta 全量重建。

  TurnFoldPolicy get _foldPolicy => TurnFoldPolicy(
        mode: widget.store.stepDisplayMode,
        timing: widget.store.turnFoldTiming,
      );

  _ProcessPlan? _livePlanCache;
  _ProcessPlan? _histPlanCache;
  int _processEpoch = 0; // 折叠状态/分批/设置变化（无需重新折叠事件）

  void _invalidateProcessPlan() {
    _processEpoch++;
  }

  List<TurnProcess> _ensureProcessTurns() {
    if (_processBuiltVersion == _processVersion) return _processTurns;
    _processBuiltVersion = _processVersion;
    _processTurns = _turnProcess.build();
    _processTurnMap = {for (final turn in _processTurns) turn.turn: turn};
    return _processTurns;
  }

  Map<int, TurnProcess> _ensureProcessTurnMap() {
    _ensureProcessTurns();
    return _processTurnMap;
  }

  _ProcessPlan _planFor({required bool history}) {
    final cached = history ? _histPlanCache : _livePlanCache;
    // 每份计划各自记录折叠版本：live 与历史分段会各自前进，共享一个版本会让
    // 先构建的那份误判为新鲜（分段历史第二页起的 latent 过期）。
    if (cached != null &&
        cached.processVersion == _processVersion &&
        cached.epoch == _processEpoch) {
      return cached;
    }
    final items = history ? _histItems : <_MsgItem>[..._items, ..._olderItems];
    final plan = _buildProcessPlan(items, historyView: history);
    if (history) {
      _histPlanCache = plan;
    } else {
      _livePlanCache = plan;
    }
    return plan;
  }

  /// 按 callId 从**当前列表**取工具条目（计划只存 key，不持有对象）。
  ///
  /// 详情加载/失败回退/反馈 toggle 都是**原地替换**条目对象，不新增事件版本；
  /// 计划若缓存旧对象，过程块里的工具卡就不会刷新。渲染时按 key 取当前对象，
  /// 从根上避免这类过期缓存。
  _MsgItem? _currentToolItem(String? callId, {required bool historyView}) {
    if (callId == null) return null;
    final lists = historyView
        ? <List<_MsgItem>>[_histItems]
        : <List<_MsgItem>>[_items, _olderItems];
    for (final list in lists) {
      for (final item in list) {
        if (item.kind == _MsgKind.tool && item.toolCallId == callId) {
          return item;
        }
      }
    }
    return null;
  }

  /// 按 seq 从当前列表取该轮最后一条助手消息（页脚操作附着点，反馈高亮需实时）。
  _MsgItem? _currentAssistantItem(int? seq, {required bool historyView}) {
    if (seq == null) return null;
    final lists = historyView
        ? <List<_MsgItem>>[_histItems]
        : <List<_MsgItem>>[_items, _olderItems];
    for (final list in lists) {
      for (final item in list) {
        if (item.kind == _MsgKind.assistant && item.seq == seq) return item;
      }
    }
    return null;
  }

  /// 建立「宿主条目 → 过程块」计划与索引（每次结构变化重建一次）。
  _ProcessPlan _buildProcessPlan(
    List<_MsgItem> items, {
    required bool historyView,
  }) {
    LiveProcessCounters.processPlanBuilds++;
    final policy = _foldPolicy;
    final turns = _ensureProcessTurnMap();
    final humanUserSeqs = _turnProcess.humanUserSeqs;
    final itemsByTurn = <int, List<_MsgItem>>{};
    for (final item in items) {
      int? turn;
      if (item.kind == _MsgKind.divider) {
        final seq = item.seq;
        if (seq != null) {
          turn = _turnProcess.turnOfStartSeq(seq) ?? _turnProcess.turnOfEndSeq(seq);
        }
      } else if (item.kind == _MsgKind.tool) {
        final callId = item.toolCallId;
        if (callId != null) turn = _turnProcess.turnOfCall(callId);
      } else {
        turn = _turnProcess.turnOfSeq(item.seq);
      }
      if (turn == null || !turns.containsKey(turn)) continue;
      (itemsByTurn[turn] ??= <_MsgItem>[]).add(item);
    }

    final hosts = <int, List<_ProcessBlockPlan>>{};
    final renderedCallIds = <String>{};
    // issue #84：真正渲染可见的运行中工具（segment 展开 + 组展开 + 未被分批隐藏），
    // 仅用于活动条去重；renderedCallIds 仍表示「过程块承载」用于平铺卡抑制。
    final visibleToolCallIds = <String>{};
    final anchoredTurns = <int>{};
    // 页脚需要「该轮最后一条助手消息」：只存 seq（渲染时再从当前列表取对象，
    // 避免反馈/详情原地替换后仍拿着旧对象）。
    final assistantSeqByTurn = <int, int>{};
    final hiddenByTurn = <int, int>{};
    // issue #70：provisional 只注入「当前流式轮次的最后一段」，且该段必须已有宿主
    // （无持久过程行 → 无锚点 → 不凭空造过程块，活动条保留现状思考）。
    // 计划里只存排序键，不存文本（文本由行级 ValueNotifier 读取，避免陈旧缓存）。
    final live = historyView ? null : _liveReasoning.current;
    var provisionalRendered = false;
    var reasoningRowVisible = false;

    // 仅轮次开始边界（重试边界只取首个）参与锚定，避免同一轮重复渲染。
    final primaryStarts = <int, int>{};
    for (final entry in itemsByTurn.entries) {
      final turn = entry.key;
      final process = turns[turn]!;
      final start = _turnProcess.startSeqOfTurn(turn);
      if (start != null) primaryStarts[turn] = start;
      // 该轮最后一条助手消息（页脚操作附着点）。
      for (final item in entry.value) {
        if (item.kind != _MsgKind.assistant) continue;
        final seq = item.seq;
        if (seq == null || seq < process.startSeq) continue;
        final end = process.endSeq;
        if (end != null && seq > end) continue;
        final best = assistantSeqByTurn[turn];
        if (best == null || best < seq) assistantSeqByTurn[turn] = seq;
      }
    }

    for (final entry in itemsByTurn.entries) {
      final turn = entry.key;
      final process = turns[turn]!;
      final turnItems = entry.value;
      final start = primaryStarts[turn];
      if (start == null) continue; // 历史截断：没有 turn/start，不构造过程块
      anchoredTurns.add(turn);
      final segments = segmentsOf(process);
      final liveNow = !process.ended;
      // issue #108：运行中插话强制段展开（简洁档也一样）；异常结束同样强制。
      final forcedLive = liveNow && process.hasInterjection;
      final segmentExpandedByDefault = liveNow
          ? (policy.liveSegment == LiveSegmentMode.expanded || forcedLive)
          : (process.forceExpanded ||
              !turnAutoCollapsed(
                process,
                policy: policy,
                humanUserSeqs: humanUserSeqs,
              ));
      final limit = _processRowLimits[turn] ?? processBatchSize;
      final batchWindow = batchProcessRows(process.rows, limit);
      final visibleSeqSet = <int>{
        for (final row in batchWindow.visible) row.seq,
      };
      final hiddenTotal = batchWindow.hidden;
      for (var si = 0; si < segments.length; si++) {
        final segment = segments[si];
        // 宿主：该段第一条过程行所在的（或其后最近的）条目——过程块渲染在它之前。
        var lastRowSeq = segment.startSeq - 1;
        for (final row in segment.rows) {
          if (row.seq > lastRowSeq) lastRowSeq = row.seq;
        }
        _MsgItem? host;
        for (final item in turnItems) {
          final seq = item.seq;
          if (seq == null || seq < segment.startSeq) continue;
          if (item.kind == _MsgKind.user && seq <= lastRowSeq) continue;
          if (host == null || seq < (host.seq ?? 1 << 62)) host = item;
        }
        if (host == null || host.seq == null) continue;
        final key = '$turn:$si';
        final manual = _turnExpansions[key];
        final occupied = manual ?? segmentExpandedByDefault;
        final groupStyle = liveNow ? policy.liveGroups : policy.completedGroups;
        final flat = groupStyle == LiveGroupMode.flat ||
            groupStyle == CompletedGroupMode.flat;
        final grouping = occupied && !flat && policy.mode != WorkStepDisplayMode.expanded;
        final visibleRows = <int>{};
        if (occupied) {
          for (final row in segment.rows) {
            if (visibleSeqSet.contains(row.seq)) visibleRows.add(row.seq);
          }
        }
        List<bool>? groupExpandedFlags;
        if (grouping) {
          final defaultGroupExpanded = liveNow
              ? switch (policy.liveGroups) {
                  LiveGroupMode.expanded => true,
                  LiveGroupMode.hidden => true, // 简洁手动展开段后组默认展开
                  LiveGroupMode.collapsed || LiveGroupMode.flat => false,
                }
              : false; // 已完成详细：组抬头折叠
          groupExpandedFlags = [
            for (final group in segment.groups)
              _groupExpansions['$key:${group.step ?? 'x'}'] ??
                  defaultGroupExpanded,
          ];
        }
        if (occupied) {
          if (grouping) {
            for (var gi = 0; gi < segment.groups.length; gi++) {
              if (!groupExpandedFlags![gi]) continue;
              for (final row in segment.groups[gi].rows) {
                final callId = row.callId;
                if (!row.isTool || callId == null) continue;
                if (visibleRows.contains(row.seq)) visibleToolCallIds.add(callId);
              }
            }
          } else {
            for (final row in segment.rows) {
              final callId = row.callId;
              if (!row.isTool || callId == null) continue;
              if (visibleRows.contains(row.seq)) visibleToolCallIds.add(callId);
            }
          }
        }
        _ProvisionalSlot? slot;
        if (live != null &&
            turn == live.turn &&
            si == segments.length - 1 &&
            occupied) {
          var visible = true;
          if (grouping) {
            final gi = segment.groups.indexWhere((g) => g.step == live.step);
            if (gi >= 0 && !groupExpandedFlags![gi]) visible = false;
          }
          if (visible) {
            slot = _ProvisionalSlot(
              turn: live.turn,
              step: live.step,
              orderSeq: live.firstSeq,
            );
            provisionalRendered = true;
          }
        }
        if (live != null && turn == live.turn && occupied) {
          var hasReasoning = slot != null;
          if (!hasReasoning && grouping) {
            for (var gi = 0; gi < segment.groups.length; gi++) {
              if (!groupExpandedFlags![gi]) continue;
              for (final row in segment.groups[gi].rows) {
                if (row.isReasoning && visibleRows.contains(row.seq)) {
                  hasReasoning = true;
                  break;
                }
              }
              if (hasReasoning) break;
            }
          } else if (!hasReasoning) {
            for (final row in segment.rows) {
              if (row.isReasoning && visibleRows.contains(row.seq)) {
                hasReasoning = true;
                break;
              }
            }
          }
          if (hasReasoning) reasoningRowVisible = true;
        }
        final plan = _ProcessBlockPlan(
          process: process,
          segmentIndex: si,
          segment: segment,
          expanded: occupied,
          grouping: grouping,
          intervalKey: key,
          isLastSegmentOfTurn: si == segments.length - 1,
          hiddenTotalInTurn: 0, // 稍后回填
          visibleRowSeqs: visibleRows,
          turnVisibleRowSeqs: visibleSeqSet,
          liveProcessDetail: policy.liveProcessDetail,
          historyView: historyView,
          provisional: slot,
        );
        (hosts[host.seq!] ??= <_ProcessBlockPlan>[]).add(plan);
        // 无论该段当前是否展开、行是否被分批隐藏，只要段有宿主，
        // 它的工具行就由过程块承载——否则平铺工具卡会与折叠摘要同时出现。
        for (final row in segment.rows) {
          final callId = row.callId;
          if (row.isTool && callId != null) renderedCallIds.add(callId);
        }
      }
      if (hiddenTotal > 0) hiddenByTurn[turn] = hiddenTotal;
    }

    // 回填「该轮还有多少行未展示」，让最后一段承载「显示更多」。
    if (hiddenByTurn.isNotEmpty) {
      hosts.forEach((seq, plans) {
        for (var i = 0; i < plans.length; i++) {
          final plan = plans[i];
          final hidden = hiddenByTurn[plan.process.turn];
          if (hidden == null || !plan.isLastSegmentOfTurn) continue;
          plans[i] = plan.copyWith(hiddenTotalInTurn: hidden);
        }
      });
    }

    return _ProcessPlan(
      processVersion: _processVersion,
      epoch: _processEpoch,
      hostsBySeq: hosts,
      renderedCallIds: renderedCallIds,
      visibleToolCallIds: visibleToolCallIds,
      anchoredTurns: anchoredTurns,
      assistantSeqByTurn: assistantSeqByTurn,
      provisionalRendered: provisionalRendered,
      reasoningRowVisible: reasoningRowVisible,
    );
  }

  Widget _buildProcessBlockPlan(_ProcessBlockPlan plan) {
    final context = this.context;
    final policy = _foldPolicy;
    final process = plan.process;
    if (plan.segment.isEmpty) return const SizedBox.shrink();
    // issue #92：compaction 回放的旧 turn 只有工具行、没有轮次锚点/用户上下文；
    // 明确标注为历史工具结果 fallback（仍可随该过程块折叠），不伪装成当前过程行。
    final toolOnlyReplay = process.partial &&
        process.humanUserSeqs.isEmpty &&
        process.groups.isNotEmpty &&
        process.groups.every((g) => g.rows.every((row) => row.isTool));
    // 强制展开（未结束 / 有插话 / 异常结束）时摘要不可点——点了也收不起来，
    // 与其给一个无效点按，不如禁用并保留箭头缺失的静态态。
    final liveNow = !process.ended;
    // issue #108 v4：完全展开只自动展开当前运行轮的详情；完成/历史不自动。
    // 完全展开：当前运行轮自动展开详情；运行中插话/异常不自动展开。
    final autoDetail =
        policy.liveDetailsAutoExpanded && liveNow && !process.hasInterjection;
    // 强制展开（运行中/插话/异常）保持不可收起；简洁正常运行中的摘要仍可手动展开。
    final forcedLive = liveNow && process.hasInterjection;
    final forced =
        process.forceExpanded &&
        !(policy.mode == WorkStepDisplayMode.concise &&
            liveNow &&
            !forcedLive);
    final children = <Widget>[];
    if (toolOnlyReplay) {
      children.add(Padding(
        key: Key('historical-tool-results-${process.turn}'),
        padding: const EdgeInsets.only(bottom: 4, left: 2),
        child: Text(
          L10n.t(
            '历史工具结果（无过程上下文）',
            'Historical tool results (no process context)',
          ),
          style: TextStyle(fontSize: 10.5, color: DshColors.ink3(context)),
        ),
      ));
    }
    // issue #61：摘要行只作折叠态的「展开入口」；展开后组抬头/过程行已经表达了同一信息，
    // 再挂整轮摘要会造成层级重复（alpha.7 真机截图问题 1）。
    if (!plan.expanded) {
      // issue #74：整轮/整段折叠态聚合该段所有过程行（含分批隐藏行）的图片，
      // 点 chip 直接开图库——图片是结果，不应要求先展开或点「显示更多」才可达。
      final summaryImages = _imagesForProcessRows(
        plan.segment.rows,
        historyView: plan.historyView,
      );
      final summaryFailures = _failedToolCountForRows(
        plan.segment.rows,
        historyView: plan.historyView,
      );
      children.add(
        _ProcessSummaryRow(
          text: plan.segment.summary,
          expanded: false,
          failureCount: summaryFailures,
          imageCount: summaryImages.length,
          onOpenImages: summaryImages.isEmpty
              ? null
              : () => _openImagesGallery(summaryImages),
          onTap: forced
              ? null
              : () {
                  setState(() {
                    _turnExpansions[plan.intervalKey] = true;
                    _invalidateProcessPlan();
                  });
                  _onContentLayoutChanged();
                },
        ),
      );
    } else {
      final groupList = plan.segment.groups;
      final slot = plan.provisional;
      if (plan.grouping) {
        // provisional 若属于某个已有组，按 firstSeq 插在该组有序行之间（不重排已成行）；
        // 若该 step 还没有任何持久行（新组）→ 不合成组抬头，直接追加到块末尾（ADR #70 裁决 D2）。
        final slotGroupIndex = slot == null
            ? -1
            : groupList.indexWhere((group) => group.step == slot.step);
        var slotPlaced = false;
        var renderedGroups = 0;
        for (var gi = 0; gi < groupList.length; gi++) {
          final group = groupList[gi];
          // issue #75：没有任何可见行（分批把整组行挡在窗口外等）的组不渲染抬头，
          // 避免「0 次工具调用」幽灵行；用户可通过块末尾的「显示更多」把行放出来。
          final hasVisibleRow = group.rows.any(
            (row) => plan.visibleRowSeqs.contains(row.seq),
          );
          if (!hasVisibleRow) continue;
          final groupKey = '${plan.intervalKey}:${group.step ?? 'x'}';
          final manual = _groupExpansions[groupKey];
          // issue #108 v4：运行中简洁/详细组默认展开、标准折叠；已完成统一折叠。
          final defaultGroupExpanded = liveNow
              ? switch (policy.liveGroups) {
                  LiveGroupMode.expanded => true,
                  LiveGroupMode.hidden => true, // 简洁手动展开段后一次见内容
                  LiveGroupMode.collapsed || LiveGroupMode.flat => false,
                }
              : false;
          final groupExpanded = manual ?? defaultGroupExpanded;
          // issue #61（note 1791）：抬头只信真实运行态——组内还有未 settled 的工具行，
          // 且轮次尚未结束。此前「最后一段最后一组强制 running」的兜底会让已完成的
          // 工具一直挂着「正在调用工具…」，直到整轮结束（alpha.7 真机截图问题 4）。
          final groupRunning = group.running && !process.ended;
          // issue #76：组间 8–12dp（设计取 8）；首个组前不加。
          if (renderedGroups > 0) children.add(const SizedBox(height: 8));
          renderedGroups++;
          final reasoningOnly = !group.rows.any((row) => row.isTool);
          final groupFailures = _failedToolCountForRows(
            group.rows,
            historyView: plan.historyView,
          );
          // issue #74：组折叠态聚合该组全部工具结果图片（含被分批隐藏的行），
          // 展开后由各工具卡/内容区呈现，不重复挂 chip。
          final groupImages = groupExpanded
              ? const <Map<String, dynamic>>[]
              : _imagesForProcessRows(
                  group.rows,
                  historyView: plan.historyView,
                );
          children.add(_ProcessGroupHeader(
            text: processGroupHeader(
              group,
              running: groupRunning,
              showDetail: plan.liveProcessDetail,
            ),
            expanded: groupExpanded,
            running: groupRunning,
            failureCount: groupFailures,
            reasoningOnly: reasoningOnly,
            imageCount: groupImages.length,
            onOpenImages: groupImages.isEmpty
                ? null
                : () => _openImagesGallery(groupImages),
            onTap: () {
              setState(() {
                _groupExpansions[groupKey] = !groupExpanded;
                _invalidateProcessPlan();
              });
              _onContentLayoutChanged();
            },
          ));
          if (!groupExpanded) continue;
          final groupRowWidgets = <Widget>[];
          if (slot != null && gi == slotGroupIndex) {
            var inserted = false;
            for (final row in group.rows) {
              if (!inserted && row.seq > slot.orderSeq) {
                groupRowWidgets.add(_buildProvisionalReasoningRow(slot, autoExpanded: autoDetail));
                inserted = true;
              }
              if (!plan.visibleRowSeqs.contains(row.seq)) continue;
              groupRowWidgets.add(
                _buildProcessRow(
                  process,
                  row,
                  historyView: plan.historyView,
                  policy: policy,
                ),
              );
            }
            if (!inserted) {
              groupRowWidgets.add(_buildProvisionalReasoningRow(slot, autoExpanded: autoDetail));
            }
            slotPlaced = true;
          } else {
            for (final row in group.rows) {
              if (!plan.visibleRowSeqs.contains(row.seq)) continue;
              groupRowWidgets.add(
                _buildProcessRow(
                  process,
                  row,
                  historyView: plan.historyView,
                  policy: policy,
                ),
              );
            }
          }
          // issue #76：A 导轨——仅展开组出现：左 6dp 处 2dp line，内容左移 14dp，
          // 行间 1dp hairline（首末无）；组收起不留线/空白；不加组外框。
          children.add(_buildGroupRail(groupRowWidgets));
        }
        if (slot != null && !slotPlaced) {
          children.add(_buildProvisionalReasoningRow(slot, autoExpanded: autoDetail));
        }
      } else {
        var inserted = false;
        for (final row in plan.segment.rows) {
          if (slot != null && !inserted && row.seq > slot.orderSeq) {
            children.add(_buildProvisionalReasoningRow(slot, autoExpanded: autoDetail));
            inserted = true;
          }
          if (!plan.visibleRowSeqs.contains(row.seq)) continue;
          children.add(
            _buildProcessRow(
              process,
              row,
              historyView: plan.historyView,
              policy: policy,
            ),
          );
        }
        if (slot != null && !inserted) {
          children.add(_buildProvisionalReasoningRow(slot, autoExpanded: autoDetail));
        }
      }
      if (plan.hiddenTotalInTurn > 0) {
        final limit = _processRowLimits[process.turn] ?? processBatchSize;
        // issue #74：被分批隐藏的行里若有工具结果图片，直接在「显示更多」行给入口，
        // 不需要先点开 50 行。只聚合分批隐藏行，组折叠隐藏不算（那层由组抬头负责）。
        final hiddenImages = _imagesForProcessRows(
          plan.process.rows.where(
            (row) => !plan.turnVisibleRowSeqs.contains(row.seq),
          ),
          historyView: plan.historyView,
        );
        // issue #76：批次入口平铺（透明、无卡、无额外箭头），最小 48dp 命中；
        // 图片 chip 保留 #74 独立命中区（32 高），窄屏可自然换行到第二行。
        final ink2 = DshColors.ink2(context);
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 14, bottom: 6),
            child: InkWell(
              onTap: () {
                setState(() {
                  _processRowLimits[process.turn] = limit + processBatchSize;
                  _invalidateProcessPlan();
                });
                _onContentLayoutChanged();
              },
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        L10n.t(
                          '显示更多（还有 ${plan.hiddenTotalInTurn} 行）',
                          'Show more (${plan.hiddenTotalInTurn} rows left)',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: ink2,
                        ),
                      ),
                      if (hiddenImages.isNotEmpty)
                        _ImageCountChip(
                          count: hiddenImages.length,
                          onOpen: () => _openImagesGallery(hiddenImages),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
      // issue #61：展开后摘要行不在，收起的入口改为过程块末尾的行内控件
      // （非卡片底色、chevron 向上）。issue #108：非强制段手动收起优先于档位默认。
      if (!forced) {
        children.add(
          _CollapseProcessRow(
            key: ValueKey<String>('collapse-process:${plan.intervalKey}'),
            onTap: () {
              setState(() {
                _turnExpansions[plan.intervalKey] = false;
                _invalidateProcessPlan();
              });
              _onContentLayoutChanged();
            },
          ),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildProcessRow(
    TurnProcess process,
    ProcessRow row, {
    required bool historyView,
    required TurnFoldPolicy policy,
  }) {
    final autoDetail = policy.liveDetailsAutoExpanded &&
        !process.ended &&
        !process.hasInterjection;
    if (row.isReasoning) {
      final key = '${process.turn}:${row.seq}';
      final expanded = _reasoningRowExpansions[key] ?? autoDetail;
      return _ReasoningProcessRow(
        rowKey: ValueKey<String>('reasoning-row:${process.turn}:${row.seq}'),
        text: row.reasoning,
        chars: row.reasoningChars,
        // settledReasoningPreview 只作用于已结束思考行的折叠预览。
        preview: policy.settledReasoningPreview ? row.reasoningPreview() : '',
        expanded: expanded,
        onToggle: () {
          setState(() {
            _reasoningRowExpansions[key] = !expanded;
            _invalidateProcessPlan();
          });
          _onContentLayoutChanged();
        },
      );
    }
    final item = _currentToolItem(row.callId, historyView: historyView);
    final callId = row.callId;
    Widget child;
    if (item == null) {
      // 该工具卡不在当前列表（分页边界）：给一行只读摘要，不假装能展开详情。
      child = Padding(
        padding: const EdgeInsets.only(left: 24, bottom: 6),
        child: Text(
          '${_isPlaceholderToolName(row.toolName) ? L10n.t('工具调用', 'Tool call') : row.toolName} · '
          '${switch (row.status) {
            'success' => L10n.t('成功', 'Succeeded'),
            'failed' => L10n.t('失败', 'Failed'),
            _ => L10n.t('进行中', 'Running'),
          }}',
          style: TextStyle(fontSize: 12, color: DshColors.ink3(context)),
        ),
      );
    } else {
      // 单张工具卡在所有档位默认收起（note 1700 / 桌面 useDisclosure 默认关闭）。
      // issue #76：过程区内用平铺变体（无逐卡边框）。
      child = _buildToolCard(item, flat: true, autoExpanded: autoDetail);
    }
    if (callId == null) return child;
    final rowKey = _processToolRowKeys.putIfAbsent(
      callId,
      () => GlobalKey(debugLabel: 'process-tool-row:$callId'),
    );
    return KeyedSubtree(key: rowKey, child: child);
  }

  /// issue #70：过程块里的运行中思考行（provisional）。
  ///
  /// 行内容由 `_liveReasoningRevision` 行级通知驱动（读同一份 [LiveReasoning] 快照），
  /// 计划里只有排序键、没有文本 → delta 增长不会重建整轮计划；展开态由用户动作控制，
  /// 收起态恒定一行（最近非空行预览），delta 不改变行高（issue「不得明显跳动」）。
  Widget _buildProvisionalReasoningRow(_ProvisionalSlot slot, {bool autoExpanded = false}) {
    final stepKey = slot.step ?? 'null';
    final stateKey = '${slot.turn}:$stepKey';
    return ValueListenableBuilder<int>(
      valueListenable: _liveReasoningRevision,
      builder: (context, _, _) {
        LiveProcessCounters.provisionalRowBuilds++;
        final live = _liveReasoning.current;
        if (live == null || live.turn != slot.turn || live.step != slot.step) {
          // 落定/清理后计划会在同帧重建；退化为空占位，不渲染陈旧行。
          return const SizedBox.shrink();
        }
        final expanded = _provisionalExpansions[stateKey] ?? autoExpanded;
        return _ReasoningProcessRow(
          rowKey: ValueKey<String>(
            'provisional-reasoning-row:${slot.turn}:$stepKey',
          ),
          bodyKey: ValueKey<String>(
            'provisional-reasoning-body:${slot.turn}:$stepKey',
          ),
          text: live.text,
          chars: live.chars,
          preview: latestReasoningLinePreview(live.text),
          collapsedLabel: L10n.t('思考中…', 'Thinking…'),
          expandedLabel: L10n.t(
            '思考中…（${live.chars} 字）',
            'Thinking… (${live.chars} chars)',
          ),
          expanded: expanded,
          cappedBody: true,
          onToggle: () {
            setState(() {
              _provisionalExpansions[stateKey] = !expanded;
            });
            _onContentLayoutChanged();
          },
        );
      },
    );
  }

  /// issue #74：折叠层图片入口打开图库（不展开任何折叠层、不预加载原图）。
  void _openImagesGallery(List<Map<String, dynamic>> images) {
    if (images.isEmpty) return;
    final sessionId = _mySessionId ?? widget.store.sessionId ?? '';
    final cache = ImageGalleryCache(api: _api, sessionId: sessionId);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => ImageGalleryViewer(
        api: _api,
        sessionId: sessionId,
        images: images,
        cache: cache,
      ),
    );
  }

  /// issue #74：聚合若干过程行（含被 50 行分批隐藏的行）里工具结果的图片。
  ///
  /// 图片元数据在 `_MsgItem.images` 上已经存在；这里只按当前列表里的条目取，
  /// 不读 `visibleRowSeqs`——分批只影响渲染行，不应影响图片入口的计数与可达性。
  List<Map<String, dynamic>> _imagesForProcessRows(
    Iterable<ProcessRow> rows, {
    required bool historyView,
  }) {
    final sources = <List<Map<String, dynamic>>>[];
    for (final row in rows) {
      if (!row.isTool) continue;
      final item = _currentToolItem(row.callId, historyView: historyView);
      final images = item?.images ?? const <Map<String, dynamic>>[];
      if (images.isNotEmpty) sources.add(images);
    }
    return collectToolImages(sources);
  }

  /// issue #76：失败计数口径——只统计 `toolError` / `toolStatus == 'failed'` 的工具行，
  /// 不把工具失败等同于轮次异常，也不触发自动展开。
  int _failedToolCountForRows(
    Iterable<ProcessRow> rows, {
    required bool historyView,
  }) {
    var count = 0;
    for (final row in rows) {
      if (!row.isTool) continue;
      final item = _currentToolItem(row.callId, historyView: historyView);
      if (item == null) continue;
      if (item.toolError || item.toolStatus == 'failed') count++;
    }
    return count;
  }

  /// issue #76：A 导轨 —— 展开组内容左 6dp 处 2dp 低对比 line、内容左移 14dp、
  /// 相邻行 1dp hairline（首末无）；组收起时调用方不渲染，因此不留线/空白。
  Widget _buildGroupRail(List<Widget> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final line = DshColors.line(context);
    final separated = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) separated.add(Container(height: 1, color: line));
      separated.add(rows[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: line, width: 2)),
        ),
        padding: const EdgeInsets.only(left: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: separated,
        ),
      ),
    );
  }

  Widget _buildToolCard(_MsgItem item, {bool flat = false, bool autoExpanded = false}) {
    final toolKey = 'tool:${item.toolCallId ?? item.seq}';
    return _ToolActivityCard(
      key: ValueKey<String>(
        'tool:${item.toolCallId ?? item.seq ?? item.text}:${item.seq}',
      ),
      expandedOverride: _failureExpansionOverrides[toolKey],
      onExpandedOverride: (value) {
        setState(() => _failureExpansionOverrides[toolKey] = value);
        _onContentLayoutChanged();
      },
      onAutoLoadDetail: () => _autoLoadFailureDetail(item),
      flat: flat,
      // issue #74：折叠行图片入口——点 chip 直接开图库，不展开工具卡。
      onOpenImages: item.images.isEmpty
          ? null
          : () => _openImagesGallery(collectToolImages([item.images])),
      item: item,
      autoExpanded: autoExpanded,
      debug: widget.store.timelineDebug,
      sessionId: _mySessionId ?? '',
      api: _api,
      // issue #54：仅服务端声明支持的工具有专用卡；旧插件/未知工具一律通用卡。
      toolCardsEnabled: _api.toolCardsCapabilities.supports(item.toolName),
      // issue #68：PTC 子调用树能力位（旧插件 false → 计数/子行完全不渲染）。
      ptcEnabled: _api.toolCardsCapabilities.ptcAvailable,
      // issue #66：待答问询入口——构建时实时读取当前会话的 pending 问询（resolved 后自然为空）。
      pendingQuestionIds: _pendingQuestionIdsForCards,
      onOpenQuestion: _openPendingQuestion,
      // issue #67：折叠行路径可点进预览（服务端两字段同现时才渲染为链接）。
      onOpenFilePath: _openFilePathPreview,
      onLoadDetail: _api.timelineCapabilities.detail &&
              item.detailAvailable &&
              item.detailSeq != null
          ? () => _loadEventDetail(item)
          : null,
    );
  }

  /// issue #66：当前会话仍待回答的问题 id 集合（来源与 composer 问询卡同一条 pending 通道）。
  Set<String> get _pendingQuestionIdsForCards {
    final question = widget.store.questionForSession(_mySessionId);
    if (question == null) return const <String>{};
    return {
      for (final q in question.questions)
        if (q.id.trim().isNotEmpty) q.id,
    };
  }

  // ── issue #53（ADR 0027 §3 / docs/03-api.md §6.20–§6.23）：轮末产出物 ──────

  String? get _tailSessionId => _mySessionId ?? widget.store.sessionId;

  /// 合并 `/history` 的 `turnTails`（只增不减：历史页/实时页可能先后到达）。
  void _absorbTurnTails(Map<int, TurnTail> tails) {
    if (tails.isEmpty) return;
    tails.forEach((turn, tail) => _absorbTurnTail(turn, tail));
    _turnTailVersion++;
  }

  void _absorbTurnTail(int turn, TurnTail tail) {
    final previous = _turnTails[turn];
    final merged = TurnTail(
      changes: tail.changes || (previous?.changes ?? false),
      presented: tail.presented || (previous?.presented ?? false),
    );
    if (merged == previous) return;
    _turnTails[turn] = merged;
    _turnTailVersion++;
  }

  /// 同轮多次 `present`：按路径去重、说明取最后一次声明（§6.20）。
  void _absorbDeliverables(int turn, List<DeliverableFile> files) {
    _deliverablesByTurn[turn] = mergeDeliverableDeclarations(
      _deliverablesByTurn[turn] ?? const <DeliverableFile>[],
      files,
    );
    _absorbTurnTail(turn, const TurnTail(presented: true));
    _turnTailVersion++;
  }

  /// 行内链接解析器：只吃本轮**已到达**的记录（交付声明 + 已加载改动摘要）。
  TurnFileLinkResolver? _fileLinkResolverForTurn(int turn) {
    final cached = _linkResolvers[turn];
    if (cached != null && cached.version == _turnTailVersion) {
      return cached.resolver;
    }
    final sessionId = _tailSessionId;
    if (sessionId == null) return null;
    final presented = _deliverablesByTurn[turn] ?? const <DeliverableFile>[];
    final summary = _changedSummaryCache.lookup(turn);
    final changed = summary != null && summary.state == ChangesState.available
        ? summary.files
        : const <ChangedFile>[];
    if (presented.isEmpty && changed.isEmpty) return null;
    final resolver = TurnFileLinkResolver(
      sessionId: sessionId,
      presented: presented,
      changed: changed,
    );
    _linkResolvers[turn] = (version: _turnTailVersion, resolver: resolver);
    return resolver;
  }

  /// 懒加载本轮改动摘要：`tail.changes` 为真时才拉；失败静默重试 1 次后整卡不显示
  /// （调试模式留原因行）。`absent/unavailable` 由缓存短 TTL 承担负结果节流。
  void _scheduleChangedSummary(int turn) {
    final sessionId = _tailSessionId;
    if (sessionId == null) return;
    if (_changedSummaryRequested.contains(turn)) return;
    final retryAfter = _changedSummaryRetryAfter[turn];
    if (retryAfter != null && retryAfter.isAfter(DateTime.now())) return;
    _changedSummaryRequested.add(turn);
    unawaited(_loadChangedSummary(sessionId, turn));
  }

  /// 失败退避时长：只抑制短时间内的重复请求；负结果的正规节流由缓存 TTL 承担。
  static const Duration _changedSummaryFailureBackoff = Duration(seconds: 60);

  Future<void> _loadChangedSummary(String sessionId, int turn) async {
    final generation = _tailLoadGeneration;
    bool stillCurrent() =>
        mounted && generation == _tailLoadGeneration && sessionId == _tailSessionId;
    try {
      for (var attempt = 0; attempt < 2; attempt += 1) {
        try {
          final summary = await _api.changesSummary(sessionId, turn);
          // issue #60 recheck-11：reset/重同步后旧请求完成 → 丢弃，不回填缓存。
          if (!stillCurrent()) return;
          _changedSummaryCache.store(turn, summary);
          _changedSummaryErrors.remove(turn);
          _changedSummaryRetryAfter.remove(turn);
          setState(() => _turnTailVersion++);
          return;
        } catch (e) {
          if (!stillCurrent()) return;
          _changedSummaryErrors[turn] = e.toString();
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            if (!stillCurrent()) return;
          }
        }
      }
      if (!stillCurrent()) return;
      // 两次都失败：记录下来并退避；**不**阻止 TTL/重建后的恢复性重试。
      _changedSummaryRetryAfter[turn] =
          DateTime.now().add(_changedSummaryFailureBackoff);
      if (mounted) setState(() {});
    } finally {
      // in-flight 门闩必须总是释放：否则缓存 TTL 到期后卡片永久消失（issue #60 R06）。
      // 旧代际完成不得移除 reset 后新请求的门闩（recheck-11）。
      if (generation == _tailLoadGeneration) {
        _changedSummaryRequested.remove(turn);
      }
    }
  }

  /// 轮末两卡：改动卡（懒加载摘要）→ 交付卡。无文件不占位；能力位缺失不渲染。
  Widget _buildTurnTailSection(int turn, {required bool historyView}) {
    final caps = _api.turnTailCapabilities;
    if (!caps.available) return const SizedBox.shrink();
    final children = <Widget>[];

    if (caps.changed && (_turnTails[turn]?.changes ?? false)) {
      final summary = _changedSummaryCache.lookup(turn);
      if (summary == null) {
        _scheduleChangedSummary(turn);
      } else if (summary.state == ChangesState.available &&
          summary.files.isNotEmpty) {
        children.add(
          ChangedFilesCard(
            turn: turn,
            summary: summary,
            onOpenFile: (file) => _openTurnFile(
              TurnFileCoordinate(
                sessionId: _tailSessionId ?? '',
                kind: TurnFileKind.changed,
                seq: file.seq,
                index: file.index,
              ),
              display: file.display,
              name: file.name,
            ),
            onOpenDiff: (index) => _openTurnChangesDiff(
              turn,
              summary.files,
              index,
            ),
          ),
        );
      }
    }

    if (caps.presented) {
      final delivered = _deliverablesByTurn[turn] ?? const <DeliverableFile>[];
      if (delivered.isNotEmpty) {
        children.add(
          DeliveredFilesCard(
            turn: turn,
            files: delivered,
            onOpen: (file) => _openTurnFile(
              TurnFileCoordinate(
                sessionId: _tailSessionId ?? '',
                kind: TurnFileKind.presented,
                seq: file.seq,
                index: file.index,
              ),
              display: file.display,
              name: file.name,
            ),
            onActions: (file) => _openTurnFileActions(
              TurnFileCoordinate(
                sessionId: _tailSessionId ?? '',
                kind: TurnFileKind.presented,
                seq: file.seq,
                index: file.index,
              ),
              file.name,
            ),
          ),
        );
      }
    }

    if (children.isEmpty) {
      final error = _changedSummaryErrors[turn];
      if (widget.store.timelineDebug && error != null) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            L10n.t('改动摘要不可用：$error', 'Changed-files summary unavailable: $error'),
            style: TextStyle(fontSize: 11, color: DshColors.ink3(context)),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  void _openTurnFile(
    TurnFileCoordinate coordinate, {
    required String display,
    required String name,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TurnFilePreviewScreen(
          api: _api,
          coordinate: coordinate,
          display: display,
          name: name,
        ),
      ),
    );
  }

  /// issue #83：行内绝对路径的用户确认入口。
  ///
  /// 只有用户点“打开预览”才发起 `/m/api/files` 读取；取消/复制路径都不请求。
  Future<void> _confirmOpenPath(String rawPath) async {
    final path = rawPath.trim();
    if (!looksLikeInlineFilePath(path)) return;
    final name = inlinePathBasename(path);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final ink2 = DshColors.ink2(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  L10n.t('打开文件预览', 'Open file preview'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  path,
                  style: TextStyle(fontSize: 13, color: ink2, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Text(
                  L10n.t(
                    '将读取电脑上的文件，仅在你确认后读取。',
                    'This will read a file from the host only after you confirm.',
                  ),
                  style: TextStyle(fontSize: 12, color: ink2),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext, 'copy'),
                      child: Text(L10n.t('复制路径', 'Copy path')),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(L10n.t('取消', 'Cancel')),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, 'open'),
                      child: Text(L10n.t('打开预览', 'Open preview')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: path));
      if (!mounted) return;
      showToast(context, L10n.t('路径已复制', 'Path copied'));
      return;
    }
    if (action != 'open') return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TurnFilePreviewScreen.path(
          api: _api,
          path: path,
          display: path,
          name: name,
        ),
      ),
    );
  }

  void _openTurnFileActions(TurnFileCoordinate coordinate, String name) {
    unawaited(
      showTurnFileActions(
        context,
        api: _api,
        coordinate: coordinate,
        name: name,
      ),
    );
  }

  void _openTurnChangesDiff(int turn, List<ChangedFile> files, int index) {
    final sessionId = _tailSessionId;
    if (sessionId == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TurnChangesDiffScreen(
          api: _api,
          sessionId: sessionId,
          turn: turn,
          files: files,
          initialIndex: index,
        ),
      ),
    );
  }

  Widget _buildTurnFooter(int turn, {required bool historyView}) {
    final process = _ensureProcessTurnMap()[turn];
    if (process == null || !process.ended) return const SizedBox.shrink();
    final assistant = _currentAssistantItem(
      _planFor(history: historyView).assistantSeqByTurn[turn],
      historyView: historyView,
    );
    final ink3 = DshColors.ink3(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 14),
      child: Row(
        children: [
          // issue #76：320dp + 大字号下页脚文案不得把操作栏挤到溢出。
          Flexible(
            child: Text(
              turnFooterText(process),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: ink3),
            ),
          ),
          const Spacer(),
          // 无 hover → 页脚操作常显；助手气泡内不再重复（issue #52 §5）。
          if (assistant != null)
            _MessageActionsBar(
              item: assistant,
              padding: EdgeInsets.zero,
              onAction: (action) => _runMessageAction(assistant, action),
            ),
        ],
      ),
    );
  }

  Widget _buildItem(_MsgItem item, {bool historyView = false}) {
    switch (item.kind) {
      case _MsgKind.user:
        // v3.1.4（issue #12）：系统注入消息（内核 source.kind ≠ "user"）不当普通气泡铺屏，
        // 改为可折叠块——默认收起、点按展开，展开状态按 messageId 持久化（同思维链机制）。
        if (_isNoiseText(item.text)) return const SizedBox.shrink();
        if (item.injected && !widget.store.timelineDebug) {
          // issue #101：只显示会触发轮次的 agent-message/team-message；
          // subagent-settled 与系统 context 注入仍隐藏（debug 全可见）。
          if (!_isTriggerSourceKind(item.sourceKind)) {
            return const SizedBox.shrink();
          }
        }
        if (item.injected) {
          final ikey = item.messageId ?? 's${item.seq}';
          final expanded =
              widget.store.reasoningOverrideOf(
                _mySessionId ?? '',
                'inj:$ikey',
              ) ??
              false;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InjectedBubble(
                  key: Key('injected-${item.messageId ?? item.seq ?? 'x'}'),
                  text: item.text,
                  sourceKind: item.sourceKind,
                  expanded: expanded,
                  // setReasoningOverride 是 async（内部同步更新内存映射、再异步落盘）：
                  // 必须放在 setState 之外，否则 setState 的闭包返回 Future → debug/profile
                  // 构建下每次点按都会断言失败且展开状态不生效。
                  onToggle: (v) {
                    widget.store.setReasoningOverride(
                      _mySessionId ?? '',
                      'inj:$ikey',
                      v,
                    );
                    setState(() {});
                  },
                ),
                if (expanded &&
                    (item.images.isNotEmpty || item.files.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ImageGalleryGrid(
                          images: item.images,
                          sessionId: _mySessionId ?? '',
                          api: _api,
                        ),
                        if (item.files.isNotEmpty)
                          _FileResults(files: item.files),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }
        // v3.0.0(热修 06)：对齐 PC 端——图卡与文本为**两个独立气泡**（图在上、文在下）；
        // 服务端 blocksToText 为 image 块生成的「[图片]」占位行由图卡渲染替代（带图时不再展示）。
        final images = item.images;
        // v3.0.0(热修 07)：不再剥离 [图片]——占位改由服务端 user 摘要直接去除
        // （blocksToText imagePlaceholder:false），客户端保留用户原文，不误删手打内容。
        final text = item.text;
        Widget userBubble(Widget child) => Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: DshColors.line(context),
              borderRadius: BorderRadius.circular(14),
            ),
            child: child,
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (images.isNotEmpty)
              userBubble(
                ImageGalleryGrid(
                  images: images,
                  sessionId: _mySessionId ?? '',
                  api: _api,
                ),
              ),
            if (item.files.isNotEmpty)
              userBubble(_FileResults(files: item.files)),
            if (text.isNotEmpty)
              userBubble(
                Text(text, style: const TextStyle(fontSize: 15, height: 1.5)),
              ),
            // v3.1.5（issue #15）：用户消息此前没有任何复制入口（只有助手消息有操作栏）——
            // 这里右对齐补一个「复制」，复用 _runMessageAction('copy')：复制正文 + 「已复制」提示，
            // 与助手消息行为一致。整段选择另由 SelectionArea 承担（长按选词）。
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 2, bottom: 14),
                child: _ActionIcon(
                  icon: Icons.content_copy,
                  tooltip: L10n.t('复制', 'Copy'),
                  onTap: () => _runMessageAction(item, 'copy'),
                ),
              ),
            ),
          ],
        );
      case _MsgKind.assistant:
        if (_isNoiseText(item.text)) return const SizedBox.shrink();
        // v2.8.0：常驻操作栏（对齐 PC 端 MessageIconActions）——复制/好的回答/有问题的回答/分支，
        // 移除长按弹面板（操作可见即用）；逻辑与 _showMessageActions 共用 _runMessageAction
        final rk = item.messageId ?? 's${item.seq}';
        // issue #52：思维链改为过程组首成员、消息操作迁到轮次页脚；
        // 仅当该轮没有可锚定的过程块（旧数据/无 turn 事件）时才保留气泡内旧形态。
        final turn = _turnProcess.turnOfSeq(item.seq);
        final inProcess = turn != null &&
            _planFor(history: historyView).anchoredTurns.contains(turn);
        // issue #53 §6：收尾正文的行内文件链接只认本轮记录内的路径（精确优先、
        // 唯一 basename 次之、歧义不链接）。
        final linkResolver =
            turn == null ? null : _fileLinkResolverForTurn(turn);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AssistantBubble(
              text: item.text,
              api: _api,
              usage: item.usage,
              images: item.images,
              sessionId: _mySessionId ?? '',
              streaming: false,
              reasoning: inProcess ? null : item.reasoning,
              // issue #108：隐藏「思维链默认展开」；旧 key 不读取，默认折叠。
              defaultExpanded: false,
              expandedOverride: inProcess
                  ? null
                  : widget.store.reasoningOverrideOf(_mySessionId ?? '', rk),
              // 同上：异步方法不得放进 setState 闭包（否则点按思维链折叠会断言失败）
              onOverride: inProcess
                  ? null
                  : (v) {
                      widget.store.setReasoningOverride(
                        _mySessionId ?? '',
                        rk,
                        v,
                      );
                      setState(() {});
                    },
              codeTap: (code) {
                // issue #88：绝对路径只做精确记录匹配，绝不走 basename 兜底
                // （`/tmp/B/report.pdf` 不得因为本轮记录了 /tmp/A/report.pdf 的同名
                // display 而直接打开 A）；未命中则走确认 sheet → /api/files。
                final absolutePath = looksLikeInlineFilePath(code);
                final coordinate = absolutePath
                    ? linkResolver?.resolveExact(code)
                    : linkResolver?.resolve(code);
                if (coordinate != null) {
                  final name = code.split('/').last;
                  return () => _openTurnFile(
                    coordinate,
                    display: code,
                    name: name,
                  );
                }
                // issue #83：未记录在本轮产出物里的绝对路径（如 /tmp/...）也允许
                // 用户确认后预览；不在渲染阶段发起任何读取。
                if (!absolutePath) return null;
                return () => _confirmOpenPath(code);
              },
              codeTapKey: linkResolver == null
                  ? ''
                  : '$_turnTailVersion:$turn',
              imageLoader: _markdownImageLoader,
              imageUserAction: _markdownImageUserAction,
            ),
            if (item.detailDegraded)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  L10n.t(
                    '详情来自当前界面，可能不完整',
                    'Details came from the current surface and may be incomplete',
                  ),
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ),
            if (item.detailErrorCode != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _detailErrorLabel(item.detailErrorCode!),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.redAccent,
                      ),
                    ),
                    TextButton(
                      onPressed: _api.timelineCapabilities.detail
                          ? () => _loadEventDetail(item)
                          : null,
                      child: Text(L10n.t('重试', 'Retry')),
                    ),
                  ],
                ),
              ),
            // 需求变更（issue #1）：assistant 产出文件不再展示（时间线不提供该下载入口）。
            // 详情入口（issue #1 需求变更）：普通模式只在**确有正文增量**时出现
            // （服务端 detail.textChars 大于当前可见正文长度）；调试模式提供原始事件入口。
            // 两者都不再默认出现“看着像能加载更多、实际只会多出一份思维链”的按钮。
            if (item.detailAvailable &&
                item.seq != null &&
                (widget.store.timelineDebug ||
                    timelineHasTextIncrement(
                      item.detailTextChars,
                      item.text.length,
                    )))
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.detailLoading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    TextButton(
                      onPressed: _api.timelineCapabilities.detail
                          ? () => _loadEventDetail(item)
                          : null,
                      child: Text(
                        widget.store.timelineDebug
                            ? (item.rawData == null
                                  ? L10n.t('查看原始事件', 'View raw event')
                                  : L10n.t('重新加载原始事件', 'Reload raw event'))
                            : (item.rawData == null
                                  ? L10n.t('加载完整正文', 'Load full response')
                                  : L10n.t('重新加载正文', 'Reload full response')),
                      ),
                    ),
                  ],
                ),
              )
            else if (widget.store.timelineDebug &&
                item.rawData == null &&
                !item.detailAvailable)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  L10n.t(
                    '详情不可用（旧服务端未保存）',
                    'Detail unavailable (not retained by server)',
                  ),
                  style: TextStyle(
                    fontSize: 11,
                    color: DshColors.ink3(context),
                  ),
                ),
              ),
            if (widget.store.timelineDebug && item.rawData != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: SelectableText(
                  _debugPreviewOf(item),
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            if (!inProcess)
              _MessageActionsBar(
                item: item,
                onAction: (a) => _runMessageAction(item, a),
              ),
          ],
        );
      case _MsgKind.tool:
        // 过程块已经呈现该工具行时不再平铺重复；折叠轮因此不构建任何工具子项。
        // 只按「这一行真的被渲染进过程块」判断——缺 turn 字段的旧宿主事件、
        // 以及分页截断导致过程块未锚定的工具卡仍按原样平铺（不会凭空消失）。
        if (item.toolCallId != null &&
            _planFor(history: historyView)
                .renderedCallIds
                .contains(item.toolCallId)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildToolCard(item),
        );
      case _MsgKind.event:
        // 协议/运行时元数据在普通模式不渲染（模型里仍保留 seq 与详情指针）；
        // 调试模式完整呈现。可见性判据与模型侧共用同一实现。
        if (!timelineTypeVisibleIn(
          widget.store.timelineDebug
              ? TimelineMode.debug
              : TimelineMode.ordinary,
          item.eventType ?? '',
        )) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _TimelineEventCard(
            key: ValueKey<String>(
              'event:${item.eventType}:${item.seq ?? item.text}',
            ),
            expandedOverride:
                _failureExpansionOverrides['event:${item.eventType}:${item.seq ?? item.text}'],
            onExpandedOverride: (value) {
              setState(
                () =>
                    _failureExpansionOverrides['event:${item.eventType}:${item.seq ?? item.text}'] =
                        value,
              );
              _onContentLayoutChanged();
            },
            onAutoLoadDetail: () => _autoLoadFailureDetail(item),
            item: item,
            debug: widget.store.timelineDebug,
            onLoadDetail:
                _api.timelineCapabilities.detail &&
                    item.detailAvailable &&
                    item.detailSeq != null
                ? () => _loadEventDetail(item)
                : null,
          ),
        );
      case _MsgKind.divider:
        final seq = item.seq;
        // issue #52：轮次边界分隔条原位替换为「过程块」/「轮次页脚」。
        final startTurn = seq == null ? null : _turnProcess.turnOfStartSeq(seq);
        if (startTurn != null) {
          // 过程块已移到过程行位置（提示词之后）；轮次开始分隔条不再单独占位。
          return const SizedBox.shrink();
        }
        final endTurn = seq == null ? null : _turnProcess.turnOfEndSeq(seq);
        if (endTurn != null && _ensureProcessTurnMap().containsKey(endTurn)) {
          // 同一轮多次 turn/end：页脚只渲染在末个边界，避免重复操作栏。
          if (_turnProcess.endSeqOfTurn(endTurn) != seq) {
            return const SizedBox.shrink();
          }
          // issue #53：轮末顺序 = 过程(折叠) → 最终回答 → 改动卡 → 交付卡 → 页脚。
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTurnTailSection(endTurn, historyView: historyView),
              _buildTurnFooter(endTurn, historyView: historyView),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              item.text,
              style: TextStyle(fontSize: 11, color: DshColors.ink3(context)),
            ),
          ),
        );
    }
  }
}

// ── 消息模型 ──
enum _MsgKind { user, assistant, divider, tool, event }

/// 上翻一页的结果（issue #25：滚动上翻与跨页跳转共用同一实现，但提示口径不同）。
enum _PrependOutcome { loaded, exhausted, skipped, failed }

class _MsgItem {
  final _MsgKind kind;
  final String text;
  final Map<String, dynamic>? usage;

  /// Anchor used for grouping/render order; tool cards may receive later result seqs.
  final int? seq;
  final int? latestSeq;
  final int? detailSeq;
  final String? messageId;
  // v2.8.0：本地反馈状态（positive / negative / null=未评），驱动操作栏图标高亮与 toggle
  final String? rating;
  // v3.0.0 图像链路：消息附图元数据 [{attachmentId, mediaType, width?, height?, name?}]
  final List<Map<String, dynamic>> images;
  final List<Map<String, dynamic>> files;
  // 思维链正文（可折叠；assistant 消息专用，null/空 = 无思维链）
  final String? reasoning;

  /// v3.1.4（issue #12）：内核对 user 消息的来源标记（createUserMessage({source}).kind）——
  /// "user" = 真人发言；"plugin" / "agent-instructions" / "tool" 等 = 系统注入；
  /// null = 旧内核未下发（客户端退回启发式判断）。
  final String? sourceKind;
  // 对话时间线 Tool activity / 未知 Visible event 字段。
  final String? toolCallId;
  final String? toolName;
  final String toolArguments;
  final String toolResult;
  final String toolStatus;
  final bool toolError;
  final bool detailAvailable;
  final Map<String, dynamic>? rawData;
  final String? eventType;
  final bool detailLoading;
  final bool detailDegraded;
  final String? detailMode;
  final String? detailErrorCode;

  /// 详情正文长度提示（服务端 `detail.textChars`）：普通模式据此判断是否真有正文增量。
  final int? detailTextChars;

  /// issue #54（M3 Batch 1）：工具卡结构化摘要（tool/call 与 tool/result 分别投影）。
  final ToolCallSummary? callSummary;
  final ToolResultSummary? resultSummary;

  /// issue #68（M3 Batch 2-C）：PTC 子调用树（仅根工具卡携带；默认收起）。
  final List<ToolSubCall> subCalls;
  final bool subCallsTruncated;
  _MsgItem.user(
    this.text, {
    this.seq,
    this.messageId,
    this.images = const [],
    this.files = const [],
    this.sourceKind,
    this.detailTextChars,
  }) : kind = _MsgKind.user,
       latestSeq = seq,
       detailSeq = seq,
       usage = null,
       rating = null,
       reasoning = null,
       toolCallId = null,
       toolName = null,
       toolArguments = '',
       toolResult = '',
       toolStatus = 'complete',
       toolError = false,
       detailAvailable = false,
       rawData = null,
       eventType = null,
       detailLoading = false,
       detailDegraded = false,
       detailMode = null,
       detailErrorCode = null,
       callSummary = null,
       resultSummary = null,
       subCalls = const <ToolSubCall>[],
       subCallsTruncated = false;
  _MsgItem.assistant(
    this.text, {
    this.usage,
    this.seq,
    this.messageId,
    this.rating,
    this.images = const [],
    this.files = const [],
    this.reasoning,
    this.detailAvailable = false,
    this.rawData,
    this.detailLoading = false,
    this.detailDegraded = false,
    this.detailMode,
    this.detailErrorCode,
    this.detailTextChars,
  }) : kind = _MsgKind.assistant,
       latestSeq = seq,
       detailSeq = seq,
       sourceKind = null,
       toolCallId = null,
       toolName = null,
       toolArguments = '',
       toolResult = '',
       toolStatus = 'complete',
       toolError = false,
       eventType = null,
       callSummary = null,
       resultSummary = null,
       subCalls = const <ToolSubCall>[],
       subCallsTruncated = false;
  _MsgItem.divider(this.text, {this.seq})
    : kind = _MsgKind.divider,
      latestSeq = seq,
      detailSeq = seq,
      detailTextChars = null,
      usage = null,
      messageId = null,
      rating = null,
      images = const [],
      files = const [],
      reasoning = null,
      sourceKind = null,
      toolCallId = null,
      toolName = null,
      toolArguments = '',
      toolResult = '',
      toolStatus = 'complete',
      toolError = false,
      detailAvailable = false,
      rawData = null,
      eventType = null,
      detailLoading = false,
      detailDegraded = false,
      detailMode = null,
      detailErrorCode = null,
      callSummary = null,
      resultSummary = null,
      subCalls = const <ToolSubCall>[],
      subCallsTruncated = false;
  _MsgItem.tool({
    required this.toolCallId,
    required this.toolName,
    this.toolArguments = '',
    this.toolResult = '',
    this.toolStatus = 'running',
    this.toolError = false,
    this.seq,
    this.latestSeq,
    this.detailSeq,
    this.files = const [],
    this.images = const [],
    this.detailAvailable = false,
    this.rawData,
    this.detailLoading = false,
    this.detailDegraded = false,
    this.detailMode,
    this.detailErrorCode,
    this.detailTextChars,
    this.callSummary,
    this.resultSummary,
    this.subCalls = const <ToolSubCall>[],
    this.subCallsTruncated = false,
  }) : kind = _MsgKind.tool,
       text = toolResult.isNotEmpty ? toolResult : toolArguments,
       usage = null,
       messageId = null,
       rating = null,
       reasoning = null,
       sourceKind = null,
       eventType = 'tool/activity';
  _MsgItem.event({
    required this.eventType,
    required this.text,
    this.seq,
    int? latestSeq,

    int? detailSeq,
    this.rawData,
    this.detailAvailable = false,
    this.detailLoading = false,
    this.detailDegraded = false,
    this.detailMode,
    this.detailErrorCode,
    this.toolError = false,
    this.detailTextChars,
  }) : kind = _MsgKind.event,
       latestSeq = latestSeq ?? seq,
       detailSeq = detailSeq ?? seq,
       usage = null,
       messageId = null,
       rating = null,
       images = const [],
       files = const [],
       reasoning = null,
       sourceKind = null,
       toolCallId = null,
       toolName = null,
       toolArguments = '',
       toolResult = '',
       toolStatus = 'complete',
       callSummary = null,
       resultSummary = null,
       subCalls = const <ToolSubCall>[],
       subCallsTruncated = false;

  /// 注入消息（非真人发言）→ 渲染成可折叠块，而不是普通气泡（v3.1.4）
  bool get injected => sourceKind != null && sourceKind != 'user';

  _MsgItem copyWith({int? seq, String? messageId}) {
    assert(kind == _MsgKind.user, 'copyWith only supports user items');
    return _MsgItem.user(
      text,
      seq: seq ?? this.seq,
      messageId: messageId ?? this.messageId,
      images: images,
      files: files,
      sourceKind: sourceKind,
      detailTextChars: detailTextChars,
    );
  }

  _MsgItem copyTool({
    String? name,
    int? anchorSeq,
    String? arguments,
    String? result,
    String? status,
    bool? error,
    List<Map<String, dynamic>>? images,
    List<Map<String, dynamic>>? files,
    bool? detailAvailable,
    int? latestSeq,

    int? detailSeq,
    Map<String, dynamic>? rawData,
    bool? detailLoading,
    bool? detailDegraded,
    String? detailMode,
    String? detailErrorCode,
    bool clearDetailError = false,
    ToolCallSummary? callSummary,
    ToolResultSummary? resultSummary,
    List<ToolSubCall>? subCalls,
    bool? subCallsTruncated,
  }) => _MsgItem.tool(
    toolCallId: toolCallId,
    toolName: name ?? toolName ?? L10n.t('工具', 'Tool'),
    toolArguments: arguments ?? toolArguments,
    toolResult: result ?? toolResult,
    toolStatus: status ?? toolStatus,
    toolError: error ?? toolError,
    seq: anchorSeq ?? seq,
    latestSeq: latestSeq ?? this.latestSeq ?? seq,
    detailSeq: detailSeq ?? this.detailSeq ?? seq,
    images: images ?? this.images,
    files: files ?? this.files,
    detailAvailable: detailAvailable ?? this.detailAvailable,
    rawData: rawData ?? this.rawData,
    detailLoading: detailLoading ?? this.detailLoading,
    detailDegraded: detailDegraded ?? this.detailDegraded,
    detailMode: detailMode ?? this.detailMode,
    detailErrorCode: clearDetailError
        ? null
        : (detailErrorCode ?? this.detailErrorCode),
    detailTextChars: detailTextChars,
    callSummary: callSummary ?? this.callSummary,
    resultSummary: resultSummary ?? this.resultSummary,
    subCalls: subCalls ?? this.subCalls,
    subCallsTruncated: subCallsTruncated ?? this.subCallsTruncated,
  );

  _MsgItem copyAssistant({
    String? text,
    List<Map<String, dynamic>>? files,
    Map<String, dynamic>? rawData,
    bool? detailAvailable,
    bool? detailLoading,
    bool? detailDegraded,
    String? detailMode,
    String? detailErrorCode,
    bool clearDetailError = false,
    int? detailTextChars,
  }) => _MsgItem.assistant(
    text ?? this.text,
    usage: usage,
    seq: seq,
    messageId: messageId,
    rating: rating,
    images: images,
    files: files ?? this.files,
    reasoning: reasoning,
    detailAvailable: detailAvailable ?? this.detailAvailable,
    rawData: rawData ?? this.rawData,
    detailLoading: detailLoading ?? this.detailLoading,
    detailDegraded: detailDegraded ?? this.detailDegraded,
    detailMode: detailMode ?? this.detailMode,
    detailErrorCode: clearDetailError
        ? null
        : (detailErrorCode ?? this.detailErrorCode),
    detailTextChars: detailTextChars ?? this.detailTextChars,
  );

  _MsgItem copyEvent({
    Map<String, dynamic>? rawData,
    bool? detailLoading,
    bool? detailDegraded,
    String? detailMode,
    String? detailErrorCode,
    bool clearDetailError = false,
  }) => _MsgItem.event(
    eventType: eventType ?? 'unknown',
    text: text,
    seq: seq,
    latestSeq: latestSeq,
    detailSeq: detailSeq,
    rawData: rawData ?? this.rawData,
    detailAvailable: detailAvailable,
    detailLoading: detailLoading ?? this.detailLoading,
    detailDegraded: detailDegraded ?? this.detailDegraded,
    detailMode: detailMode ?? this.detailMode,
    detailErrorCode: clearDetailError
        ? null
        : (detailErrorCode ?? this.detailErrorCode),
    toolError: toolError,
    detailTextChars: detailTextChars,
  );
}

// ── 气泡组件 ──
/// v3.1.4（issue #12）：系统注入消息折叠块——默认收起成一行摘要，点按展开正文。
/// 展开状态复用「思维链」同一套每消息覆盖存储（键前缀 `inj:`），列表回收重建不丢。
/// 判定依据是内核 `createUserMessage({source}).kind`（非 "user" 即注入），比关键词黑名单可靠。
class _InjectedBubble extends StatelessWidget {
  final String text;
  final String? sourceKind;
  final bool expanded;
  final ValueChanged<bool> onToggle;
  const _InjectedBubble({
    super.key,
    required this.text,
    required this.sourceKind,
    required this.expanded,
    required this.onToggle,
  });

  bool get _trigger => _isTriggerSourceKind(sourceKind);

  String get _label {
    if (sourceKind == 'agent-message') {
      return L10n.t('收到任务消息', 'Task message received');
    }
    if (sourceKind == 'team-message') {
      return L10n.t('收到团队消息', 'Team message received');
    }
    switch (sourceKind) {
      case 'agent-instructions':
        return L10n.t('系统指令注入', 'Injected instructions');
      case 'plugin':
        return L10n.t('插件注入', 'Plugin injection');
      case 'tool':
        return L10n.t('工具注入', 'Tool injection');
      default:
        return L10n.t('系统注入', 'System injection');
    }
  }

  IconData get _icon => sourceKind == 'team-message'
      ? Icons.groups_outlined
      : sourceKind == 'agent-message'
          ? Icons.send_outlined
          : Icons.settings_suggest_outlined;

  @override
  Widget build(BuildContext context) {
    final ink3 = DshColors.ink3(context);
    final preview = text.replaceAll('\r', '').split('\n').first.trim();
    final canExpand = text.trim().isNotEmpty;
    if (_trigger) {
      return Container(
        width: double.infinity,
        key: const Key('trigger-message-card'),
        decoration: BoxDecoration(
          color: DshColors.surface(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: DshColors.line(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: canExpand ? () => onToggle(!expanded) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(_icon, size: 15, color: DshColors.brand(context)),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _label,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ink3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (canExpand)
                      Icon(
                        expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: ink3,
                      ),
                  ],
                ),
              ),
            ),
            if (canExpand && !expanded && preview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 10, 8),
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 1.3, color: ink3),
                ),
              ),
            if (canExpand && expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 0, 10, 10),
                  child: Text(
                    text,
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: ink3),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DshColors.line(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => onToggle(!expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(_icon, size: 14, color: ink3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$_label · ${text.length} ${L10n.t('字', 'chars')}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ink3,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: ink3,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Text(
                  text,
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: ink3),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// issue #101：会触发轮次的代理/团队消息（普通模式显示紧凑触发卡）。
bool _isTriggerSourceKind(String? sourceKind) =>
    sourceKind == 'agent-message' || sourceKind == 'team-message';

/// issue #61：通用占位名（不是真实工具名）。工具卡标题/摘要据此判断「缺名」。
bool _isPlaceholderToolName(String? name) =>
    name == null ||
    name.isEmpty ||
    name == L10n.t('工具', 'Tool') ||
    name == L10n.t('工具调用', 'Tool call');

/// issue #61：缺名工具卡的折叠行摘要——优先参数 JSON 的 `description`，其次参数首行，
/// 再次结果首行；压平成一行、截断 ≤[max] 字。都没有时返回空串（不占位）。
String _genericToolSummary(
  String arguments,
  String result, {
  int max = 80,
}) {
  String firstLine(String text) {
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isNotEmpty) return line;
    }
    return '';
  }

  var text = '';
  final args = arguments.trim();
  if (args.isNotEmpty) {
    try {
      final decoded = jsonDecode(args);
      if (decoded is Map) {
        final description = decoded['description'];
        if (description is String && description.trim().isNotEmpty) {
          text = description.trim();
        }
      }
    } catch (_) {
      // 参数不是合法 JSON（旧内核/半截 delta）：退回首行文本。
    }
    if (text.isEmpty) text = firstLine(args);
  }
  if (text.isEmpty) text = firstLine(result);
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max)}…';
}

String _detailErrorLabel(String code) {
  switch (code) {
    case 'session-not-found':
      return L10n.t('会话不存在', 'Session not found');
    case 'event-not-found':
      return L10n.t('事件不存在', 'Event not found');
    case 'session-corrupt':
      return L10n.t('会话数据损坏', 'Session data is corrupt');
    case 'event-detail-too-large':
      return L10n.t('事件详情过大', 'Event details are too large');
    case 'event-read-failed':
      return L10n.t('事件详情读取失败', 'Could not read event details');
    default:
      return L10n.t('详情暂时不可用', 'Details are temporarily unavailable');
  }
}

class _ToolActivityCard extends StatefulWidget {
  final _MsgItem item;
  final bool debug;
  final String sessionId;

  /// issue #69：附图拉取用 ChatScreen 注入的 Api（测试可计数/打桩，生产同全局单例）。
  final Api api;

  /// issue #54：服务端能力位声明的工具集合包含当前工具（旧插件 false → 通用卡）。
  final bool toolCardsEnabled;

  /// issue #68：PTC 子调用树能力位（`capabilities.toolCards.ptc.version >= 1`）。
  /// 旧插件/无能力位时即便 wire 带 subCalls 也完全不渲染（widget 层 gating）。
  final bool ptcEnabled;

  /// issue #66：当前会话仍待回答的问题 id 集合；question 卡命中时折叠行尾给「打开问询」。
  final Set<String> pendingQuestionIds;

  /// issue #66：点「打开问询」的回调（复用既有问询卡作答；行内不出现作答控件）。
  final VoidCallback? onOpenQuestion;

  /// issue #67：折叠行路径点击回调（参数是服务端下发的 cwd 相对路径，原样透传）。
  final ValueChanged<String>? onOpenFilePath;
  final bool? expandedOverride;
  final ValueChanged<bool>? onExpandedOverride;
  final VoidCallback? onLoadDetail;
  final VoidCallback? onAutoLoadDetail;

  /// issue #74：折叠行图片入口——点 chip 直接开图库，不展开工具卡。
  final VoidCallback? onOpenImages;

  /// issue #76：过程区平铺变体（透明、无逐卡边框/圆角/阴影；详情才用轻底）。
  final bool flat;

  /// issue #108：档位默认展开（仅完全展开的当前轮）；手动 override 优先。
  final bool autoExpanded;
  const _ToolActivityCard({
    super.key,
    required this.item,
    required this.debug,
    required this.sessionId,
    required this.api,
    this.toolCardsEnabled = false,
    this.ptcEnabled = false,
    this.pendingQuestionIds = const <String>{},
    this.onOpenQuestion,
    this.onOpenFilePath,
    this.expandedOverride,
    this.onExpandedOverride,
    this.onLoadDetail,
    this.onAutoLoadDetail,
    this.onOpenImages,
    this.flat = false,
    this.autoExpanded = false,
  });

  @override
  State<_ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<_ToolActivityCard> {
  bool expanded = false;
  bool requested = false;
  bool userOverride = false;

  /// issue #67：折叠行路径段的点击识别器（与 State 同生命周期，dispose 必须释放）。
  TapGestureRecognizer? _pathTap;

  @override
  void dispose() {
    _pathTap?.dispose();
    _pathTap = null;
    super.dispose();
  }

  bool get _failed =>
      widget.item.toolError || widget.item.toolStatus == 'failed';
  bool get _defaultExpanded => widget.debug && _failed;

  void _requestDetailIfNeeded() {
    if (expanded &&
        !requested &&
        widget.item.detailSeq != null &&
        widget.onAutoLoadDetail != null &&
        !widget.item.detailLoading) {
      requested = true;
      widget.onAutoLoadDetail!();
    }
  }

  @override
  void initState() {
    super.initState();
    expanded = widget.expandedOverride ?? (widget.autoExpanded || _defaultExpanded);
    userOverride = widget.expandedOverride != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestDetailIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant _ToolActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final override = widget.expandedOverride;
    userOverride = override != null;
    if (!userOverride &&
        (_failed ||
            oldWidget.debug != widget.debug ||
            oldWidget.autoExpanded != widget.autoExpanded)) {
      expanded = widget.autoExpanded || _defaultExpanded;
    }
    if (override != null && override != expanded) expanded = override;
    if (oldWidget.item.toolCallId != widget.item.toolCallId ||
        oldWidget.item.detailSeq != widget.item.detailSeq ||
        oldWidget.debug != widget.debug) {
      requested = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestDetailIfNeeded();
      });
    }
  }

  void _setExpanded(bool value) {
    userOverride = true;
    widget.onExpandedOverride?.call(value);
    setState(() => expanded = value);
    if (value && !requested && widget.onLoadDetail != null) {
      requested = true;
      widget.onLoadDetail!();
    }
  }

  String _status() {
    if (widget.item.detailLoading) return L10n.t('加载详情…', 'Loading details…');
    if (widget.item.toolStatus == 'failed' || widget.item.toolError) {
      return L10n.t('失败', 'Failed');
    }
    if (widget.item.toolStatus == 'success') return L10n.t('成功', 'Succeeded');
    return L10n.t('进行中', 'Running');
  }

  /// schema / 原始事件预览（v3.1.6，app-audit ①3）：上限 4000 字符（见 [timelineDebugPreview]），
  /// 并按对象身份缓存一次编码结果——此前每次 build 都对 8 MiB 级原始事件重新缩进编码。
  Object? _prettyFor = _noValue;
  String _prettyCache = '';
  static const Object _noValue = Object();

  String _pretty(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (identical(value, _prettyFor)) return _prettyCache;
    _prettyFor = value;
    _prettyCache = timelineDebugPreview(value);
    return _prettyCache;
  }

  bool _looksMarkdown(String value) =>
      value.contains('```') ||
      RegExp(r'(^|\n)\s{0,3}(#{1,6} |[-*] |\d+\. )').hasMatch(value) ||
      value.contains('**') ||
      value.contains('`');

  Widget _markdownResult(String value) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: renderMarkdownBlocks(value, context),
      ),
    ),
  );

  Widget _code(String label, String value) {
    final long = value.length > 1200 || '\n'.allMatches(value).length > 14;
    final text = SelectableText(
      value,
      style: const TextStyle(
        fontSize: 11,
        height: 1.35,
        fontFamily: 'monospace',
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: DshColors.ink3(context),
            ),
          ),
          const SizedBox(height: 3),
          Container(
            width: double.infinity,
            constraints: long ? const BoxConstraints(maxHeight: 260) : null,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: DshColors.surface(context),
              borderRadius: BorderRadius.circular(6),
            ),
            // issue #103：这里不能再嵌 SingleChildScrollView——它会在竖直手势竞技场
            // 抢走父 CustomScrollView 的上翻；长内容用裁剪 + “查看全文”入口。
            child: long ? ClipRect(child: text) : text,
          ),
          if (long)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: ValueKey('tool-code-full-${label.hashCode}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showFullText(label, value),
                child: Text(L10n.t('查看全文', 'View full text')),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showFullText(String label, String value) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).maybePop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    value,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── issue #54（M3 Batch 1）：专用工具卡投影（fail-open 到通用卡） ──────────

  IconData _kindIcon(ToolCardKind kind) => switch (kind) {
    ToolCardKind.command => Icons.terminal,
    ToolCardKind.file => Icons.description_outlined,
    ToolCardKind.search => Icons.search,
    ToolCardKind.web => Icons.language,
    ToolCardKind.image => Icons.image_outlined,
    ToolCardKind.todo => Icons.checklist,
    ToolCardKind.question => Icons.forum_outlined,
    ToolCardKind.skill => Icons.auto_awesome_outlined,
  };

  Widget _chip(String text, Color color) => Container(
    margin: const EdgeInsets.only(left: 5),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      maxLines: 1,
      style: TextStyle(fontSize: 10.5, color: color, fontFamily: 'monospace'),
    ),
  );

  /// issue #61：当前条目是否缺真实工具名（占位名不算已知名称）。
  bool get _nameUnknown => _isPlaceholderToolName(widget.item.toolName);

  /// issue #61：缺名通用卡的折叠行。摘要可读；调试模式额外保留原始 callId/事件类型。
  Widget _genericFoldRow(String summary, {bool flat = false}) {
    final ink3 = flat ? DshColors.ink2(context) : DshColors.ink3(context);
    final debugLine = 'callId: ${widget.item.toolCallId} · '
        '${widget.item.eventType ?? 'tool/activity'}';
    if (summary.isEmpty && !widget.debug) return const SizedBox.shrink();
    return Padding(
      padding: flat
          ? const EdgeInsets.only(left: 24, right: 0, bottom: 6)
          : const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary.isNotEmpty)
            Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: flat ? 12 : 11.5,
                color: ink3,
              ),
            ),
          if (widget.debug)
            Padding(
              padding: EdgeInsets.only(top: summary.isEmpty ? 0 : 2),
              child: Text(
                debugLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: ink3,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 折叠行：`$ command` / 路径+行范围 / pattern / URL + 统计/退出码/命中数胶囊。
  ///
  /// issue #67：file/image 卡在服务端两字段同现时，把**路径段**渲染成品牌色 + 下划线的
  /// 行内链接（Text.rich 两段 span，`toPlainText()` 仍是整行原字符串，既有 find.text 不破）；
  /// 不可点时保持原纯 Text 代码路径与视觉（零布局位移）。点击只把 `relative` 交给页面，
  /// 不在卡片里拼路径；卡片标题的手势与本行无关，点击路径不改变展开态。
  Widget _foldRow(ToolCallSummary call, {bool flat = false}) {
    final ink3 = flat ? DshColors.ink2(context) : DshColors.ink3(context);
    final text = toolFoldText(call) ?? '';
    final stats = toolFileStats(call);
    // issue #60 R14：退出码/信号只对**已关联 command 工具**的卡片展示；非命令工具即便
    // 结果摘要带了终止字段（旧服务端/伪造内容）也不显示。
    final exit = call.isCommand ? toolExitBadge(widget.item.resultSummary) : null;
    final count = toolResultCountBadge(call, widget.item.resultSummary);
    // issue #66：仅当该问询卡仍有命中当前会话 pending 集合的问题时，行尾给「打开问询」入口。
    final showOpenQuestion =
        widget.onOpenQuestion != null &&
        questionCallPending(call, widget.pendingQuestionIds);
    final tapParts = _previewTapParts(call);
    final baseStyle = TextStyle(
      fontSize: flat ? 12 : 11.5,
      color: ink3,
      fontFamily: call.isCommand ? 'monospace' : null,
    );
    final Widget foldText;
    if (tapParts == null) {
      // B/D 态：与 issue #54/#66 完全同形（无手势、无下划线、无 key）。
      foldText = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    } else {
      final pathText = tapParts.path;
      final suffix = tapParts.suffix;
      final relative = tapParts.relative;
      final linkStyle = baseStyle.copyWith(
        color: DshColors.brand(context),
        decoration: TextDecoration.underline,
        decorationColor: DshColors.brand(context),
      );
      foldText = Semantics(
        label: L10n.t('打开文件预览：$pathText', 'Open file preview: $pathText'),
        link: true,
        onTap: () => widget.onOpenFilePath?.call(relative),
        excludeSemantics: true,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: pathText, style: linkStyle, recognizer: _pathTap),
              // suffix（如 ` · 行 2–5`）沿用折叠行 ink3 基础样式。
              TextSpan(text: suffix),
            ],
          ),
          key: Key(
            'tool-path-fold:${widget.item.toolCallId ?? widget.item.seq}',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: baseStyle,
        ),
      );
    }
    return Padding(
      padding: flat
          ? const EdgeInsets.only(left: 24, right: 0, bottom: 6)
          : const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Row(
        children: [
          Expanded(child: foldText),
          if (stats != null) _chip(stats, ink3),
          if (exit != null)
            _chip(exit, flat ? DshColors.danger(context) : Colors.redAccent),
          if (count != null) _chip(count, ink3),
          if (showOpenQuestion)
            TextButton(
              key: Key('open-question:${widget.item.toolCallId}'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: widget.onOpenQuestion,
              child: Text(
                L10n.t('打开问询', 'Open question'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }

  /// issue #67：可点的「路径 + 其余文案 + 相对路径」；不可点返回 null。
  ///
  /// 识别器只在 State 生命周期内创建/复用、在 [dispose] 统一释放——不在 build 中途
  /// dispose（用户按住路径时若发生重建，中途释放会打断手势）。
  ({String path, String suffix, String relative})? _previewTapParts(
    ToolCallSummary call,
  ) {
    final parts = toolFoldPathParts(call);
    final relative = call.relativePath;
    if (parts == null || relative == null || widget.onOpenFilePath == null) {
      _pathTap?.onTap = null;
      return null;
    }
    final tap = _pathTap ??= TapGestureRecognizer();
    tap.onTap = () => widget.onOpenFilePath?.call(relative);
    return (path: parts.path, suffix: parts.suffix, relative: relative);
  }

  /// 通用参数/结果块（issue #60 R12：无内联 diff 时普通模式也要可达参数，不只是结果）。
  List<Widget> _genericBody({bool includeResult = true}) => [
    if (widget.item.toolArguments.isNotEmpty)
      _code(L10n.t('参数', 'Arguments'), widget.item.toolArguments),
    if (includeResult && widget.item.toolResult.isNotEmpty)
      _looksMarkdown(widget.item.toolResult) && !widget.debug
          ? _markdownResult(widget.item.toolResult)
          : _code(L10n.t('结果', 'Result'), widget.item.toolResult),
  ];

  /// 展开态专用内容；返回空列表时由调用方回退通用参数/结果块。
  List<Widget> _specializedBody(ToolCallSummary call) {
    final resultText = widget.item.toolResult;
    // issue #60 R11：write/edit 的内联 diff 来自**调用参数**，不代表执行成功；失败时
    // 必须保留真实结果原因（old_string 未找到/沙箱拒绝/read_image 读取失败）。
    // 红色 Failed 抬头不能替代失败原因。
    final failed = widget.item.toolError || widget.item.toolStatus == 'failed';
    if (failed) {
      // issue #60 recheck-5（R12 交叉场景）：失败也必须是"错误原因 + 通用参数/结果"，
      // 失败的大 write/edit（diffTruncated/无 diff）在普通模式仍要能看到参数。
      return [
        if (resultText.isNotEmpty)
          _code(L10n.t('错误', 'Error'), resultText)
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              L10n.t('工具失败（无错误详情）', 'Tool failed (no error detail)'),
              style: TextStyle(fontSize: 11.5, color: Colors.redAccent),
            ),
          ),
        // 结果已作为错误原因展示，这里只补参数，避免重复。
        ..._genericBody(includeResult: false),
      ];
    }
    switch (call.kind) {
      case ToolCardKind.command:
        return [
          if (resultText.isNotEmpty)
            _code(L10n.t('输出', 'Output'), resultText)
          else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                L10n.t('无输出', 'No output'),
                style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
              ),
            ),
        ];
      case ToolCardKind.file:
        // write/edit：服务端给了内联 diff 就直接用统一查看器（issue #54 §4）。
        if (toolHasInlineDiff(call)) {
          return [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                height: 320,
                child: GitFileViewer(
                  key: const Key('tool-diff-viewer'),
                  mode: GitFileViewerMode.diff,
                  path: call.filePath,
                  diff: call.diff!,
                  keys: const GitFileViewerKeys(prefix: 'tool-diff'),
                ),
              ),
            ),
          ];
        }
        // issue #60 R12：缺 diff / 超过 8 KiB 被截断时，按规格回退**通用参数+结果**
        // （普通模式参数必须可达），而不是只给一句提示。
        if (call.diffTruncated) {
          return [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                L10n.t(
                  'diff 较大，未内联展示；以下为参数/结果',
                  'Diff too large to inline; showing arguments/result',
                ),
                style: TextStyle(fontSize: 11, color: DshColors.ink3(context)),
              ),
            ),
            ..._genericBody(),
          ];
        }
        // read 或没有内联 diff 的 write/edit：回退通用参数+结果。
        return _genericBody();
      case ToolCardKind.search:
        return resultText.isEmpty
            ? const []
            : [_code(L10n.t('结果', 'Result'), resultText)];
      case ToolCardKind.web:
        if (resultText.isEmpty) return const [];
        return [
          _looksMarkdown(resultText) && !widget.debug
              ? _markdownResult(resultText)
              : _code(L10n.t('结果', 'Result'), resultText),
        ];
      case ToolCardKind.image:
        // 图片本体仍由既有 images 元数据网格渲染（下方通用块）。
        return const [];
      // issue #66（M3 Batch 2-A）：todo / question / skill 展开态均为只读回放。
      case ToolCardKind.todo:
        return _todoBody(call);
      case ToolCardKind.question:
        return _questionBody(call);
      case ToolCardKind.skill:
        return _skillBody(resultText);
    }
  }

  // ── issue #66（M3 Batch 2-A）：todo / question / skill 专用行（只读，无作答控件） ──

  IconData _todoStatusIcon(String status) => switch (status) {
    'completed' => Icons.check_circle,
    'in_progress' => Icons.radio_button_checked,
    _ => Icons.radio_button_unchecked,
  };

  Color _todoStatusColor(String status) => status == 'in_progress'
      ? DshColors.brand(context)
      : DshColors.ink3(context);

  /// todo：只读清单（状态图标 + 文本，不可点）；空清单显示「无任务」。
  List<Widget> _todoBody(ToolCallSummary call) {
    final items = call.todoItems ?? const <TodoCardItem>[];
    if (items.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            L10n.t('无任务', 'No tasks'),
            style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
          ),
        ),
      ];
    }
    return [
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _todoStatusIcon(item.status),
                size: 16,
                color: _todoStatusColor(item.status),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.35),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// 某题在结果摘要里的答案项（无该题答案项返回 null）。
  QuestionAnswerItem? _answerItemOf(
    ToolResultSummary? result,
    String? questionId,
  ) {
    if (result == null || questionId == null) return null;
    for (final answer in result.answers ?? const <QuestionAnswerItem>[]) {
      if (answer.questionId == questionId) return answer;
    }
    return null;
  }

  /// question：每题只读块（header / 问题文本 / 选项 / 答案行）——绝不放作答控件。
  List<Widget> _questionBody(ToolCallSummary call) {
    final questions = call.questions ?? const <QuestionCardItem>[];
    final result = widget.item.resultSummary;
    final pending = questionCallPending(call, widget.pendingQuestionIds);
    return [
      for (var index = 0; index < questions.length; index++)
        _questionBlock(
          question: questions[index],
          result: result,
          pending: pending,
          first: index == 0,
        ),
    ];
  }

  Widget _questionBlock({
    required QuestionCardItem question,
    required ToolResultSummary? result,
    required bool pending,
    required bool first,
  }) {
    final ink3 = DshColors.ink3(context);
    final brand = DshColors.brand(context);
    final answerItem = _answerItemOf(result, question.id);
    final values = answerItem?.values ?? const <String>[];
    final answer = answerTextOf(result, question.id);
    // 同题缺少稳定 id 时不给 key（避免多题 null 键在兄弟节点重复）。
    final answerKey = question.id == null
        ? null
        : ValueKey<String>('tool-question-answer:${question.id}');
    return Padding(
      padding: EdgeInsets.only(top: first ? 6 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (question.header != null)
            Text(
              question.header!,
              style: TextStyle(fontSize: 11, color: ink3),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              question.question,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          for (final option in question.options)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    values.contains(option.label)
                        ? Icons.check
                        : Icons.radio_button_unchecked,
                    size: 15,
                    color: values.contains(option.label) ? brand : ink3,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          option.label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: values.contains(option.label)
                                ? FontWeight.w600
                                : null,
                          ),
                        ),
                        if (option.description != null)
                          Text(
                            option.description!,
                            style: TextStyle(
                              fontSize: 11,
                              color: ink3,
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (answer != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                key: answerKey,
                L10n.t('答案：$answer', 'Answer: $answer'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            )
          // values 为空数组 → 未回答；结果里完全没该题答案时，仅在该卡仍待答时隐藏
          // 答案行（作答入口在行尾），已结束/取消则明确显示未回答。
          else if (answerItem != null || !pending)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                key: answerKey,
                L10n.t('未回答', 'Unanswered'),
                style: TextStyle(fontSize: 12, color: ink3),
              ),
            ),
        ],
      ),
    );
  }

  /// skill：只读说明（结果文本为空 → 无说明）。
  List<Widget> _skillBody(String resultText) => resultText.isEmpty
      ? [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              L10n.t('无说明', 'No details'),
              style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
            ),
          ),
        ]
      : [_code(L10n.t('说明', 'Details'), resultText)];

  // ── issue #68（M3 Batch 2-C）：PTC 子调用树（根卡内计数行 + 缩进只读子行） ──
  //
  // 只显示名称 + 状态 + 安全摘要；不做 args/结果二级展开、不显示图片；子调用不进入
  // M1 过程行（它们只存在于根工具卡内部）。默认收起、失败不自动展开（#61 语义不变）。

  bool get _ptcVisible =>
      widget.ptcEnabled &&
      (widget.item.subCalls.isNotEmpty || widget.item.subCallsTruncated);

  Color _subCallStatusColor(String status) => switch (status) {
    'failed' => Colors.redAccent,
    'success' => DshColors.ink3(context),
    _ => DshColors.brand(context),
  };

  /// 折叠行计数：「N 个子调用」+ truncated 后缀（根卡未展开时也可见）。
  Widget _ptcCountRow() {
    final count = widget.item.subCalls.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 13,
            color: DshColors.ink3(context),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              toolSubCallCountLabel(
                count,
                truncated: widget.item.subCallsTruncated,
              ),
              key: Key(
                'tool-ptc-count:${widget.item.toolCallId ?? widget.item.seq}',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: DshColors.ink3(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 展开后的缩进子行（仅名称 + 状态 + 安全摘要；无二级详情）。
  List<Widget> _ptcChildRows() {
    final ink3 = DshColors.ink3(context);
    final rows = <Widget>[];
    for (final sub in widget.item.subCalls) {
      final name = sub.name.isEmpty ? L10n.t('工具', 'Tool') : sub.name;
      final status = toolSubCallStatusLabel(sub.status);
      final fold = toolSubCallFoldText(
        sub.summary,
        text: sub.text,
        isError: sub.isError,
      );
      final label = fold == null ? '$name · $status' : '$name · $status · $fold';
      // A3：按 depth 分级缩进（depth1=10、2=24、3=38…；≥9 层封顶 122，避免
      // 16 层嵌套在小屏横向溢出），仍单行 ellipsis、无二级交互。
      final indent = 10 + ((sub.depth - 1).clamp(0, 8)) * 14;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: 4, left: indent.toDouble()),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 5),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _subCallStatusColor(sub.status),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  key: Key('tool-ptc-subcall:${sub.callId}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: ink3),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // 工具 schema 目前只在少数内核/服务端形态下随详情下发（tool/call 的 data 里）；
    // 内核 SessionEventMap 的 tool/call 只有 turn/step/callId/name/arguments，
    // 因此这里读不到就不显示，不做任何猜测重建。
    final raw = item.rawData;
    final rawData = raw?['data'] is Map ? raw!['data'] as Map : const {};
    final schema =
        raw?['toolSchema'] ??
        raw?['schema'] ??
        raw?['inputSchema'] ??
        rawData['toolSchema'] ??
        rawData['schema'] ??
        rawData['inputSchema'];
    final danger = DshColors.danger(context);
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final accent = item.toolError
        ? (widget.flat ? danger : Colors.redAccent)
        : (widget.flat ? ink2 : DshColors.brand(context));
    // issue #54：能力位声明支持 + 摘要可渲染才启用专用卡；否则完整回退通用卡。
    final call = item.callSummary;
    final specialized = widget.toolCardsEnabled && call != null && call.renderable;
    final fold = specialized ? toolFoldText(call) : null;
    final column = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _setExpanded(!expanded),
            child: Padding(
              padding: widget.flat
                  ? const EdgeInsets.symmetric(vertical: 6)
                  : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    item.toolError
                        ? Icons.error_outline
                        : specialized
                        ? _kindIcon(call.kind)
                        : Icons.build_outlined,
                    size: 16,
                    color: accent,
                  ),
                  SizedBox(width: widget.flat ? 8 : 7),
                  Expanded(
                    child: Text(
                      // issue #61：缺名时明确是「工具调用」，不再用信息量为零的「工具」。
                      _nameUnknown
                          ? L10n.t('工具调用', 'Tool call')
                          : item.toolName!,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            widget.flat ? FontWeight.w500 : FontWeight.w600,
                        color: widget.flat ? ink : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // issue #74：折叠态给图片入口（展开后由 ImageGalleryGrid 呈现）。
                  if (!expanded &&
                      item.images.isNotEmpty &&
                      widget.onOpenImages != null) ...[
                    _ImageCountChip(
                      count: countToolImages([item.images]),
                      onOpen: widget.onOpenImages!,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    _status(),
                    style: TextStyle(
                      fontSize: widget.flat ? 11.5 : 11,
                      color: widget.flat
                          ? (item.toolError ? ink : ink2)
                          : (item.toolError
                                ? Colors.redAccent
                                : DshColors.ink3(context)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: widget.flat
                        ? ink2
                        : DshColors.ink3(context),
                  ),
                ],
              ),
            ),
          ),
          if (specialized && fold != null)
            _foldRow(call, flat: widget.flat)
          else if (_nameUnknown)
            // issue #61：通用卡缺名时给一行可读摘要（description → 参数首行 → 结果首行）。
            _genericFoldRow(
              _genericToolSummary(item.toolArguments, item.toolResult),
              flat: widget.flat,
            ),
          // issue #68：子调用计数行在收起态也可见（能力位缺失时完全不渲染）。
          if (_ptcVisible) _ptcCountRow(),
          if (expanded)
            Padding(
              padding: widget.flat
                  ? const EdgeInsets.only(left: 24, top: 8, bottom: 4)
                  : const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Container(
                padding: widget.flat ? const EdgeInsets.all(10) : null,
                decoration: widget.flat
                    ? BoxDecoration(
                        color: item.toolError
                            ? DshColors.danger(context).withValues(alpha: .05)
                            : DshColors.surface(context),
                        borderRadius: BorderRadius.circular(DshTheme.radiusSm),
                      )
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  if (item.toolCallId != null)
                    Text(
                      'callId: ${item.toolCallId}',
                      style: TextStyle(
                        fontSize: 10,
                        color: DshColors.ink3(context),
                      ),
                    ),
                  // issue #68：展开后缩进子行（名称/状态/安全摘要，只读，无二级详情）。
                  if (_ptcVisible) ..._ptcChildRows(),
                  if (specialized) ...[
                    ..._specializedBody(call),
                    if (widget.debug && item.toolArguments.isNotEmpty)
                      _code(L10n.t('参数', 'Arguments'), item.toolArguments),
                  ] else ...[
                    if (item.toolArguments.isNotEmpty)
                      _code(L10n.t('参数', 'Arguments'), item.toolArguments),
                    if (item.toolResult.isNotEmpty)
                      _looksMarkdown(item.toolResult) && !widget.debug
                          ? _markdownResult(item.toolResult)
                          : _code(L10n.t('结果', 'Result'), item.toolResult),
                  ],
                  if (item.images.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ImageGalleryGrid(
                        images: item.images,
                        sessionId: widget.sessionId,
                        api: widget.api,
                      ),
                    ),
                  // 需求变更（issue #1）：工具产出文件不再展示（时间线不提供该下载入口）。
                  if (item.detailLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  if (item.detailDegraded)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        L10n.t(
                          '详情来自当前界面，可能不完整',
                          'Details came from the current surface and may be incomplete',
                        ),
                        style: TextStyle(fontSize: 11, color: Colors.orange),
                      ),
                    ),
                  if (item.detailErrorCode != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _detailErrorLabel(item.detailErrorCode!),
                        style: TextStyle(fontSize: 11, color: Colors.redAccent),
                      ),
                    ),
                  if (!item.detailAvailable && item.rawData == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        L10n.t(
                          '详情不可用（旧服务端未保存）',
                          'Details unavailable (not retained by the server)',
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: DshColors.ink3(context),
                        ),
                      ),
                    ),
                  if (item.detailErrorCode != null &&
                      widget.onLoadDetail != null)
                    TextButton(
                      onPressed: () {
                        requested = false;
                        widget.onLoadDetail!();
                      },
                      child: Text(L10n.t('重试', 'Retry')),
                    ),
                  if (widget.debug && schema != null)
                    _code(L10n.t('工具 schema', 'Tool schema'), _pretty(schema)),
                  if (widget.debug && item.rawData != null)
                    _code(L10n.t('原始事件', 'Raw event'), _pretty(item.rawData)),
                  ],
                ),
              ),
            ),
        ],
      );
    if (widget.flat) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: column,
      );
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: item.toolError
              ? Colors.redAccent.withValues(alpha: .5)
              : DshColors.line(context),
        ),
      ),
      child: column,
    );
  }
}

class _TimelineEventCard extends StatefulWidget {
  final _MsgItem item;
  final bool debug;
  final bool? expandedOverride;
  final ValueChanged<bool>? onExpandedOverride;
  final VoidCallback? onLoadDetail;
  final VoidCallback? onAutoLoadDetail;
  const _TimelineEventCard({
    super.key,
    required this.item,
    required this.debug,
    this.expandedOverride,
    this.onExpandedOverride,
    this.onLoadDetail,
    this.onAutoLoadDetail,
  });

  @override
  State<_TimelineEventCard> createState() => _TimelineEventCardState();
}

class _TimelineEventCardState extends State<_TimelineEventCard> {
  bool expanded = false;
  bool requested = false;
  bool userOverride = false;

  /// 原始事件预览缓存（v3.1.6，app-audit ①3）：上限 4000 字符 + 按对象身份缓存编码结果。
  Object? _rawFor = _noValue;
  String _rawCache = '';
  static const Object _noValue = Object();

  String get _rawPreview {
    final data = widget.item.rawData;
    if (identical(data, _rawFor)) return _rawCache;
    _rawFor = data;
    _rawCache = timelineDebugPreview(data);
    return _rawCache;
  }

  bool get _defaultExpanded => widget.debug && widget.item.toolError;

  @override
  void initState() {
    super.initState();
    expanded = widget.expandedOverride ?? _defaultExpanded;
    userOverride = widget.expandedOverride != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          expanded &&
          !requested &&
          widget.onAutoLoadDetail != null) {
        requested = true;
        widget.onAutoLoadDetail!();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _TimelineEventCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final override = widget.expandedOverride;
    userOverride = override != null;
    if (!userOverride &&
        (oldWidget.debug != widget.debug || widget.item.toolError)) {
      expanded = _defaultExpanded;
    }
    if (override != null && override != expanded) expanded = override;
    if (oldWidget.item.seq != widget.item.seq ||
        oldWidget.debug != widget.debug) {
      requested = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            expanded &&
            widget.onAutoLoadDetail != null &&
            !widget.item.detailLoading) {
          requested = true;
          widget.onAutoLoadDetail!();
        }
      });
    }
  }

  void _toggle(bool value) {
    userOverride = true;
    widget.onExpandedOverride?.call(value);
    setState(() => expanded = value);
    if (value && !requested && widget.onLoadDetail != null) {
      requested = true;
      widget.onLoadDetail!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: item.toolError
              ? Colors.redAccent.withValues(alpha: .5)
              : DshColors.line(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggle(!expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    item.toolError ? Icons.error_outline : Icons.bolt_outlined,
                    size: 15,
                    color: DshColors.ink3(context),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      item.text.split('\n').first,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (item.seq != null)
                    Text(
                      '#${item.seq}',
                      style: TextStyle(
                        fontSize: 10,
                        color: DshColors.ink3(context),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 17,
                    color: DshColors.ink3(context),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.text.contains('\n'))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        item.text.substring(item.text.indexOf('\n') + 1),
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  if (item.detailLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  if (item.detailDegraded)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        L10n.t(
                          '详情来自当前界面，可能不完整',
                          'Details came from the current surface and may be incomplete',
                        ),
                        style: TextStyle(fontSize: 11, color: Colors.orange),
                      ),
                    ),
                  if (item.detailErrorCode != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _detailErrorLabel(item.detailErrorCode!),
                        style: TextStyle(fontSize: 11, color: Colors.redAccent),
                      ),
                    ),
                  if (!item.detailAvailable && item.rawData == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        L10n.t('详情不可用', 'Details unavailable'),
                        style: TextStyle(
                          fontSize: 11,
                          color: DshColors.ink3(context),
                        ),
                      ),
                    ),
                  if (item.detailErrorCode != null &&
                      widget.onLoadDetail != null)
                    TextButton(
                      onPressed: () {
                        requested = false;
                        widget.onLoadDetail!();
                      },
                      child: Text(L10n.t('重试', 'Retry')),
                    ),
                  if (widget.debug && item.rawData != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText(
                        _rawPreview,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// v3.1.4（issue #12 姊妹需求）：任务清单面板（对齐 PC 端「任务」面板）——
/// 折叠态一行计数、展开态完整清单；数据来自内核 `dsh-tool-todo` 的 `todo/write` 快照。
class _TodoPanel extends StatelessWidget {
  final List<Map<String, dynamic>> todos;
  final bool collapsed;
  final int inProgress;
  final int pending;
  final int completed;
  final VoidCallback onToggle;
  const _TodoPanel({
    required this.todos,
    required this.collapsed,
    required this.inProgress,
    required this.pending,
    required this.completed,
    required this.onToggle,
  });

  IconData _statusIcon(Object? status) {
    switch (status) {
      case 'in_progress':
        return Icons.pending_outlined;
      case 'completed':
        return Icons.check_circle_outline;
      default:
        return Icons.radio_button_unchecked;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final brand = DshColors.brand(context);
    final summary = [
      if (inProgress > 0) L10n.t('$inProgress 进行中', '$inProgress in progress'),
      if (pending > 0) L10n.t('$pending 待处理', '$pending pending'),
      if (completed > 0) L10n.t('$completed 已完成', '$completed done'),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.checklist_rtl, size: 13, color: ink3),
                  const SizedBox(width: 5),
                  Text(
                    L10n.t('任务', 'Tasks'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: ink3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      summary,
                      style: TextStyle(fontSize: 11.5, color: ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 15,
                    color: ink3,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final todo in todos)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                _statusIcon(todo['status']),
                                size: 13,
                                color: todo['status'] == 'completed'
                                    ? ink3
                                    : brand,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${todo['content'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: todo['status'] == 'completed'
                                      ? ink3
                                      : ink2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Agent 气泡：Markdown 解析结果按文本缓存（流式时每次重建不重新解析，只解析增量）。
/// 携带思维链正文时，在正文上方渲染可折叠「思维链」块（默认展开状态由设置决定，单条可点按切换）。
class _AssistantBubble extends StatefulWidget {
  final String text;
  final Map<String, dynamic>? usage;
  final bool streaming;
  // v3.0.0 图像链路：附图元数据（渲染按 attachmentId 经 /attachment 拉取）
  final List<Map<String, dynamic>> images;
  final String sessionId;

  /// issue #69：附图拉取用 ChatScreen 注入的 Api（测试可计数/打桩，生产同全局单例）。
  final Api api;
  // 思维链正文（null/空 = 不渲染折叠块）
  final String? reasoning;
  // 设置项：思维链默认折叠还是展开
  final bool defaultExpanded;
  // 用户手动切换的覆盖值（null = 跟随设置项）；提升到界面层按消息持久化，列表回收重建不丢
  final bool? expandedOverride;
  final ValueChanged<bool>? onOverride;
  // issue #53 §6：行内代码 → 本轮记录内文件链接（null = 不可链接）。
  final InlineCodeTap? codeTap;

  /// 解析缓存附加键：记录集合变化（新交付声明/改动摘要到达）时强制重新解析。
  final String codeTapKey;
  final MarkdownImageLoader? imageLoader;
  final MarkdownImageUserAction? imageUserAction;
  const _AssistantBubble({
    required this.text,
    required this.api,
    this.usage,
    this.images = const [],
    this.sessionId = '',
    this.streaming = false,
    this.reasoning,
    this.defaultExpanded = false,
    this.expandedOverride,
    this.onOverride,
    this.codeTap,
    this.codeTapKey = '',
    this.imageLoader,
    this.imageUserAction,
  });

  @override
  State<_AssistantBubble> createState() => _AssistantBubbleState();
}

class _AssistantBubbleState extends State<_AssistantBubble> {
  String? _parsedFor;
  List<Widget>? _blocks;
  int _parseLogs = 0; // 排障：每个气泡实例最多记 3 次解析日志

  @override
  Widget build(BuildContext context) {
    // v2.9.0 review(M4)：缓存键含亮度——切深/浅色后已渲染气泡颜色需重建
    // （原仅按文本缓存 key,渲染颜色已烘焙进 Widget,切换主题不刷新）
    final cacheKey =
        '${widget.text}\u0000${Theme.of(context).brightness}\u0000${widget.codeTapKey}';
    if (cacheKey != _parsedFor) {
      _parsedFor = cacheKey;
      _blocks = renderMarkdownBlocks(
        widget.text.isEmpty ? '…' : widget.text,
        context,
        codeTap: widget.codeTap,
        imageLoader: widget.imageLoader,
        imageUserAction: widget.imageUserAction,
      );
      if (_parseLogs < 3) {
        _parseLogs++;
        AppLog.instance.log(
          'Chat: bubble 解析 len=${widget.text.length} blocks=${_blocks!.length}',
        );
      }
    }
    final ink3 = DshColors.ink3(context);
    final hasReasoning = (widget.reasoning ?? '').isNotEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '✦ Agent',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DshColors.ink2(context),
                  ),
                ),
                const SizedBox(width: 7),
                if (widget.streaming)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            if (hasReasoning) _buildReasoningChain(context),
            ..._blocks!,
            // v3.0.0 图像链路：附图（agent 回复里的图片，点击全屏）
            if (widget.images.isNotEmpty) ...[
              const SizedBox(height: 6),
              ImageGalleryGrid(
                images: widget.images,
                sessionId: widget.sessionId,
                api: widget.api,
              ),
            ],
            if (widget.usage != null &&
                ((widget.usage!['inputTokens'] as num? ?? 0) > 0 ||
                    (widget.usage!['outputTokens'] as num? ?? 0) > 0))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _fmtMsgUsage(widget.usage!),
                  style: TextStyle(fontSize: 10.5, color: ink3),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 可折叠「思维链」块：标题行（图标 + 字数 + 箭头）点按切换展开/收起，内容为斜体浅灰小字。
  Widget _buildReasoningChain(BuildContext context) {
    final expanded = widget.expandedOverride ?? widget.defaultExpanded;
    final reasoning = widget.reasoning ?? '';
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final brand = DshColors.brand(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: DshColors.brandSoft(context),
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => widget.onOverride?.call(!expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined, size: 15, color: brand),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      L10n.t(
                        '思维链 ${reasoning.length} 字',
                        'Thinking chain · ${reasoning.length} chars',
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: ink2,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: ink3,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SelectableText(
                reasoning,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: ink3,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _fmtMsgUsage(Map<String, dynamic> u) {
    final input = (u['inputTokens'] as num?)?.toInt() ?? 0;
    final read = (u['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final write = (u['cacheWriteTokens'] as num?)?.toInt() ?? 0;
    final out = (u['outputTokens'] as num?)?.toInt() ?? 0;
    final total = input + read + write;
    final hit = total > 0 ? ((read / total) * 100).round() : 0;
    return '↑${fmtTokens(input)} ↓${fmtTokens(out)} · ${L10n.t('缓存 ', 'cache ')}$hit%';
  }
}

/// 消息附件展示（issue #1 需求变更）：只显示文件名/类型/大小，**不提供下载**。
/// 工具与 assistant 产出的文件行已整体移除，这里只服务用户自己的附件。
class _FileResults extends StatelessWidget {
  final List<Map<String, dynamic>> files;
  const _FileResults({required this.files});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [for (final file in files) _FileResultTile(file: file)],
  );
}

class _FileResultTile extends StatelessWidget {
  final Map<String, dynamic> file;
  const _FileResultTile({required this.file});

  String get _label {
    final name = file['name']?.toString();
    if (name != null && name.isNotEmpty) return name;
    final path = file['path']?.toString();
    if (path != null && path.isNotEmpty) {
      return path.split(RegExp(r'[/\\]')).last;
    }
    return L10n.t('附件', 'Attachment');
  }

  @override
  Widget build(BuildContext context) {
    final mediaType = file['mediaType']?.toString();
    final sizeValue = file['size'];
    final size = sizeValue is num ? sizeValue.toInt() : null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: DshColors.surface(context),
          border: Border.all(color: DshColors.line(context)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 18),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (mediaType != null || size != null)
                    Text(
                      [
                        if (mediaType != null && mediaType.isNotEmpty)
                          mediaType,
                        if (size != null) '${(size / 1024).ceil()} KB',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 10,
                        color: DshColors.ink3(context),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v2.8.0：消息常驻操作栏（对齐 PC 端 MessageIconActions）——复制 / 好的回答 / 有问题的回答 / 在新对话中分支。
/// 小尺寸图标一行，置于消息气泡下方；逻辑经 onAction 回调复用 _runMessageAction。
/// 反馈选中态对齐 PC 端 data-active：品牌蓝图标 + 浅蓝圆底（positive/negative 同色，与 PC 一致）。
class _MessageActionsBar extends StatelessWidget {
  final _MsgItem item;
  final void Function(String action) onAction;
  /// issue #52：页脚内复用同一组操作图标（无 hover → 常显），间距由调用方决定。
  final EdgeInsetsGeometry padding;
  const _MessageActionsBar({
    required this.item,
    required this.onAction,
    this.padding = const EdgeInsets.only(left: 2, bottom: 14),
  });

  @override
  Widget build(BuildContext context) {
    final rating = item.rating;
    return Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionIcon(
            icon: Icons.content_copy,
            tooltip: L10n.t('复制', 'Copy'),
            onTap: () => onAction('copy'),
          ),
          _ActionIcon(
            icon: Icons.thumb_up_alt_outlined,
            active: rating == 'positive',
            tooltip: rating == 'positive'
                ? L10n.t(
                    '好的回答（已选，点此取消）',
                    'Good answer (selected, tap to clear)',
                  )
                : L10n.t('好的回答', 'Good answer'),
            onTap: () => onAction('positive'),
          ),
          _ActionIcon(
            icon: Icons.thumb_down_alt_outlined,
            active: rating == 'negative',
            tooltip: rating == 'negative'
                ? L10n.t(
                    '有问题的回答（已选，点此取消）',
                    'Bad answer (selected, tap to clear)',
                  )
                : L10n.t('有问题的回答', 'Bad answer'),
            onTap: () => onAction('negative'),
          ),
          _ActionIcon(
            icon: Icons.call_split,
            tooltip: L10n.t('在新对话中分支', 'Fork in a new chat'),
            onTap: () => onAction('fork'),
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  // v2.8.0：选中态（对齐 PC 端 data-active）= 品牌蓝图标 + 浅蓝圆底
  final bool active;
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final brandSoft = DshColors.brandSoft(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: active ? brandSoft : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 15,
            color: active ? brand : DshColors.ink3(context),
          ),
        ),
      ),
    );
  }
}

// ── issue #52：轮次过程的三层折叠控件 ──────────────────────────────

/// 整轮抬头：折叠时替代整个过程块的一行摘要；展开时兼作「收起」入口。
class _ProcessSummaryRow extends StatelessWidget {
  final String text;
  final bool expanded;

  /// 强制展开时为空：摘要不可点（避免「点了没反应」）。
  final VoidCallback? onTap;

  /// issue #74：该段（含分批隐藏行）工具结果图片数；0 时不渲染入口。
  final int imageCount;

  /// issue #74：点图片 chip 直接打开图库（与整行展开解耦）。
  final VoidCallback? onOpenImages;

  /// issue #76：该段工具失败数（仅 toolError/toolStatus=failed，不改轮次异常策略）。
  final int failureCount;
  const _ProcessSummaryRow({
    required this.text,
    required this.expanded,
    required this.onTap,
    this.imageCount = 0,
    this.onOpenImages,
    this.failureCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    final hasMeta = imageCount > 0 || failureCount > 0;
    final body = Padding(
      padding: EdgeInsets.fromLTRB(12, hasMeta ? 10 : 12, 12, hasMeta ? 8 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.account_tree_outlined, size: 16, color: ink2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                    color: ink,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
                color: onTap == null ? line : ink2,
              ),
            ],
          ),
          if (hasMeta)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (imageCount > 0 && onOpenImages != null)
                    _ImageCountChip(
                      count: imageCount,
                      onOpen: onOpenImages!,
                    ),
                  if (failureCount > 0) _FailureCountChip(count: failureCount),
                ],
              ),
            ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(DshTheme.radiusMd),
      ),
      child: onTap == null
          ? body
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(DshTheme.radiusMd),
              child: body,
            ),
    );
  }
}

/// issue #74：折叠层图片入口 chip（摘要行 / 组抬头 / 工具折叠行 / 分批行共用）。
///
/// 按 #76 设计规格 §4.5：`image_outlined` 12 + N 10.5/w600，底 brandSoft、高 24、
/// 圆角 6；独立命中区（32 高），点 chip 开图库、不触发所在行的折叠开关。
class _ImageCountChip extends StatelessWidget {
  final int count;
  final VoidCallback onOpen;

  const _ImageCountChip({required this.count, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink = DshColors.ink(context);
    final label = L10n.t('查看 $count 张图片', 'View $count images');
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 32,
            child: Center(
              child: Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: DshColors.brandSoft(context),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.image_outlined, size: 12, color: brand),
                    const SizedBox(width: 3),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// issue #76：失败计数 chip（整轮/组聚合，状态而非按钮；不改轮次异常策略）。
///
/// 24 高、H6、radius6、danger@8% 底；图标 danger，文字用 ink（小字不直接着 danger，
/// 保证对比度）。
class _FailureCountChip extends StatelessWidget {
  final int count;
  const _FailureCountChip({required this.count});

  @override
  Widget build(BuildContext context) {
    final danger = DshColors.danger(context);
    final ink = DshColors.ink(context);
    return Semantics(
      label: L10n.t('$count 个工具失败', '$count tools failed'),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 12, color: danger),
            const SizedBox(width: 4),
            Text(
              L10n.t('失败 $count', 'Failed $count'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 过程组抬头：运行中「正在调用工具…」，完成态「N 次工具调用」，不显示用时。
class _ProcessGroupHeader extends StatelessWidget {
  final String text;
  final bool expanded;
  final bool running;
  final VoidCallback onTap;

  /// issue #74：该组（含分批隐藏行）工具结果图片数；仅在组折叠时由调用方传入。
  final int imageCount;

  /// issue #74：点图片 chip 直接打开图库（不展开该组）。
  final VoidCallback? onOpenImages;

  /// issue #76：该组工具失败数（仅 toolError/failed，不自动展开、不改轮次异常策略）。
  final int failureCount;

  /// issue #76：仅思考组（#75）用 psychology 品牌图标，其余工具组用 ink2 工具图标。
  final bool reasoningOnly;
  const _ProcessGroupHeader({
    required this.text,
    required this.expanded,
    required this.running,
    required this.onTap,
    this.imageCount = 0,
    this.onOpenImages,
    this.failureCount = 0,
    this.reasoningOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final brand = DshColors.brand(context);
    final hasMeta = imageCount > 0 || failureCount > 0;
    final textScaler = MediaQuery.textScalerOf(context);
    final scale = textScaler.scale(13) / 13;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // issue #76：宽屏且未放大文字时徽标在右栏；窄屏/大字/实测装不下时
            // 徽标下移到文案左缘下一行，主行仍保留 chevron 与完整点击区。
            final narrow = constraints.maxWidth < 328 || scale > 1.2;
            final icon = running
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: brand,
                    ),
                  )
                : Icon(
                    reasoningOnly
                        ? Icons.psychology_outlined
                        : Icons.build_outlined,
                    size: 16,
                    color: reasoningOnly ? brand : ink2,
                  );
            final title = Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.45,
                color: ink,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            );
            final meta = Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (imageCount > 0 && onOpenImages != null)
                  _ImageCountChip(count: imageCount, onOpen: onOpenImages!),
                if (failureCount > 0) _FailureCountChip(count: failureCount),
              ],
            );
            final chevron = Icon(
              expanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 18,
              color: ink2,
            );
            final mainRow = Row(
              children: [
                icon,
                const SizedBox(width: 8),
                Expanded(child: title),
                if (hasMeta && !narrow) ...[
                  const SizedBox(width: 8),
                  meta,
                ],
                const SizedBox(width: 4),
                chevron,
              ],
            );
            if (!hasMeta || !narrow) {
              return Align(alignment: Alignment.centerLeft, child: mainRow);
            }
            return Align(
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  mainRow,
                  Padding(
                    padding: const EdgeInsets.only(left: 24, top: 4),
                    child: meta,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// issue #61：展开态过程块末尾的紧凑「收起过程」控件。
///
/// 行内样式（无卡片底色/边框），与 [_ProcessGroupHeader] 的文字/图标层级一致；
/// chevron 向上表示「点这里收起」。只在非强制展开的过程块出现。
class _CollapseProcessRow extends StatelessWidget {
  final VoidCallback onTap;
  const _CollapseProcessRow({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Container(height: 1, color: line),
        Align(
          alignment: Alignment.centerRight,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.unfold_less, size: 16, color: ink2),
                    const SizedBox(width: 4),
                    Text(
                      L10n.t('收起过程', 'Collapse process'),
                      style: TextStyle(fontSize: 12, color: ink2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 思维链过程行：折叠态保留一行预览，展开后显示全文（SelectableText，可复制）。
///
/// issue #70 起同一外观承载两种语义：
/// - 落定行（默认分叉）：收起态显示首行预览 / `思维链 N 字`，正文不设高度上限；
/// - provisional 行（[collapsedLabel] 非空）：收起态显示「思考中…」+ 最近一行预览，
///   展开态显示「思考中…（N 字）」+ 全文；正文 `maxHeight: 200` 内部滚动，不撑高消息流。
class _ReasoningProcessRow extends StatelessWidget {
  final String text;
  final int chars;
  final String preview;
  final bool expanded;
  final VoidCallback onToggle;

  /// 非空 = provisional 行：收起态标签（L10n「思考中…」/「Thinking…」）。
  final String? collapsedLabel;

  /// provisional 展开态标签（含字数）。
  final String? expandedLabel;

  /// 展开正文是否限制高度并内部滚动（provisional：true；落定行：false，保持现状）。
  final bool cappedBody;

  /// 行根节点 key（`provisional-reasoning-row:*` / `reasoning-row:*`，供测试断言唯一性）。
  final Key? rowKey;

  /// 展开正文滚动容器 key（`provisional-reasoning-body:*`）。
  final Key? bodyKey;

  const _ReasoningProcessRow({
    required this.text,
    required this.chars,
    required this.preview,
    required this.expanded,
    required this.onToggle,
    this.collapsedLabel,
    this.expandedLabel,
    this.cappedBody = false,
    this.rowKey,
    this.bodyKey,
  });

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final brand = DshColors.brand(context);
    final provisional = collapsedLabel != null;
    final settledLabel =
        L10n.t('思维链 $chars 字', 'Thinking chain · $chars chars');
    final label = expanded
        ? (expandedLabel ?? settledLabel)
        : (collapsedLabel ?? (preview.isEmpty ? settledLabel : preview));
    final showPreview = !expanded && provisional && preview.isNotEmpty;
    // issue #76：中文小字不用斜体；落定行正文与过程区统一 ink2。
    final bodyStyle = TextStyle(fontSize: 12, height: 1.6, color: ink2);
    final body = SelectableText(text, style: bodyStyle);
    final header = Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: provisional ? 10 : 0,
            vertical: 6,
          ),
          child: Row(
            children: [
              Icon(
                Icons.psychology_outlined,
                size: 16,
                color: brand,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: showPreview
                    ? Row(
                        children: [
                          Text(
                            collapsedLabel!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              preview,
                              style: TextStyle(fontSize: 12, color: ink2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              provisional ? FontWeight.w600 : FontWeight.w400,
                          color: ink2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
                color: ink2,
              ),
            ],
          ),
        ),
      ),
    );
    final bodyWidget = expanded && text.isNotEmpty
        ? Padding(
            padding: EdgeInsets.fromLTRB(provisional ? 10 : 24, 0, 0, 6),
            child: cappedBody
                // issue #70 裁决 D1：展开正文不撑高消息流（与活动条内容面板同口径）。
                ? ConstrainedBox(
                    key: bodyKey,
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: SingleChildScrollView(child: body),
                  )
                : body,
          )
        : null;
    if (!provisional) {
      // issue #76：落定思考行平铺（无卡片/底色/边框），只有展开正文。
      return Column(
        key: rowKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          ?bodyWidget,
        ],
      );
    }
    return Container(
      key: rowKey,
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: DshColors.brandSoft(context),
        borderRadius: BorderRadius.circular(DshTheme.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          ?bodyWidget,
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// issue #97：斜杠 token 的正式配色（设计 note 2541）。
///
/// 命令蓝/技能绿在浅色下用深色文字保证对比度；深色改用浅色文字 + 深色 chip 底。
class _SlashPalette {
  const _SlashPalette._();

  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  // 最终角色映射（#90/#97 复核后交换）：命令=绿、技能=蓝。
  static Color commandText(BuildContext context) =>
      _dark(context) ? const Color(0xFF7ED9A8) : const Color(0xFF1F7A46);
  static Color commandChipBg(BuildContext context) =>
      _dark(context) ? const Color(0xFF12301F) : const Color(0xFFE6F7EC);
  static Color commandChipBorder(BuildContext context) =>
      _dark(context) ? const Color(0xFF1F4D32) : const Color(0xFFBDE8CD);

  static Color skillText(BuildContext context) =>
      _dark(context) ? const Color(0xFF8FA8FF) : const Color(0xFF2A54F0);
  static Color skillChipBg(BuildContext context) =>
      _dark(context) ? const Color(0xFF1B2747) : const Color(0xFFE9EEFF);
  static Color skillChipBorder(BuildContext context) =>
      _dark(context) ? const Color(0xFF31436E) : const Color(0xFFC7D2FF);
}

/// issue #97：输入框编辑态 token 高亮。
///
/// 只改 `buildTextSpan` 的显示样式，**不重建/修改 TextEditingValue**：原文、光标、选区、
/// 复制、清空、粘贴都保持系统默认语义。IME 组合区按 `withComposing` 保留系统下划线。
class _SlashHighlightController extends TextEditingController {
  Set<String> commandNames = const <String>{};
  Set<String> skillNames = const <String>{};

  /// 目录晚到时刷新高亮；不在外部直接调用受保护的 notifyListeners。
  void setCatalogs(Set<String> commands, Set<String> skills) {
    if (setEquals(commandNames, commands) && setEquals(skillNames, skills)) {
      return;
    }
    commandNames = commands;
    skillNames = skills;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    final tokens = slashTextTokens(text);
    if (tokens.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final commands = commandNames;
    final skills = skillNames;
    bool known(SlashTextToken token) =>
        commands.contains(token.name) ||
        (!commands.contains(token.name) && skills.contains(token.name));
    final knownTokens = tokens.where(known).toList(growable: false);
    if (knownTokens.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final composing = value.composing;
    final hasComposing =
        withComposing && composing.isValid && !composing.isCollapsed;
    // 以 token 边界 + 组合区边界切段，逐段应用样式；组合区优先保留下划线。
    final boundaries = <int>{0, text.length};
    for (final token in knownTokens) {
      boundaries.add(token.start);
      boundaries.add(token.end);
    }
    if (hasComposing) {
      boundaries.add(composing.start.clamp(0, text.length));
      boundaries.add(composing.end.clamp(0, text.length));
    }
    final sorted = boundaries.toList()..sort();
    final children = <InlineSpan>[];
    for (var index = 0; index + 1 < sorted.length; index += 1) {
      final start = sorted[index];
      final end = sorted[index + 1];
      if (start >= end) continue;
      final token = knownTokens
          .where((item) => item.start <= start && end <= item.end)
          .firstOrNull;
      final composingHere = hasComposing &&
          composing.start < end &&
          composing.end > start;
      if (token == null && !composingHere) {
        children.add(TextSpan(text: text.substring(start, end), style: base));
        continue;
      }
      final isCommand = token != null && commands.contains(token.name);
      final tokenStyle = token == null
          ? base
          : base.copyWith(
              color: isCommand
                  ? _SlashPalette.commandText(context)
                  : _SlashPalette.skillText(context),
              backgroundColor: isCommand
                  ? _SlashPalette.commandChipBg(context)
                  : _SlashPalette.skillChipBg(context),
            );
      children.add(TextSpan(
        text: text.substring(start, end),
        style: composingHere
            ? tokenStyle.copyWith(decoration: TextDecoration.underline)
            : tokenStyle,
      ));
    }
    return TextSpan(style: base, children: children);
  }
}

/// 活动条：agent 当前在干什么（思考中 / 工具执行中）。
/// 思考面板可展开看实时思考内容（仅 showContent 时）；工具执行结束即消失；正文流式开始后由文字本身反馈。
/// issue #90：用户气泡内联斜杠 chip（不可点、不额外语义；命令/技能不同配色）。
class _SlashInlineChip extends StatelessWidget {
  final String name;
  final bool skill;
  const _SlashInlineChip({required this.name, required this.skill});

  @override
  Widget build(BuildContext context) {
    // issue #97：命令蓝/技能绿正式 token（浅色深字、深色浅字 + chip 底/边）。
    final color = skill
        ? _SlashPalette.skillText(context)
        : _SlashPalette.commandText(context);
    final background = skill
        ? _SlashPalette.skillChipBg(context)
        : _SlashPalette.commandChipBg(context);
    final border = skill
        ? _SlashPalette.skillChipBorder(context)
        : _SlashPalette.commandChipBorder(context);
    return Container(
      key: Key('slash-chip-${skill ? 'skill' : 'command'}-$name'),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border, width: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            skill ? Icons.auto_awesome : Icons.terminal,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                '/$name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, height: 1.3, color: color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityBar extends StatelessWidget {
  final String reasoning;
  final bool expanded;
  final bool textStreaming;
  final bool showContent; // 是否显示思考内容原文（默认关：只显示状态，思考原文多为英文）
  final List<String> tools;
  final VoidCallback onToggleReasoning;
  const _ActivityBar({
    required this.reasoning,
    required this.expanded,
    required this.textStreaming,
    required this.showContent,
    required this.tools,
    required this.onToggleReasoning,
  });

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final surface = DshColors.surface(context);
    final brand = DshColors.brand(context);
    final toolLabel = tools.isEmpty
        ? ''
        : (tools.length > 1
              ? L10n.t(
                  '正在执行 ${tools.length} 个工具（${tools.take(2).join('、')}${tools.length > 2 ? '…' : ''}）',
                  'Running ${tools.length} tools (${tools.take(2).join('、')}${tools.length > 2 ? '…' : ''})',
                )
              : '${L10n.t('正在调用 ', 'Calling ')}${tools.first}…');
    final thinking = !textStreaming;
    final header = expanded
        ? (thinking
              ? L10n.t('思考中，点此收起', 'Thinking — tap to collapse')
              : L10n.t('思考内容，点此收起', 'Thinking content — tap to collapse'))
        : (thinking
              ? L10n.t(
                  '思考中…（${reasoning.length} 字）',
                  'Thinking… (${reasoning.length} chars)',
                )
              : L10n.t(
                  '已思考 ${reasoning.length} 字',
                  'Thought: ${reasoning.length} chars',
                ));
    return Container(
      key: const ValueKey<String>('activity-bar'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reasoning.isNotEmpty)
            InkWell(
              key: const ValueKey<String>('activity-bar-thinking'),
              onTap: showContent ? onToggleReasoning : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.psychology_outlined, size: 16, color: brand),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        header,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: ink2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showContent)
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: ink3,
                      ),
                  ],
                ),
              ),
            ),
          if (showContent && expanded && reasoning.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText(
                  reasoning,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.55,
                    color: ink3,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ),
          if (tools.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: reasoning.isNotEmpty ? 4 : 0),
              child: Row(
                key: const ValueKey<String>('activity-bar-tools'),
                children: [
                  Icon(Icons.handyman_outlined, size: 15, color: ink2),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      toolLabel,
                      style: TextStyle(fontSize: 12.5, color: ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// v2.7：进行中任务卡片（活动条下方；运行中的后台任务实时状态，点击进工具弹层）。
/// v2.8.0：后台任务卡片——移到对话框顶部、可收纳（默认收起成一行，点标题展开/收起）、
/// 精简为单任务行 + 计数，避免底部弹窗堆叠与卡片过大。
class _JobCard extends StatefulWidget {
  final List<Map<String, dynamic>> jobs;
  final VoidCallback onOpen;
  final void Function(String jobId) onKill;
  const _JobCard({
    required this.jobs,
    required this.onOpen,
    required this.onKill,
  });

  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final surface = DshColors.surface(context);
    final running = widget.jobs
        .where((j) => j['status'] == 'running' || j['status'] == 'stopping')
        .toList();
    final extra = running.length - 1;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  Icon(Icons.hourglass_top_outlined, size: 14, color: brand),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      running.length > 1
                          ? L10n.t(
                              '后台任务 ${running.length} 个进行中',
                              '${running.length} background tasks running',
                            )
                          : L10n.t('后台任务进行中', 'Background task running'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: ink2,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: ink3,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            for (final j in running.take(2))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 6, color: brand),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        (j['label'] as String? ??
                                j['id'] as String? ??
                                L10n.t('任务', 'Task'))
                            .toString(),
                        style: const TextStyle(fontSize: 11.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: j['status'] == 'stopping'
                          ? null
                          : () => widget.onKill(j['id'] as String? ?? ''),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 24),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        j['status'] == 'stopping'
                            ? L10n.t('停止中', 'Stopping')
                            : L10n.t('取消', 'Cancel'),
                        style: TextStyle(
                          fontSize: 11,
                          color: j['status'] == 'stopping'
                              ? ink3
                              : DshColors.danger(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          if (_expanded && extra > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: widget.onOpen,
                borderRadius: BorderRadius.circular(6),
                child: Text(
                  L10n.t('还有 $extra 个任务 ▸', '$extra more tasks ▸'),
                  style: TextStyle(fontSize: 11, color: brand),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final String status;
  const _StatusDot({required this.status});
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'running' => DshColors.ok(context),
      // 内核 AgentStatus 只有 idle/running（ADR 0013）；等待用户在列表页另有标识，
      // 这里不再保留 v2.1 的防御性 'waiting' 分支（内核从未产生过该取值）。
      _ => DshColors.ink3(context),
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// live 列表视觉顶部的"查看更早"入口。
class _OlderButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _OlderButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: onTap,
                icon: const Icon(Icons.history, size: 16),
                label: Text(
                  L10n.t('查看更早的消息', 'View earlier messages'),
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
      ),
    );
  }
}

/// 上翻后浮于消息流右下角（输入框正上方）的"回到底部"圆钮：
/// 灰白浅色调、向下箭头、带描边与轻阴影；淡入淡出，隐藏时不可点击。
class _JumpToLatestButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _JumpToLatestButton({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.white.withValues(alpha: 0.88);
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: IgnorePointer(
        ignoring: !visible,
        child: Material(
          color: bg,
          shape: CircleBorder(
            side: BorderSide(color: DshColors.line(context), width: 0.8),
          ),
          elevation: 2,
          shadowColor: Colors.black26,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: jumpToLatestSize,
              height: jumpToLatestSize,
              child: Icon(
                Icons.keyboard_arrow_down,
                size: 24,
                color: DshColors.ink2(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 上下文窗口占用圆环（对齐 PC 端）：绿色 <70%，橙色 <90%，红色 ≥90%。
class _ContextRing extends StatelessWidget {
  final double ratio;
  const _ContextRing({required this.ratio});

  @override
  Widget build(BuildContext context) {
    final color = ratio < 0.7
        ? DshColors.ok(context)
        : ratio < 0.9
        ? DshColors.warn(context)
        : DshColors.danger(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            value: ratio,
            strokeWidth: 2,
            backgroundColor: DshColors.line(context),
            color: color,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '${(ratio * 100).round()}%',
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Pill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final line = DshColors.line(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: line,
          borderRadius: BorderRadius.circular(999),
        ),
        // v2.8.0 review(P1-2)：单行 + 省略号，避免长模型名撑爆胶囊行（旧 ListView 可滚、Row 不可）
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: ink2,
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final Map<String, dynamic> action;
  final VoidCallback onTap;
  const _ActionChip({required this.action, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final surface = DshColors.surface(context);
    final line = DshColors.line(context);
    final ink = DshColors.ink(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          action['title'] as String? ?? '',
          style: TextStyle(fontSize: 12.5, color: ink),
        ),
      ),
    );
  }
}

/// 内核问询弹窗卡片：问题 + 选项（单选/多选）+ 「输入其他答案」自由输入 + 提交/取消。
/// 挂在消息流与输入框之间（思考中途需要用户拍板时出现）。
class _QuestionCard extends StatefulWidget {
  final QuestionRequest request;
  final VoidCallback onCancel;
  final Future<void> Function(List<Map<String, dynamic>> answers) onSubmitted;
  // v3.1.6（app-audit ①5）：支持 key——聊天页按 rpcId 传 ValueKey，换问询时强制新建 State
  const _QuestionCard({
    super.key,
    required this.request,
    required this.onCancel,
    required this.onSubmitted,
  });

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final Map<String, Set<String>> _selected = {}; // questionId -> 选项 label 集合
  final Map<String, String> _custom = {}; // questionId -> 自定义输入
  final Map<String, TextEditingController> _ctrls = {};
  bool _submitting = false;
  String? _hint; // 校验提示

  @override
  void initState() {
    super.initState();
    for (final q in widget.request.questions) {
      _selected[q.id] = {};
      _custom[q.id] = '';
      _ctrls[q.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggle(AskQuestion q, String label) {
    setState(() {
      final sel = _selected[q.id]!;
      if (q.multiSelect) {
        if (!sel.add(label)) sel.remove(label);
      } else {
        if (sel.contains(label)) {
          sel.clear();
        } else {
          sel
            ..clear()
            ..add(label);
        }
      }
      // 单选语义：选了选项就清掉自定义输入（内核要求二选一）
      if (!q.multiSelect && sel.isNotEmpty) {
        _custom[q.id] = '';
        _ctrls[q.id]!.clear();
      }
      _hint = null;
    });
  }

  void _onCustom(AskQuestion q, String v) {
    setState(() {
      _custom[q.id] = v;
      // 单选语义：输入了自定义答案就清掉选项
      if (!q.multiSelect && v.trim().isNotEmpty) _selected[q.id]!.clear();
      _hint = null;
    });
  }

  Future<void> _submit() async {
    final answers = <Map<String, dynamic>>[];
    for (final q in widget.request.questions) {
      final sel = _selected[q.id] ?? const <String>{};
      final custom = (_custom[q.id] ?? '').trim();
      if (custom.isEmpty && sel.isEmpty) {
        setState(
          () => _hint = L10n.t(
            '请选择选项，或输入其他答案',
            'Choose an option or type another answer',
          ),
        );
        return;
      }
      answers.add({
        'id': q.id,
        'selected': custom.isEmpty ? sel.toList() : const <String>[],
        if (custom.isNotEmpty) 'custom': custom,
      });
    }
    setState(() => _submitting = true);
    try {
      await widget.onSubmitted(answers);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final brandSoft = DshColors.brandSoft(context);
    final header = widget.request.questions.isEmpty
        ? null
        : widget.request.questions.first.header;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: brandSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: brand.withValues(alpha: 0.55)),
      ),
      child: ConstrainedBox(
        // 问询卡片封顶 40% 屏高：问题说明长/选项多时卡片内滚动，不把输入框挤出屏幕
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.4,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.live_help_outlined, size: 18, color: brand),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      header ?? L10n.t('需要你决定', 'Your input needed'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: brand,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _submitting ? null : widget.onCancel,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: ink3),
                    ),
                  ),
                ],
              ),
              for (final q in widget.request.questions) ...[
                if (q.detail != null && q.detail!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 2),
                    child: Text(
                      q.detail!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ink3,
                        height: 1.4,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(
                    q.question,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final o in q.options)
                  _OptionTile(
                    label: o.label,
                    description: o.description,
                    multi: q.multiSelect,
                    selected: _selected[q.id]!.contains(o.label),
                    onTap: () => _toggle(q, o.label),
                  ),
                const SizedBox(height: 2),
                TextField(
                  controller: _ctrls[q.id],
                  onChanged: (v) => _onCustom(q, v),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: q.multiSelect
                        ? L10n.t('补充说明（可选）…', 'Add details (optional)…')
                        : L10n.t('或输入其他答案…', 'Or type another answer…'),
                    hintStyle: TextStyle(fontSize: 13, color: ink3),
                    filled: true,
                    fillColor: DshColors.surface(context),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: line),
                    ),
                  ),
                ),
              ],
              if (_hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _hint!,
                    style: TextStyle(
                      fontSize: 12,
                      color: DshColors.danger(context),
                    ),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting ? null : widget.onCancel,
                    child: Text(
                      L10n.t('取消', 'Cancel'),
                      style: TextStyle(fontSize: 13.5, color: ink2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      backgroundColor: brand,
                    ),
                    onPressed: _submitting ? null : _submit,
                    child: Text(
                      _submitting
                          ? L10n.t('提交中…', 'Submitting…')
                          : L10n.t('提交', 'Submit'),
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final String label;
  final String? description;
  final bool multi;
  final bool selected;
  final VoidCallback onTap;
  const _OptionTile({
    required this.label,
    this.description,
    required this.multi,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink3 = DshColors.ink3(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              multi
                  ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
                  : (selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
              size: 18,
              color: brand,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (description != null && description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        description!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: ink3,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内核权限审批弹窗卡片：工具名 + 原因 + 允许一次 / 拒绝。
class _ApprovalCard extends StatefulWidget {
  final ApprovalRequest request;
  final Future<void> Function(String outcome) onDecide;
  final VoidCallback onCancel;
  const _ApprovalCard({
    required this.request,
    required this.onDecide,
    required this.onCancel,
  });

  @override
  State<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<_ApprovalCard> {
  bool _busy = false;

  Future<void> _decide(String outcome) async {
    setState(() => _busy = true);
    try {
      await widget.onDecide(outcome);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final warn = DshColors.warn(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final danger = DshColors.danger(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: warn.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.admin_panel_settings_outlined, size: 18, color: warn),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  L10n.t('权限请求', 'Permission request'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: warn,
                  ),
                ),
              ),
              InkWell(
                onTap: _busy ? null : widget.onCancel,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: ink3),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              L10n.t(
                '工具「${widget.request.toolName}」需要你的授权',
                'Tool “${widget.request.toolName}” needs your authorization',
              ),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (widget.request.reason != null &&
              widget.request.reason!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.request.reason!,
                style: TextStyle(fontSize: 12.5, color: ink2, height: 1.45),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => _decide('rejected'),
                child: Text(
                  L10n.t('拒绝', 'Deny'),
                  style: TextStyle(fontSize: 13.5, color: danger),
                ),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  backgroundColor: warn,
                ),
                onPressed: _busy ? null : () => _decide('allowed-once'),
                child: Text(
                  _busy
                      ? L10n.t('处理中…', 'Processing…')
                      : L10n.t('允许一次', 'Allow once'),
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── issue #52：过程块渲染计划（结构变化时重建一次，每帧只查表） ─────────────

/// issue #70：仅在渲染层使用的 provisional 定位信息（不可变，不污染纯模型）。
///
/// [orderSeq] = 该 (turn, step) 首个 reasoning delta 的 seq：与落定后持久行的排序键
/// 完全相同，因此「工具先到 → 追加其后」与「思考先到 → 不被工具挤到后面」同时成立，
/// 且落定瞬间不跳位。
class _ProvisionalSlot {
  final int turn;
  final int? step;
  final int orderSeq;

  const _ProvisionalSlot({
    required this.turn,
    required this.step,
    required this.orderSeq,
  });
}

/// 单个过程段在某条目处渲染的计划。
class _ProcessBlockPlan {
  final TurnProcess process;
  final int segmentIndex;
  final ProcessSegment segment;
  final bool expanded;
  final bool grouping;
  final String intervalKey;
  final bool isLastSegmentOfTurn;
  final int hiddenTotalInTurn;
  final Set<int> visibleRowSeqs;

  /// issue #74：该轮分批后真正可见的过程行 seq（与 `visibleRowSeqs` 的段内视图区分），
  /// 用于把「被分批隐藏的行」里的图片聚合到「显示更多」入口上。
  final Set<int> turnVisibleRowSeqs;
  final bool liveProcessDetail;
  final bool historyView;

  /// issue #70：该段要注入的 provisional（仅运行中最后一段可见时非空）。
  final _ProvisionalSlot? provisional;

  const _ProcessBlockPlan({
    required this.process,
    required this.segmentIndex,
    required this.segment,
    required this.expanded,
    required this.grouping,
    required this.intervalKey,
    required this.isLastSegmentOfTurn,
    required this.hiddenTotalInTurn,
    required this.visibleRowSeqs,
    required this.turnVisibleRowSeqs,
    required this.liveProcessDetail,
    required this.historyView,
    this.provisional,
  });

  _ProcessBlockPlan copyWith({int? hiddenTotalInTurn}) => _ProcessBlockPlan(
        process: process,
        segmentIndex: segmentIndex,
        segment: segment,
        expanded: expanded,
        grouping: grouping,
        intervalKey: intervalKey,
        isLastSegmentOfTurn: isLastSegmentOfTurn,
        hiddenTotalInTurn: hiddenTotalInTurn ?? this.hiddenTotalInTurn,
        visibleRowSeqs: visibleRowSeqs,
        turnVisibleRowSeqs: turnVisibleRowSeqs,
        liveProcessDetail: liveProcessDetail,
        historyView: historyView,
        provisional: provisional,
      );
}

/// 一棵时间线列表的完整过程渲染计划。
class _ProcessPlan {
  /// 该计划对应的过程折叠版本（live/历史分段各存各的，互不失效误判）。
  final int processVersion;

  /// 折叠状态/分批/设置变化版本。
  final int epoch;
  final Map<int, List<_ProcessBlockPlan>> hostsBySeq;
  final Set<String> renderedCallIds;

  /// issue #84：真正渲染进可见过程块（展开段 + 展开组 + 未被分批隐藏）的工具 callId。
  ///
  /// 活动条只用它去重——`renderedCallIds` 包含被折叠/分批隐藏的行，会造成
  /// 「活动条消失但界面上看不到该运行工具」的回归。
  final Set<String> visibleToolCallIds;
  final Set<int> anchoredTurns;

  /// 该轮最后一条助手消息的 seq（渲染时再从当前列表取对象，见 `_currentAssistantItem`）。
  final Map<int, int> assistantSeqByTurn;

  /// issue #70：该计划是否真的在过程块里注入了 provisional（活动条据此去重）。
  final bool provisionalRendered;

  /// issue #70：当前流式轮次的可见过程块里是否已有 reasoning 行（provisional 或落定）。
  /// 活动条只显示工具/状态，不再重复思考文本。
  final bool reasoningRowVisible;

  const _ProcessPlan({
    required this.processVersion,
    required this.epoch,
    required this.hostsBySeq,
    required this.renderedCallIds,
    required this.visibleToolCallIds,
    required this.anchoredTurns,
    required this.assistantSeqByTurn,
    this.provisionalRendered = false,
    this.reasoningRowVisible = false,
  });
}
