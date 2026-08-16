// 全局状态 + SSE 事件桥（对齐网页端 page.html 的 state / connect / handleEvent）
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'logger.dart';
import 'models.dart';

class AppStore extends ChangeNotifier {
  // ── 数据 ──
  String? sessionId; // 当前会话
  Catalog? catalog;
  SessionConfig sessionConfig = SessionConfig();
  List<Session> sessions = [];
  List<Map<String, dynamic>> actions = [];
  int unread = 0;
  bool showTools = false;
  String agentStatus = 'idle'; // idle | running | waiting
  String darkMode = 'system'; // system | dark | light

  /// 已注册工作区（PC 端 workspaceRegistry）：[{id, path, title}]。
  List<Map<String, dynamic>> workspaces = [];

  /// 当前选中的工作区路径（null = 全部）。影响会话列表过滤与新建会话默认目录。
  String? workspacePath;

  /// 内核待回答的问询/审批（弹窗数据，与 PC 端同一 pending 通道；断线重连后服务端会补发）。
  QuestionRequest? pendingQuestion;
  ApprovalRequest? pendingApproval;

  // ── 事件监听（聊天页挂载） ──
  void Function(ChatEvent ev)? onChatEvent;
  VoidCallback? onSessionsChanged; // 标题/预设变化 → 外部刷新

  // ── SSE 内部 ──
  StreamSubscription<Map<String, dynamic>>? _sub;
  int _retry = 0;
  Timer? _retryTimer;
  bool _connecting = false;

  static const _kSession = 'dsh_mr_session';
  static const _kTools = 'dsh_mr_showtools';
  static const _kDark = 'dsh_mr_darkmode';
  static const _kWorkspace = 'dsh_mr_workspace';
  static const _kSessCache = 'dsh_mr_sessions_cache';

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    sessionId = prefs.getString(_kSession);
    showTools = prefs.getBool(_kTools) ?? false;
    darkMode = prefs.getString(_kDark) ?? 'system';
    final savedWs = prefs.getString(_kWorkspace);
    workspacePath = savedWs == null ? null : _normPath(savedWs);
    // 会话本地缓存：App 打开瞬间先显示上次的列表，后台静默刷新（解决"进去要等一会才有数据"）
    try {
      final raw = prefs.getString(_kSessCache);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        sessions = list
            .map((e) => Session.fromJson(e as Map<String, dynamic>))
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
          jsonEncode(sessions.map((s) => s.toJson()).toList()),
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

  /// 切换当前工作区（null = 全部）。
  Future<void> setWorkspace(String? path) async {
    workspacePath = path == null ? null : _normPath(path);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (workspacePath == null) {
      await prefs.remove(_kWorkspace);
    } else {
      await prefs.setString(_kWorkspace, workspacePath!);
    }
  }

  Future<void> setDarkMode(String v) async {
    darkMode = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDark, v);
  }

  Future<void> setSession(String? id) async {
    sessionId = id;
    notifyListeners();
    if (id != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSession, id);
      // 记录打开时间（"最近会话"排序依据之一），失败静默
      unawaited(api.touchSession(id));
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
  Future<String?> answerQuestion(String rpcId, String sessionId, List<Map<String, dynamic>> answers) async {
    try {
      final r = await api.respond(kind: 'question', rpcId: rpcId, sessionId: sessionId, answers: answers);
      if (r['accepted'] == true) {
        if (pendingQuestion?.rpcId == rpcId) {
          pendingQuestion = null;
          notifyListeners();
        }
        return null;
      }
      // not-pending / bad-response：PC 端可能已先答，弹窗应关闭
      if (pendingQuestion?.rpcId == rpcId) {
        pendingQuestion = null;
        notifyListeners();
      }
      return '${r['reason'] ?? '回答未被接受'}（可能电脑端已先回答）';
    } catch (e) {
      return '回答失败：$e';
    }
  }

  /// 审批工具权限：outcome = "allowed-once" | "rejected"。
  Future<String?> answerApproval(String rpcId, String sessionId, String approvalId, String outcome) async {
    try {
      final r = await api.respond(
          kind: 'approval', rpcId: rpcId, sessionId: sessionId, approvalId: approvalId, outcome: outcome);
      if (r['accepted'] == true) {
        if (pendingApproval?.rpcId == rpcId) {
          pendingApproval = null;
          notifyListeners();
        }
        return null;
      }
      if (pendingApproval?.rpcId == rpcId) {
        pendingApproval = null;
        notifyListeners();
      }
      return '${r['reason'] ?? '审批未被接受'}（可能电脑端已先处理）';
    } catch (e) {
      return '审批失败：$e';
    }
  }

  /// 取消（跳过）问询/审批：内核收到 cancelled，agent 按 ASK_CANCELLED 继续。
  Future<void> cancelRespond(String rpcId) async {
    try {
      await api.respond(kind: 'cancel', rpcId: rpcId, sessionId: '');
    } catch (_) {}
    if (pendingQuestion?.rpcId == rpcId) pendingQuestion = null;
    if (pendingApproval?.rpcId == rpcId) pendingApproval = null;
    notifyListeners();
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
      if (w['path'] == workspacePath) return w;
    }
    return null;
  }

