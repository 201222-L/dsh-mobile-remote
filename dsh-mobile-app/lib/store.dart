// 全局状态 + SSE 事件桥（对齐网页端 page.html 的 state / connect / handleEvent）
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'attention.dart';
import 'floating.dart';
import 'git_models.dart';
import 'l10n.dart';
import 'logger.dart';
import 'models.dart';
import 'session_list.dart';
import 'theme.dart';
import 'turn_process.dart';

/// 内核 `AgentStatus` 是 **`idle | running` 二元联合**（ADR 0013）——不存在 `waiting`。
/// 等待用户审批/作答时驱动仍在跑，属于 `running`；该事实由挂起的问询/审批独立承载。
/// 这里对未知取值统一归一到 `idle`（防御性猜测不再保留，避免列表出现永不消失的第三态）。
String normalizeAgentStatus(Object? status) =>
    status == 'running' ? 'running' : 'idle';

class AppStore extends ChangeNotifier {
  // ── 数据 ──
  String? sessionId; // 当前会话
  Catalog? catalog;
  SessionConfig sessionConfig = SessionConfig();
  List<Session> sessions = [];
  List<Map<String, dynamic>> actions = [];
  int unread = 0;
  String agentStatus = 'idle'; // idle | running（内核 AgentStatus 二元；无 waiting）

  /// v2.7.1：各 agent 最新状态映射（bootstrap + agent/status 帧维护）。
  final Map<String, String> agentStatusMap = {};

  /// SSE 的 agentId 与 sessionId 不是同一标识时，按 session 维护页面状态。
  final Map<String, String> sessionAgentStatus = {};

  /// issue #124/#133：主会话根 → 递归 running 子代理数（SSE agent/status 帧维护）。
  /// 值可为 0（显式“没有运行子代理”）；缺失时才回退 `/sessions` 字段或本地树聚合。
  final Map<String, int> subagentRunningByRoot = {};

  /// agent/status 帧计数（v3.1.6）：`/bootstrap` 是"某一刻的活跃 agent 全量快照"，
  /// 若快照请求期间已有更新帧落地，就跳过裁剪（只合并）——否则旧快照会抹掉刚到的 running。
  /// 下一轮 bootstrap 自然收敛，不必在这里赌时序。
  int _agentStatusEpoch = 0;
  String agentStatusForSession(String? id) {
    if (id == null) return agentStatus;
    final mapped = sessionAgentStatus[id] ?? agentStatusMap[id];
    if (mapped != null) return mapped;
    if (id != sessionId) return 'idle';
    // issue #133（复审 P2）：legacy 全局 agentStatus 只代表“当前打开的 agent”。
    // 当前会话是子代理时，断链清理映射后这里曾继续回退到旧 running，导致主会话
    // 经本地树聚合误报；子代理查询一律屏蔽该回退（根会话语义不变）。
    if (_isKnownSubagentSession(id)) return 'idle';
    return agentStatus;
  }

  bool _isKnownSubagentSession(String id) {
    for (final s in sessions) {
      if (s.id == id) return s.isSubagent;
    }
    return false;
  }
  String darkMode = 'system'; // system | dark | light
  DshSkin skin = DshSkin.dsh; // 主题皮肤（默认 / 深潜夜航 / 海盐汽水 / 鲸落星海）
  String appIcon = 'default'; // 桌面图标样式 id（default/deepsea/shell/moon/sticker/stamp/neon/mono）
  bool showReasoning = false; // 活动条思考面板是否显示内容（默认关：只显示状态，防英文思考刷屏）
  /// 会话文件浏览是否显示点开头的隐藏条目（默认开；`.git` 始终排除）。
  bool showHiddenFiles = true;
  bool reasoningDefaultExpanded = false; // 思维链默认展开还是折叠（默认折叠：防英文思考刷屏；单条消息仍可点按切换）
  bool timelineDebug = false; // 普通/调试模式：默认普通，调试显示原始事件详情
  /// issue #52（ADR 0027 §2）：工作步骤展示模式（四档）与收起时机（两档）。
  /// 偏好只存手机本地（不新增宿主设置端点）；默认「标准」+「回答结束后」。
  WorkStepDisplayMode stepDisplayMode = WorkStepDisplayMode.standard;
  /// issue #86：Git 分支图选中上限（全局偏好）。
  GitGraphBranchLimit gitGraphBranchLimit = GitGraphBranchLimit.fallback;
  TurnFoldTiming turnFoldTiming = TurnFoldTiming.afterAnswer;

  /// 思维链折叠手动状态（会话 -> 消息key -> 手动展开值；滚动/重进/重启持久，null=跟随设置默认）
  Map<String, Map<String, bool>> reasoningOverrides = {};
  String language = 'zh'; // zh | en（v2.7：界面语言，持久化）
  bool balanceAlert = false; // 余额预警开关（v2.7：低于阈值提醒充值）
  double balanceThreshold = 10; // 预警阈值（元）
  /// Git 浏览页显示的 Tab 顺序（最多三个）；配置跨 App 启动持久化。
  List<String> gitTabs = const ['branches', 'graph', 'worktree'];
  static const gitTabIds = ['branches', 'graph', 'worktree', 'fileHistory'];
  static const _defaultGitTabs = ['branches', 'graph', 'worktree'];

  /// Chat-page action rail order, shared across conversations on this device.
  ///
  /// 新增动作时**必须同步 [conversationActionIds]**：持久化的旧顺序因长度不等
  /// 会被 [_validConversationActionOrder] 判为无效，自动回退到新默认顺序
  /// （用户只丢一次自定义排序，不会拿到缺项或未知项的脏数据）。
  List<String> conversationActionOrder = const [
    'git',
    'files',
    'session_tools',
    'copy',
  ];
  static const conversationActionIds = [
    'git',
    'files',
    'session_tools',
    'copy',
  ];
  static const _defaultConversationActionOrder = [
    'git',
    'files',
    'session_tools',
    'copy',
  ];
  bool floatingEnabled = false; // 桌面宠物开关（沿用旧悬浮球 key，v2.7.2 起持久化）
  int petHeight = 96; // 宠物画布高度 dp（56~160）
  bool petReducedMotion = false; // 减少动效：宠物静态姿势 + 首页角色/背景静止
  bool petEdgeHide = true; // 贴边 5 秒后自动躲藏/虚化
  bool petHideInApp = true; // App 在前台时收起桌面宠物（避免与首页角色同屏 + 挡住按钮）

  /// 已注册工作区（PC 端 workspaceRegistry）：[{id, path, title}]。
  List<Map<String, dynamic>> workspaces = [];

  /// 当前选中的工作区路径（null = 全部）。影响会话列表过滤与新建会话默认目录。
  String? workspacePath;

  /// 内核待回答的问询/审批（弹窗数据，与 PC 端同一 pending 通道；断线重连后服务端会补发）。
  QuestionRequest? pendingQuestion;
  ApprovalRequest? pendingApproval;
  final Map<String, QuestionRequest> _pendingQuestionsBySession = {};
  final Map<String, ApprovalRequest> _pendingApprovalsBySession = {};
  QuestionRequest? questionForSession(String? id) => id == null
      ? pendingQuestion
      : _pendingQuestionsBySession[id] ??
            (pendingQuestion?.sessionId == id ? pendingQuestion : null);
  ApprovalRequest? approvalForSession(String? id) => id == null
      ? pendingApproval
      : _pendingApprovalsBySession[id] ??
            (pendingApproval?.sessionId == id ? pendingApproval : null);

  QuestionRequest? _questionForRpc(Object? rpcId) {
    for (final q in _pendingQuestionsBySession.values) {
      if (q.rpcId == rpcId) return q;
    }
    return pendingQuestion?.rpcId == rpcId ? pendingQuestion : null;
  }

  ApprovalRequest? _approvalForId(Object? approvalId) {
    for (final a in _pendingApprovalsBySession.values) {
      if (a.approvalId == approvalId) return a;
    }
    return pendingApproval?.approvalId == approvalId ? pendingApproval : null;
  }

  ApprovalRequest? _approvalForRpc(Object? rpcId) {
    for (final a in _pendingApprovalsBySession.values) {
      if (a.rpcId == rpcId) return a;
    }
    return pendingApproval?.rpcId == rpcId ? pendingApproval : null;
  }

  void _clearPendingQuestion(Object? rpcId, [String? sessionId]) {
    _pendingQuestionsBySession.removeWhere(
      (sid, q) => q.rpcId == rpcId && (sessionId == null || sid == sessionId),
    );
    if (pendingQuestion?.rpcId == rpcId &&
        (sessionId == null || pendingQuestion?.sessionId == sessionId)) {
      pendingQuestion = null;
    }
  }

  void _clearPendingApproval(Object? rpcId, [String? sessionId]) {
    _pendingApprovalsBySession.removeWhere(
      (sid, a) => a.rpcId == rpcId && (sessionId == null || sid == sessionId),
    );
    if (pendingApproval?.rpcId == rpcId &&
        (sessionId == null || pendingApproval?.sessionId == sessionId)) {
      pendingApproval = null;
    }
  }

  // ── v2.7：会话级输入草稿（返回/切会话后恢复） ──
  final Map<String, String> _drafts = {};
  String draftOf(String sessionId) => _drafts[sessionId] ?? '';
  void saveDraft(String sessionId, String text) {
    if (text.isEmpty) {
      _drafts.remove(sessionId);
    } else {
      _drafts[sessionId] = text;
    }
  }

  void clearDraft(String sessionId) => _drafts.remove(sessionId);

  // ── v2.7：会话任务视图（session/jobs 帧，与 PC 端同源） ──
  final Map<String, List<Map<String, dynamic>>> jobsBySession = {};
  List<Map<String, dynamic>> jobsOf(String sessionId) =>
      jobsBySession[sessionId] ?? const [];
  bool hasRunningJobs(String sessionId) =>
      jobsBySession[sessionId]?.any(
        (j) => j['status'] == 'running' || j['status'] == 'stopping',
      ) ??
      false;

  // ── v3.0.0：会话排队消息镜像（内核 session/queue 帧权威源 + REST 兜底） ──
  // 修复此前 dock 陈旧问题：帧被丢弃、全靠 400ms 节流 REST + 20s 轮询，排队消息被 agent 认领后
  // 行残留、删除必然失败。帧到达即写；REST 结果仅在没有帧可依时兜底（帧永远更新，旧快照不覆盖）。
  final Map<String, List<Map<String, dynamic>>> queueBySession = {};
  final Set<String> _queueFramed = {};
  List<Map<String, dynamic>> queueOf(String sessionId) =>
      queueBySession[sessionId] ?? const [];
  void applyQueue(
    String sessionId,
    List<Map<String, dynamic>> rows, {
    required bool fromFrame,
  }) {
    if (!fromFrame && _queueFramed.contains(sessionId)) {
      return; // 帧为权威源：丢弃迟到的 REST 旧快照
    }
    if (fromFrame) _queueFramed.add(sessionId);
    queueBySession[sessionId] = rows;
    notifyListeners();
    _emitChatEvent(
      ChatEvent(
        type: 'mobile/queue',
        sessionId: sessionId,
        data: {'sessionId': sessionId},
      ),
    );
  }

