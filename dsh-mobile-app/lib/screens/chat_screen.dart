// 对话页：消息流（Markdown/流式/工具折叠/token 用量）+ 上翻加载 + 快捷动作 + composer
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../toast.dart';
import '../api.dart';
import '../chat_copy.dart';
import '../logger.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import '../timeline.dart';
import '../theme.dart';
import '../md.dart';
import '../fmt.dart';
import 'sheets.dart';
import 'session_tools_sheet.dart';

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
      'method-not-allowed' =>
        true,
      _ => false,
    };

/// v3.0.0(热修 07)：发送异常后的草稿恢复决策——仅当输入框仍为空（本次发送清空后的预期
/// 状态）才回填旧草稿；发送期间用户输入的新内容一律保留（绝不覆盖，见 Codex review）。
String draftAfterFailure(String current, String fallback) =>
    current.trim().isEmpty ? fallback : current;

/// v3.0.0(热修 07)：草稿签名——会话 + 最终生效模式 + 文本 + 图片路径；任一变化即换新
/// requestId（例：排队发送结果未知后改用插队 → 新 requestId → 插队真正执行而非回放旧结果）。
String composerSignature(String sessionId, String mode, String text, List<String> imagePaths) =>
    '$sessionId|$mode|$text|${imagePaths.join(',')}';

/// v3.1.4（issue #13 排查建议 3）：轮次结束时是否需要**兜底补拉**——
/// 本轮出现过真人提问（lastUserSeq 非空），但没有渲染出更晚的回复条目
/// （lastAssistantSeq 为空或早于提问）→ 判定内容被静默吞掉，补拉一次历史。
/// 纯函数便于单测：见 test/issue13_logic_test.dart。
bool needsTurnEndResync({int? lastUserSeq, int? lastAssistantSeq}) =>
    lastUserSeq != null && (lastAssistantSeq == null || lastAssistantSeq <= lastUserSeq);

/// 是否应由本次滚动通知触发“加载更早”。抽出为纯判定，避免 ScrollStart/ScrollEnd
/// 在列表已位于顶部时重复触发异步分页。
bool shouldLoadOlderFromScroll(ScrollNotification notification, {required bool infiniteMode}) {
  if (!infiniteMode || !notification.metrics.hasContentDimensions) return false;
  if (notification.depth != 0) return false;
  if (notification.metrics.axis != Axis.vertical) return false;
  // ScrollStart/ScrollEnd/UserScroll 在 pixels=0 时也会冒泡；异步分页若在 start 时
  // 启动、在 end 前完成，end 会立刻再触发一页。只响应真正向顶部发生的位移更新。
  final distanceToLeadingEdge = notification.metrics.pixels - notification.metrics.minScrollExtent;
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
Future<void> openChat(BuildContext context, AppStore store, String sessionId,
    {VoidCallback? onTitleChanged, Future<void> Function()? onReturn}) async {
  await store.setSession(sessionId);
  store.refreshSessionConfig();
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ChatScreen(store: store, onTitleChanged: onTitleChanged ?? () {}),
    ),
  );
  if (onReturn != null) await onReturn();
}