  /// 未归档会话，按最近活跃（打开/SSE 动静）排序；按当前工作区过滤。
  List<Session> get activeSessions {
    final ws = _selectedWorkspace();
    final list = sessions
        .where((s) => !s.archived && (ws == null || _inWorkspace(s, ws)))
        .toList();
    list.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return list;
  }

  /// 已归档会话，同样按最近活跃排序；按当前工作区过滤。
  List<Session> get archivedSessions {
    final ws = _selectedWorkspace();
    final list = sessions
        .where((s) => s.archived && (ws == null || _inWorkspace(s, ws)))
        .toList();
    list.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return list;
  }

  /// 当前工作区的显示名（无工作区/全部时为 null）。
  String? get workspaceTitle {
    if (workspacePath == null) return null;
    for (final w in workspaces) {
      if (w['path'] == workspacePath) return (w['title'] as String?) ?? workspacePath;
    }
    return workspacePath;
  }

  Future<void> setShowTools(bool v) async {
    showTools = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTools, v);
  }

  // ── 启动加载（对齐网页端 bootstrap） ──
  Future<void> refreshAll() async {
    // 整体限时 8 秒：网络不通时避免 5 个请求各自 15s 超时堆积
    await Future.any([_refreshAllInner(), Future<void>.delayed(const Duration(seconds: 8))]);
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
          } catch (_) {/* 冷会话保持旧值 */}
        }
        notifyListeners();
      } catch (_) {/* 目录加载失败不阻塞首屏 */}
    } catch (_) {/* 首屏失败由连接页处理 */}
  }

  /// 拉取模型目录（新建会话弹层懒加载用），成功返回目录、失败返回 null。
  Future<Catalog?> refreshCatalog() async {
    try {
      catalog = await api.catalog();
      notifyListeners();
      return catalog;
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshWorkspaces({bool notify = true}) async {
    try {
      final raw = await api.workspaces();
      // 统一规范化 path，保证与 workspacePath/会话 cwd 的匹配形态一致
      workspaces = raw
          .map((w) => {...w, 'path': _normPath(w['path'] as String? ?? '')})
          .toList();
      // 已选工作区不再存在时回退到"全部"
      if (workspacePath != null && !workspaces.any((w) => w['path'] == workspacePath)) {
        workspacePath = null;
      }
      if (notify) notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshSessions({bool notify = true}) async {
    try {
      sessions = await api.sessions();
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
  }

  Future<void> refreshNotifs({bool notify = true}) async {
    try {
      final items = await api.notifications();
      unread = items.where((n) => n.unread).length;
      if (notify) notifyListeners();
    } catch (_) {}
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
        AppLog.instance.log('SSE: 心跳超时（${DateTime.now().difference(_lastLiveness).inSeconds}s），强制重建连接');
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
    try {
      final d = await api.getJson('/api/bootstrap');
      // 合并服务端返回的全部地址（含 Tailscale IP）+ 记录插件版本
      api.absorbBootstrap(d);
      _setConnState('connected');
      // 关键修复：探针成功 ≠ 旧 SSE 流还活着。App 后台期间 TCP 可能已静默死亡
      // 而流未触发 onDone/onError —— 若不重建，connect() 会被 `_sub != null` 挡住，
      // 永远卡在"显示已连接但实际离线"，只能划掉 App 重开。
      final stale = DateTime.now().difference(_lastLiveness).inSeconds > 45;
      if (_sub != null && stale) {
        AppLog.instance.log('SSE: 前台恢复发现旧流已死（${DateTime.now().difference(_lastLiveness).inSeconds}s 无心跳），重建连接');
        _sub!.cancel();
        _sub = null;
        _connecting = false;
      }
      if (_sub == null) connect();
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

  void _onFrame(Map<String, dynamic> frame) {
    _retry = 0;
    final type = frame['type'];
    if (type == 'hello') {
      _setConnState('connected');
      _catchup();
      // 连接成功：收集电脑全部地址（LAN + Tailscale），供断线时自动轮换
      unawaited(api.collectUrls());
      // 重连成功：补拉会话/通知/目录/工作区（桌面端重启后 App 无需手动刷新即可完整恢复）
      _debounceSessions();
      refreshNotifs(notify: false);
      unawaited(refreshCatalog());
      unawaited(refreshWorkspaces());
      return;
    }
    if (type == 'notifications/changed') {
      // 通知被增删（如移动端删除记录）：刷新列表与未读角标
      refreshNotifs();
      return;
    }
    if (type == 'mobile/frame') {
      // 内核问询/审批瞬态帧（question|approval requested/resolved）
      final f = frame['frame'];
      if (f is! Map<String, dynamic>) return;
      final ftype = f['type'];
      if (ftype == 'question/requested') {
        pendingQuestion = QuestionRequest(
          rpcId: f['rpcId'] as String? ?? '',
          sessionId: f['sessionId'] as String? ?? '',
          questions: (f['questions'] as List? ?? [])
              .map((q) => AskQuestion.fromJson(q as Map<String, dynamic>))
              .toList(),
        );
        notifyListeners();
        onChatEvent?.call(ChatEvent(type: 'question/requested',
            data: {'rpcId': pendingQuestion!.rpcId, 'sessionId': pendingQuestion!.sessionId}));
        return;
      }
      if (ftype == 'question/resolved') {
        final rid = f['questionRpcId'];
        if (pendingQuestion != null && pendingQuestion!.rpcId == rid) {
          pendingQuestion = null;
          notifyListeners();
        }
        // 无条件转发：即使本地已在提交/取消时提前清空，聊天页也要据此收起卡片
        onChatEvent?.call(ChatEvent(type: 'question/resolved', data: {'rpcId': rid}));
        return;
      }
      if (ftype == 'approval/requested') {
        pendingApproval = ApprovalRequest(
          rpcId: f['rpcId'] as String? ?? '',
          sessionId: f['sessionId'] as String? ?? '',
          approvalId: f['approvalId'] as String? ?? '',
          toolName: f['toolName'] as String? ?? '',
          callId: f['callId'] as String?,
          reason: f['reason'] as String?,
        );
        notifyListeners();
        onChatEvent?.call(ChatEvent(type: 'approval/requested',
            data: {'rpcId': pendingApproval!.rpcId, 'sessionId': pendingApproval!.sessionId}));
        return;
      }
      if (ftype == 'approval/resolved') {
        final aid = f['approvalId'];
        if (pendingApproval != null && pendingApproval!.approvalId == aid) {
          pendingApproval = null;
          notifyListeners();
        }
        // 无条件转发：聊天页据此收起审批卡片
        onChatEvent?.call(ChatEvent(type: 'approval/resolved', data: {'approvalId': aid}));
        return;
      }
      return;
    }
    if (type == 'session/context') {
      // 上下文窗口实时帧：转发给聊天页（圆环即时刷新，无需重进会话）
      final fsid = frame['sessionId'];
      if (sessionId == null || fsid == sessionId) {
        onChatEvent?.call(ChatEvent(type: 'session/context', data: {'contextWindow': frame['contextWindow']}));
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
      // 排障日志：帧到达与过滤（高频 chunk 不记）
      if (evType != 'assistant/chunk' && evType != 'tool/call' && evType != 'tool/result') {
        AppLog.instance.log('SSE: session/event $evType from=$fsid 当前=${sessionId ?? "无"} ${sessionId != null && fsid != sessionId ? "（被过滤）" : ""}');
      }
      if (sessionId == null || fsid == sessionId) {
        onChatEvent?.call(ChatEvent.fromJson(event));
      }
    } else if (type == 'agent/status') {
      final st = frame['status'];
      agentStatus = st == 'running' ? 'running' : (st == 'waiting' ? 'waiting' : 'idle');
      notifyListeners();
      onChatEvent?.call(ChatEvent(type: 'agent/status', data: {'status': st}));
    }
  }

  void _catchup() {
    final id = sessionId;
    if (id == null) return;
    // 聊天页自己管理 lastSeq；这里仅触发一次历史补拉回调
    onChatEvent?.call(ChatEvent(type: '_catchup', data: {}));
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _sub = null;
    _connecting = false;
    _retryTimer?.cancel();
    _setConnState('offline');
    if (_retry >= 3) {
      _retryTimer = Timer(const Duration(seconds: 2), () async {
        try {
          await api.getJson('/api/bootstrap');
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
    final delay = Duration(milliseconds: (1000 * (1 << _retry)).clamp(1000, 15000));
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

  void disposeBridge() {
    _sub?.cancel();
    _retryTimer?.cancel();
    _sessTimer?.cancel();
    _watchdog?.cancel();
    _watchdog = null;
    api.onSseKeepalive = null;
    _sub = null;
    _connecting = false;
  }

  @override
  void dispose() {
    disposeBridge();
    super.dispose();
  }
}