  // ── 事件监听（聊天页挂载） ──
  // v2.7.2 review(M1)：单回调 → 监听器列表——叠层 ChatScreen（分支/悬浮球打开会话）
  // 不再互相覆盖，旧页 pop 回来仍能收到 SSE 事件（此前新页覆盖、dispose 置 null 导致旧页冻结）
  final List<void Function(ChatEvent ev)> _chatListeners = [];
  void addChatListener(void Function(ChatEvent ev) l) => _chatListeners.add(l);
  void removeChatListener(void Function(ChatEvent ev) l) =>
      _chatListeners.remove(l);
  void _emitChatEvent(ChatEvent ev) {
    for (final l in List.of(_chatListeners)) {
      try {
        l(ev);
      } catch (_) {
        // 单个监听器异常不影响其他页面
      }
    }
  }

  VoidCallback? onSessionsChanged; // 标题/预设变化 → 外部刷新

  /// 新增未读通知回调（横幅提示用）：参数 = 新增条数；force=true 时绕过 10 秒防抖
  /// （v2.7.1：悬浮球跳转/回前台时"错过的也提醒"）。
  void Function(int count, {bool force})? onNewNotifications;

  /// M1a：结构化事件（带 approvalId，身份稳定、可精确撤销）。
  void Function(AttentionEvent event)? onAttentionEvent;

  /// M1a：事件已结算（`approval/resolved` / `question/resolved`），参数是 identity。
  void Function(String identity)? onAttentionResolved;
  void Function(String source, Set<String> pendingKeys)? onAttentionSnapshot;

  /// S1：用户打开了某个会话——调用方应清掉该会话的横幅并标已读。
  void Function(String sessionId)? onChatOpened;

  /// 通知用户「进入了某会话」：撤横幅 + 该会话未读标已读。
  Future<void> notifyChatOpened(String sessionId) async {
    if (sessionId.isEmpty) return;
    onChatOpened?.call(sessionId);
    await markSessionNotifsRead(sessionId);
  }

  /// 把某会话的未读通知标为已读（S1：现在只有点单条才标已读，所以会积到几十条）。
  ///
  /// 缓存只是加速手段，不是真源（issue #96）：点系统通知进会话时 App 可能刚从后台
  /// 回来，缓存是旧的、不含这条通知——旧实现此时 `ids` 为空直接 return，一条都不标。
  /// 现在缓存里找不到该会话的未读时，先重拉一次服务端再判定。
  Future<void> markSessionNotifsRead(String sessionId) async {
    try {
      var items = notifs;
      if (items.isEmpty) {
        items = await api.notifications();
        notifs = items;
      }
      var ids = _unreadIdsOfSession(items, sessionId);
      if (ids.isEmpty) {
        // 缓存非空但没命中：可能是后台期间新到的通知，或重连前拿到的旧列表。
        items = await api.notifications();
        notifs = items;
        ids = _unreadIdsOfSession(items, sessionId);
      }
      if (ids.isEmpty) return;
      await api.markNotifsRead(ids: ids);
      AppLog.instance.log('通知：进入会话 $sessionId，标记 ${ids.length} 条已读');
      await refreshNotifs(notify: false);
    } catch (e) {
      AppLog.instance.log('通知：标记会话已读失败（$e）');
    }
  }

  /// 某会话里仍未读的通知 id（顺序与列表一致，便于稳定测试）。
  List<String> _unreadIdsOfSession(
    List<AppNotification> items,
    String sessionId,
  ) => items
      .where((n) => n.unread && n.sessionId == sessionId)
      .map((n) => n.id)
      .toList(growable: false);


  // ── SSE 内部 ──
  StreamSubscription<Map<String, dynamic>>? _sub;
  int _retry = 0;
  Timer? _retryTimer;
  // SSE 503（服务端 too-many-connections）：单独退避，避免 bootstrap 成功后
  // 又把 retry 清零、每 2s 重连一次形成风暴。
  bool _sseBusy = false;
  bool _connecting = false;