class ChatScreen extends StatefulWidget {
  final AppStore store;
  final String? initialSend; // 首页直达发送
  final VoidCallback onTitleChanged;
  final Api? apiClient;
  const ChatScreen({super.key, required this.store, this.initialSend, required this.onTitleChanged, this.apiClient});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  static const _liveCenterKey = ValueKey<String>('chat-live-center');
  // live 视图：最新在前（普通列表渲染时倒序，最新位于列表底部）
  final List<_MsgItem> _items = [];
  // 无限上翻时放在 center 之前的旧消息，按“距 center 近→远”排列（新→旧）。
  // 新分页追加到尾部，已有 child index 不变，CustomScrollView.center 可保持锚点。
  final List<_MsgItem> _olderItems = [];
  // 活动条状态：执行中的工具（callId -> 工具名）+ 思考累积文本
  final Map<String, String> _activeTools = {};
  // Shared pure projection owns seq de-duplication/call correlation for both live and history paths;
  // _MsgItem remains the richer Flutter rendering adapter.
  final TimelineReducer _timelineReducer = TimelineReducer();
  final Map<String, bool> _failureExpansionOverrides = {};
  final Set<String> _failureDetailRequests = {};
  String _reasoning = '';
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
  Api get _api => widget.apiClient ?? api;
  String get _pageAgentStatus => widget.store.agentStatusForSession(_mySessionId);
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
  bool _showJumpToLatest = false; // 上翻后显示"回到底部"浮钮
  bool _pinnedToBottom = true; // 用户是否停留在最新（底部）：流式输出时据此决定是否自动跟随
  QuestionRequest? _question; // 内核问询弹窗（当前会话，思考中途需要拍板）
  ApprovalRequest? _approval; // 内核权限审批弹窗（当前会话）
  final Set<String> _transientFrameKeys = {}; // mobile/frame 无 durable seq，按业务 id 去重
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
  bool _pickingImages = false; // 选图在途锁（相册多选期间防重复触发）

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
    _question = widget.store.questionForSession(_mySessionId);
    _approval = widget.store.approvalForSession(_mySessionId);
    _queue = widget.store.queueOf(_mySessionId ?? ''); // v3.0.0：初始即取镜像快照（帧/缓存）
    widget.store.addChatListener(_handleEvent); // v2.7.2 review(M1)：监听器列表，叠层页面互不覆盖
    _scrollCtrl.addListener(_onScrollTick);
    _load();
    // v2.7：恢复该会话上次未发送的输入草稿
    final sid = _mySessionId;
    if (sid != null) {
      final draft = widget.store.draftOf(sid);
      if (draft.isNotEmpty) _inputCtrl.text = draft;
    }
    _inputCtrl.addListener(_onDraftChanged);
    if (widget.initialSend != null && widget.initialSend!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(widget.initialSend!));
    }
  }

  /// v2.7：输入变化 → 按会话保存草稿（返回/重进后恢复；清空即移除）。
  /// v2.7.2(B 方案)：输入变化同时刷新「排队发送」胶囊的显隐。
  void _onDraftChanged() {
    final sid = _mySessionId;
    if (sid != null) widget.store.saveDraft(sid, _inputCtrl.text);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _activityTimer?.cancel();
    _queueRefreshTimer?.cancel();
    _queuePollTimer?.cancel();
    _queueEditCtrl.dispose();
    _inputCtrl.removeListener(_onDraftChanged);
    _scrollCtrl.removeListener(_onScrollTick);
    widget.store.removeChatListener(_handleEvent); // v2.7.2 review(M1)
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 滚动监听：上翻超过阈值显示"回到底部"浮钮，回到最新位置时隐藏。
  /// v2.8.0：live 视图统一普通（非 reverse）列表，"最新"恒在 maxScrollExtent。
  void _onScrollTick() {
    if (!mounted || _inHistory) return;
    final pos = _scrollCtrl.position;
    if (!pos.hasContentDimensions) return;
    // 距底部 160px 内视为「停留最新」：同步钉住状态 + 回到底部按钮显隐
    final nearBottom = pos.maxScrollExtent - pos.pixels <= 160;
    if (nearBottom != _pinnedToBottom) {
      _pinnedToBottom = nearBottom;
    }
    if (!nearBottom != _showJumpToLatest) {
      setState(() => _showJumpToLatest = !nearBottom);
    }
  }

  /// 一键回到最新消息：近距平滑滚动，远距直接跳（避免超长距离动画卡顿）。
  void _jumpToLatest() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final target = pos.maxScrollExtent;
    AppLog.instance.log('Chat: 回到底部 pixels=${pos.pixels.toStringAsFixed(0)} target=${target.toStringAsFixed(0)}');
    if ((pos.pixels - target).abs() > 4000) {
      _scrollCtrl.jumpTo(target);
    } else {
      _scrollCtrl.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  /// 提交问询答案（answers 顺序与提问一致），失败时弹窗保留可重试。
  Future<void> _submitQuestion(List<Map<String, dynamic>> answers) async {
    final q = _question;
    if (q == null) return;
    AppLog.instance.log('Chat: 回答问询 ${q.rpcId}（${answers.length} 问）');
    final err = await widget.store.answerQuestion(q.rpcId, q.sessionId, answers);
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
    final err = await widget.store.answerApproval(a.rpcId, a.sessionId, a.approvalId, outcome);
    if (!mounted) return;
    if (err != null) {
      showToast(context, err);
    } else {
      setState(() => _approval = null);
    }
  }

  /// 滚动到最新消息。live 视图为普通（非 reverse）列表，"最新"在 maxScrollExtent；
  /// 历史浏览视图不跟随滚动。
  void _scrollToBottom({bool force = false}) {
    if (_inHistory) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      final target = pos.maxScrollExtent;
      if (force || !_scrolledLogged) {
        _scrolledLogged = true;
        AppLog.instance.log('Chat: 滚动${force ? "(force)" : ""} pixels=${pos.pixels.toStringAsFixed(0)} max=${pos.maxScrollExtent.toStringAsFixed(0)} target=${target.toStringAsFixed(0)}');
      }
      // force（加载完成/发送/回到底部）；或用户停留在底部（钉住）——流式输出期间
      // 持续跟随到最新。按「钉住」状态判断而非与新 maxScrollExtent 比距离，
      // 避免大段 chunk 单帧推高内容后 220px 判定失效、输出掉出屏幕。
      if (force || _pinnedToBottom) {
        _pinnedToBottom = true;
        _scrollCtrl.jumpTo(target);
      }
    });
  }

  /// 流式草稿节流：chunk 到达只累加文本，定时（~80ms）合并刷新一次。
  void _scheduleDraftFlush() {
    _streaming = true;
    _draftTimer ??= Timer(const Duration(milliseconds: 80), () {
      _draftTimer = null;
      if (mounted) setState(() {});
      _scrollToBottom();
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
      final events = page.events;
      // 打开/重同步会话时以本次响应为准（赋值，而非 |=）：避免上一条会话的「仅部分历史」
      // 横幅残留到正常会话。后续增量分页（after/before）仍用 |=：任一页降级即持续提示。
      _historyDegraded = page.degraded;
      AppLog.instance.log('Chat: 历史加载成功 ${events.length} 条${reset ? '（重同步）' : ''}');
      if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
      setState(() {
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
        _timelineReducer.reset();
        _transientFrameKeys.clear();
        _activeTools.clear();
        _reasoning = '';
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
            foldedTodos = ((ev.data?['todos'] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();
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
          } else if (ev.type == 'assistant/message' && ((ev.data?['text'] as String?) ?? '').trim().isNotEmpty) {
            _lastAssistantSeq = ev.seq;
          }
        }
        final durableUsers = _items.where((m) => m.kind == _MsgKind.user).toList();
        final keepWithoutEcho = keep.where((m) {
          final duplicate = durableUsers.any((d) {
            if (m.messageId != null && d.messageId != null) return m.messageId == d.messageId;
            return m.messageId == null && d.messageId == null && m.text.trim().isNotEmpty && m.text == d.text;
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
      AppLog.instance.log('Chat: 已入列 ${_items.length} 条（历史 ${events.length} 条）lastSeq=$_lastSeq firstSeq=$_earliestSeq');
      _scrollToBottom(force: true); // 初始定位到最新消息
      _refreshUsage();
      widget.store.refreshSessionConfig();
    } catch (e) {
      if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
      AppLog.instance.log('Chat: 历史加载失败 $id → $e');
      if (mounted) {
        if (_items.isNotEmpty || _olderItems.isNotEmpty) {
          showToast(context, L10n.t('连接不可用，已保留当前时间线；稍后可重试详情', 'Connection unavailable; cached timeline kept, retry details later'));
        } else {
          showToast(context, '${L10n.t('该会话暂不可用：', 'This session is unavailable: ')}$e');
          Navigator.of(context).pop();
        }
      }
    }
  }

  // ── 无限上翻（微信式） ──
  /// 滑到 live 顶部时静默加载更早一页：追加到 center 之前的旧消息 sliver。
  /// center 让顶部增长不会改变当前 viewport 锚点，视觉连续无缝（最新在底部）。
  Future<void> _loadMoreInfinite() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _loadingMore || _earliestSeq <= 0 || _noMoreHistory) return;
    _loadingMore = true;
    final generation = _loadGeneration;
    AppLog.instance.log('Chat: 无限上翻 before=$_earliestSeq');
    try {
      final page = await _api.historyPage(id, before: _earliestSeq, limit: _histPageSize);
      final events = page.events;
      if (page.degraded) _historyDegraded = true;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
      if (events.isEmpty) {
        _noMoreHistory = true;
        showToast(context, L10n.t(_historyDegraded ? '更早历史不可恢复' : '没有更早的消息了', _historyDegraded ? 'Earlier history unavailable' : 'No earlier messages'));
        return; // 已到最顶：不再查询，_earliestSeq 保持不动
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
      AppLog.instance.log('Chat: 无限上翻完成 items=${_items.length + _olderItems.length} firstSeq=$_earliestSeq');
    } catch (e) {
      AppLog.instance.log('Chat: 无限上翻失败 $e');
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  /// 无限模式滚动监测：距视觉顶部 80px 内触发加载更早。
  /// v2.8.0：live 视图统一普通（非 reverse）列表，视觉顶部是 pixels≈0。
  bool _onLiveScroll(ScrollNotification n) {
    if (shouldLoadOlderFromScroll(n, infiniteMode: _infiniteMode)) {
      _loadMoreInfinite();
    }
    return false;
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
      final page = await _api.historyPage(id, before: _earliestSeq, limit: _histPageSize);
      final events = page.events;
      if (page.degraded) _historyDegraded = true;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
      if (events.isEmpty) {
        showToast(context, L10n.t(_historyDegraded ? '更早历史不可恢复' : '没有更早的消息了', _historyDegraded ? 'Earlier history unavailable' : 'No earlier messages'));
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
      final page = await _api.historyPage(id, before: _histOldestSeq, limit: _histPageSize);
      final events = page.events;
      if (page.degraded) _historyDegraded = true;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
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
      final page = await _api.historyPage(id, after: _histNewestSeq, limit: _histPageSize);
      final events = page.events;
      if (page.degraded) _historyDegraded = true;
      if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
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
      _scrollCtrl.jumpTo(0);
    });
  }

  /// 回到最新视图。
  void _backToLive() {
    setState(() {
      _inHistory = false;
      _pendingNew = false;
    });
    _scrollToBottom(force: true);
  }

  /// live 视图：普通列表（非 reverse，最旧在顶、最新在底、草稿末尾），
  /// 列表占满高度、可正常滚动、内容贴顶——无"下半空白死区 + 滑动消息消失"问题（v2.8.0）。
  /// 统一单一方向（不再按条数切换 reverse）：根治 50/51 条边界翻转导致滚动位置跳变
  /// （review P1-1）；无限模式上翻加载更早时新数据出现在视觉顶部，阅读位置不跳动。
  Widget _buildLiveView() {
    final hasDraft = _streaming || _draft.isNotEmpty;
    final topButton = !_infiniteMode && _earliestSeq > 0;
    final loadingTail = _infiniteMode && _loadingMore && _earliestSeq > 0;
    final currentExtra = (hasDraft ? 1 : 0) + (topButton ? 1 : 0) + (loadingTail ? 1 : 0);
    final itemCount = _olderItems.length + _items.length + currentExtra;
    if (itemCount != _lastLoggedCount) {
      _lastLoggedCount = itemCount;
      AppLog.instance.log('Chat: build itemCount=$itemCount streaming=$_streaming draftLen=${_draft.length} items=${_items.length + _olderItems.length}');
    }
    // v3.1.5（issue #15）：整条消息流包一层 SelectionArea —— 普通 Text 也能长按选中复制，
    // 且不引入 SelectableText（后者在部分 Android 设备上长文本换行/重叠渲染异常，见 md.dart 注释）。
    return SelectionArea(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onLiveScroll,
        child: CustomScrollView(
          controller: _scrollCtrl,
          center: _liveCenterKey,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildItem(_olderItems[index]),
                  childCount: _olderItems.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(key: _liveCenterKey, child: SizedBox.shrink()),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    // center 之后：加载条/按钮 → 当前窗口消息（最旧→最新）→ 草稿。
                    if ((topButton || loadingTail) && index == 0) {
                      if (topButton) return _OlderButton(busy: _loadingMore, onTap: _openHistory);
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),),
                      );
                    }
                    final dataIndex = index - (topButton || loadingTail ? 1 : 0);
                    if (dataIndex < _items.length) return _buildItem(_items[_items.length - 1 - dataIndex]);
                    if (hasDraft) return _AssistantBubble(text: _draft, streaming: true);
                    return const SizedBox.shrink();
                  },
                  childCount: _items.length + currentExtra,
                ),
              ),
            ),
          ],
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
                label: Text(L10n.t('更早', 'Older'), style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: _histHasNewer && !_loadingMore ? _histNewer : null,
                icon: const Icon(Icons.arrow_downward, size: 15),
                label: Text(L10n.t('更新', 'Newer'), style: TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _backToLive,
                icon: const Icon(Icons.subdirectory_arrow_right, size: 15),
                label: Text(
                  _pendingNew
                      ? L10n.t('回到最新 · 有新消息', 'Back to latest · New messages')
                      : L10n.t('回到最新', 'Back to latest'),
                  style: TextStyle(fontSize: 12, color: _pendingNew ? DshColors.brand(context) : ink2),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _histItems.isEmpty
              ? Center(child: Text(L10n.t(_historyDegraded ? '更早历史不可恢复' : '没有更早的消息', _historyDegraded ? 'Earlier history unavailable' : 'No earlier messages')))
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                    itemCount: _histItems.length,
                    itemBuilder: (context, index) => _buildItem(_histItems[index]),
                  ),
                ),
        ),
      ],
    );
  }

  /// v3.1.5（issue #15）：已加载消息 → 可复制的整段对话纯文本（时间正序）。
  /// - live 视图用 `_items`（**最新在前**，需 reversed）
  /// - 历史浏览视图用 `_histItems`（**旧→新**，已是正序）——复制当前正在看的那一段
  /// 轮次分隔条不导出；工具活动卡/未知可见事件只在有文本摘要时导出（正文为空的行由
  /// conversationText 跳过，避免把超长工具结果灌进剪贴板）。
  String _conversationText() {
    final inHistory = _inHistory && _histItems.isNotEmpty;
    final ordered = inHistory ? _histItems : _items.reversed.toList();
    return conversationText([
      for (final m in ordered)
        if (m.kind != _MsgKind.divider)
          switch (m.kind) {
            _MsgKind.user => (m.injected ? '系统注入' : '你', m.text),
            _MsgKind.assistant => ('助手', m.text),
            _MsgKind.tool => ('工具', m.text),
            _MsgKind.event => ('事件', m.text),
            _MsgKind.divider => ('', ''),
          },
    ]);
  }

  /// v3.1.5（issue #15）：复制整段对话（当前已加载的消息，含角色标注）到剪贴板。
  Future<void> _copyConversation() async {
    final text = _conversationText();
    if (text.isEmpty) {
      showToast(context, L10n.t('当前没有可复制的对话内容', 'Nothing to copy'));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showToast(context, L10n.t('已复制整段对话', 'Conversation copied'));
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
      if (mounted && request == _usageRequest && version == _usageVersion && generation == _loadGeneration && id == _mySessionId) {
        setState(() {
          _usage = u;
          _usageLoaded = true;
        });
      }
    } catch (_) {}
  }

  // ── 事件处理（对齐网页端 handleEvent） ──
  void _handleEvent(ChatEvent ev) {
    if (!mounted) return;
    // v2.7.2 review(M1)：只处理本页会话的事件（store 全量广播，叠层页面各收各的）。
    // bridge 事件兼容旧 store：若 sessionId 只存在 data 中也必须按页面绑定过滤。
    final eventSessionId = ev.sessionId ?? ev.data?['sessionId']?.toString();
    if (eventSessionId != null && eventSessionId != _mySessionId) return;
    // 所有带 durable seq 的事件先去重，再更新任何投影（todo/jobs/tool card）。
    // 否则 SSE 重复帧与 catch-up 会各自追加一张 timeline card。
    if (ev.seq != null) {
      if (ev.seq! <= _lastSeq) return;
      _lastSeq = ev.seq!;
    }
    if (ev.type == 'compaction/end') {
      _resyncAfterCompaction();
      return;
    }
    if (hiddenTimelineTypes.contains(ev.type)) {
      // Consume its cursor without retaining sensitive payloads.
      return;
    }
    if (ev.type == '_capabilities') {
      // Bootstrap/SSE hello can arrive after history; rebuild detail affordances.
      setState(() {});
      return;
    }
    if (ev.type == '_catchup') {
      _catchup();
      _refreshTodos(); // v3.1.4：重连/唤醒后任务清单也对齐一次
      return;
    }
    if (ev.type == 'agent/status') {
      setState(() {});
      return;
    }
    // 内核问询/审批弹窗帧（store 已按 sessionId 分发，这里只认当前会话）
    if (ev.type == 'question/requested') {
      final q = widget.store.questionForSession(_mySessionId);
      if (q != null && q.sessionId == _mySessionId) {
        final key = 'question:${q.rpcId}:requested';
        setState(() {
          _question = q;
          if (_transientFrameKeys.add(key)) _appendEvent(ev);
        });
      }
      return;
    }
    if (ev.type == 'question/resolved') {
      final rid = ev.data?['rpcId'];
      if (eventSessionId != _mySessionId) return;
      final key = 'question:${rid ?? 'unknown'}:resolved';
      setState(() {
        if (rid != null && _question?.rpcId == rid) _question = null;
        if (_transientFrameKeys.add(key)) _appendEvent(ev);
      });
      return;
    }
    if (ev.type == 'approval/requested') {
      final a = widget.store.approvalForSession(_mySessionId);
      if (a != null && a.sessionId == _mySessionId) {
        final key = 'approval:${a.approvalId}:requested';
        setState(() {
          _approval = a;
          if (_transientFrameKeys.add(key)) _appendEvent(ev);
        });
      }
      return;
    }
    if (ev.type == 'approval/resolved') {
      final aid = ev.data?['approvalId'];
      if (eventSessionId != _mySessionId) return;
      final key = 'approval:${aid ?? 'unknown'}:resolved';
      setState(() {
        if (aid != null && _approval?.approvalId == aid) _approval = null;
        if (_transientFrameKeys.add(key)) _appendEvent(ev);
      });
      return;
    }
    // 上下文窗口实时帧：更新圆环数据（无需重进会话）
    if (ev.type == 'session/context') {
      final window = (ev.data?['contextWindow'] as num?)?.toInt();
      if (window != null && window > 0) {
        _usageVersion++;
         _usage['contextWindow'] = window;
        setState(() {});
      }
      return;
    }
    // v2.7：会话任务视图更新（后台任务卡片/工具弹层刷新）
    if (ev.type == 'session/jobs') {
      // jobs is a non-durable projection rendered by the top JobCard; do not
      // turn every reconnect snapshot into another timeline event.
      if (mounted) setState(() {});
      return;
    }
    // v3.1.4（issue #12 姊妹需求）：任务清单实时折叠——与内核 dsh-tool-todo 的会话投影
    // 完全同语义（最新 todo/write 覆盖整份、turn/start 清空）。
    // 这里是实时 SSE 路径；历史/回放由 _loadInitial 按**时间正序**折叠后再存状态
    // （历史事件是倒序入列的，顺序折叠会得到旧状态）。
    if (ev.type == 'todo/write') {
      _todoProjectionVersion++;
      _todos = ((ev.data?['todos'] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();
      // 任务面板与时间线同时更新；不要把 todo/write 静默成只有当前投影。
    }
    if (ev.type == 'turn/start') {
      _todoProjectionVersion++;
      _todos = []; // 新一轮开始清空清单（继续走下方渲染，保留"轮次 N 开始"分隔条）
    }
    // v3.0.0：队列快照帧（认领/删除/编辑即时反映）→ 本页 dock 即时同步
    if (ev.type == 'mobile/queue') {
      final sid = ev.data?['sessionId'] as String?;
      if (sid != null && sid == _mySessionId) {
        setState(() {
          _queue = widget.store.queueOf(sid);
          if (_queue.isEmpty) _queueCollapsed = true;
        });
      }
      return;
    }
    // 关键事件日志（排除高频 chunk，便于排障）
    if (ev.type != 'assistant/chunk' && ev.type != 'assistant/live-chunk' && ev.type != 'tool/call' && ev.type != 'tool/result') {
      AppLog.instance.log('Chat: SSE 事件 ${ev.type} seq=${ev.seq}');
    }
    if (ev.type == 'assistant/chunk' || ev.type == 'assistant/live-chunk') {
      final text = ev.data?['text'] as String? ?? '';
      final reasoning = ev.data?['reasoning'] == true;
      if (text.isNotEmpty && !reasoning) {
        _draft += text;
        _scheduleDraftFlush();
      } else if (text.isNotEmpty && reasoning) {
        // 思考内容实时累积（活动条面板，可展开）
        if (_reasoning.isEmpty) AppLog.instance.log('Chat: 思考开始（首个 reasoning chunk）');
        _reasoning += text;
        _scheduleActivityFlush();
      }
      if (ev.data?['toolCall'] != null || ev.data?['argumentsDelta'] != null) {
        final data = ev.data ?? const <String, dynamic>{};
        _activeTools[_toolActivityKey(data, ev.seq, _items.length)] = ev.data?['toolCall']?.toString() ?? L10n.t('工具', 'Tool');
        // 参数 delta 可达数百上千条：只更新模型，交给 80ms 节流统一重建
        // （与正文草稿 _scheduleDraftFlush 同口径），避免每个 delta 触发一次全量 setState。
        _appendEvent(ev);
        _scheduleActivityFlush();
      }
      return;
    }
    if (ev.type == 'assistant/message' || ev.type == 'turn/end') {
      _draftTimer?.cancel();
      _draftTimer = null;
      _activityTimer?.cancel();
      _activityTimer = null;
      if (ev.type == 'assistant/message') {
        // 正文到达：工具阶段结束（思考保留到轮次结束，面板显示"已思考 N 字"）
        _activeTools.clear();
        AppLog.instance.log('Chat: 活动条-正文到达（思考 ${_reasoning.length} 字）');
      } else {
        // 轮次结束：清空活动条与思考草稿
        _activeTools.clear();
        if (_reasoning.isNotEmpty) AppLog.instance.log('Chat: 活动条-轮次结束清理（思考 ${_reasoning.length} 字）');
        _reasoning = '';
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
        for (final key in ['inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'reasoningTokens']) {
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
    _scrollToBottom();
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
    if (!needsTurnEndResync(lastUserSeq: _lastUserSeq, lastAssistantSeq: _lastAssistantSeq)) return;
    final now = DateTime.now();
    if (_lastResyncAt != null && now.difference(_lastResyncAt!) < const Duration(seconds: 10)) return;
    _lastResyncAt = now;
    AppLog.instance.log('Chat: 轮次结束但无回复条目（lastUser=$_lastUserSeq lastAssistant=$_lastAssistantSeq）→ 兜底补拉');
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
      if (!mounted || request != _todoRefreshRequest || version != _todoProjectionVersion || generation != _loadGeneration || id != _mySessionId || list == null) return;
      setState(() => _todos = list);
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
      while (pageNo < _catchupMaxPages) {
        pageNo++;
        final page = await _api.historyPage(id, after: cursor, limit: 100);
        if (page.degraded) _historyDegraded = true;
        if (!mounted || generation != _loadGeneration || id != _mySessionId) return;
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
              _todos = ((ev.data?['todos'] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();
            }
            _appendEvent(ev);
          }
        });
        if (!page.hasMore) break;
        truncated = pageNo >= _catchupMaxPages;
      }
      if (truncated) AppLog.instance.log('Chat: catch-up 截断于 $_catchupMaxPages 页（cursor=$cursor），剩余由下次补拉收敛');
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
    final affects = type == 'turn/start' || type == 'tool/call' || type == 'user/message' || type == 'assistant/message';
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
          {'type': 'text', 'text': text}
        ],
      });
      if (mounted) setState(() => _editingQueueId = null);
      _refreshQueue();
    } catch (e) {
      if (!mounted) return;
      setState(() => _editingQueueId = null);
      if (e is ApiException && e.code == 'queue-item-not-found') {
        // v3.0.0：已被 agent 认领（正在执行）——语义化提示，行由帧/REST 刷新移除
        showToast(context, L10n.t('该消息已被 agent 处理，无法编辑', 'The agent already picked it up — cannot edit'));
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
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(L10n.t('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(L10n.t('删除', 'Remove'))),
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
        showToast(context, L10n.t('该消息已被 agent 开始处理，未能删除', 'The agent already picked it up — could not remove'));
      }
      _refreshQueue();
    } catch (e) {
      if (mounted) {
        if (e is ApiException && e.code == 'queue-item-not-found') {
          // v3.0.0：已被 agent 认领（正在执行）——内核返回 queue-item-not-found，
          // 语义化提示 + 即时刷新（帧/REST 会移除该行，不再残留陈旧行）
          showToast(context, L10n.t('该消息已被 agent 开始处理，未能删除', 'The agent already picked it up — could not remove'));
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
        if (e is ApiException && (e.code == 'queue-item-not-found' || e.code == 'steer-unavailable')) {
          // v3.0.0：已被处理/当前轮不再接受插话——语义化提示
          showToast(context, L10n.t('该消息已被 agent 处理，无法插话', 'The agent already picked it up — cannot steer'));
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
                      style: TextStyle(fontSize: 11.5, color: ink3, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 3),
                    Icon(_queueCollapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 15, color: ink3),
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
                decoration: const InputDecoration(isDense: true, border: InputBorder.none),
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
              style: TextStyle(fontSize: 12, fontStyle: hasText ? FontStyle.normal : FontStyle.italic, color: hasText ? null : ink3),
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
    _buildInto(_items, ev, history: history, tail: tail);
    if (!_infiniteMode) {
      // 裁剪：live 列表最多保留 _liveMax 条，超出丢弃最旧（尾部），
      // 同时推进"查看更早"的分页起点，保证翻页无缝隙。
      while (_items.length > _liveMax) {
        _items.removeLast();
      }
      if (_items.isNotEmpty) {
        final oldest = _items.last.seq;
        if (oldest != null) _earliestSeq = oldest;
      }
    }
  }

  /// 系统注入的噪声消息判定（PC 端 GUI 也不显示）：
  /// 上下文快照 / 后台任务通知。判据与模型侧共用同一实现。
  bool _isNoiseText(String text) => timelineIsInjectedNoise(text);

  /// 工具关联 id 与模型侧共用同一实现（避免两处规则分叉）。
  String _toolActivityKey(Map<String, dynamic> data, int? seq, int fallback) =>
      timelineCallIdOf(data, seq, fallback);

  void _rebuildActiveToolsFromHistory(List<ChatEvent> events) {
    _activeTools.clear();
    for (final ev in events) {
      final data = ev.data ?? const <String, dynamic>{};
      if (ev.type == 'tool/call') {
        _activeTools[_toolActivityKey(data, ev.seq, _activeTools.length)] =
            data['name']?.toString() ?? data['toolCall']?.toString() ?? L10n.t('工具', 'Tool');
      } else if (ev.type == 'tool/result') {
        _activeTools.remove(_toolActivityKey(data, ev.seq, _activeTools.length));
      } else if (ev.type == 'assistant/message' || ev.type == 'turn/end') {
        _activeTools.clear();
      }
    }
  }

  /// Tool activity 的 Flutter 侧投影：**合并规则由 [TimelineReducer] 单点实现**
  /// （参数替换/追加、status、anchor/detail seq、关联 id、images/files），
  /// 这里只负责放置位置与携带 UI 专属状态（rawData / detailLoading）。
  /// 曾经在此复刻合并规则，导致 tool/call 的整串参数被拼在 delta 之后（参数重复）。
  void _upsertToolItem(List<_MsgItem> out, ChatEvent ev, {required bool history}) {
    final d = ev.data ?? const <String, dynamic>{};
    final callId = timelineCallIdOf(d, ev.seq, out.length);
    final isResult = ev.type == 'tool/result';
    var owner = out;
    var index = out.indexWhere((m) => m.kind == _MsgKind.tool && m.toolCallId == callId);
    if (index < 0) {
      for (final candidate in <List<_MsgItem>>[_items, _olderItems, _histItems]) {
        if (identical(candidate, out)) continue;
        final found = candidate.indexWhere((m) => m.kind == _MsgKind.tool && m.toolCallId == callId);
        if (found >= 0) {
          owner = candidate;
          index = found;
          break;
        }
      }
    }
    final old = index >= 0 ? owner[index] : null;
    // apply() 已在 _buildInto 入口执行，故 tools[callId] 已是合并后的权威生命周期。
    final lifecycle = _timelineReducer.tools[callId] ??
        ToolLifecycle(
          id: callId,
          name: d['name']?.toString() ?? d['toolCall']?.toString() ?? L10n.t('工具', 'Tool'),
          seq: ev.seq,
        );
    final item = _MsgItem.tool(
      toolCallId: lifecycle.id,
      toolName: lifecycle.name,
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
    );
    if (index >= 0) {
      final settled = old?.toolStatus == 'success' || old?.toolStatus == 'failed';
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

  void _appendVisibleEvent(List<_MsgItem> out, ChatEvent ev, {required bool history}) {
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
      toolError: d['isError'] == true || d['error'] == true || d['status'] == 'failed',
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
  void _buildInto(List<_MsgItem> out, ChatEvent ev,
      {bool history = false, bool tail = false}) {
    final d = ev.data;
    if (hiddenTimelineTypes.contains(ev.type)) return;
    // Historical reconstruction must still render a record even when the same seq
    // arrived via SSE while the REST request was in flight. Live ingestion can
    // discard the duplicate because _handleEvent already owns the visible stream.
    if (!_timelineReducer.apply(ev) && !history) return;
    switch (ev.type) {
      case 'user/message':
        final text = d?['text'] as String? ?? '';
        // 已知 runtime context 噪声保留 seq/model 对账，但系统提示词与上下文快照在所有模式均隐藏。
        final mid = d?['messageId'] as String?;
        // v3.1.4（issue #12）：内核来源标记——非 "user" 即系统注入（plugin/agent-instructions/tool…），
        // 渲染成可折叠块；缺字段（旧内核）时为 null，退回关键词启发式。
        final sourceKind = d?['sourceKind'] as String?;
        // v3.1.4（issue #13）：只有**真人提问**参与"本轮是否缺回复"的兜底判定
        // （注入消息不是提问，不该因它触发补拉）
        if ((!history || tail) && (sourceKind == null || sourceKind == 'user')) {
          if (ev.seq != null) _lastUserSeq = ev.seq;
        }
        // 去重（SSE 回显 vs 本地乐观添加）：
        // 1) 已有同 messageId 的消息 → 直接跳过（回显已完成渲染，同文本连发也不误并）
        if (mid != null && out.any((m) => m.kind == _MsgKind.user && m.messageId == mid)) return;
        // 2) 列表中已存在本地乐观添加（messageId 尚未赋值）且文本一致的消息 → 合并。
        //    全列表查找而非只看 out.first：turn/start 等事件可能先于回显插入，
        //    把乐观消息挤到非首位（否则会出现"同一条消息显示两次"）。
        if (!history) {
          // v2.7.2 乱序排查：合并到"最旧"的未回显乐观消息（lastIndexWhere）——
          // 同文本连发时回显按发送顺序到达，合并顺序必须与发送顺序一致；
          // 此前 indexWhere 从头部（最新）找，先到的回显会合并到最新一条，
          // 造成 seq 与视觉顺序错配（后续重建时可能乱序）。
          final idx = out.lastIndexWhere((m) =>
              m.kind == _MsgKind.user && m.messageId == null && m.text.trim() == text.trim());
          if (idx != -1) {
            out[idx] = out[idx].copyWith(seq: ev.seq, messageId: mid);
            return;
          }
        }
        if (history) {
          out.add(_MsgItem.user(text, seq: ev.seq, messageId: mid, images: _imagesOf(d), files: _filesOf(d), sourceKind: sourceKind));
        } else {
          out.insert(0, _MsgItem.user(text, seq: ev.seq, messageId: mid, images: _imagesOf(d), files: _filesOf(d), sourceKind: sourceKind));
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
            : (reasoningChars > 0 ? L10n.t('（思考 $reasoningChars 字）\n', '(Thought: $reasoningChars chars)\n') : '');
        final item = _MsgItem.assistant(prefix + body,
            usage: d?['usage'] as Map<String, dynamic>?,
            seq: ev.seq,
            messageId: d?['messageId'] as String?,
            images: _imagesOf(d),
            files: _filesOf(d),
            reasoning: reasoningText.isEmpty ? null : reasoningText,
            detailAvailable: ev.detailAvailable,
            detailTextChars: ev.detailTextChars);
        // v3.1.4（issue #13）：记录最近一条**会渲染出来**的回复，供轮次兜底判定
        // （注入的上下文快照虽然进模型但界面隐藏，不能算作本轮已有回复）。
        if ((!history || tail) && ev.seq != null && !timelineIsInjectedNoise(body)) _lastAssistantSeq = ev.seq;
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
        final name = d?['name']?.toString() ?? L10n.t('工具', 'Tool');
        if (!history) {
          _activeTools[_toolActivityKey(d ?? const <String, dynamic>{}, ev.seq, out.length)] = name;
          _scheduleActivityFlush();
        }
        _upsertToolItem(out, ev, history: history);
      case 'tool/result':
        if (!history) {
          _activeTools.remove(_toolActivityKey(d ?? const <String, dynamic>{}, ev.seq, out.length));
          _scheduleActivityFlush();
        }
        _upsertToolItem(out, ev, history: history);
      case 'todo/write':
        _appendVisibleEvent(out, ev, history: history);
      case 'turn/start':
        if (history) {
          out.add(_MsgItem.divider(L10n.t('轮次 ${d?['turn']} 开始', 'Turn ${d?['turn']} started'), seq: ev.seq));
        } else {
          out.insert(0, _MsgItem.divider(L10n.t('轮次 ${d?['turn']} 开始', 'Turn ${d?['turn']} started'), seq: ev.seq));
        }
      case 'turn/end':
        if (!history || tail) {
          _draft = '';
          _streaming = false;
        }
        final reason = (d?['reason'] as Map<String, dynamic>?)?['kind'];
        final item = _MsgItem.divider(
            L10n.t('轮次 ${d?['turn']} 结束${reason != null ? '（$reason）' : ''}',
                'Turn ${d?['turn']} ended${reason != null ? ' ($reason)' : ''}'),
            seq: ev.seq);
        if (history) {
          out.add(item);
        } else {
          out.insert(0, item);
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
  Future<Map<String, dynamic>?> _resolveUnknownSend(String sessionId, String requestId) async {
    for (var i = 0; i < 4; i++) {
      try {
        final receipt = await _api.sendReceipt(sessionId, requestId, timeout: const Duration(seconds: 3));
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

  Future<void> _send([String? preset, String mode = 'followup']) async {
    final text = (preset ?? _inputCtrl.text).trim();
    // v2.9.0 review(HIGH)：页级动作绑定本页会话，叠层聊天不回退时发错会话
    final id = _mySessionId ?? widget.store.sessionId;
    if ((text.isEmpty && _pendingImages.isEmpty) || id == null || _sending || preset != null && _pendingImages.isNotEmpty) return;
    // v3.0.0 图像链路：有待发图片 → 走图片通路（原始字节不压缩；成功/失败处理独立）
    if (mode == 'steer' && _pageAgentStatus != 'running') {
      showToast(context, L10n.t('agent 空闲，已按普通消息发送', 'Agent idle — sent as a normal message'));
      mode = 'followup';
    }
    // v3.0.0(热修 07)：降级提前到分流之前——最终生效模式参与 requestId 签名
    if (_pendingImages.isNotEmpty) {
      await _sendImages(id, text, mode);
      return;
    }
    AppLog.instance.log('Chat: 发送 → $id : ${text.length > 20 ? '${text.substring(0, 20)}…' : text}${mode == 'steer' ? '（插队）' : ''}');
    // v3.0.0：运行中排队（followup）→ 消息**不进对话窗口**（与 PC 端一致：仅进 Queue Dock，
    // 被 agent 认领执行时 user/message 回显才上屏）——乐观气泡只保留给「立即生效」的发送
    final queued = mode != 'steer' && _pageAgentStatus == 'running';
    // v3.0.0(热修 05)：requestId 与草稿内容绑定——内容未变的重试复用同一 id
    // （服务端幂等，重复投递最多一次）；内容变化（文本/图片改动）则换新 id。
    final signature = composerSignature(id, mode, text, _pendingImages.map((f) => f.path).toList());
    if (_pendingRequestId == null || _pendingSignature != signature) {
      _pendingRequestId = genRequestId();
      _pendingSignature = signature;
    }
    final requestId = _pendingRequestId!;
    // 收起键盘，输入框回到原位
    FocusScope.of(context).unfocus();
    // agent 忙时提示（避免用户以为没反应而重复发送）；插队时不提示排队
    if (_pageAgentStatus == 'running' && preset == null && mode != 'steer') {
      showToast(context, L10n.t('agent 正在处理上一轮，消息会排队等待', 'The agent is still processing the last turn — your message will be queued'));
    }
    setState(() {
      _sending = true;
      if (!queued) _items.insert(0, _MsgItem.user(text)); // 最新在前：插入头部（视觉底部）
    });
    _inputCtrl.clear();
    _scrollToBottom(force: true);
    try {
      final (mid, note, configDegraded) = await _api.send(id, text, mode: mode, requestId: requestId);
      _pendingRequestId = null;
      _pendingSignature = null;
      AppLog.instance.log('Chat: 发送成功 mid=$mid${note != null ? ' note=$note' : ''}${configDegraded ? ' configDegraded' : ''}');
      if (!mounted) return;
      // v3.1.5：休眠会话配置折叠失败 → 服务端已用默认模型/权限恢复该会话。必须让用户知道，
      // 否则配置被静默改写（issue #20 验收里「configDegraded 显式标记」在 App 侧的兑现）：
      // 置常驻横幅标记，并首次即时 toast（后续 toast 可能覆盖，横幅仍在）。
      if (configDegraded && !_configDegraded) {
        setState(() => _configDegraded = true);
        showToast(context, L10n.t('该会话配置已回退默认（模型/权限）', 'Session settings reverted to defaults'));
      }
      // v2.7.2 review：mounted 检查之后才刷新队列（发送成功=新消息入队）
      _scheduleQueueRefresh();
      if (queued) {
        // 排队：无乐观气泡；插件持存（任务结束才释放）时明确提示
        if (note == 'held-until-idle') {
          showToast(context, L10n.t('已排队：当前任务结束后自动发送', 'Queued: will send after the current task finishes'));
        } else if (note == 'steer-degraded-held') {
          showToast(context, L10n.t('已排队（插队不可用）：任务结束后自动发送', 'Queued (steer unavailable): will send after the task finishes'));
        }
        return;
      }
      // 服务端实际持存但本地状态判断偏差（SSE 断线期间 agentStatus 停滞）：
      // 撤回乐观气泡，保持"排队消息不进对话窗口"一致
      if (note == 'held-until-idle' || note == 'steer-degraded-held') {
        setState(() {
          _items.removeWhere((m) => m.kind == _MsgKind.user && m.messageId == null && m.text == text);
        });
        showToast(context, L10n.t('已排队：当前任务结束后自动发送', 'Queued: will send after the current task finishes'));
        return;
      }
      // v2.7.2：插队成功明确提示（否则和普通发送看起来一样，用户会困惑）
      if (mode == 'steer') {
        showToast(context, L10n.t('已插队：消息将插到 agent 下一步执行', 'Steered: will run at the agent\'s next step'));
      }
      setState(() {
        // 按文本定位乐观消息补 messageId（可能已被 SSE 回显合并，此时已是同 id，幂等）。
        // v2.7.2 review：与回显合并对称用 lastIndexWhere（合并到最旧未回显）——
        // 同文本多条时 mid 不会挂错条目
        final idx = _items.lastIndexWhere(
            (m) => m.kind == _MsgKind.user && m.messageId == null && m.text == text);
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
            _items.removeWhere((m) => m.kind == _MsgKind.user && m.messageId == null && m.text == text);
            _items.insert(0, _MsgItem.divider('⚠ ${L10n.t('发送失败：', 'Send failed: ')}$e'));
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
        showToast(context, L10n.t('已送达：刚才网络波动，请勿重复发送', 'Delivered despite a network hiccup — do not resend'));
        return;
      }
      if (receipt != null && receipt['status'] == 'error') {
        _pendingRequestId = null;
        _pendingSignature = null;
        final rmap = receipt['result'] is Map ? receipt['result'] as Map : const {};
        final msg = '${L10n.t('发送失败：', 'Send failed: ')}${rmap['detail'] ?? ''}';
        setState(() {
          if (!queued) {
            _items.removeWhere((m) => m.kind == _MsgKind.user && m.messageId == null && m.text == text);
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
          _items.removeWhere((m) => m.kind == _MsgKind.user && m.messageId == null && m.text == text);
          _items.insert(0, _MsgItem.divider('⚠ ${L10n.t('发送结果未知：', 'Outcome unknown: ')}$e'));
        }
      });
      _restoreDraftIfUntouched(text);
      showToast(context, L10n.t('发送结果未知：请稍后点重试，重试不会重复发送', 'Outcome unknown — retry later; retries will not duplicate'));
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
      final maxBytes = ((limits['maxImageBytes'] as num?)?.toInt() ?? 20 * 1024 * 1024);
      // v3.0.0：兜底对齐内核默认（DEFAULT_MAX_MESSAGE_IMAGE_BYTES = 200MB；此前误写 20MB，
      // catalog 缺失时总大小被错误限制在单张额度）
      final catalogMax = ((limits['maxMessageImageBytes'] as num?)?.toInt() ?? 200 * 1024 * 1024);
      // v3.0.0(热修 05)：客户端传输天花板 40MB——服务端 HTTP body 上限 64MB，
      // base64 膨胀（×4/3）加 JSON 开销后仍有富余；超限在客户端明确提示，
      // 不再落到服务端 413。内核侧 200MB 能力不受影响（PC 端同源）。
      const transportCeiling = 40 * 1024 * 1024;
      final maxTotal = catalogMax > transportCeiling ? transportCeiling : catalogMax;
      final mediaTypes = (limits['mediaTypes'] as List?)?.map((e) => e.toString()).toSet() ??
          {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
      // 模型能力（服务端也会校验，此处前置拦截给用户明确提示）
      if (!_currentModelSupportsImages()) {
        showToast(context, L10n.t('当前模型不支持图片输入，请先切换模型', 'The current model does not support images — switch models first'));
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
            showToast(context, L10n.t('不支持的图片格式：$mediaType', 'Unsupported image format: $mediaType'));
          } else {
            showToast(context, L10n.t('仅支持 PNG/JPEG/WebP/GIF 图片', 'Only PNG/JPEG/WebP/GIF images are supported'));
          }
          return;
        }
        if (b.length > maxBytes) {
          showToast(context, L10n.t('单张图片超过 ${_mbOf(maxBytes)}MB 上限', 'One image exceeds the ${_mbOf(maxBytes)}MB limit'));
          return;
        }
        total += b.length;
        if (total > maxTotal) {
          showToast(context, L10n.t('图片总大小超过 ${_mbOf(maxTotal)}MB 上限', 'Images exceed the ${_mbOf(maxTotal)}MB total limit'));
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
      final signature = composerSignature(id, mode, text, _pendingImages.map((f) => f.path).toList());
      if (_pendingRequestId == null || _pendingSignature != signature) {
        _pendingRequestId = genRequestId();
        _pendingSignature = signature;
      }
      requestId = _pendingRequestId!;
      AppLog.instance.log('Chat: 发送(图) → $id : ${images.length} 张, 共 $total 字节${mode == 'steer' ? '（插队）' : ''}');
      final (accepted, note, configDegraded) = await _api.sendImages(id, text, images, mode: mode, requestId: requestId);
      _pendingRequestId = null;
      _pendingSignature = null;
      if (!mounted) return;
      // v3.1.5：语义同文本发送——配置回退默认必须显式提示（常驻横幅 + 首次 toast）
      if (configDegraded && !_configDegraded) {
        setState(() => _configDegraded = true);
        showToast(context, L10n.t('该会话配置已回退默认（模型/权限）', 'Session settings reverted to defaults'));
      }
      _scheduleQueueRefresh();
      if (!accepted) {
        // v3.0.0：先判 accepted，避免与下方 note 提示产生矛盾（不弹"已排队"却弹"未被接受"）
        showToast(context, L10n.t('发送未被接受', 'Send was not accepted'));
        return;
      }
      if (note == 'held-until-idle') {
        showToast(context, L10n.t('已排队：当前任务结束后自动发送', 'Queued: will send after the current task finishes'));
      } else if (note == 'steer-degraded-held') {
        showToast(context, L10n.t('已排队（插队不可用）：任务结束后自动发送', 'Queued (steer unavailable): will send after the task finishes'));
      } else if (mode == 'steer') {
        showToast(context, L10n.t('已插队：消息将插到 agent 下一步执行', 'Steered: will run at the agent\'s next step'));
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
        showToast(context, L10n.t('已送达：刚才网络波动，请勿重复发送', 'Delivered despite a network hiccup — do not resend'));
        return;
      }
      if (receipt != null && receipt['status'] == 'error') {
        _pendingRequestId = null;
        _pendingSignature = null;
        final rmap = receipt['result'] is Map ? receipt['result'] as Map : const {};
        showToast(context, '${L10n.t('发送失败：', 'Send failed: ')}${rmap['detail'] ?? ''}');
        return;
      }
      // 未确认：保留 requestId 与草稿供幂等重试
      showToast(context, L10n.t('发送结果未知：请稍后点重试，重试不会重复发送', 'Outcome unknown — retry later; retries will not duplicate'));
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

    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'image/png';
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
    if (startsWith(const [0x66, 0x74, 0x79, 0x70], 4)) {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (const ['heic', 'heix', 'hevc', 'mif1'].contains(brand)) return 'image/heic';
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
        showToast(context, L10n.t('已请求停止，agent 当前轮次结束后停下', 'Stop requested — the agent will halt after its current turn'));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, '${L10n.t('停止失败：', 'Stop failed: ')}$e${L10n.t('（桌面端插件需重启生效）', ' (the desktop plugin may need a restart)')}');
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
      if (mounted) showToast(context, '${L10n.t('取消失败：', 'Cancel failed: ')}$e');
    }
  }

  void _openTools() {
    // v2.9.0 review：与页级动作一致，绑定本页会话（工具页上下文不能跟随全局切换）
    final sid = _mySessionId ?? widget.store.sessionId;
    if (sid == null) return;
    showSessionToolsSheet(context, widget.store, sid);
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
          showToast(context, L10n.t('该消息暂不支持反馈（旧消息无 messageId）', 'Feedback is not available for this message (older messages lack a message ID)'));
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
            final i = list.indexWhere((m) => m.kind == _MsgKind.assistant && m.messageId == mid);
            if (i == -1) return;
            final old = list[i];
            list[i] = _MsgItem.assistant(old.text,
                usage: old.usage, seq: old.seq, messageId: old.messageId, rating: newRating,
                images: old.images, files: old.files, reasoning: old.reasoning, detailAvailable: old.detailAvailable, rawData: old.rawData, detailLoading: old.detailLoading);
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
          showToast(context, L10n.t('该消息暂不支持分支', 'Forking is not available for this message'));
          return;
        }
        try {
          final childId = await _api.forkSession(id, atSeq: seq);
          if (!mounted) return;
          showToast(context, L10n.t('已分支，正在打开新对话…', 'Forked — opening the new chat…'));
          final prevId = _mySessionId;
          widget.store.refreshSessions();
          // Phase 2(A4)：统一打开会话流程；返回后恢复原会话（分支页不改变主会话）
          await openChat(context, widget.store, childId,
              onTitleChanged: widget.onTitleChanged,
              onReturn: () async {
            if (mounted && prevId != null && prevId != childId) {
              await widget.store.setSession(prevId);
            }
          });
        } catch (e) {
          if (!mounted) return;
          showToast(context, '${L10n.t('分支失败：', 'Fork failed: ')}$e');
        }
    }
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final ink3 = DshColors.ink3(context);
    final brand = DshColors.brand(context);
    final surface = DshColors.surface(context);

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
              child: Text(_title ?? L10n.t('会话', 'Session'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            _StatusDot(status: store.connState == 'connected' ? _pageAgentStatus : 'offline'),
          ],
        ),
        actions: [
          // v2.7：会话工具（任务 / 子代理 / 目标）
          IconButton(
            icon: const Icon(Icons.assignment_outlined, size: 20),
            tooltip: L10n.t('任务 / 子代理 / 目标', 'Tasks / Subagents / Goals'),
            onPressed: () {
              final sid = _mySessionId;
              if (sid != null) showSessionToolsSheet(context, widget.store, sid);
            },
          ),
          // v3.1.5（issue #15）：会话级「复制整段对话」入口
          IconButton(
            icon: const Icon(Icons.copy_all, size: 20),
            tooltip: L10n.t('复制整段对话', 'Copy whole conversation'),
            onPressed: _copyConversation,
          ),
        ],
      ),
      body: Column(
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
                      L10n.t('当前仅能恢复部分历史，更早内容可能不可用', 'Only partial history available'),
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  if (_configDegraded)
                    Text(
                      L10n.t('该会话配置已回退默认（模型/权限/预设）',
                          'Session settings reverted to defaults (model/permissions)'),
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          // 消息流：live 视图（普通列表，最新在底部）或历史分段浏览；
          // 上翻时右下角浮出"回到底部"圆钮（位于输入框正上方，不在消息流内）
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _inHistory ? _buildHistoryView() : _buildLiveView()),
                if (!_inHistory)
                  Positioned(
                    bottom: 12,
                    right: 14,
                    child: _JumpToLatestButton(visible: _showJumpToLatest, onTap: _jumpToLatest),
                  ),
              ],
            ),
          ),
          // 活动条：思考中 / 工具执行中（过程反馈，不依赖任何开关）
          if (!_inHistory && (_reasoning.isNotEmpty || _activeTools.isNotEmpty))
            _ActivityBar(
              reasoning: _reasoning,
              expanded: _reasoningExpanded,
              textStreaming: _streaming,
              showContent: widget.store.showReasoning,
              tools: _activeTools.values.toList(),
              onToggleReasoning: () => setState(() => _reasoningExpanded = !_reasoningExpanded),
            ),
          // 内核问询/审批弹窗（思考中途需要你拍板，与 PC 端同一 pending 通道）
          if (_question != null)
            _QuestionCard(
              request: _question!,
              onCancel: () {
                // 立即收起卡片（内核 resolved 帧可能因本地状态已清而不再转发）
                final rpc = _question!.rpcId;
                setState(() => _question = null);
                widget.store.cancelRespond(rpc);
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
                widget.store.cancelRespond(rpc);
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
                      child: _ActionChip(action: a, onTap: () => showActionSheet(context, a)),
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
          // composer（v2.8.0 重构为两层，对齐 PC 端 InputBar）：
          // 第一层 = [/命令] + 输入框（独占最宽）；第二层 = 模型/权限/排队胶囊 + 上下文圆环 + 发送
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: Theme.of(context).brightness == Brightness.dark ? DshTheme.shadowDark : DshTheme.shadow,
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
                              contentPadding: const EdgeInsets.symmetric(vertical: 8),
                            ),
                            onSubmitted: (_) => _send(),
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
                            child: Icon(Icons.add, size: 17, color: DshColors.ink3(context)),
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
                                  label: _shortPerm(_permName(store.sessionConfig.permissionPreset)),
                                  onTap: () => showPermSheet(context, store),
                                ),
                              ),
                              // 运行中且输入非空 → 「排队发送」胶囊（点击=普通发送，运行中自动排队）；
                              // 固定宽度（不参与收缩，始终完整显示）
                              if (_pageAgentStatus == 'running' && _inputCtrl.text.trim().isNotEmpty) ...[
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
                            decoration: BoxDecoration(color: brand, borderRadius: BorderRadius.circular(9)),
                            child: _pageAgentStatus == 'running'
                                ? Center(
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  )
                                : _sending
                                    ? const SizedBox(
                                        width: 15,
                                        height: 15,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Icon(Icons.arrow_upward, size: 17, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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
  String _shortPerm(String perm) => perm.length > 14 ? '${perm.substring(0, 13)}…' : perm;

  /// v2.8.0：斜杠命令菜单（对齐 PC 端 command menu）——列出命令，点选填入输入框。
  /// v3.0.0 图像链路：⊕ = 更多菜单（拍照 / 从相册选择 / 命令）。
  Future<void> _showComposerMenu() async {
    if (_pickingImages) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  const Icon(Icons.add_circle_outline, size: 16, color: Color(0xFF426EFE)),
                  const SizedBox(width: 6),
                  Text(L10n.t('更多', 'More'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.photo_camera_outlined, size: 20),
              title: Text(L10n.t('拍照', 'Take a photo'), style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('camera'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.photo_library_outlined, size: 20),
              title: Text(L10n.t('从相册选择', 'Choose from gallery'), style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('gallery'),
            ),
            // v3.1.2（csborbbnc 反馈）：文件传输入口（系统选择器/下载保存）
            ListTile(
              dense: true,
              leading: const Icon(Icons.upload_file_outlined, size: 20),
              title: Text(L10n.t('上传文件', 'Upload file'), style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('upload-file'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.download_outlined, size: 20),
              title: Text(L10n.t('下载文件', 'Download file'), style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('download-file'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.code, size: 20),
              title: Text(L10n.t('命令', 'Commands'), style: const TextStyle(fontSize: 14)),
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
      final picked = await _filesChannel.invokeMapMethod<String, dynamic>('pickFile');
      if (picked == null) return; // 取消
      final name = picked['name'] as String? ?? 'file';
      final bytes = picked['bytes'] as Uint8List?;
      if (bytes == null || bytes.isEmpty) {
        if (mounted) showToast(context, L10n.t('读取文件失败', 'Failed to read the file'));
        return;
      }
      final r = await _api.uploadFile(sid, name, bytes);
      if (mounted) {
        showToast(context,
            '${L10n.t('已上传到电脑工作目录：', 'Uploaded to PC workspace: ')}${r['path'] ?? name}');
      }
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('上传失败：', 'Upload failed: ')}$e');
    }
  }

  /// v3.1.2（csborbbnc 反馈）：下载文件——可视化文件选择器（盘符/目录树/点文件）
  /// → 保存到手机「下载」目录。
  Future<void> _downloadFile() async {
    final path = await showFilePicker(context);
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final bytes = await _api.downloadFile(path);
      final name = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? 'file';
      final saved = await _filesChannel
          .invokeMethod<String>('saveToDownloads', {'name': name, 'bytes': bytes});
      if (mounted) {
        showToast(context, '${L10n.t('已保存到手机：', 'Saved on phone: ')}${saved ?? name}');
      }
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('下载失败：', 'Download failed: ')}$e');
    }
  }

  /// v3.0.0 图像链路：选图（原始解析，不压缩）——上限按内核 imageLimits（PC 端同源数字）。
  Future<void> _pickImages({required bool fromCamera}) async {
    if (_pickingImages) return;
    _pickingImages = true;
    try {
      final limits = widget.store.catalog?.imageLimits ?? const {};
      final maxCount = ((limits['maxImagesPerMessage'] as num?)?.toInt() ?? 20).clamp(1, 20).toInt();
      final picker = ImagePicker();
      final picked = fromCamera
          ? [await picker.pickImage(source: ImageSource.camera)]
          : await picker.pickMultiImage(limit: maxCount);
      final files = picked.whereType<XFile>().toList();
      if (files.isEmpty || !mounted) return;
      final room = maxCount - _pendingImages.length;
      if (room <= 0) {
        showToast(context, L10n.t('已达单条消息的图片数量上限', 'Reached the image count limit per message'));
        return;
      }
      if (files.length > room) {
        showToast(context, L10n.t('最多还能添加 $room 张图片', 'You can add up to $room more image(s)'));
      }
      setState(() => _pendingImages.addAll(files.take(room)));
      _scrollToBottom();
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
                        errorBuilder: (_, _, _) => Container(
                          width: 76,
                          height: 76,
                          color: line,
                          child: const Icon(Icons.image_outlined, color: Colors.white54),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: InkWell(
                        onTap: () => setState(() => _pendingImages.removeAt(i)),
                        child: Container(
                          decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(Icons.close, size: 13, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            IconButton(
              onPressed: _pickingImages ? null : () => _pickImages(fromCamera: false),
              icon: Icon(Icons.add_photo_alternate_outlined, size: 22, color: ink3),
              tooltip: L10n.t('继续添加', 'Add more'),
            ),
          ],
        ),
      ),
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
      showToast(context, '${L10n.t('命令列表加载失败：', 'Failed to load commands: ')}$e');
      return;
    }
    if (!mounted) return;
    // v2.9.0 review(LOW#13)：区分"命令服务不可用"与"会话无命令"
    if (unavailable) {
      showToast(context, L10n.t('当前 DSH 未提供命令服务', 'Command service is unavailable in this DSH'));
      return;
    }
    if (cmds.isEmpty) {
      showToast(context, L10n.t('当前会话没有可用命令', 'No commands available for this session'));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                  Text(L10n.t('命令', 'Commands'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            // v2.8.0 review(P3-6)：过滤无名命令，避免填入 '/null'
            for (final c in cmds.where((c) => c['name'] is String && (c['name'] as String).isNotEmpty))
              ListTile(
                dense: true,
                leading: const Icon(Icons.tag, size: 18),
                title: Text('/${c['name']}', style: const TextStyle(fontSize: 14)),
                subtitle: c['description'] is String && (c['description'] as String).isNotEmpty
                    ? Text(c['description'] as String, style: TextStyle(fontSize: 12, color: DshColors.ink3(ctx)))
                    : null,
                onTap: () => Navigator.of(ctx).pop('/${c['name']}'),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // 对齐 PC 端 leadingInput：命令名填入输入框，用户可补参数后发送
    _inputCtrl.text = '$picked ';
    _inputCtrl.selection = TextSelection.collapsed(offset: _inputCtrl.text.length);
    _onDraftChanged();
  }

  /// 上下文占用比例（已用 tokens / 模型上下文窗口），数据缺失时为 null。
  /// 上下文窗口来自服务端 usage 接口（request/context 事件捕获，与 PC 端圆环同源）。
  /// 口径与 PC 端一致：最近一次请求的 prompt 侧 token（pressureTokens），
  /// 而非历史累计总量（旧版服务端无该字段时回退累计和）。
  double? get _contextRatio {
    if (_usage.isEmpty) return null;
    final window = (_usage['contextWindow'] as num?)?.toInt();
    if (window == null || window <= 0) return null;
    final used = (_usage['pressureTokens'] as num?)?.toDouble() ??
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
      final attachment = value['type'] == 'image' && value['attachment'] is Map ? value['attachment'] : value;
      final attachmentId = attachment is Map ? attachment['attachmentId']?.toString() : null;
       final mediaType = attachment is Map ? attachment['mediaType']?.toString() ?? '' : '';
       final isImage = imageContext || value['type'] == 'image' || mediaType.startsWith('image/');
      if (isImage && attachmentId != null && attachmentId.isNotEmpty && seen.add(attachmentId)) {
        out.add({
          'attachmentId': attachmentId,
          'mediaType': attachment['mediaType']?.toString() ?? 'image/jpeg',
          if (attachment['width'] is num) 'width': attachment['width'],
          if (attachment['height'] is num) 'height': attachment['height'],
          if (attachment['name'] is String && (attachment['name'] as String).isNotEmpty) 'name': attachment['name'],
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
      final attachment = value['attachment'] is Map ? value['attachment'] as Map : value;
      final id = (attachment['attachmentId'] ?? attachment['id'])?.toString();
      final mediaType = attachment['mediaType']?.toString() ?? attachment['mimeType']?.toString() ?? '';
      final isImage = value['type'] == 'image' || mediaType.startsWith('image/');
      final path = (attachment['path'] ?? attachment['filePath'])?.toString();
      final name = attachment['name']?.toString() ?? path?.split(RegExp(r'[/\\]')).last;
      if (!isImage && (id != null && id.isNotEmpty || path != null && path.isNotEmpty) && seen.add(id ?? path!)) {
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

  String _prettyTimeline(Map<String, dynamic> value) {
    try {
      final text = JsonEncoder.withIndent('  ').convert(value);
      const maxChars = 240000;
      return text.length <= maxChars ? text : '${text.substring(0, maxChars)}\n… (debug preview truncated)';
    } catch (_) {
      return value.toString();
    }
  }

  String _failureKey(_MsgItem item) => item.kind == _MsgKind.tool
      ? 'tool:${item.toolCallId ?? item.seq}'
      : 'event:${item.eventType}:${item.seq ?? item.text}';

  void _autoLoadFailureDetail(_MsgItem item) {
    final key = '${_failureKey(item)}:${item.detailSeq ?? item.seq}';
    if (_failureDetailRequests.add(key)) _loadEventDetail(item);
  }

  Future<void> _loadEventDetail(_MsgItem item) async {
    final id = _mySessionId ?? widget.store.sessionId;
    final detailSeq = item.detailSeq ?? item.seq;
    if (id == null || detailSeq == null || item.detailLoading || !_api.timelineCapabilities.detail) return;
    final generation = _loadGeneration;
    final loading = item.kind == _MsgKind.tool
        ? item.copyTool(detailLoading: true, clearDetailError: true)
        : item.kind == _MsgKind.assistant
            ? item.copyAssistant(detailLoading: true, clearDetailError: true)
            : item.copyEvent(detailLoading: true, clearDetailError: true);
    if (mounted) setState(() => _replaceTimelineItem(item, loading));
    try {
      final detail = await _api.eventDetail(id, detailSeq);
      final full = detail.event;
      final data = full['data'] is Map ? Map<String, dynamic>.from(full['data'] as Map) : <String, dynamic>{};
      String textOf(Object? value) {
        if (value is String) return value;
        if (value is List) return value.map(textOf).where((text) => text.isNotEmpty).join();
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
        setState(() => _replaceTimelineItem(item, current.copyTool(detailLoading: false)));
        return;
      }
      if (current.kind == _MsgKind.tool) {
        final args = data['arguments'] is String ? data['arguments'] as String : (data['arguments'] == null ? current.toolArguments : JsonEncoder.withIndent('  ').convert(data['arguments']));
        final directResult = textOf(data['text']);
        final nestedResult = textOf(data['result']).isNotEmpty ? textOf(data['result']) : textOf(data['message']);
        final result = directResult.isNotEmpty ? directResult : (nestedResult.isNotEmpty ? nestedResult : current.toolResult);
        setState(() => _replaceTimelineItem(item, current.copyTool(
          arguments: args,
          result: result,
          error: data['isError'] == true || current.toolError,
          images: _imagesOf(data).isNotEmpty ? _imagesOf(data) : current.images,
          rawData: full,
          files: _filesOf(data).isNotEmpty ? _filesOf(data) : current.files,
          detailAvailable: true,
          detailLoading: false,
          detailDegraded: detail.degraded,
          detailMode: detail.detailMode,
          clearDetailError: true,
        )));
      } else if (current.kind == _MsgKind.assistant) {
        // 正文口径（issue #1 需求变更）：只认服务端给出的规范化 text（与摘要同一
        // blocksToText 口径，已跳过 reasoning/内部块）。**不得**递归拼接 message.content
        // ——那会把 reasoning 并进正文，使思维链在折叠块之外重复出现。
        final canonical = timelineDetailText(data);
        final fullText = canonical ?? '';
        setState(() => _replaceTimelineItem(item, current.copyAssistant(
          text: fullText.isNotEmpty ? fullText : current.text,
          rawData: full,
          files: _filesOf(data).isNotEmpty ? _filesOf(data) : current.files,
          detailAvailable: true,
          detailLoading: false,
          detailDegraded: detail.degraded,
          detailMode: detail.detailMode,
          clearDetailError: true,
          detailTextChars: fullText.isNotEmpty ? fullText.length : current.detailTextChars,
        )));
      } else {
        setState(() => _replaceTimelineItem(item, current.copyEvent(
          rawData: full,
          detailLoading: false,
          detailDegraded: detail.degraded,
          detailMode: detail.detailMode,
          clearDetailError: true,
        )));
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      final current = _currentTimelineItem(item);
      if (current == null || ((current.kind == _MsgKind.tool || current.kind == _MsgKind.assistant) && current.detailSeq != detailSeq)) return;
      final code = e is ApiException ? (e.code ?? 'event-detail-unavailable') : 'event-detail-unavailable';
      final fallback = current.kind == _MsgKind.tool
          ? current.copyTool(detailErrorCode: code, detailLoading: false)
          : current.kind == _MsgKind.assistant
              ? current.copyAssistant(detailErrorCode: code, detailLoading: false)
              : current.copyEvent(detailErrorCode: code, detailLoading: false);
      setState(() => _replaceTimelineItem(item, fallback));
    }
  }

  Widget _buildItem(_MsgItem item) {
    switch (item.kind) {
      case _MsgKind.user:
        // v3.1.4（issue #12）：系统注入消息（内核 source.kind ≠ "user"）不当普通气泡铺屏，
        // 改为可折叠块——默认收起、点按展开，展开状态按 messageId 持久化（同思维链机制）。
        if (_isNoiseText(item.text)) return const SizedBox.shrink();
        if (item.injected && !widget.store.timelineDebug) return const SizedBox.shrink();
        if (item.injected) {
          final ikey = item.messageId ?? 's${item.seq}';
          final expanded = widget.store.reasoningOverrideOf(_mySessionId ?? '', 'inj:$ikey') ?? false;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InjectedBubble(
                  text: item.text,
                  sourceKind: item.sourceKind,
                  expanded: expanded,
                  // setReasoningOverride 是 async（内部同步更新内存映射、再异步落盘）：
                  // 必须放在 setState 之外，否则 setState 的闭包返回 Future → debug/profile
                  // 构建下每次点按都会断言失败且展开状态不生效。
                  onToggle: (v) {
                    widget.store.setReasoningOverride(_mySessionId ?? '', 'inj:$ikey', v);
                    setState(() {});
                  },
                ),
                if (expanded && (item.images.isNotEmpty || item.files.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ImagesGrid(images: item.images, sessionId: _mySessionId ?? ''),
                        if (item.files.isNotEmpty) _FileResults(files: item.files),
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
              userBubble(_ImagesGrid(images: images, sessionId: _mySessionId ?? '')),
             if (item.files.isNotEmpty)
               userBubble(_FileResults(files: item.files)),
            if (text.isNotEmpty)
              userBubble(Text(text, style: const TextStyle(fontSize: 15, height: 1.5))),
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AssistantBubble(
              text: item.text,
              usage: item.usage,
              images: item.images,
              sessionId: _mySessionId ?? '',
              streaming: false,
              reasoning: item.reasoning,
              defaultExpanded: widget.store.reasoningDefaultExpanded,
              expandedOverride: widget.store.reasoningOverrideOf(_mySessionId ?? '', rk),
              // 同上：异步方法不得放进 setState 闭包（否则点按思维链折叠会断言失败）
              onOverride: (v) {
                widget.store.setReasoningOverride(_mySessionId ?? '', rk, v);
                setState(() {});
              },
            ),
            if (item.detailDegraded)
               Padding(
                 padding: const EdgeInsets.only(left: 4, bottom: 4),
                 child: Text(L10n.t('详情来自当前界面，可能不完整', 'Details came from the current surface and may be incomplete'), style: TextStyle(fontSize: 11, color: Colors.orange)),
               ),
             if (item.detailErrorCode != null)
               Padding(
                 padding: const EdgeInsets.only(left: 4, bottom: 4),
                 child: Row(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     Text(_detailErrorLabel(item.detailErrorCode!), style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
                     TextButton(onPressed: _api.timelineCapabilities.detail ? () => _loadEventDetail(item) : null, child: Text(L10n.t('重试', 'Retry'))),
                   ],
                 ),
               ),
             // 需求变更（issue #1）：assistant 产出文件不再展示（时间线不提供该下载入口）。
            // 详情入口（issue #1 需求变更）：普通模式只在**确有正文增量**时出现
             // （服务端 detail.textChars 大于当前可见正文长度）；调试模式提供原始事件入口。
             // 两者都不再默认出现“看着像能加载更多、实际只会多出一份思维链”的按钮。
             if (item.detailAvailable && item.seq != null && (widget.store.timelineDebug || timelineHasTextIncrement(item.detailTextChars, item.text.length)))
               Padding(
                 padding: const EdgeInsets.only(left: 4, bottom: 4),
                 child: Row(
                   mainAxisSize: MainAxisSize.min,
                   children: [
  if (item.detailLoading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                     TextButton(
                       onPressed: _api.timelineCapabilities.detail ? () => _loadEventDetail(item) : null,
                       child: Text(
                         widget.store.timelineDebug
                             ? (item.rawData == null ? L10n.t('查看原始事件', 'View raw event') : L10n.t('重新加载原始事件', 'Reload raw event'))
                             : (item.rawData == null ? L10n.t('加载完整正文', 'Load full response') : L10n.t('重新加载正文', 'Reload full response')),
                       ),
                     ),
                   ],
                 ),
               )
             else if (widget.store.timelineDebug && item.rawData == null && !item.detailAvailable)
               Padding(
                 padding: const EdgeInsets.only(left: 4, bottom: 4),
                 child: Text(L10n.t('详情不可用（旧服务端未保存）', 'Detail unavailable (not retained by server)'), style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
               ),
             if (widget.store.timelineDebug && item.rawData != null)
               Padding(
                 padding: const EdgeInsets.only(left: 4, bottom: 8),
                 child: SelectableText(_prettyTimeline(item.rawData!), style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
               ),
             _MessageActionsBar(
              item: item,
              onAction: (a) => _runMessageAction(item, a),
            ),
          ],
        );
      case _MsgKind.tool:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ToolActivityCard(
            key: ValueKey<String>('tool:${item.toolCallId ?? item.seq ?? item.text}:${item.seq}'),
             expandedOverride: _failureExpansionOverrides['tool:${item.toolCallId ?? item.seq}'],
             onExpandedOverride: (value) => setState(() => _failureExpansionOverrides['tool:${item.toolCallId ?? item.seq}'] = value),
             onAutoLoadDetail: () => _autoLoadFailureDetail(item),
            item: item,
            debug: widget.store.timelineDebug,
            sessionId: _mySessionId ?? '',
            onLoadDetail: _api.timelineCapabilities.detail && item.detailAvailable && item.detailSeq != null ? () => _loadEventDetail(item) : null,
          ),
        );
      case _MsgKind.event:
        // 协议/运行时元数据在普通模式不渲染（模型里仍保留 seq 与详情指针）；
        // 调试模式完整呈现。可见性判据与模型侧共用同一实现。
        if (!timelineTypeVisibleIn(
            widget.store.timelineDebug ? TimelineMode.debug : TimelineMode.ordinary, item.eventType ?? '')) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _TimelineEventCard(
            key: ValueKey<String>('event:${item.eventType}:${item.seq ?? item.text}'),
             expandedOverride: _failureExpansionOverrides['event:${item.eventType}:${item.seq ?? item.text}'],
             onExpandedOverride: (value) => setState(() => _failureExpansionOverrides['event:${item.eventType}:${item.seq ?? item.text}'] = value),
             onAutoLoadDetail: () => _autoLoadFailureDetail(item),
            item: item,
            debug: widget.store.timelineDebug,
            onLoadDetail: _api.timelineCapabilities.detail && item.detailAvailable && item.detailSeq != null ? () => _loadEventDetail(item) : null,
          ),
        );
      case _MsgKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(item.text, style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
          ),
        );
    }
  }
}

// ── 消息模型 ──
enum _MsgKind { user, assistant, divider, tool, event }

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
  _MsgItem.user(this.text, {this.seq, this.messageId, this.images = const [], this.files = const [], this.sourceKind, this.detailTextChars})
      : kind = _MsgKind.user,
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
        detailErrorCode = null;
  _MsgItem.assistant(this.text, {this.usage, this.seq, this.messageId, this.rating, this.images = const [], this.files = const [], this.reasoning, this.detailAvailable = false, this.rawData, this.detailLoading = false, this.detailDegraded = false, this.detailMode, this.detailErrorCode, this.detailTextChars})
      : kind = _MsgKind.assistant,
        latestSeq = seq,
        detailSeq = seq,
        sourceKind = null,
        toolCallId = null,
        toolName = null,
        toolArguments = '',
        toolResult = '',
        toolStatus = 'complete',
        toolError = false,
        eventType = null;
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
        detailErrorCode = null;
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
  })  : kind = _MsgKind.tool,
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
  })  : kind = _MsgKind.event,
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
        toolStatus = 'complete';

  /// 注入消息（非真人发言）→ 渲染成可折叠块，而不是普通气泡（v3.1.4）
  bool get injected => sourceKind != null && sourceKind != 'user';

  _MsgItem copyWith({int? seq, String? messageId}) {
    assert(kind == _MsgKind.user, 'copyWith only supports user items');
    return _MsgItem.user(text, seq: seq ?? this.seq, messageId: messageId ?? this.messageId, images: images, files: files, sourceKind: sourceKind, detailTextChars: detailTextChars);
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
        detailErrorCode: clearDetailError ? null : (detailErrorCode ?? this.detailErrorCode),
        detailTextChars: detailTextChars,
      );

  _MsgItem copyAssistant({String? text, List<Map<String, dynamic>>? files, Map<String, dynamic>? rawData, bool? detailAvailable, bool? detailLoading, bool? detailDegraded, String? detailMode, String? detailErrorCode, bool clearDetailError = false, int? detailTextChars}) => _MsgItem.assistant(
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
        detailErrorCode: clearDetailError ? null : (detailErrorCode ?? this.detailErrorCode),
        detailTextChars: detailTextChars ?? this.detailTextChars,
      );

  _MsgItem copyEvent({Map<String, dynamic>? rawData, bool? detailLoading, bool? detailDegraded, String? detailMode, String? detailErrorCode, bool clearDetailError = false}) => _MsgItem.event(
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
        detailErrorCode: clearDetailError ? null : (detailErrorCode ?? this.detailErrorCode),
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
    required this.text,
    required this.sourceKind,
    required this.expanded,
    required this.onToggle,
  });

  String get _label {
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

  @override
  Widget build(BuildContext context) {
    final ink3 = DshColors.ink3(context);
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
                  Icon(Icons.settings_suggest_outlined, size: 14, color: ink3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$_label · ${text.length} ${L10n.t('字', 'chars')}',
                      style: TextStyle(fontSize: 11.5, color: ink3, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 16, color: ink3),
                ],
              ),
            ),
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: ink3)),
              ),
            ),
        ],
      ),
    );
  }
}

String _detailErrorLabel(String code) {
  switch (code) {
    case 'session-not-found': return L10n.t('会话不存在', 'Session not found');
    case 'event-not-found': return L10n.t('事件不存在', 'Event not found');
    case 'session-corrupt': return L10n.t('会话数据损坏', 'Session data is corrupt');
    case 'event-detail-too-large': return L10n.t('事件详情过大', 'Event details are too large');
    case 'event-read-failed': return L10n.t('事件详情读取失败', 'Could not read event details');
    default: return L10n.t('详情暂时不可用', 'Details are temporarily unavailable');
  }
}

class _ToolActivityCard extends StatefulWidget {
  final _MsgItem item;
  final bool debug;
  final String sessionId;
  final bool? expandedOverride;
  final ValueChanged<bool>? onExpandedOverride;
  final VoidCallback? onLoadDetail;
  final VoidCallback? onAutoLoadDetail;
  const _ToolActivityCard({super.key, required this.item, required this.debug, required this.sessionId, this.expandedOverride, this.onExpandedOverride, this.onLoadDetail, this.onAutoLoadDetail});

  @override
  State<_ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<_ToolActivityCard> {
  bool expanded = false;
  bool requested = false;
  bool userOverride = false;

  bool get _failed => widget.item.toolError || widget.item.toolStatus == 'failed';
  bool get _defaultExpanded => widget.debug && _failed;

  void _requestDetailIfNeeded() {
    if (expanded && !requested && widget.item.detailSeq != null && widget.onAutoLoadDetail != null && !widget.item.detailLoading) {
      requested = true;
      widget.onAutoLoadDetail!();
    }
  }

  @override
  void initState() {
    super.initState();
    expanded = widget.expandedOverride ?? _defaultExpanded;
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
    if (!userOverride && (_failed || oldWidget.debug != widget.debug)) expanded = _defaultExpanded;
    if (override != null && override != expanded) expanded = override;
    if (oldWidget.item.toolCallId != widget.item.toolCallId || oldWidget.item.detailSeq != widget.item.detailSeq || oldWidget.debug != widget.debug) {
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
    if (widget.item.toolStatus == 'failed' || widget.item.toolError) return L10n.t('失败', 'Failed');
    if (widget.item.toolStatus == 'success') return L10n.t('成功', 'Succeeded');
    return L10n.t('进行中', 'Running');
  }

  String _pretty(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      final text = JsonEncoder.withIndent('  ').convert(value);
       const maxChars = 240000;
       return text.length <= maxChars ? text : '${text.substring(0, maxChars)}\n… (debug preview truncated)';
    } catch (_) {
      return value.toString();
    }
  }

  bool _looksMarkdown(String value) => value.contains('```') ||
       RegExp(r'(^|\n)\s{0,3}(#{1,6} |[-*] |\d+\. )').hasMatch(value) ||
       value.contains('**') || value.contains('`');

   Widget _markdownResult(String value) => Padding(
         padding: const EdgeInsets.only(top: 8),
         child: Container(
           width: double.infinity,
           padding: const EdgeInsets.all(8),
           decoration: BoxDecoration(color: DshColors.surface(context), borderRadius: BorderRadius.circular(6)),
           child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: renderMarkdownBlocks(value, context)),
         ),
       );

   Widget _code(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DshColors.ink3(context))),
            const SizedBox(height: 3),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: DshColors.surface(context), borderRadius: BorderRadius.circular(6)),
              child: SingleChildScrollView(child: SelectableText(value, style: const TextStyle(fontSize: 11, height: 1.35, fontFamily: 'monospace'))),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // 工具 schema 目前只在少数内核/服务端形态下随详情下发（tool/call 的 data 里）；
    // 内核 SessionEventMap 的 tool/call 只有 turn/step/callId/name/arguments，
    // 因此这里读不到就不显示，不做任何猜测重建。
    final raw = item.rawData;
    final rawData = raw?['data'] is Map ? raw!['data'] as Map : const {};
    final schema = raw?['toolSchema'] ??
        raw?['schema'] ??
        raw?['inputSchema'] ??
        rawData['toolSchema'] ??
        rawData['schema'] ??
        rawData['inputSchema'];
    final accent = item.toolError ? Colors.redAccent : DshColors.brand(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: item.toolError ? Colors.redAccent.withValues(alpha: .5) : DshColors.line(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _setExpanded(!expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(item.toolError ? Icons.error_outline : Icons.build_outlined, size: 16, color: accent),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(item.toolName ?? L10n.t('工具', 'Tool'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  ),
                  Text(_status(), style: TextStyle(fontSize: 11, color: item.toolError ? Colors.redAccent : DshColors.ink3(context))),
                  const SizedBox(width: 4),
                  Icon(expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18, color: DshColors.ink3(context)),
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
                  if (item.toolCallId != null) Text('callId: ${item.toolCallId}', style: TextStyle(fontSize: 10, color: DshColors.ink3(context))),
                  if (item.toolArguments.isNotEmpty) _code(L10n.t('参数', 'Arguments'), item.toolArguments),
                  if (item.toolResult.isNotEmpty)
                     _looksMarkdown(item.toolResult) && !widget.debug
                         ? _markdownResult(item.toolResult)
                         : _code(L10n.t('结果', 'Result'), item.toolResult),
                  if (item.images.isNotEmpty) Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ImagesGrid(images: item.images, sessionId: widget.sessionId),
                   ),
                  // 需求变更（issue #1）：工具产出文件不再展示（时间线不提供该下载入口）。
                  if (item.detailLoading) const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                  ),
                  if (item.detailDegraded)
                     Padding(
                       padding: const EdgeInsets.only(top: 8),
                       child: Text(L10n.t('详情来自当前界面，可能不完整', 'Details came from the current surface and may be incomplete'), style: TextStyle(fontSize: 11, color: Colors.orange)),
                     ),
                   if (item.detailErrorCode != null)
                     Padding(
                       padding: const EdgeInsets.only(top: 8),
                       child: Text(_detailErrorLabel(item.detailErrorCode!), style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                     ),
                   if (!item.detailAvailable && item.rawData == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(L10n.t('详情不可用（旧服务端未保存）', 'Details unavailable (not retained by the server)'), style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
                    ),
                  if (item.detailErrorCode != null && widget.onLoadDetail != null)
                    TextButton(onPressed: () { requested = false; widget.onLoadDetail!(); }, child: Text(L10n.t('重试', 'Retry'))),
                  if (widget.debug && schema != null) _code(L10n.t('工具 schema', 'Tool schema'), _pretty(schema)),
                   if (widget.debug && item.rawData != null) _code(L10n.t('原始事件', 'Raw event'), _pretty(item.rawData)),
                ],
              ),
            ),
        ],
      ),
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
  const _TimelineEventCard({super.key, required this.item, required this.debug, this.expandedOverride, this.onExpandedOverride, this.onLoadDetail, this.onAutoLoadDetail});

  @override
  State<_TimelineEventCard> createState() => _TimelineEventCardState();
}

class _TimelineEventCardState extends State<_TimelineEventCard> {
  bool expanded = false;
  bool requested = false;
  bool userOverride = false;

  bool get _defaultExpanded => widget.debug && widget.item.toolError;

  @override
  void initState() {
    super.initState();
    expanded = widget.expandedOverride ?? _defaultExpanded;
    userOverride = widget.expandedOverride != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && expanded && !requested && widget.onAutoLoadDetail != null) {
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
    if (!userOverride && (oldWidget.debug != widget.debug || widget.item.toolError)) expanded = _defaultExpanded;
    if (override != null && override != expanded) expanded = override;
    if (oldWidget.item.seq != widget.item.seq || oldWidget.debug != widget.debug) {
      requested = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && expanded && widget.onAutoLoadDetail != null && !widget.item.detailLoading) {
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
    String raw() {
      try {
        final text = JsonEncoder.withIndent('  ').convert(item.rawData);
        const maxChars = 240000;
        return text.length <= maxChars ? text : '${text.substring(0, maxChars)}\n… (debug preview truncated)';
      } catch (_) {
        return item.rawData.toString();
      }
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: DshColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: item.toolError ? Colors.redAccent.withValues(alpha: .5) : DshColors.line(context)),
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
                  Icon(item.toolError ? Icons.error_outline : Icons.bolt_outlined, size: 15, color: DshColors.ink3(context)),
                  const SizedBox(width: 7),
                  Expanded(child: Text(item.text.split('\n').first, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                  if (item.seq != null) Text('#${item.seq}', style: TextStyle(fontSize: 10, color: DshColors.ink3(context))),
                  const SizedBox(width: 4),
                  Icon(expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 17, color: DshColors.ink3(context)),
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
                  if (item.text.contains('\n')) Padding(padding: const EdgeInsets.only(top: 6), child: Text(item.text.substring(item.text.indexOf('\n') + 1), style: const TextStyle(fontSize: 12, height: 1.4))),
                  if (item.detailLoading) const Padding(padding: EdgeInsets.only(top: 8), child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))),
                  if (item.detailDegraded)
                     Padding(
                       padding: const EdgeInsets.only(top: 8),
                       child: Text(L10n.t('详情来自当前界面，可能不完整', 'Details came from the current surface and may be incomplete'), style: TextStyle(fontSize: 11, color: Colors.orange)),
                     ),
                   if (item.detailErrorCode != null)
                     Padding(
                       padding: const EdgeInsets.only(top: 8),
                       child: Text(_detailErrorLabel(item.detailErrorCode!), style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                     ),
                   if (!item.detailAvailable && item.rawData == null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(L10n.t('详情不可用', 'Details unavailable'), style: TextStyle(fontSize: 11, color: DshColors.ink3(context)))),
                  if (item.detailErrorCode != null && widget.onLoadDetail != null)
                    TextButton(onPressed: () { requested = false; widget.onLoadDetail!(); }, child: Text(L10n.t('重试', 'Retry'))),
                  if (widget.debug && item.rawData != null) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(raw(), style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
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
                    style: TextStyle(fontSize: 11.5, color: ink3, fontWeight: FontWeight.w600),
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
                  Icon(collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 15, color: ink3),
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
                                color: todo['status'] == 'completed' ? ink3 : brand,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${todo['content'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: todo['status'] == 'completed' ? ink3 : ink2,
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
  // 思维链正文（null/空 = 不渲染折叠块）
  final String? reasoning;
  // 设置项：思维链默认折叠还是展开
  final bool defaultExpanded;
  // 用户手动切换的覆盖值（null = 跟随设置项）；提升到界面层按消息持久化，列表回收重建不丢
  final bool? expandedOverride;
  final ValueChanged<bool>? onOverride;
  const _AssistantBubble({
    required this.text,
    this.usage,
    this.images = const [],
    this.sessionId = '',
    this.streaming = false,
    this.reasoning,
    this.defaultExpanded = false,
    this.expandedOverride,
    this.onOverride,
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
    final cacheKey = '${widget.text}\u0000${Theme.of(context).brightness}';
    if (cacheKey != _parsedFor) {
      _parsedFor = cacheKey;
      _blocks = renderMarkdownBlocks(widget.text.isEmpty ? '…' : widget.text, context);
      if (_parseLogs < 3) {
        _parseLogs++;
        AppLog.instance.log('Chat: bubble 解析 len=${widget.text.length} blocks=${_blocks!.length}');
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
                Text('✦ Agent',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DshColors.ink2(context))),
                const SizedBox(width: 7),
                if (widget.streaming)
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
              ],
            ),
            const SizedBox(height: 3),
            if (hasReasoning) _buildReasoningChain(context),
            ..._blocks!,
            // v3.0.0 图像链路：附图（agent 回复里的图片，点击全屏）
            if (widget.images.isNotEmpty) ...[
              const SizedBox(height: 6),
              _ImagesGrid(images: widget.images, sessionId: widget.sessionId),
            ],
            if (widget.usage != null &&
                ((widget.usage!['inputTokens'] as num? ?? 0) > 0 || (widget.usage!['outputTokens'] as num? ?? 0) > 0))
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
                      L10n.t('思维链 ${reasoning.length} 字', 'Thinking chain · ${reasoning.length} chars'),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
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
                style: TextStyle(fontSize: 12, height: 1.6, color: ink3, fontStyle: FontStyle.italic),
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

// ── v3.0.0 图像链路：消息附图渲染（按 attachmentId 经 /attachment 拉取字节，LRU 缓存） ──

/// 下载/保存目标目录。Android 优先应用外部私有目录（可经文件管理器/USB 访问），
/// 其它平台回退应用文档目录——`getExternalStorageDirectory()` 在 iOS 会抛
/// `UnsupportedError`，异常不会走到 `??` 的右操作数，必须显式 platform 判定 + try。
/// 两者都是**应用私有**目录，不会出现在系统相册/下载列表，提示文案需如实说明。
Future<Directory> _appSaveDirectory() async {
  if (Platform.isAndroid) {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    } catch (_) {
      // 外部存储不可用（无介质/被策略限制）→ 回退内部目录
    }
  }
  return getApplicationDocumentsDirectory();
}

/// 消息附件展示（issue #1 需求变更）：只显示文件名/类型/大小，**不提供下载**。
/// 工具与 assistant 产出的文件行已整体移除，这里只服务用户自己的附件。
class _FileResults extends StatelessWidget {
  final List<Map<String, dynamic>> files;
  const _FileResults({required this.files});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final file in files) _FileResultTile(file: file),
        ],
      );
}

class _FileResultTile extends StatelessWidget {
  final Map<String, dynamic> file;
  const _FileResultTile({required this.file});

  String get _label {
    final name = file['name']?.toString();
    if (name != null && name.isNotEmpty) return name;
    final path = file['path']?.toString();
    if (path != null && path.isNotEmpty) return path.split(RegExp(r'[/\\]')).last;
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
                  Text(_label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  if (mediaType != null || size != null)
                    Text(
                      [
                        if (mediaType != null && mediaType.isNotEmpty) mediaType,
                        if (size != null) '${(size / 1024).ceil()} KB',
                      ].join(' · '),
                      style: TextStyle(fontSize: 10, color: DshColors.ink3(context)),
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

class _ImagesGrid extends StatelessWidget {
  final List<Map<String, dynamic>> images;
  final String sessionId;
  const _ImagesGrid({required this.images, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final img in images) ...[
          if (img != images.first) const SizedBox(height: 6),
          _MsgImage(
            key: ValueKey<String>('$sessionId:${img['attachmentId']}'),
            image: img,
            sessionId: sessionId,
          ),
        ],
      ],
    );
  }
}

class _MsgImage extends StatefulWidget {
  final Map<String, dynamic> image;
  final String sessionId;
  const _MsgImage({super.key, required this.image, required this.sessionId});

  @override
  State<_MsgImage> createState() => _MsgImageState();
}

class _MsgImageState extends State<_MsgImage> {
  Uint8List? _bytes;
  bool _loading = true;
  int _loadToken = 0;

  String get _attachmentId => widget.image['attachmentId'] as String? ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _MsgImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.image['attachmentId'] as String? ?? '';
    if (oldId != _attachmentId || oldWidget.sessionId != widget.sessionId) {
      _loadToken++;
      _bytes = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    if (!_loading && mounted) setState(() => _loading = true);
    final id = _attachmentId;
    final sessionId = widget.sessionId;
    if (id.isEmpty || sessionId.isEmpty) {
      if (mounted && token == _loadToken) setState(() => _loading = false);
      return;
    }
    try {
      final bytes = await api.attachmentBytes(sessionId, id);
      if (!mounted || token != _loadToken || sessionId != widget.sessionId || id != _attachmentId) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || token != _loadToken || sessionId != widget.sessionId || id != _attachmentId) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _saveImage() async {
    final b = _bytes;
    if (b == null) return;
    try {
      final dir = await _appSaveDirectory();
      final media = widget.image['mediaType']?.toString() ?? 'image/jpeg';
      final ext = media.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
      final target = File('${dir.path}/dsh-$_attachmentId.${ext.isEmpty ? 'jpg' : ext}');
      await target.writeAsBytes(b, flush: true);
      if (mounted) showToast(context, '${L10n.t('已保存：', 'Saved: ')}${target.path}');
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('保存失败：', 'Save failed: ')}$e');
    }
  }

  void _openFull() {
    final b = _bytes;
    if (b == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Image.memory(b, fit: BoxFit.contain, width: double.infinity),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _saveImage,
                    tooltip: L10n.t('保存图片', 'Save image'),
                    icon: const Icon(Icons.download_outlined, color: Colors.white),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = (widget.image['width'] as num?)?.toDouble() ?? 4;
    final h = (widget.image['height'] as num?)?.toDouble() ?? 3;
    // v3.0.0：竖图完整显示——比例不再硬收进方形（旧：clamp 0.4~2.5 且高上限 236 = 方形裁剪），
    // 上限放宽到 480 并配合 BoxFit.contain（cover 会把竖图裁成中间一条，即"显示不全"的根因）
    final ratio = (w > 0 && h > 0) ? (w / h).clamp(0.3, 3.0) : 1.5;
    final boxW = 236.0;
    final boxH = (boxW / ratio).clamp(80.0, 480.0);
    final line = DshColors.line(context);
    // v3.0.0(版本二)：GIF 动图 Flutter 原生支持（MultiFrameImageStreamCompleter 逐帧播放），
    // 无需第三方包；超大 GIF（长边>4096 或 >16MB）解码耗 CPU/首帧慢，加"GIF·原图较大"角标提醒
    final isGif = widget.image['mediaType'] == 'image/gif';
    final bigGif = isGif &&
        ((w > 0 && h > 0 && (w > 4096 || h > 4096)) || (_bytes?.length ?? 0) > 16 * 1024 * 1024);
    return GestureDetector(
      onTap: _bytes != null ? _openFull : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: boxW,
          height: boxH,
          color: line,
          child: _loading
              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : _bytes != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(_bytes!, fit: BoxFit.contain, gaplessPlayback: true),
                        if (bigGif)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(L10n.t('GIF·原图较大', 'GIF · large file'),
                                  style: const TextStyle(fontSize: 9.5, color: Colors.white)),
                            ),
                          ),
                      ],
                    )
                  : InkWell(
                      onTap: _load,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image_outlined, size: 24, color: DshColors.ink3(context)),
                            const SizedBox(height: 4),
                            Text(L10n.t('加载失败，点按重试', 'Failed to load — tap to retry'),
                                style: TextStyle(fontSize: 10.5, color: DshColors.ink3(context))),
                          ],
                        ),
                      ),
                    ),
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
  const _MessageActionsBar({required this.item, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final rating = item.rating;
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 14),
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
                ? L10n.t('好的回答（已选，点此取消）', 'Good answer (selected, tap to clear)')
                : L10n.t('好的回答', 'Good answer'),
            onTap: () => onAction('positive'),
          ),
          _ActionIcon(
            icon: Icons.thumb_down_alt_outlined,
            active: rating == 'negative',
            tooltip: rating == 'negative'
                ? L10n.t('有问题的回答（已选，点此取消）', 'Bad answer (selected, tap to clear)')
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
  const _ActionIcon({required this.icon, required this.tooltip, required this.onTap, this.active = false});

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
          child: Icon(icon, size: 15, color: active ? brand : DshColors.ink3(context)),
        ),
      ),
    );
  }
}

/// 活动条：agent 当前在干什么（思考中 / 工具执行中）。
/// 思考面板可展开看实时思考内容（仅 showContent 时）；工具执行结束即消失；正文流式开始后由文字本身反馈。
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
            ? L10n.t('正在执行 ${tools.length} 个工具（${tools.take(2).join('、')}${tools.length > 2 ? '…' : ''}）',
                'Running ${tools.length} tools (${tools.take(2).join('、')}${tools.length > 2 ? '…' : ''})')
            : '${L10n.t('正在调用 ', 'Calling ')}${tools.first}…');
    final thinking = !textStreaming;
    final header = expanded
        ? (thinking
            ? L10n.t('思考中，点此收起', 'Thinking — tap to collapse')
            : L10n.t('思考内容，点此收起', 'Thinking content — tap to collapse'))
        : (thinking
            ? L10n.t('思考中…（${reasoning.length} 字）', 'Thinking… (${reasoning.length} chars)')
            : L10n.t('已思考 ${reasoning.length} 字', 'Thought: ${reasoning.length} chars'));
    return Container(
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
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ink2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showContent)
                      Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: ink3),
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
                  style: TextStyle(fontSize: 12, height: 1.55, color: ink3, fontStyle: FontStyle.italic),
                ),
              ),
            ),
          if (tools.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: reasoning.isNotEmpty ? 4 : 0),
              child: Row(
                children: [
                  Icon(Icons.handyman_outlined, size: 15, color: ink2),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(toolLabel, style: TextStyle(fontSize: 12.5, color: ink2), overflow: TextOverflow.ellipsis),
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
  const _JobCard({required this.jobs, required this.onOpen, required this.onKill});

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
    final running = widget.jobs.where((j) => j['status'] == 'running' || j['status'] == 'stopping').toList();
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
                          ? L10n.t('后台任务 ${running.length} 个进行中', '${running.length} background tasks running')
                          : L10n.t('后台任务进行中', 'Background task running'),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ink2),
                    ),
                  ),
                  Icon(_expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 16, color: ink3),
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
                        (j['label'] as String? ?? j['id'] as String? ?? L10n.t('任务', 'Task')).toString(),
                        style: const TextStyle(fontSize: 11.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: j['status'] == 'stopping' ? null : () => widget.onKill(j['id'] as String? ?? ''),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 24),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        j['status'] == 'stopping'
                            ? L10n.t('停止中', 'Stopping')
                            : L10n.t('取消', 'Cancel'),
                        style: TextStyle(fontSize: 11, color: j['status'] == 'stopping' ? ink3 : DshColors.danger(context)),
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
      'waiting' => DshColors.warn(context),
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
                label: Text(L10n.t('查看更早的消息', 'View earlier messages'), style: TextStyle(fontSize: 12.5)),
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
    final bg = isDark ? Colors.white.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.88);
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: IgnorePointer(
        ignoring: !visible,
        child: Material(
          color: bg,
          shape: CircleBorder(side: BorderSide(color: DshColors.line(context), width: 0.8)),
          elevation: 2,
          shadowColor: Colors.black26,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(Icons.keyboard_arrow_down, size: 24, color: DshColors.ink2(context)),
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
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
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
        decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(999)),
        // v2.8.0 review(P1-2)：单行 + 省略号，避免长模型名撑爆胶囊行（旧 ListView 可滚、Row 不可）
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ink2),
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
  const _QuestionCard({required this.request, required this.onCancel, required this.onSubmitted});

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
        setState(() => _hint = L10n.t('请选择选项，或输入其他答案', 'Choose an option or type another answer'));
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
    final header = widget.request.questions.isEmpty ? null : widget.request.questions.first.header;
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
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
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
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: brand),
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
                  child: Text(q.detail!, style: TextStyle(fontSize: 11.5, color: ink3, height: 1.4)),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(q.question, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
                child: Text(_hint!, style: TextStyle(fontSize: 12, color: DshColors.danger(context))),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submitting ? null : widget.onCancel,
                  child: Text(L10n.t('取消', 'Cancel'), style: TextStyle(fontSize: 13.5, color: ink2)),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    backgroundColor: brand,
                  ),
                  onPressed: _submitting ? null : _submit,
                  child: Text(
                      _submitting ? L10n.t('提交中…', 'Submitting…') : L10n.t('提交', 'Submit'),
                      style: const TextStyle(fontSize: 13.5)),
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
                  : (selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
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
                    style: TextStyle(fontSize: 13.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                  ),
                  if (description != null && description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(description!, style: TextStyle(fontSize: 11.5, color: ink3, height: 1.35)),
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
  const _ApprovalCard({required this.request, required this.onDecide, required this.onCancel});

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
                child: Text(L10n.t('权限请求', 'Permission request'),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: warn)),
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
              L10n.t('工具「${widget.request.toolName}」需要你的授权',
                  'Tool “${widget.request.toolName}” needs your authorization'),
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          if (widget.request.reason != null && widget.request.reason!.isNotEmpty)
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
                child: Text(L10n.t('拒绝', 'Deny'), style: TextStyle(fontSize: 13.5, color: danger)),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  backgroundColor: warn,
                ),
                onPressed: _busy ? null : () => _decide('allowed-once'),
                child: Text(
                    _busy ? L10n.t('处理中…', 'Processing…') : L10n.t('允许一次', 'Allow once'),
                    style: const TextStyle(fontSize: 13.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}



