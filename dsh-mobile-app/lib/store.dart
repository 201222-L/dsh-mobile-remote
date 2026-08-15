// 全局状态 + SSE 事件桥（对齐网页端 page.html 的 state / connect / handleEvent）
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
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

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    sessionId = prefs.getString(_kSession);
    showTools = prefs.getBool(_kTools) ?? false;
    darkMode = prefs.getString(_kDark) ?? 'system';
    notifyListeners();
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
    }
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
      catalog = await api.catalog();
      if (sessionId != null) {
        try {
          sessionConfig = await api.sessionConfig(sessionId!);
        } catch (_) {/* 冷会话保持旧值 */}
      }
      await refreshSessions(notify: false);
      await refreshNotifs(notify: false);
      await refreshActions(notify: false);
      notifyListeners();
    } catch (_) {/* 首屏失败由连接页处理 */}
  }

  Future<void> refreshSessions({bool notify = true}) async {
    try {
      sessions = await api.sessions();
      if (notify) notifyListeners();
    } catch (_) {}
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

  void connect() {
    if (_sub != null || _connecting) return;
    _connecting = true;
    _setConnState('connecting');
    _sub = api.eventsRaw().listen(
      _onFrame,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
  }

  /// App 回到前台时调用：探测电脑端在线状态，SSE 断开则立即重连，并刷新数据。
  Future<void> resume() async {
    if (api.baseUrl.isEmpty || api.token.isEmpty) return; // 未配置连接
    try {
      await api.getJson('/api/bootstrap');
      _setConnState('connected');
      if (_sub == null) connect();
      refreshAll();
    } catch (_) {
      _setConnState('offline');
      if (_sub == null) connect(); // 由重连机制持续尝试
    }
  }

  void _onFrame(Map<String, dynamic> frame) {
    _retry = 0;
    final type = frame['type'];
    if (type == 'hello') {
      _setConnState('connected');
      _catchup();
      return;
    }
    if (type == 'session/event') {
      final event = frame['event'];
      if (event is! Map<String, dynamic>) return;
      final evType = event['type'];
      if (evType == 'session/title' || evType == 'agent-preset/selected') {
        _debounceSessions();
      }
      final fsid = frame['sessionId'];
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
          _retry++;
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
    _sub = null;
    _connecting = false;
  }

  @override
  void dispose() {
    disposeBridge();
    super.dispose();
  }
}