  static const _kSession = 'dsh_mr_session';
  static const _kDark = 'dsh_mr_darkmode';
  static const _kReasoning = 'dsh_mr_show_reasoning';
  static const _kShowHiddenFiles = 'dsh_mr_show_hidden_files';
  static const _kReasoningDefaultExpanded = 'dsh_mr_reasoning_default_expanded';
  static const _kTimelineDebug = 'dsh_mr_timeline_debug';
  static const _kStepDisplayMode = 'dsh_mr_step_display_mode';
  static const _kGitGraphBranchLimit = 'dsh_mr_git_graph_branch_limit';
  static const _kTurnFoldTiming = 'dsh_mr_turn_fold_timing';
  static const _kReasoningOverrides = 'dsh_mr_reasoning_overrides';
  static const _kWorkspace = 'dsh_mr_workspace';
  static const _kSessCache = 'dsh_mr_sessions_cache';
  static const _kLang = 'dsh_mr_language';
  static const _kBalanceAlert = 'dsh_mr_balance_alert';
  static const _kBalanceThreshold = 'dsh_mr_balance_threshold';
  static const _kFloating = 'dsh_mr_floating';
  static const _kPetHeight = 'dsh_mr_pet_height';
  static const _kPetReducedMotion = 'dsh_mr_pet_reduced_motion';
  static const _kPetEdgeHide = 'dsh_mr_pet_edge_hide';
  static const _kPetHideInApp = 'dsh_mr_pet_hide_in_app';
  static const _kGitTabs = 'dsh_mr_git_tabs';
  static const _kConversationActionOrder = 'dsh_mr_conversation_action_order';
  static const _kSkin = 'dsh_mr_skin';
  static const _kAppIcon = 'dsh_mr_app_icon';

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    sessionId = prefs.getString(_kSession);
    darkMode = prefs.getString(_kDark) ?? 'system';
    skin = DshSkin.fromId(prefs.getString(_kSkin));
    appIcon = prefs.getString(_kAppIcon) ?? 'default';
    iconMigrationTipShown = prefs.getBool(_kIconMigrationTip) ?? false;
    // issue #108：旧「思考内容 / 思维链默认展开」key 保留在 prefs 但不读取，
    // 不迁移、不改变行为（字段仅为旧代码兼容保留，默认 false）。
    showHiddenFiles = prefs.getBool(_kShowHiddenFiles) ?? true;
    timelineDebug = prefs.getBool(_kTimelineDebug) ?? false;
    stepDisplayMode = WorkStepDisplayMode.values.firstWhere(
      (mode) => mode.name == prefs.getString(_kStepDisplayMode),
      orElse: () => WorkStepDisplayMode.standard,
    );
    gitGraphBranchLimit = GitGraphBranchLimit.fromStorage(
      prefs.getString(_kGitGraphBranchLimit),
    );
    final foldTiming = prefs.getString(_kTurnFoldTiming);
    turnFoldTiming = foldTiming == 'onNewMessage'
        ? TurnFoldTiming.onNewMessage
        : TurnFoldTiming.afterAnswer;
    try {
      final raw = prefs.getString(_kReasoningOverrides);
      if (raw != null && raw.isNotEmpty) {
        reasoningOverrides = (jsonDecode(raw) as Map<String, dynamic>).map(
          (sid, v) => MapEntry(
            sid,
            (v as Map<String, dynamic>).map((k, b) => MapEntry(k, b as bool)),
          ),
        );
      }
    } catch (_) {
      // 数据损坏则忽略，全部按设置默认展开
    }
    language = prefs.getString(_kLang) ?? 'zh';
    L10n.lang = language;
    balanceAlert = prefs.getBool(_kBalanceAlert) ?? false;
    balanceThreshold = prefs.getDouble(_kBalanceThreshold) ?? 10;
    floatingEnabled = prefs.getBool(_kFloating) ?? false;
    petHeight = (prefs.getInt(_kPetHeight) ?? 96).clamp(56, 160).toInt();
    petReducedMotion = prefs.getBool(_kPetReducedMotion) ?? false;
    petEdgeHide = prefs.getBool(_kPetEdgeHide) ?? true;
    petHideInApp = prefs.getBool(_kPetHideInApp) ?? true;
    gitTabs = List.unmodifiable(_defaultGitTabs);
    try {
      final raw = prefs.getString(_kGitTabs);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (_validGitTabs(decoded)) {
          gitTabs = List.unmodifiable((decoded as List).cast<String>());
        }
      }
    } catch (_) {
      // Invalid/corrupt preferences recover to the current default tabs.
      gitTabs = List.unmodifiable(_defaultGitTabs);
    }
    conversationActionOrder = List.unmodifiable(
      _defaultConversationActionOrder,
    );
    try {
      final raw = prefs.getString(_kConversationActionOrder);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (_validConversationActionOrder(decoded)) {
          conversationActionOrder = List.unmodifiable(
            (decoded as List).cast<String>(),
          );
        }
      }
    } catch (_) {
      // Invalid/corrupt preferences recover to the default action order.
      conversationActionOrder = List.unmodifiable(
        _defaultConversationActionOrder,
      );
    }
    final savedWs = prefs.getString(_kWorkspace);
    workspacePath = savedWs == null ? null : _normPath(savedWs);
    // 会话本地缓存：App 打开瞬间先显示上次的列表，后台静默刷新（解决"进去要等一会才有数据"）
    try {
      final raw = prefs.getString(_kSessCache);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        sessions = list
            .map((e) => Session.fromJson(e as Map<String, dynamic>))
            // issue #133：子代理运行数是瞬态数据（连接相关），不得从本地缓存带出来。
            .map((s) => s.copyWith(clearSubagentsRunning: true))
            .toList();
      }
    } catch (_) {
      // 缓存损坏则忽略，等待网络刷新
    }
    notifyListeners();
  }

  void _persistSessions() {
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _kSessCache,
          jsonEncode(
            sessions.map((s) {
              final json = s.toJson();
              // issue #133：瞬态字段不落盘（避免下次启动/切宿主误显示运行中）。
              json.remove('subagentsRunning');
              return json;
            }).toList(),
          ),
        );
      } catch (_) {}
    }());
  }

  /// 规范化路径用于比较：去首尾空格、统一反斜杠、小写、去尾部斜杠。
  /// 这样无论存储/接口返回的路径是 `D:\work`、`D:/work/` 还是 `D:\work\` 都能匹配。
  static String _normPath(String s) {
    var p = s.trim().replaceAll('/', '\\').toLowerCase();
    while (p.endsWith('\\') && p.length > 1) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// 路径规范化（外部复用：新建会话弹层等工作目录匹配用）。
  static String normPath(String s) => _normPath(s);

  static bool _validGitTabs(Object? value) {
    if (value is! List || value.isEmpty || value.length > 3) return false;
    if (value.any((item) => item is! String || !gitTabIds.contains(item))) {
      return false;
    }
    return value.toSet().length == value.length;
  }

  static bool _validConversationActionOrder(Object? value) {
    if (value is! List || value.length != conversationActionIds.length) {
      return false;
    }
    if (value.any(
      (item) => item is! String || !conversationActionIds.contains(item),
    )) {
      return false;
    }
    return value.toSet().length == conversationActionIds.length;
  }

  /// 显示哪些 Git 浏览 Tab 及其顺序（1–3 项，跨启动持久化）。
  Future<void> setGitTabs(List<String> tabs) async {
    if (!_validGitTabs(tabs)) {
      throw ArgumentError('Git tabs must be 1–3 unique known views');
    }
    gitTabs = List.unmodifiable(tabs);
    notifyListeners();
    await _persistPrefs(_kGitTabs, jsonEncode(gitTabs));
  }

  /// Updates the app-wide order of the chat action rail and persists it locally.
  Future<void> setConversationActionOrder(List<String> order) async {
    if (!_validConversationActionOrder(order)) {
      throw ArgumentError('Conversation action order must contain all actions');
    }
    conversationActionOrder = List.unmodifiable(order);
    notifyListeners();
    await _persistPrefs(
      _kConversationActionOrder,
      jsonEncode(conversationActionOrder),
    );
  }

  /// 单值持久化（Phase 0 收敛：原各 setter 的 getInstance+setX 样板统一；null = 删除键）。
  Future<void> _persistPrefs(String key, Object? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value == null) {
      await prefs.remove(key);
    } else {
      // 静默丢配置比崩溃更难排查：不支持的类型快速失败
      throw ArgumentError('unsupported pref type: ${value.runtimeType}');
    }
  }

  /// 切换当前工作区（null = 全部）。
  Future<void> setWorkspace(String? path) async {
    workspacePath = path == null ? null : _normPath(path);
    notifyListeners();
    await _persistPrefs(_kWorkspace, workspacePath);
  }

  Future<void> setDarkMode(String v) async {
    darkMode = v;
    notifyListeners();
    await _persistPrefs(_kDark, v);
  }

  /// 切换主题皮肤（默认 / 深潜夜航 / 海盐汽水 / 鲸落星海），即时重建 Theme。
  Future<void> setSkin(DshSkin v) async {
    if (skin == v) return;
    skin = v;
    notifyListeners();
    await _persistPrefs(_kSkin, v.id);
  }

  /// 记住已选的桌面图标样式（真正的 activity-alias 切换在原生侧完成）。
  Future<void> setAppIcon(String id) async {
    if (appIcon == id) return;
    appIcon = id;
    notifyListeners();
    await _persistPrefs(_kAppIcon, id);
  }

  /// 图标入口迁移提示是否已展示（v3.2.2 build 27：从 MainActivity 换成 IconDefault alias，
  /// 老桌面快捷方式指向旧组件名会失效一次，需要在首次启动时说清楚，而不是等用户发现点不开）。
  bool iconMigrationTipShown = false;
  static const _kIconMigrationTip = 'dsh_mr_icon_migration_tip';

  Future<void> markIconMigrationTipShown() async {
    if (iconMigrationTipShown) return;
    iconMigrationTipShown = true;
    await _persistPrefs(_kIconMigrationTip, true);
  }

  /// 切换界面语言（zh/en），即时生效 + 持久化。
  Future<void> setLanguage(String v) async {
    language = v;
    L10n.lang = v;
    notifyListeners();
    await _persistPrefs(_kLang, v);
  }

  /// 余额预警开关（低于阈值时提醒充值）。
  /// v2.7.1：开关变化立即同步悬浮球（关闭 → 悬浮球不再因余额报警/亮起）。
  Future<void> setBalanceAlert(bool v) async {
    balanceAlert = v;
    notifyListeners();
    await _persistPrefs(_kBalanceAlert, v);
    unawaited(Floating.setBalanceAlert(v, balanceThreshold));
  }

  /// 悬浮球开关持久化（v2.7.2：清理后台/重启 App 后记住用户选择，不再每次重开）。
  Future<void> setFloatingEnabled(bool v) async {
    floatingEnabled = v;
    notifyListeners();
    await _persistPrefs(_kFloating, v);
  }

  /// App 启动自动恢复桌面宠物（沿用旧悬浮球恢复逻辑）：上次开启过且服务没在跑 → 自动拉起。
  /// 悬浮窗权限被撤销（罕见）时不强启，等用户到设置页重新开启。
  Future<void> restoreFloating() async {
    if (!floatingEnabled) return;
    if (await Floating.isRunning()) return;
    if (!await Floating.canDrawOverlay()) return;
    // v2.7.2 review(M7)：异步恢复期间用户可能已关掉开关（stop 与 start 竞态），复查一次
    if (!floatingEnabled) return;
    await Floating.start();
    // 服务是新起的，补宠物配置与余额预警
    await _syncPetConfig();
    unawaited(Floating.setBalanceAlert(balanceAlert, balanceThreshold));
  }

  /// 宠物大小/减少动效/贴边躲藏/前台收起：持久化后实时同步原生服务。
  Future<void> setPetHeight(int v) async {
    petHeight = v.clamp(56, 160).toInt();
    notifyListeners();
    await _persistPrefs(_kPetHeight, petHeight);
    await _syncPetConfig();
  }

  Future<void> setPetReducedMotion(bool v) async {
    petReducedMotion = v;
    notifyListeners();
    await _persistPrefs(_kPetReducedMotion, v);
    await _syncPetConfig();
  }

  Future<void> setPetEdgeHide(bool v) async {
    petEdgeHide = v;
    notifyListeners();
    await _persistPrefs(_kPetEdgeHide, v);
    await _syncPetConfig();
  }

  /// App 在前台时收起桌面宠物（默认开）：既避免与首页角色同屏重复，也避免悬浮窗挡住按钮。
  Future<void> setPetHideInApp(bool v) async {
    petHideInApp = v;
    notifyListeners();
    await _persistPrefs(_kPetHideInApp, v);
    await _syncPetConfig();
  }

  Future<void> _syncPetConfig() async {
    if (!floatingEnabled) return;
    await Floating.setPetConfig(
      height: petHeight,
      reducedMotion: petReducedMotion,
      edgeHide: petEdgeHide,
      hideInApp: petHideInApp,
    );
  }

  /// 余额预警阈值（元），持久化并同步悬浮球（悬浮球的判定完全以 App 端设置为依据）。
  Future<void> setBalanceThreshold(double v) async {
    balanceThreshold = v;
    notifyListeners();
    await _persistPrefs(_kBalanceThreshold, v);
    unawaited(Floating.setBalanceAlert(balanceAlert, v));
  }

  Future<void> setSession(String? id) async {
    sessionId = id;
    // v2.7.1：打开会话时立即按该会话的状态显示（不等下一帧 agent/status）
    applyAgentStatusForSession();
    notifyListeners();
    if (id != null) {
      await _persistPrefs(_kSession, id);
      // v3.1.6（issue #14 / ADR 0013）：不再调用 /sessions/touch——打开会话不得
      // 改变列表顺序（排序依据已改为最新消息时间）。端点保留给旧版 App。
    }
  }

  /// 手动切换到指定地址：探测可达后保存为当前地址并重连。
  /// 返回 null 表示切换成功；否则返回错误描述（保持原连接不变）。
  Future<String?> switchBase(String base) async {
    if (_normPath(base).isEmpty) return '地址为空';
    final err = await api.probeBase(base);
    if (err != null) return '该地址不可达';
    AppLog.instance.log('手动切换地址 → $base');
    await api.save(base: base, token: api.token);
    disposeBridge();
    connect();
    // 关键：显式通知刷新。若连接状态未变化（如正卡在 connecting），
    // 旧代码不会触发任何通知 → 界面不更新，需退出重进才看到新地址。
    notifyListeners();
    return null;
  }

  /// 回答内核问询（answers 顺序与提问一致、每问必答）。
  /// 返回 null 表示成功；否则返回错误说明（弹窗保持可重试）。
  Future<String?> answerQuestion(
    String rpcId,
    String sessionId,
    List<Map<String, dynamic>> answers,
  ) async {
    try {
      final r = await api.respond(
        kind: 'question',
        rpcId: rpcId,
        sessionId: sessionId,
        answers: answers,
      );
      if (r['accepted'] == true) {
        if (pendingQuestion?.rpcId == rpcId ||
            _pendingQuestionsBySession.values.any((q) => q.rpcId == rpcId)) {
          _clearPendingQuestion(rpcId, sessionId);
          notifyListeners();
        }
        return null;
      }
      // not-pending / bad-response：PC 端可能已先答，弹窗应关闭
      if (pendingQuestion?.rpcId == rpcId ||
          _pendingQuestionsBySession.values.any((q) => q.rpcId == rpcId)) {
        _clearPendingQuestion(rpcId, sessionId);
        notifyListeners();
      }
      return '${r['reason'] ?? '回答未被接受'}（可能电脑端已先回答）';
    } catch (e) {
      return '回答失败：$e';
    }
  }

  /// 审批工具权限：outcome = "allowed-once" | "rejected"。
  Future<String?> answerApproval(
    String rpcId,
    String sessionId,
    String approvalId,
    String outcome,
  ) async {
    try {
      final r = await api.respond(
        kind: 'approval',
        rpcId: rpcId,
        sessionId: sessionId,
        approvalId: approvalId,
        outcome: outcome,
      );
      if (r['accepted'] == true) {
        if (pendingApproval?.rpcId == rpcId ||
            _pendingApprovalsBySession.values.any((a) => a.rpcId == rpcId)) {
          _clearPendingApproval(rpcId, sessionId);
          notifyListeners();
        }
        return null;
      }
      if (pendingApproval?.rpcId == rpcId ||
          _pendingApprovalsBySession.values.any((a) => a.rpcId == rpcId)) {
        _clearPendingApproval(rpcId, sessionId);
        notifyListeners();
      }
      return '${r['reason'] ?? '审批未被接受'}（可能电脑端已先处理）';
    } catch (e) {
      return '审批失败：$e';
    }
  }

  /// 取消（跳过）问询/审批：内核收到 cancelled，agent 按 ASK_CANCELLED 继续。
  ///
  /// v3.1.6（app-audit ①6）：
  /// - [sessionId]：调用方（聊天页）自带的归属会话。此前只从本地挂起表反查——叠层打开同一
  ///   会话时，另一端先答/resolved 帧先到会清掉本地条目，反查得到空串；显式传入可避免
  ///   "归属不明"的取消（PR #11 的严格校验会直接 400）。
  /// - 返回 null=成功；否则返回可展示的错误说明（此前 `catch (_) {}` 全吞，离线时用户
  ///   以为已取消、内核其实还在等答案）。
  Future<String?> cancelRespond(String rpcId, {String? sessionId}) async {
    final question = _questionForRpc(rpcId);
    final approval = _approvalForRpc(rpcId);
    final sid = sessionId ?? question?.sessionId ?? approval?.sessionId ?? '';
    String? err;
    try {
      final r = await api.respond(kind: 'cancel', rpcId: rpcId, sessionId: sid);
      // accepted 缺省（旧服务端/代理回退路径不一定回该字段）视为成功，只对明确的 false 报错
      if (r['accepted'] == false) {
        err = '${r['reason'] ?? '取消未被接受'}（可能电脑端已先处理）';
      }
    } catch (e) {
      err = '取消失败：$e';
    }
    _clearPendingQuestion(rpcId);
    _clearPendingApproval(rpcId);
    notifyListeners();
    return err;
  }

  /// 会话是否属于某工作区（cwd 等于工作区路径或其子目录，Windows 大小写不敏感）。
  static bool _cwdIn(String? cwd, String path) {
    if (cwd == null || cwd.isEmpty) return false;
    final c = _normPath(cwd);
    final p = _normPath(path);
    if (c.isEmpty || p.isEmpty) return false;
    return c == p || c.startsWith('$p\\');
  }

  /// 会话是否属于某工作区：优先内核成员关系（sessionIds，与 PC 端分组一致）；
  /// 旧版插件无该字段时回退 cwd 前缀匹配。
  bool _inWorkspace(Session s, Map<String, dynamic> w) {
    final ids = w['sessionIds'];
    if (ids is List) return ids.any((id) => id.toString() == s.id);
    final path = w['path'];
    if (path is String && path.isNotEmpty) return _cwdIn(s.cwd, path);
    return false;
  }

  /// 会话所属工作区标题（首页最近会话小字标注用）。
  /// 无工作区概念（未注册任何工作区）→ null（不显示）；不属于任何工作区 → 「未分组」（与 PC 端分组语义一致）。
  String? workspaceLabelOf(Session s) {
    if (workspaces.isEmpty) return null;
    for (final w in workspaces) {
      if (_inWorkspace(s, w)) {
        return (w['title'] as String?) ?? (w['path'] as String?) ?? '工作区';
      }
    }
    return '未分组';
  }

  /// 当前选中的工作区条目（未选/找不到时为 null = 全部）。
  Map<String, dynamic>? _selectedWorkspace() {
    if (workspacePath == null) return null;
    for (final w in workspaces) {
      if (_normPath(w['path'] as String? ?? '') == workspacePath) return w;
    }
    return null;
  }

  /// 未归档会话，按最新消息时间排序；按当前工作区过滤；隐藏子代理会话（ADR 0013）。
  List<Session> get activeSessions {
    final ws = _selectedWorkspace();
    return projectSessions(
      sessions.where((s) => !s.archived && (ws == null || _inWorkspace(s, ws))),
    );
  }

  /// 已归档会话，同样按最新消息时间排序；子代理会话在已归档视图里也不出现。
  List<Session> get archivedSessions {
    final ws = _selectedWorkspace();
    return projectSessions(
      sessions.where((s) => s.archived && (ws == null || _inWorkspace(s, ws))),
    );
  }

  /// 会话行的状态标识（ADR 0013）：等待态优先于运行态。
  /// 「等待用户处理」来自挂起的问询/审批，不是运行状态的第三个取值。
  ///
  /// issue #124/#133：主会话行还要聚合**递归子代理**的运行状态——根 agent 已 idle、
  /// 但只要任一子代理仍在 running，行仍显示运行中（子代理会话本身不进入列表）。
  ///
  /// 双来源：
  /// - 列表里能看到子代理行时，用本地递归聚合（SSE `agent/status` 即时更新，子结束立即消失）；
  /// - 看不到子代理行时（新宿主 `/sessions` 的 `subagentsRunning` 聚合提示，可覆盖
  ///   被 includeEmpty 过滤掉的空子会话），退回服务端提示；
  /// - 旧宿主两者都缺 → false（保持既有行为，不发额外请求）。
  SessionRowState rowStateOf(String sessionId) {
    final aggregate = subagentRunAggregate(
      sessionId: sessionId,
      sessions: sessions,
      agentStatusOf: agentStatusForSession,
    );
    // issue #124/#133（UI 规范 §3）：SSE / `/sessions` 字段 / 本地树三者**取并集**，
    // 不互相门控——任一路径说 running 就显示；SSE 帧与快照合并保证不互相抹掉。
    final sseCount = subagentRunningByRoot[sessionId];
    final serverCount = _sessionSubagentCount(sessionId);
    final hasRunningSubagents =
        (sseCount ?? 0) > 0 || (serverCount ?? 0) > 0 || aggregate.running;
    return sessionRowState(
      agentStatus: agentStatusForSession(sessionId),
      hasRunningJobs: hasRunningJobs(sessionId),
      hasRunningSubagents: hasRunningSubagents,
      hasPendingQuestion: questionForSession(sessionId) != null,
      hasPendingApproval: approvalForSession(sessionId) != null,
    );
  }

  int? _sessionSubagentCount(String sessionId) {
    for (final s in sessions) {
      if (s.id == sessionId) return s.subagentsRunning;
    }
    return null;
  }

  /// 当前列表里是否存在需要驱动旋转标识的会话（存在运行中会话才启动动画）。
  bool hasRunningSessions(Iterable<Session> visible) =>
      visible.any((s) => rowStateOf(s.id) == SessionRowState.running);

  /// 当前工作区的显示名（无工作区/全部时为 null）。
  String? get workspaceTitle {
    if (workspacePath == null) return null;
    for (final w in workspaces) {
      if (_normPath(w['path'] as String? ?? '') == workspacePath) {
        // v3.1.1(issue #5)：展示原始路径（WSL 上不再出现归一后的 `\home\user` 形态）
        return (w['title'] as String?) ??
            (w['path'] as String?) ??
            workspacePath;
      }
    }
    return workspacePath;
  }

  Future<void> setShowReasoning(bool v) async {
    showReasoning = v;
    notifyListeners();
    await _persistPrefs(_kReasoning, v);
  }

  /// 会话文件浏览「显示隐藏文件」开关（默认开；只作用于会话文件浏览）。
  Future<void> setShowHiddenFiles(bool v) async {
    showHiddenFiles = v;
    notifyListeners();
    await _persistPrefs(_kShowHiddenFiles, v);
  }

  Future<void> setReasoningDefaultExpanded(bool v) async {
    reasoningDefaultExpanded = v;
    notifyListeners();
    await _persistPrefs(_kReasoningDefaultExpanded, v);
  }

  Future<void> setTimelineDebug(bool v) async {
    timelineDebug = v;
    notifyListeners();
    await _persistPrefs(_kTimelineDebug, v);
  }

  /// issue #52：工作步骤展示模式四档（简洁/标准/详细/完全展开）——改动即时重算。
  Future<void> setStepDisplayMode(WorkStepDisplayMode mode) async {
    if (stepDisplayMode == mode) return;
    stepDisplayMode = mode;
    notifyListeners();
    await _persistPrefs(_kStepDisplayMode, mode.name);
  }

  /// issue #86：Git 分支图选中上限三档（5/10/不限）——下次打开分支图生效。
  Future<void> setGitGraphBranchLimit(GitGraphBranchLimit limit) async {
    if (gitGraphBranchLimit == limit) return;
    gitGraphBranchLimit = limit;
    notifyListeners();
    await _persistPrefs(_kGitGraphBranchLimit, limit.storageValue);
  }

  /// issue #52：收起时机两档（回答结束后 / 下次有新消息时）——改动即时重算。
  Future<void> setTurnFoldTiming(TurnFoldTiming timing) async {
    if (turnFoldTiming == timing) return;
    turnFoldTiming = timing;
    notifyListeners();
    await _persistPrefs(_kTurnFoldTiming, timing.name);
  }

  bool? reasoningOverrideOf(String sessionId, String messageKey) =>
      reasoningOverrides[sessionId]?[messageKey];

  Future<void> setReasoningOverride(
    String sessionId,
    String messageKey,
    bool expanded,
  ) async {
    (reasoningOverrides[sessionId] ??= {})[messageKey] = expanded;
    // 软上限：每会话 100 条 + 全局 500 条（P2：防跨会话无限增长；先删最旧会话的最旧条目）
    final m = reasoningOverrides[sessionId]!;
    while (m.length > 100) {
      m.remove(m.keys.first);
    }
    var total = reasoningOverrides.values.fold(0, (s, v) => s + v.length);
    while (total > 500) {
      final sid0 = reasoningOverrides.keys.first;
      final m0 = reasoningOverrides[sid0]!;
      m0.remove(m0.keys.first);
      if (m0.isEmpty) reasoningOverrides.remove(sid0);
      total--;
    }
    notifyListeners();
    await _persistPrefs(_kReasoningOverrides, jsonEncode(reasoningOverrides));
  }

  // ── 启动加载（对齐网页端 bootstrap） ──
  /// 探测 → 自愈 → 拉数据（启动与下拉刷新共用）。
  /// 先探测电脑连通性，不通则轮换候选地址再试一次；恢复后重建 SSE 并拉全量数据。
  /// 返回是否与电脑连通（供 UI 做失败提示；日常成功静默）。
  Future<bool> refreshAll() async {
    var ok = false;
    // 快照时序基准：请求发起时记下帧计数，期间若有 agent/status 帧落地则只合并不裁剪
    final epoch = _agentStatusEpoch;
    try {
      final d = await api.getJson(
        '/api/bootstrap',
        timeout: const Duration(seconds: 8),
      );
      ok = true;
      // v2.7：下拉刷新也收集地址（蒲公英等新地址及时进候选）+ 同步 agent 状态
      api.absorbBootstrap(d);
      _emitChatEvent(ChatEvent(type: '_capabilities', data: {}));
      _syncAgentStatus(d, snapshotEpoch: epoch);
    } catch (_) {
      // 连接不通：尝试轮换到下一个候选地址（黑洞快速切换）再探测一次
      if (api.rotateBaseUrl()) {
        AppLog.instance.log('刷新探测失败 → 切换地址 ${api.baseUrl}');
        try {
          final d = await api.getJson(
            '/api/bootstrap',
            timeout: const Duration(seconds: 8),
          );
          ok = true;
          api.absorbBootstrap(d);
          _emitChatEvent(ChatEvent(type: '_capabilities', data: {}));
          _syncAgentStatus(d, snapshotEpoch: epoch);
          // 当前 SSE 大概率也指向旧地址：重建连接
          disposeBridge();
          connect();
        } catch (_) {
          // 候选地址也不通：保持离线自愈（看门狗/重试会继续处理）
        }
      }
    }
    // 整体限时 8 秒：网络不通时避免 5 个请求各自超时堆积
    await Future.any([
      _refreshAllInner(),
      Future<void>.delayed(const Duration(seconds: 8)),
    ]);
    return ok;
  }

  /// 从 bootstrap 响应同步各 agent 状态（连接/重连/下拉刷新时按钮立即反映 PC 真实状态）。
  /// v2.7.1 修复：不再用 agents.first（注册序第一个，与当前会话无关，会把状态串成别的会话的）——
  /// 全量入映射，只按当前 sessionId 取。
  ///
  /// v3.1.6（app-audit ①1）：`/bootstrap` 的 `agents` 是宿主 agent 注册表的**全量快照**
  /// （插件 `agents.list()`：每项 `{id, sessionId, status, hasPending, title}`，dormant 会话
  /// 根本没有条目）——因此**不在快照里 ≡ 该会话没有 live agent ≡ idle**，可以安全裁剪。
  /// 此前只做合并写入，陈旧 running 会永久驻留：发送键变"停止"、普通发送被误判成排队
  /// （`_pageAgentStatus == 'running'`）、甚至点发送实际发出 `/sessions/stop`。
  /// agentId ≠ sessionId（`session:` 前缀/子代理场景），两个映射各按自己的键裁剪。
  ///
  /// 边界：宿主缺 `agents` 服务时 payload 是空数组，届时会全部回落 idle——方向是安全的
  /// （发送走 followup + 服务端排队），与"陈旧 running 永久误操作"相比是可接受的降级。
  /// [snapshotEpoch]：请求发起时的帧计数，期间有新帧落地则只合并不裁剪（见 [_agentStatusEpoch]）。
  void _syncAgentStatus(Map<String, dynamic> d, {int? snapshotEpoch}) {
    final agents = d['agents'] as List? ?? const [];
    final liveAgents = <String, String>{}; // agentId -> status
    final liveSessions = <String, String>{}; // sessionId -> status
    for (final a in agents) {
      if (a is Map) {
        final st = a['status'];
        final norm = normalizeAgentStatus(st);
        final id = a['id'];
        if (id is String && id.isNotEmpty) liveAgents[id] = norm;
        final sid = a['sessionId'];
        if (sid is String && sid.isNotEmpty) liveSessions[sid] = norm;
      }
    }
    // v3.1.6（issue #14）：bootstrap 是**全量快照**，既会改变已存在会话的状态，
    // 也会通过裁剪（会话消失/agent 销毁）把某个会话从 running 拉回 idle。
    // 列表页的 running 标识依赖这份映射，所以这两种变化都必须让界面重绘，
    // 而不只是"当前打开的会话"变化时。下面逐项比对（含将被裁剪的键）。
    final willPrune =
        snapshotEpoch == null || snapshotEpoch == _agentStatusEpoch;
    final changed =
        _statusSetChanged(agentStatusMap, liveAgents, prune: willPrune) ||
        _statusSetChanged(sessionAgentStatus, liveSessions, prune: willPrune);

    if (willPrune) {
      // 快照权威：先删不在快照里的陈旧键，再写入快照值
      agentStatusMap.removeWhere((id, _) => !liveAgents.containsKey(id));
      sessionAgentStatus.removeWhere(
        (sid, _) => !liveSessions.containsKey(sid),
      );
    }
    agentStatusMap.addAll(liveAgents);
    sessionAgentStatus.addAll(liveSessions);
    final before = agentStatus;
    applyAgentStatusForSession();
    // 当前会话状态没变（applyAgentStatusForSession 已自行通知），但状态集合变了
    // → 补一次通知，否则会话列表的标识会卡在旧状态。
    if (changed && agentStatus == before) notifyListeners();
  }

  /// 快照与当前映射相比，状态集合是否变化（[prune] 为真时把"将被裁剪"也算变化）。
  static bool _statusSetChanged(
    Map<String, String> current,
    Map<String, String> incoming, {
    required bool prune,
  }) {
    for (final entry in incoming.entries) {
      if (current[entry.key] != entry.value) return true;
    }
    if (prune && current.length != incoming.length) return true;
    return false;
  }

  /// 把「当前打开会话」的状态应用到显示值。
  /// v2.7.2 review(M8)：该会话无状态映射时重置为 idle（此前沿用上一会话的 running，
  /// 导致发送键误变"停止"、插队误判降级，甚至停错会话）。
  void applyAgentStatusForSession() {
    final id = sessionId;
    String next;
    if (id == null) {
      next = 'idle';
    } else {
      next = sessionAgentStatus[id] ?? agentStatusMap[id] ?? 'idle';
    }
    if (next != agentStatus) {
      agentStatus = next;
      notifyListeners();
    }
  }

  Future<void> _refreshAllInner() async {
    try {
      // 会话列表是首页首屏数据：最先拉取并立即发布；其余数据并行/后台加载。
      // （旧版先等最慢的模型目录 RPC 完成才统一 notify，导致首屏空白数秒）
      await refreshSessions(notify: false);
      notifyListeners();
      unawaited(refreshWorkspaces(notify: false));
      unawaited(refreshNotifs(notify: false));
      unawaited(refreshActions(notify: false));
      try {
        catalog = await api.catalog();
        if (sessionId != null) {
          try {
            sessionConfig = await api.sessionConfig(sessionId!);
          } catch (_) {
            /* 冷会话保持旧值 */
          }
        }
        notifyListeners();
      } catch (_) {
        /* 目录加载失败不阻塞首屏 */
      }
    } catch (_) {
      /* 首屏失败由连接页处理 */
    }
  }

  /// 拉取模型目录（新建会话弹层懒加载用），成功返回目录、失败返回 null。
  Future<Catalog?> refreshCatalog({bool force = false}) async {
    try {
      catalog = await api.catalog(refresh: force);
      notifyListeners();
      return catalog;
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshWorkspaces({bool notify = true}) async {
    try {
      final raw = await api.workspaces();
      // v3.1.1(issue #5)：条目保留服务端原始路径（展示/回传 cwd 都用原始形态）——
      // 规范化只用于匹配比较（_normPath 统一 `/`/`\` 与大小写）；
      // 旧实现把 path 归一成 `\` 形态存入，WSL/Linux 上会被当作 cwd 发回服务端。
      workspaces = raw;
      // 已选工作区不再存在时回退到"全部"
      if (workspacePath != null &&
          !workspaces.any(
            (w) => _normPath(w['path'] as String? ?? '') == workspacePath,
          )) {
        workspacePath = null;
      }
      if (notify) notifyListeners();
    } catch (_) {}
  }

  /// 归档/取消归档乐观更新（v2.7.1）：本地立即生效（列表秒变），
  /// 不等慢刷新（服务端列表标题折叠 50+ 会话可达数秒）；由调用方随后静默 refreshSessions 校准。
  ///
  /// v3.1.6（issue #14）：改用 [Session.copyWith]——此前手工重建 Session，把新增的
  /// lastMessageAt/origin/parentSession 丢掉，导致归档瞬间排序键回退、时间与位置矛盾。
  void applyArchiveLocally(String sessionId, {required bool archived}) {
    final i = sessions.indexWhere((s) => s.id == sessionId);
    if (i < 0) return;
    sessions[i] = sessions[i].copyWith(archived: archived);
    notifyListeners();
  }

  // ── 会话列表刷新的在途守卫（issue #22）──
  //
  // 触发源：`_debounceSessions()` 每 800ms 就可能调一次本方法，而一次 `/sessions`
  // 在服务端是一次**全语料扫描**（实测 70 秒量级）。没有守卫时同一时刻可以有任意多个
  // 刷新在飞——实测现场 16–18 个连接全部来自手机、宿主 CPU 171%、主线程 91.6%。
  // 到达速率长期高于完成速率 → 请求无界堆积 → **谁都完不成**，列表永远刷不出来。
  //
  // 策略：在途期间不发新请求，只记一次"待补"；在途结束后补发**一次**。
  //
  // 评审指出的三条语义，逐条对应到实现：
  //  1. **被合并的调用不得提前完成**：合并时返回"待补这一轮"的共享 Future，直到补发
  //     真正结束才释放等待者。否则 `_refreshAllInner()` 会先发布旧数据，而随后的补发
  //     （notify 意图可能是 false）更新了 sessions 却不再通知 UI——列表就停在旧数据上。
  //  2. **不得越过生命周期补发**：dispose / 关闭 bridge 时清除待补并释放等待者；
  //     finally 里还必须确认当前请求仍属于当前代，才允许补发。
  //  3. **守卫按连接代归属**：切换到新地址后，旧地址的在途请求既不能阻塞新地址的刷新，
  //     也不能在迟到时清掉新代的在途标志或启动新代补发。
  //
  // 注意第 3 条**不能**用"在 disposeBridge 里直接把布尔复位"糊过去：那样旧代的
  // 迟到 finally 会把新代的守卫清掉，重新放出同代并发。故一律以 `_refreshGeneration`
  // 判定归属。
  // 评审第二轮（WARNING 1）暴露的边界：generation 只在 disposeBridge 里自增，
  // 而**自动地址轮换**（`connect.onError`、`_scheduleReconnect`、`refreshAll` 的候选
  // 切换）与手动切换都只改 `api.baseUrl`，没有任何统一回调。于是旧地址的请求仍是
  // "当代 owner"：新地址的刷新被合并到它后面，旧地址的迟到结果还能通过 generation
  // 检查被当作当前地址的数据应用。
  //
  // 逐入口补失效既容易漏，又可能在新代请求已经开始之后**重复失效新代**（评审第 4 点）。
  // 故改为**按连接身份归属**：在刷新入口比对身份，所有路径一次覆盖，且天然幂等
  // ——身份没变就什么都不做。
  int _refreshGeneration = 0;
  String? _refreshIdentity; // 上次刷新归属的连接身份；**只用于比较**
  bool _sessionsInFlight = false;
  bool _sessionsPending = false;
  bool _sessionsPendingNotify = true;
  Completer<void>? _sessionsWaiters; // 「待补这一轮」的等待者（尚未启动）
  // 评审 WARNING 2：等待者一旦成为「补发中那一轮」就会被摘成局部变量，失效逻辑只看
  // 字段就释放不到它。故用集合追踪**所有尚未完成的轮次**，直到该轮结束或生命周期失效。
  final Set<Completer<void>> _roundWaiters = <Completer<void>>{};

  /// 当前连接身份：活动地址 + **挂载路径** + 认证身份。
  /// **只用于比较**——`api.token` 绝不写入日志、界面或错误信息。
  ///
  /// 评审备注：`Api` 把挂载路径单独存在 `path` 里，并不包含在 `baseUrl` 中，
  /// 所以这里必须一并带上，否则"同地址换挂载路径"会被误判为身份未变。
  String get _connectionIdentity =>
      '${api.baseUrl}\u0000${api.path}\u0000${api.token}';

  /// 轮次等待者的**幂等**收尾：生命周期可能已经先释放过它，此时旧回调还会到达，
  /// 二次 complete 会抛 StateError / 未捕获异步异常。
  void _finishRound(Completer<void>? waiter) {
    if (waiter == null) return;
    _roundWaiters.remove(waiter);
    if (!waiter.isCompleted) waiter.complete();
  }

  void _finishAllRounds() {
    for (final w in _roundWaiters.toList(growable: false)) {
      _finishRound(w);
    }
  }

  /// issue #133：丢弃**瞬态**子代理运行数据（SSE 计数 + 会话快照里的字段）。
  ///
  /// 连接代切换/断链时必须做：否则同 sessionId 在宿主 B 上会沿用宿主 A 的 running，
  /// 且断链缓存的 `subagentsRunning` 会被读到。`copyWith(null)` 清不掉可空字段，
  /// 这里用显式 `clearSubagentsRunning`；清空后必须通知，否则换宿主瞬间旧行仍显示。
  void _clearSubagentRunningState() {
    // 只保留**根会话**状态：被名单过滤掉的子代理不在 sessions 里，不能只按可见
    // 子代理 id 清；这里反过来清所有“非根”条目（issue #133 复审 P2 盲区）。
    final rootIds = <String>{
      for (final s in sessions)
        if (!s.isSubagent) s.id,
    };
    // 当前打开的会话若已知不是子代理，也必须保留其 running（发送/停止键语义）。
    if (sessionId != null && !_isKnownSubagentSession(sessionId!)) {
      rootIds.add(sessionId!);
    }
    String normalized(String agentId) =>
        agentId.startsWith('session:') ? agentId.substring(8) : agentId;
    bool isNonRoot(String key) => !rootIds.contains(key);
    final hadSubagentStatus =
        sessionAgentStatus.keys.any(isNonRoot) ||
        agentStatusMap.keys.any((id) => isNonRoot(normalized(id)));
    final hadState =
        hadSubagentStatus ||
        subagentRunningByRoot.isNotEmpty ||
        sessions.any((s) => s.subagentsRunning != null);
    subagentRunningByRoot.clear();
    if (sessions.any((s) => s.subagentsRunning != null)) {
      sessions = [
        for (final s in sessions) s.copyWith(clearSubagentsRunning: true),
      ];
    }
    // 清掉所有非根会话状态（含 SSE 已记录、但列表被过滤的 child）。
    sessionAgentStatus.removeWhere((id, _) => isNonRoot(id));
    agentStatusMap.removeWhere((agentId, _) => isNonRoot(normalized(agentId)));
    if (hadState) notifyListeners();
  }

  /// 连接身份变化 → 旧代的刷新归属全部失效（幂等：身份没变就什么都不做）。
  void _syncConnectionGeneration() {
    final id = _connectionIdentity;
    if (id == _refreshIdentity) return;
    _refreshIdentity = id;
    _refreshGeneration++;
    // 新代从零开始：旧地址的在途不再阻塞新地址的首屏刷新。
    _sessionsInFlight = false;
    _sessionsPending = false;
    _sessionsWaiters = null;
    // issue #133：旧宿主的子代理运行数据不得进入新连接（SSE 计数 + 快照字段）。
    _clearSubagentRunningState();
    // 释放旧代**全部**等待者——包括已经变成「补发中」的那一轮（WARNING 2）。
    _finishAllRounds();
  }

  /// 连接代变更（关闭 bridge / 销毁）时使旧代的守卫与待补全部失效。
  ///
  /// 与 [_syncConnectionGeneration] 的区别：这里**不比对身份**。关闭 bridge 时地址
  /// 可能没变，但连接已经没了——等待者必须立刻释放，不能拖到旧响应回来或逻辑超时。
  void _invalidateSessionRefresh() {
    _refreshGeneration++;
    _sessionsInFlight = false;
    _sessionsPending = false;
    _sessionsWaiters = null;
    // issue #133：连接代切换（换地址/重连/销毁）后，旧宿主的子代理运行数据失效
    // （SSE 计数 + 快照字段；断链缓存也不得残留）。
    _clearSubagentRunningState();
    _finishAllRounds();
  }

  Future<void> refreshSessions({bool notify = true}) {
    // 兜底入口：任何方式的连接变更（含自动轮换）都在这里被发现。
    _syncConnectionGeneration();
    if (_sessionsInFlight) {
      // 已有刷新在飞：合并到「待补这一轮」，并返回**该轮**的 Future——
      // 调用者要的是"刷新完成"，不能在旧请求和补发都没结束时就提前完成。
      _sessionsPending = true;
      _sessionsPendingNotify = notify; // 沿用最新一次调用的意图
      final waiter = _sessionsWaiters ??= Completer<void>();
      _roundWaiters.add(waiter);
      return waiter.future;
    }
    return _runSessionRefresh(notify);
  }

  Future<void> _runSessionRefresh(bool notify) async {
    final generation = _refreshGeneration;
    final identity = _refreshIdentity;
    // issue #133：慢快照与 SSE 合并——请求期间若没有新 agent/status 帧，快照是权威的；
    // 有新帧则保留帧里的 subagentsRunning（旧快照不得清掉新帧）。
    final agentEpochAtStart = _agentStatusEpoch;
    _sessionsInFlight = true;
    try {
      try {
        final fetched = await api.sessions();
        // 归属判定必须比对**实时**连接身份，而不是 `_refreshIdentity`（它只在刷新入口
        // 更新）：地址可能在没有任何刷新的情况下被自动轮换掉，那时两者的存储值仍然相等，
        // 旧地址的数据就会被应用上去。
        if (generation != _refreshGeneration || identity != _connectionIdentity) {
          return;
        }
        // issue #133：慢快照与 SSE 合并——请求期间若有新 agent/status 帧，旧快照不得
        // 覆盖新帧：用 SSE 计数回填这些根的服务端字段；无新帧时快照才是权威。
        if (agentEpochAtStart == _agentStatusEpoch) {
          subagentRunningByRoot.clear();
          sessions = fetched;
        } else {
          sessions = fetched
              .map((s) => subagentRunningByRoot.containsKey(s.id)
                  ? s.copyWith(
                      subagentsRunning: subagentRunningByRoot[s.id],
                    )
                  : s)
              .toList();
        }
        _persistSessions(); // 本地缓存：下次打开 App 秒出列表
        // 排障日志：打印工作区选择与会话 cwd 样本，便于定位筛选不显示的问题
        AppLog.instance.log(
          'Sessions: 拉取 ${sessions.length} 条 · workspacePath=${workspacePath ?? "全部"} · '
          'workspaces=${workspaces.map((w) => w['path']).join("|")} · '
          'cwd样例=${sessions.take(3).map((s) => s.cwd ?? "null").join("|")}',
        );
        if (notify) notifyListeners();
      } catch (e) {
        AppLog.instance.log('Sessions: 拉取失败 $e');
      }
    } finally {
      // 收尾必须区分**三种**情形（第三轮评审核定）：
      //
      // ① generation 已过期：说明本代已经被别处取代（disposeBridge，或刷新入口的
      //    身份同步）。此时**绝不能触碰新代**的守卫与等待者。
      // ② 仍属当前 owner 代，但**实时连接身份已变**（自动轮换 / 手动切换，且期间
      //    没有任何刷新或 disposeBridge 来收尾）：既不能走正常收尾——那会把旧代的
      //    pending **补发到新地址**上；也**不能整个跳过**——那会留下一个永远不会被
      //    清理的 in-flight 与未释放的等待者，而且若之后又轮换回原地址，刷新入口会
      //    认为"身份没变"（存储值仍是旧地址），那个遗留守卫就**永久卡住、再也不发
      //    请求**。正确做法是同步失效本代残留并释放旧轮次等待者，**不补发**。
      // ③ generation 与实时身份都匹配：走正常复位与补发。
      if (generation == _refreshGeneration) {
        if (identity != _connectionIdentity) {
          _syncConnectionGeneration();
        } else {
          // **无论成功、失败还是异常都必须复位**：否则一次失败会把守卫永久卡在
          // in-flight，列表从此再也不刷新——那比不加守卫更糟。
          _sessionsInFlight = false;
          final waiters = _sessionsWaiters;
          _sessionsWaiters = null;
          if (_sessionsPending) {
            _sessionsPending = false;
            // 补发一次（不 await：不让当前调用方被二次刷新拖住）。
            // 等待者已登记在 `_roundWaiters` 里，**不在这里摘除**——它要等到补发结束
            // 或生命周期失效才释放（评审 WARNING 2）。
            unawaited(
              _runSessionRefresh(_sessionsPendingNotify)
                  .whenComplete(() => _finishRound(waiters)),
            );
          } else {
            _finishRound(waiters);
          }
        }
      }
    }
  }

  int _lastUnread = 0;
  bool _firstUnreadSeen = false;

  /// 最近一次拉到的通知列表（供横幅按会话合并、以及进会话标已读时复用，避免重复请求）。
  List<AppNotification> notifs = const [];

  /// 最新一条未读通知（横幅用它决定"哪个会话、多少条"）。
  AppNotification? get latestUnreadNotif {
    AppNotification? newest;
    for (final n in notifs) {
      if (!n.unread) continue;
      if (newest == null || n.time > newest.time) newest = n;
    }
    return newest;
  }

  /// 某会话的未读条数。
  int unreadOf(String sessionId) =>
      notifs.where((n) => n.unread && n.sessionId == sessionId).length;

  Future<void> refreshNotifs({bool notify = true}) async {
    try {
      final items = await api.notifications();
      notifs = items;
      final u = items.where((n) => n.unread).length;
      // 未读增量对比：重连/离线期间新增的通知也能触发提示（不只靠实时事件）
      if (_firstUnreadSeen && u > _lastUnread) {
        onNewNotifications?.call(u - _lastUnread);
      }
      _firstUnreadSeen = true;
      _lastUnread = u;
      unread = u;
      unawaited(Floating.syncUnread(u).catchError((_) {}));
      if (notify) notifyListeners();
    } catch (_) {}
  }

  /// 打开通知页后视为已读基线更新（下次增量从当前起算）。
  void markNotifsSeen() {
    _firstUnreadSeen = true;
    _lastUnread = unread;
  }

  Future<void> refreshActions({bool notify = true}) async {
    try {
      actions = await api.actions();
      if (notify) notifyListeners();
    } catch (_) {
      actions = [];
    }
  }

  Future<void> refreshSessionConfig() async {
    final id = sessionId;
    if (id == null) return;
    try {
      sessionConfig = await api.sessionConfig(id);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> applySessionConfig(Map<String, dynamic> patch) async {
    final id = sessionId;
    if (id == null) throw ApiException('无当前会话');
    await api.updateSessionConfig(id, patch);
    await refreshSessionConfig();
  }

  // ── SSE ──
  /// 连接状态：connected（SSE 在线）| connecting（正在建立）| offline（断开/重连中）
  String connState = 'connecting';

  void _setConnState(String v) {
    // issue #133：普通断链（_scheduleReconnect / resume catch / 看门狗）也必须让
    // 子代理运行数据失效，否则列表行会一直显示旧的 running。
    if (v == 'offline') _clearSubagentRunningState();
    if (connState != v) {
      connState = v;
      notifyListeners();
    }
  }

  /// 连接存活性看门狗：服务器每 25s 发 `: ping` 心跳。
  /// 若 45s（约 2 个周期）没有任何心跳/数据帧，说明 TCP 已静默死亡（网络切换/路由器丢连接/电脑退出），
  /// 此时流不会自行报错——旧版会永远卡在"已连接但实际离线"，必须划掉 App 重开。
  /// 看门狗每 15s 检查一次，检测到超时后强制重建连接。
  DateTime _lastLiveness = DateTime.now();
  Timer? _watchdog;

  void _touchLiveness() {
    _lastLiveness = DateTime.now();
  }

  void _startWatchdog() {
    _watchdog ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (_sub == null || _connecting) return;
      final stale = DateTime.now().difference(_lastLiveness).inSeconds > 45;
      if (stale) {
        AppLog.instance.log(
          'SSE: 心跳超时（${DateTime.now().difference(_lastLiveness).inSeconds}s），强制重建连接',
        );
        // issue #133：静默断链同样是连接代失效——清掉旧子代理运行数据。
        _clearSubagentRunningState();
        _sub?.cancel();
        _sub = null;
        _connecting = false;
        _retry = 0;
        connect();
      }
    });
  }

  void connect() {
    if (_sub != null || _connecting) return;
    _connecting = true;
    _setConnState('connecting');
    AppLog.instance.log('SSE: connect → ${api.baseUrl}');
    api.onSseKeepalive = _touchLiveness;
    _startWatchdog();
    _sub = api.eventsRaw().listen(
      _onFrame,
      onError: (e) {
        AppLog.instance.log('SSE: error $e');
        if ('$e'.contains('SSE HTTP 503')) _sseBusy = true;
        // 超时 = 黑洞地址（路由不可达，如手机关了组网 VPN）→ 立即轮换候选地址，
        // 不再白等 3×15 秒的重试循环（连接被拒/中断等瞬时错误仍走正常退避）
        if (e is TimeoutException && api.rotateBaseUrl()) {
          AppLog.instance.log('SSE: 超时视为黑洞 → 立即切换 ${api.baseUrl}');
          _retry = 0;
        }
        _scheduleReconnect();
      },
      onDone: () {
        AppLog.instance.log('SSE: done（连接关闭）');
        _scheduleReconnect();
      },
      cancelOnError: true,
    );
  }

  /// App 回到前台时调用：探测电脑端在线状态，SSE 断开则立即重连，并刷新数据。
  Future<void> resume() async {
    if (api.baseUrl.isEmpty || api.token.isEmpty) return; // 未配置连接
    final epoch =
        _agentStatusEpoch; // 快照时序基准（见 _syncAgentStatus 的 snapshotEpoch）
    try {
      final d = await api.getJson(
        '/api/bootstrap',
        timeout: const Duration(seconds: 8),
      );
      // 合并服务端返回的全部地址（含 Tailscale IP）+ 记录插件版本
      api.absorbBootstrap(d);
      _emitChatEvent(ChatEvent(type: '_capabilities', data: {}));
      _syncAgentStatus(d, snapshotEpoch: epoch);
      _setConnState('connected');
      // 关键修复：探针成功 ≠ 旧 SSE 流还活着。App 后台期间 TCP 可能已静默死亡
      // 而流未触发 onDone/onError —— 若不重建，connect() 会被 `_sub != null` 挡住，
      // 永远卡在"显示已连接但实际离线"，只能划掉 App 重开。
      final stale = DateTime.now().difference(_lastLiveness).inSeconds > 45;
      if (_sub != null && stale) {
        AppLog.instance.log(
          'SSE: 前台恢复发现旧流已死（${DateTime.now().difference(_lastLiveness).inSeconds}s 无心跳），重建连接',
        );
        _sub!.cancel();
        _sub = null;
        _connecting = false;
      }
      if (_sub == null) connect();
      // v3.0.0：唤醒后强制打开中的聊天页重同步——后台冻结/流静默死亡时，SSE hello 可能没触发、
      // 新消息不会上屏（表现为"要退出会话重进才有"）。catchup 按 lastSeq 补拉，重复无害。
      _emitChatEvent(ChatEvent(type: '_catchup', data: {}));
      refreshAll();
    } catch (_) {
      _setConnState('offline');
      // 探针失败：旧流同样不可信，直接重建（重连机制会持续尝试直到成功）
      if (_sub != null) {
        _sub!.cancel();
        _sub = null;
        _connecting = false;
      }
      connect();
    }
  }

  /// v3.1.6（issue #14）：把一帧 SSE 载荷喂给进度处理器。
  /// 仅供 widget 测试构造真实的 agent/status 与 mobile/frame 帧（测试 seam），
  /// 生产路径由 SSE 订阅直接调用 [_onFrame]。
  @visibleForTesting
  void injectFrame(Map<String, dynamic> frame) => _onFrame(frame);

  void _onFrame(Map<String, dynamic> frame) {
    _sseBusy = false;
    _retry = 0;
    final type = frame['type'];
    if (type == 'hello') {
      final capabilities = frame['capabilities'];
      api.timelineCapabilities =
          capabilities is Map && capabilities['eventTimeline'] is Map
          ? TimelineCapabilities.fromJson(
              Map<String, dynamic>.from(capabilities['eventTimeline'] as Map),
            )
          : const TimelineCapabilities();
      // issue #25 二期：轮次大纲能力同样由服务端显式声明（不按版本推断）。
      api.turnOutlineCapabilities =
          capabilities is Map && capabilities['turnOutline'] is Map
          ? TurnOutlineCapabilities.fromJson(
              Map<String, dynamic>.from(capabilities['turnOutline'] as Map),
            )
          : const TurnOutlineCapabilities();
      // issue #53：轮末产出物能力位（bootstrap 与 hello 同判据；旧插件不下发 → 降级隐藏）。
      api.turnTailCapabilities =
          capabilities is Map && capabilities['turnTail'] is Map
          ? TurnTailCapabilities.fromJson(
              Map<String, dynamic>.from(capabilities['turnTail'] as Map),
            )
          : const TurnTailCapabilities();
      // issue #54：工具卡能力位（bootstrap 与 hello 同判据；旧插件 → 全部通用卡）。
      api.toolCardsCapabilities =
          capabilities is Map && capabilities['toolCards'] is Map
          ? ToolCardsCapabilities.fromJson(
              Map<String, dynamic>.from(capabilities['toolCards'] as Map),
            )
          : const ToolCardsCapabilities();
      _emitChatEvent(ChatEvent(type: '_capabilities', data: {}));
      _setConnState('connected');
      _catchup();
      // v2.7.1：重连成功后按已知映射恢复当前会话状态（bootstrap 可能没跑到，帧也可能漏）
      applyAgentStatusForSession();
      // v2.7.2（审批残留修复）：后台冻帧可能丢失 resolved 帧（PC 端已回答但手机仍显示卡片）——
      // 重连后先清空本地 pending 问询/审批，服务端随后补发的挂起帧才是权威状态；
      // 未补发 = 已解决，卡片正确销毁
      if (pendingQuestion != null ||
          pendingApproval != null ||
          _pendingQuestionsBySession.isNotEmpty ||
          _pendingApprovalsBySession.isNotEmpty) {
        final questions = <QuestionRequest>{
          ..._pendingQuestionsBySession.values,
        };
        final approvals = <ApprovalRequest>{
          ..._pendingApprovalsBySession.values,
        };
        if (pendingQuestion != null) questions.add(pendingQuestion!);
        if (pendingApproval != null) approvals.add(pendingApproval!);
        pendingQuestion = null;
        pendingApproval = null;
        _pendingQuestionsBySession.clear();
        _pendingApprovalsBySession.clear();
        notifyListeners();
        for (final q in questions) {
          _emitChatEvent(
            ChatEvent(
              type: 'question/resolved',
              sessionId: q.sessionId,
              data: {'rpcId': q.rpcId, 'sessionId': q.sessionId},
            ),
          );
        }
        for (final a in approvals) {
          _emitChatEvent(
            ChatEvent(
              type: 'approval/resolved',
              sessionId: a.sessionId,
              data: {'approvalId': a.approvalId, 'sessionId': a.sessionId},
            ),
          );
        }
      }
      // 连接成功：收集电脑全部地址（LAN + Tailscale），供断线时自动轮换
      unawaited(api.collectUrls());
      // 重连成功：补拉会话/通知/目录/工作区（桌面端重启后 App 无需手动刷新即可完整恢复）
      _debounceSessions();
      refreshNotifs(notify: false);
      unawaited(refreshCatalog());
      unawaited(refreshWorkspaces());
      return;
    }
    if (type == 'attention/snapshot') {
      final entries = frame['pending'];
      if (frame['version'] != 1 || entries is! List) return;
      final source = api.notificationScope;
      final keys = <String>{};
      for (final item in entries) {
        if (item is! Map ||
            item['kind'] is! String ||
            item['sessionId'] is! String ||
            item['identity'] is! String) {
          return;
        }
        keys.add(
          attentionKey(
            kind: item['kind'] as String,
            sessionId: item['sessionId'] as String,
            identity: item['identity'] as String,
            source: source,
          ),
        );
      }
      onAttentionSnapshot?.call(source, keys);
      return;
    }
    if (type == 'git/changed') {
      final repositoryId = frame['repositoryId'];
      if (repositoryId is String && repositoryId.isNotEmpty) {
        _emitChatEvent(
          ChatEvent(type: 'git/changed', data: {'repositoryId': repositoryId}),
        );
      }
      return;
    }
    if (type == 'notifications/changed') {
      // 通知被增删（如移动端删除记录）：刷新列表与未读角标
      refreshNotifs();
      return;
    }
    if (type == 'mobile/notify') {
      // v2.7.2 review(M6)：通知帧（含审批/提问 needs-answer）与悬浮球同源——
      // 即时刷新通知中心/角标，不再等 turn/end 或 notifications/changed 兜底
      // v3.3.1（可观测性）：真机排查"通知有时不弹"时，先确认帧到底有没有到。
      final n = frame['notification'];
      if (n is Map) {
        AppLog.instance.log(
          '通知：收到 mobile/notify id=${n['id']} kind=${n['kind']} '
          'session=${n['sessionId']} approvalId=${n['approvalId'] ?? "无"}',
        );
      }
      refreshNotifs();
      return;
    }
    if (type == 'mobile/frame') {
      // 内核问询/审批瞬态帧（question|approval requested/resolved）
      final f = frame['frame'];
      if (f is! Map<String, dynamic>) return;
      final ftype = f['type'];
      if (ftype == 'question/requested') {
        final request = QuestionRequest(
          rpcId: f['rpcId'] as String? ?? '',
          sessionId: f['sessionId'] as String? ?? sessionId ?? '',
          questions: (f['questions'] as List? ?? [])
              .map((q) => AskQuestion.fromJson(q as Map<String, dynamic>))
              .toList(),
        );
        _pendingQuestionsBySession[request.sessionId] = request;
        pendingQuestion = request; // legacy single-pending compatibility
        // issue #120：真机定位日志（只观测）——记录问询实际挂到哪个 session、
        // 帧自身携带的 sessionId、以及 store 当前会话，便于与 ChatScreen 的日志对账。
        AppLog.instance.log(
          '[120-debug] question pending stored: '
          'sessionId=${request.sessionId} '
          'frameSessionId=${f['sessionId'] ?? ''} '
          'storeSessionId=${sessionId ?? ''} '
          'rpcId=${request.rpcId}',
        );
        notifyListeners();
        _emitChatEvent(
          ChatEvent(
            type: 'question/requested',
            sessionId: request.sessionId,
            data: {'rpcId': request.rpcId, 'sessionId': request.sessionId},
          ),
        );
        onAttentionEvent?.call(
          AttentionEvent(
            kind: AttentionKind.question,
            source: api.notificationScope,
            sessionId: request.sessionId,
            identity: request.rpcId,
            at: DateTime.now(),
            summary: request.questions.isEmpty
                ? null
                : request.questions.first.question,
          ),
        );
        AppLog.instance.log(
          '通知：问询帧到达 rpc=${request.rpcId} session=${request.sessionId}（已交给本地通知）',
        );
        return;
      }
      if (ftype == 'question/resolved') {
        final rid = f['questionRpcId'];
        final explicitSessionId = f['sessionId'] as String?;
        final matchingQuestion = _questionForRpc(rid);
        final resolvedSessionId =
            explicitSessionId ?? matchingQuestion?.sessionId;
        // 按 rpcId 精确清除：带 sessionId 的 resolved 帧不得误删同会话中的其它挂起问询。
        final hadPending =
            pendingQuestion?.rpcId == rid || matchingQuestion != null;
        _clearPendingQuestion(rid);
        if (hadPending) notifyListeners();
        if (rid is String && rid.isNotEmpty) {
          onAttentionResolved?.call(rid);
        }
        // 无条件转发：即使本地已在提交/取消时提前清空，聊天页也要据此收起卡片
        _emitChatEvent(
          ChatEvent(
            type: 'question/resolved',
            sessionId: resolvedSessionId,
            data: {'rpcId': rid, 'sessionId': resolvedSessionId},
          ),
        );
        return;
      }
      if (ftype == 'approval/requested') {
        final request = ApprovalRequest(
          rpcId: f['rpcId'] as String? ?? '',
          sessionId: f['sessionId'] as String? ?? sessionId ?? '',
          approvalId: f['approvalId'] as String? ?? '',
          toolName: f['toolName'] as String? ?? '',
          callId: f['callId'] as String?,
          reason: f['reason'] as String?,
        );
        _pendingApprovalsBySession[request.sessionId] = request;
        pendingApproval = request; // legacy single-pending compatibility
        notifyListeners();
        _emitChatEvent(
          ChatEvent(
            type: 'approval/requested',
            sessionId: request.sessionId,
            data: {'rpcId': request.rpcId, 'sessionId': request.sessionId},
          ),
        );
        onAttentionEvent?.call(
          AttentionEvent(
            kind: AttentionKind.approval,
            source: api.notificationScope,
            sessionId: request.sessionId,
            identity: request.approvalId.isEmpty
                ? request.rpcId
                : request.approvalId,
            at: DateTime.now(),
            toolName: request.toolName,
            summary: request.reason,
          ),
        );
        AppLog.instance.log(
          '通知：审批帧到达 rpc=${request.rpcId} approvalId=${request.approvalId} '
          'session=${request.sessionId} tool=${request.toolName}（已交给本地通知）',
        );
        return;
      }
      if (ftype == 'approval/resolved') {
        final aid = f['approvalId'];
        final explicitSessionId = f['sessionId'] as String?;
        final matchingApproval = _approvalForId(aid);
        final resolvedSessionId =
            explicitSessionId ?? matchingApproval?.sessionId;
        // 按 approvalId 精确清除：不能按 session 盲删（会误删同会话中的其它挂起审批）。
        final hadPending =
            pendingApproval?.approvalId == aid || matchingApproval != null;
        _pendingApprovalsBySession.removeWhere((sid, a) => a.approvalId == aid);
        if (pendingApproval?.approvalId == aid) pendingApproval = null;
        if (hadPending) notifyListeners();
        // M1a：按 identity 精确撤销对应系统通知（resolved 帧不带 sessionId，
        // 所以不能靠 sessionId 重建 key）。
        if (aid is String && aid.isNotEmpty) {
          onAttentionResolved?.call(aid);
        }
        // 无条件转发：聊天页据此收起审批卡片
        _emitChatEvent(
          ChatEvent(
            type: 'approval/resolved',
            sessionId: resolvedSessionId,
            data: {'approvalId': aid, 'sessionId': resolvedSessionId},
          ),
        );
        return;
      }
      return;
    }
    if (type == 'mobile/queue') {
      // v3.0.0：内核队列快照帧（认领/删除/编辑即时反映）→ 权威镜像，聊天页 dock 即时同步
      final sid = frame['sessionId'] as String?;
      if (sid != null && sid.isNotEmpty) {
        applyQueue(
          sid,
          (frame['rows'] as List? ?? []).cast<Map<String, dynamic>>(),
          fromFrame: true,
        );
      }
      return;
    }
    if (type == 'session/context') {
      // 上下文窗口实时帧：转发给聊天页（圆环即时刷新，无需重进会话）
      final fsid = frame['sessionId'] as String?;
      if (fsid != null && fsid.isNotEmpty) {
        _emitChatEvent(
          ChatEvent(
            type: 'session/context',
            sessionId: fsid,
            data: {'contextWindow': frame['contextWindow'], 'sessionId': fsid},
          ),
        );
      }
      return;
    }
    if (type == 'session/jobs') {
      // v2.7：会话任务视图（后台任务进度，与 PC 端同源）
      final fsid = frame['sessionId'] as String?;
      if (fsid != null) {
        jobsBySession[fsid] = (frame['jobs'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        notifyListeners();
        _emitChatEvent(
          ChatEvent(
            type: 'session/jobs',
            sessionId: fsid,
            data: {'sessionId': fsid, 'jobs': jobsBySession[fsid]},
          ),
        );
      }
      return;
    }
    if (type == 'session/event') {
      final event = frame['event'];
      if (event is! Map<String, dynamic>) return;
      final evType = event['type'];
      // 任意会话事件都视为"有动静"：去抖刷新会话列表（标题/排序），
      // 高频 chunk 期间定时器持续重置，流结束后才真正刷新一次。
      _debounceSessions();
      final fsid = frame['sessionId'];
      // v2.7 修复：轮次结束 → 主动刷新通知（不依赖插件 notifications/changed 广播，
      // 旧插件写入后不广播时 App 铃铛也能跟上）
      if (evType == 'turn/end') {
        _debounceNotifs();
      }
      // 排障日志：帧到达与归属（高频 chunk 不记）
      if (evType != 'assistant/chunk' &&
          evType != 'assistant/live-chunk' &&
          evType != 'tool/call' &&
          evType != 'tool/result') {
        AppLog.instance.log(
          'SSE: session/event $evType from=$fsid 当前=${sessionId ?? "无"}',
        );
      }
      // v2.7.2 review(M1)：不再按全局 sessionId 过滤——全部广播并携带 sessionId，
      // 各 ChatScreen 按自己的会话过滤（叠层页面各收各的，旧页不被新会话事件污染）
      final ce = ChatEvent.fromJson(event);
      _emitChatEvent(
        ChatEvent(
          seq: ce.seq,
          type: ce.type,
          data: ce.data,
          sessionId: fsid as String?,
          detailAvailable: ce.detailAvailable,
          // issue #126：实时摘要的 call/result 结构化数据与正文长度提示也必须原样
          // 带给时间线；否则同一事件在 live 与 reload 后呈现不同（工具卡缺退出码/
          // 命中数徽标，assistant 缺“查看全文”入口）。
          detailTextChars: ce.detailTextChars,
          callSummary: ce.callSummary,
          resultSummary: ce.resultSummary,
          // issue #52/#53：实时摘要的 time 与 turn/end 的 tail 必须原样带给时间线，
          // 否则 live 轮次页脚没有用时、轮末卡片要等重进会话才出现。
          time: ce.time,
          tail: ce.tail,
          // issue #99：surface 投影 envelope 必须原样带给时间线/跟踪器，
          // 否则 SSE replay 会被当成新的工具调用（history 路径已直接解析）。
          surfaceOp: ce.surfaceOp,
          sourceEventSeqs: ce.sourceEventSeqs,
        ),
      );
    } else if (type == 'agent/status') {
      // agentId 与 sessionId 是不同标识；页面路由必须使用 frame.sessionId。
      final aid = frame['agentId'] as String?;
      final sid = frame['sessionId'] as String?;
      final st = frame['status'];
      final norm = normalizeAgentStatus(st);
      // issue #124/#133：新宿主帧携带 rootSessionId + 递归 running 子代理数（0 也发）。
      // 根 idle、子 running 时会话列表据此立即显示运行指示；子结束/agent disposed
      // （插件补合成 idle 帧）时立即清零。字段缺失（旧宿主）→ 本地树 fallback。
      final rootId = frame['rootSessionId'];
      final runningRaw = frame['subagentsRunning'];
      final runningCount = runningRaw is num ? runningRaw.toInt() : null;
      var subagentsChanged = false;
      if (rootId is String &&
          rootId.isNotEmpty &&
          runningCount != null &&
          subagentRunningByRoot[rootId] != runningCount) {
        subagentRunningByRoot[rootId] = runningCount;
        subagentsChanged = true;
      }
      // 同步内存会话字段（union 读取时会用到；不必等下一次 /sessions 慢快照）。
      if (rootId is String && rootId.isNotEmpty && runningCount != null) {
        final idx = sessions.indexWhere((s) => s.id == rootId);
        if (idx >= 0 && sessions[idx].subagentsRunning != runningCount) {
          sessions[idx] = sessions[idx].copyWith(subagentsRunning: runningCount);
        }
      }
      _agentStatusEpoch++; // 增量帧落地：期间到达的 bootstrap/慢快照不再裁剪（见 _syncAgentStatus）
      // v3.1.6（issue #14）：会话列表的 running 标识必须随**任意**会话的状态变化实时
      // 启停（此前只在"当前打开的会话"变化时通知界面，列表动效会卡住不动）。
      // 但也不能每帧都通知——高频重复帧会让整页反复重建；只在取值真的变化时通知。
      final changed =
          subagentsChanged ||
          (aid != null && aid.isNotEmpty && agentStatusMap[aid] != norm) ||
          (sid != null && sid.isNotEmpty && sessionAgentStatus[sid] != norm);
      if (aid != null && aid.isNotEmpty) agentStatusMap[aid] = norm;
      if (sid != null && sid.isNotEmpty) sessionAgentStatus[sid] = norm;
      final current = sid != null && sid.isNotEmpty
          ? sid == sessionId
          : aid == sessionId;
      // legacy：无 id 的帧只影响当前页显示（保留下方原有语义）
      final legacyUnrouted = sid == null && aid == null;
      if (current || legacyUnrouted) {
        agentStatus = norm;
      }
      if (current || changed || legacyUnrouted) {
        notifyListeners();
      }
      if (sid != null && sid.isNotEmpty) {
        _emitChatEvent(
          ChatEvent(
            type: 'agent/status',
            sessionId: sid,
            data: {'status': st, 'sessionId': sid, 'agentId': aid},
          ),
        );
      } else if (current) {
        // Legacy frame without sessionId: only the currently bound page may see it.
        _emitChatEvent(
          ChatEvent(
            type: 'agent/status',
            sessionId: sessionId,
            data: {'status': st, 'sessionId': sessionId, 'agentId': aid},
          ),
        );
      }
    }
  }

  void _catchup() {
    final id = sessionId;
    if (id == null) return;
    // 聊天页自己管理 lastSeq；这里仅触发一次历史补拉回调
    _emitChatEvent(ChatEvent(type: '_catchup', data: {}));
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _sub = null;
    _connecting = false;
    _retryTimer?.cancel();
    _setConnState('offline');
    if (_sseBusy) {
      // 服务端连接满：5s/10s 退避，不再每 2s 探测。
      final delay = Duration(seconds: _retry >= 6 ? 10 : 5);
      _retry = _retry >= 6 ? 6 : _retry + 1;
      // 真机诊断（issue #131）：把"被 503 拒绝"与"普通断线重连"在日志里分开。
      AppLog.instance.log(
        'SSE: 服务端连接满（503），${delay.inSeconds}s 后重试（第 $_retry 次退避）',
      );
      _retryTimer = Timer(delay, connect);
      return;
    }
    if (_retry >= 3) {
      _retryTimer = Timer(const Duration(seconds: 2), () async {
        final epoch = _agentStatusEpoch;
        try {
          final d = await api.getJson(
            '/api/bootstrap',
            timeout: const Duration(seconds: 8),
          );
          _syncAgentStatus(d, snapshotEpoch: epoch);
          _retry = 0;
          connect();
        } catch (_) {
          // 当前地址连续失败：轮换到下一个候选地址（外出自动切 Tailscale）
          if (api.rotateBaseUrl()) {
            AppLog.instance.log('连接切换地址 → ${api.baseUrl}');
            _retry = 0; // 新地址重新开始退避
          } else {
            _retry++;
          }
          _scheduleReconnect();
        }
      });
      return;
    }
    final delay = Duration(
      milliseconds: (1000 * (1 << _retry)).clamp(1000, 15000),
    );
    _retry++;
    _retryTimer = Timer(delay, connect);
  }

  Timer? _sessTimer;
  void _debounceSessions() {
    _sessTimer?.cancel();
    _sessTimer = Timer(const Duration(milliseconds: 800), () {
      refreshSessions();
      onSessionsChanged?.call();
    });
  }

  Timer? _notifTimer;
  void _debounceNotifs() {
    _notifTimer?.cancel();
    _notifTimer = Timer(const Duration(milliseconds: 500), () {
      refreshNotifs();
    });
  }

  void disposeBridge() {
    _sub?.cancel();
    _retryTimer?.cancel();
    _sessTimer?.cancel();
    _notifTimer?.cancel();
    _watchdog?.cancel();
    _watchdog = null;
    api.onSseKeepalive = null;
    _sub = null;
    _connecting = false;
    // issue #22/#133：连接代失效——释放旧代刷新守卫并清掉子代理瞬态状态。
    _invalidateSessionRefresh();
  }

  @override
  void dispose() {
    disposeBridge();
    super.dispose();
  }
}
