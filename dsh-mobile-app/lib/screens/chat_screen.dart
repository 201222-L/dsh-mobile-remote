// 对话页：消息流（Markdown/流式/工具折叠/token 用量）+ 上翻加载 + 快捷动作 + composer
import 'dart:async';
import 'package:flutter/material.dart';
import '../toast.dart';
import 'package:flutter/services.dart';
import '../api.dart';
import '../logger.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../md.dart';
import 'sheets.dart';
import 'session_tools_sheet.dart';

class ChatScreen extends StatefulWidget {
  final AppStore store;
  final String? initialSend; // 首页直达发送
  final VoidCallback onTitleChanged;
  const ChatScreen({super.key, required this.store, this.initialSend, required this.onTitleChanged});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  // live 视图：最新在前（reverse 列表 index 0 = 最新，视觉底部）
  final List<_MsgItem> _items = [];
  // 活动条状态：执行中的工具（callId -> 工具名）+ 思考累积文本
  final Map<String, String> _activeTools = {};
  String _reasoning = '';
  bool _reasoningExpanded = false;
  Timer? _activityTimer;
  String _draft = '';
  bool _streaming = false;
  int _lastSeq = 0;
  // v2.7.2 review(M1)：本页绑定的会话（initState 时捕获）——事件按它过滤，叠层页面互不污染
  String? _mySessionId;
  // v2.7.2：排队消息停靠区（对齐 PC 端 Queue Dock）——可见、自解释，无需操作手册
  List<Map<String, dynamic>> _queue = [];
  bool _queueCollapsed = true; // 多条时折叠成计数头
  String? _editingQueueId;
  final _queueEditCtrl = TextEditingController();
  Timer? _queueRefreshTimer;
  Timer? _queuePollTimer; // v2.7.2 review：dock 可见时的周期兜底刷新
  bool _queueBusy = false; // v2.7.2 review：队列操作忙碌锁（防连点双发）
  int _earliestSeq = 0; // live 窗口最旧条目的 seq（"查看更早"分页起点）
  bool _loadingMore = false;
  bool _noMoreHistory = false; // 已到会话最顶端（无更早消息），停止再查询
  bool _showJumpToLatest = false; // 上翻后显示"回到底部"浮钮
  QuestionRequest? _question; // 内核问询弹窗（当前会话，思考中途需要拍板）
  ApprovalRequest? _approval; // 内核权限审批弹窗（当前会话）
  bool _sending = false;
  String? _title;
  Map<String, dynamic> _usage = {};
  bool _usageLoaded = false;
  Timer? _draftTimer; // 流式草稿节流刷新（chunk 合并，避免每帧全量重建）
  int _lastLoggedCount = -1; // 排障：itemCount 变化时打日志
  bool _scrolledLogged = false; // 排障：滚动状态打一次日志

  // ── 分段历史浏览（超长会话的安全阀，仅当无限模式不可用时启用） ──
  static const _liveMax = 50; // 无限模式下不裁剪；分段模式下 live 窗口上限
  static const _infiniteMode = true; // 微信式无限上翻（配合 Impeller 实验）
  static const _histPageSize = 30; // 历史分段每段条数
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
    final pq = widget.store.pendingQuestion;
    final pa = widget.store.pendingApproval;
    _question = pq != null && pq.sessionId == widget.store.sessionId ? pq : null;
    _approval = pa != null && pa.sessionId == widget.store.sessionId ? pa : null;
    _mySessionId = widget.store.sessionId; // v2.7.2 review(M1)：绑定本页会话
    widget.store.addChatListener(_handleEvent); // v2.7.2 review(M1)：监听器列表，叠层页面互不覆盖
    _scrollCtrl.addListener(_onScrollTick);
    _load();
    // v2.7：恢复该会话上次未发送的输入草稿
    final sid = widget.store.sessionId;
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
    final sid = widget.store.sessionId;
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

  /// 滚动监听：上翻超过阈值显示"回到底部"浮钮，回到 offset 0 时隐藏。
  void _onScrollTick() {
    if (!mounted || _inHistory) return;
    final visible = _scrollCtrl.hasClients && _scrollCtrl.position.pixels > 160;
    if (visible != _showJumpToLatest) {
      setState(() => _showJumpToLatest = visible);
    }
  }

  /// 一键回到最新消息：近距平滑滚动，远距直接跳（避免超长距离动画卡顿）。
  void _jumpToLatest() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    AppLog.instance.log('Chat: 回到底部 pixels=${pos.pixels.toStringAsFixed(0)}');
    if (pos.pixels > 4000) {
      _scrollCtrl.jumpTo(0);
    } else {
      _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
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

  /// 滚动到最新消息。live 视图为 reverse 列表（最新固定在 offset 0），
  /// 一行 jumpTo(0) 即到底；历史浏览视图不跟随滚动。
  void _scrollToBottom({bool force = false}) {
    if (_inHistory) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      if (force || !_scrolledLogged) {
        _scrolledLogged = true;
        AppLog.instance.log('Chat: 滚动${force ? "(force)" : ""} pixels=${pos.pixels.toStringAsFixed(0)} max=${pos.maxScrollExtent.toStringAsFixed(0)}');
      }
      if (force || pos.pixels < 220) {
        _scrollCtrl.jumpTo(0);
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

  Future<void> _load() async {
    final id = widget.store.sessionId;
    if (id == null) return;
    AppLog.instance.log('Chat: 打开会话 $id');
    try {
      final events = await api.history(id, limit: _liveMax);
      AppLog.instance.log('Chat: 历史加载成功 ${events.length} 条');
      if (!mounted) return;
      setState(() {
        // 并发保护：历史请求期间 SSE 可能已把更新的事件入列（位于 _items 头部）。
        // 先收集保留项，再重建其余部分，不回退 _lastSeq。
        final fetchedLast = events.isNotEmpty ? (events.last.seq ?? 0) : 0;
        final keep = <_MsgItem>[];
        if (fetchedLast > 0) {
          for (final m in _items) {
            if (m.seq != null && m.seq! > fetchedLast) {
              keep.add(m);
            } else if (m.seq == null && m.kind == _MsgKind.user) {
              // review：无 seq 的乐观消息（刚发送尚未回显）也保留，避免重建后短暂消失
              keep.add(m);
              continue;
            } else if (m.seq == null) {
              // v2.7.2 乱序排查：无 seq 的非用户条目（如"发送失败"提示条）在头部时
              // 不能 break——否则其后的真新事件被丢弃/错位；跳过继续向上收集
              continue;
            } else {
              break; // _items 最新在前：一旦遇到 seq ≤ fetchedLast 即可停止
            }
          }
        }
        _noMoreHistory = false;
        _items.clear();
        _activeTools.clear();
        _reasoning = '';
        _reasoningExpanded = false;
        _draft = '';
        _streaming = false;
        // 最新在前：reverse 列表 index 0 = 最新（视觉底部）
        for (final ev in events.reversed) {
          if (ev.seq != null && ev.seq! > fetchedLast) continue; // 已在 keep 中
          _appendEvent(ev, history: true, tail: true);
        }
        _items.insertAll(0, keep); // SSE 期间的新事件放回头部
        if (events.isNotEmpty) {
          _earliestSeq = events.first.seq ?? 0;
          if (fetchedLast > _lastSeq) _lastSeq = fetchedLast;
        }
        if (keep.isNotEmpty) {
          final newest = keep.first.seq;
          if (newest != null && newest > _lastSeq) _lastSeq = newest;
        }
      });
      // v2.7.2 review：队列同步移到 setState 之外（避免误导为嵌套 setState）
      _refreshQueue();
      AppLog.instance.log('Chat: 已入列 ${_items.length} 条（历史 ${events.length} 条）lastSeq=$_lastSeq firstSeq=$_earliestSeq');
      _scrollToBottom(force: true); // 初始定位到最新消息
      _refreshUsage();
      widget.store.refreshSessionConfig();
    } catch (e) {
      AppLog.instance.log('Chat: 历史加载失败 $id → $e');
      if (mounted) {
        showToast(context, '${L10n.t('该会话暂不可用：', 'This session is unavailable: ')}$e');
        Navigator.of(context).pop();
      }
    }
  }

  // ── 无限上翻（微信式） ──
  /// 滑到 live 顶部时静默加载更早一页：追加到 _items 尾部（reverse 视觉顶部）。
  /// reverse 列表偏移锚定在最新端，尾部增长不会跳动，视觉连续无缝。
  Future<void> _loadMoreInfinite() async {
    final id = widget.store.sessionId;
    if (id == null || _loadingMore || _earliestSeq <= 0 || _noMoreHistory) return;
    _loadingMore = true;
    AppLog.instance.log('Chat: 无限上翻 before=$_earliestSeq');
    try {
      final events = await api.history(id, before: _earliestSeq, limit: _histPageSize);
      if (!mounted) return;
      if (events.isEmpty) {
        _noMoreHistory = true;
        showToast(context, L10n.t('没有更早的消息了', 'No earlier messages'));
        return; // 已到最顶：不再查询，_earliestSeq 保持不动
      }
      setState(() {
        // 页面最旧→最新；_items 最新在前，故逆序追加到尾部（视觉最顶部）
        for (final ev in events.reversed) {
          _appendEvent(ev, history: true);
        }
        _earliestSeq = events.first.seq ?? _earliestSeq;
      });
      AppLog.instance.log('Chat: 无限上翻完成 items=${_items.length} firstSeq=$_earliestSeq');
    } catch (e) {
      AppLog.instance.log('Chat: 无限上翻失败 $e');
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  /// 无限模式滚动监测：距视觉顶部 80px 内触发加载更早。
  bool _onLiveScroll(ScrollNotification n) {
    if (!_infiniteMode || !n.metrics.hasContentDimensions) return false;
    if (n.metrics.maxScrollExtent - n.metrics.pixels < 80) {
      _loadMoreInfinite();
    }
    return false;
  }

  /// 历史分段浏览 ──
  /// 进入"查看更早"：加载 live 窗口之前的一页（旧→新顺序），普通列表从顶部展示。
  Future<void> _openHistory() async {
    final id = widget.store.sessionId;
    if (id == null || _loadingMore || _earliestSeq <= 0) return;
    _loadingMore = true;
    AppLog.instance.log('Chat: 查看更早 before=$_earliestSeq');
    try {
      final events = await api.history(id, before: _earliestSeq, limit: _histPageSize);
      if (!mounted) return;
      if (events.isEmpty) {
        showToast(context, L10n.t('没有更早的消息了', 'No earlier messages'));
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
    final id = widget.store.sessionId;
    if (id == null || _loadingMore || !_histHasOlder) return;
    _loadingMore = true;
    AppLog.instance.log('Chat: 历史更早 before=$_histOldestSeq');
    try {
      final events = await api.history(id, before: _histOldestSeq, limit: _histPageSize);
      if (!mounted) return;
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
    final id = widget.store.sessionId;
    if (id == null || _loadingMore || !_histHasNewer) return;
    _loadingMore = true;
    AppLog.instance.log('Chat: 历史更新 after=$_histNewestSeq');
    try {
      final events = await api.history(id, after: _histNewestSeq, limit: _histPageSize);
      if (!mounted) return;
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

  /// live 视图：reverse 列表（index 0 = 最新，视觉底部）。
  /// 无限模式：滑到顶部静默加载更早（微信式无缝）；分段模式：顶部"查看更早"入口。
  Widget _buildLiveView() {
    final hasDraft = _streaming || _draft.isNotEmpty;
    final topButton = !_infiniteMode && _earliestSeq > 0;
    final loadingTail = _infiniteMode && _loadingMore && _earliestSeq > 0;
    final itemCount = _items.length + (hasDraft ? 1 : 0) + (topButton ? 1 : 0) + (loadingTail ? 1 : 0);
    if (itemCount != _lastLoggedCount) {
      _lastLoggedCount = itemCount;
      AppLog.instance.log('Chat: build itemCount=$itemCount streaming=$_streaming draftLen=${_draft.length} items=${_items.length}');
    }
    // v2.7.2：消息少时（≤50 条）内容贴顶 + 底部弹性留白——修复"新对话上方一大半空白"。
    // reverse 列表内容不足一屏时默认贴底,用 Column+shrinkWrap+Spacer 让内容贴顶、底部留白。
    final compact = _items.length <= 50;
    final list = ListView.builder(
      controller: _scrollCtrl,
      reverse: true,
      shrinkWrap: compact,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        // reverse 布局：最后一个 index 在视觉最顶部
        if (topButton && index == itemCount - 1) {
          return _OlderButton(busy: _loadingMore, onTap: _openHistory);
        }
        if (loadingTail && index == itemCount - 1) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        if (hasDraft && index == 0) {
          return _AssistantBubble(text: _draft, streaming: true);
        }
        return _buildItem(_items[index - (hasDraft ? 1 : 0)]);
      },
    );
    if (compact && !_infiniteMode) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(child: list),
          const Spacer(), // 视觉底部弹性留白（内容贴顶）
        ],
      );
    }
    if (!_infiniteMode) return list;
    return NotificationListener<ScrollNotification>(
      onNotification: _onLiveScroll,
      child: list,
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
              ? Center(child: Text(L10n.t('没有更早的消息', 'No earlier messages')))
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  itemCount: _histItems.length,
                  itemBuilder: (context, index) => _buildItem(_histItems[index]),
                ),
        ),
      ],
    );
  }

  Future<void> _refreshUsage() async {
    final id = widget.store.sessionId;
    if (id == null) return;
    try {
      final u = await api.usage(id);
      if (mounted) {
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
    // v2.7.2 review(M1)：只处理本页会话的事件（store 全量广播，叠层页面各收各的）
    if (ev.sessionId != null && ev.sessionId != _mySessionId) return;
    if (ev.type == '_catchup') {
      _catchup();
      return;
    }
    if (ev.type == 'agent/status') {
      setState(() {});
      return;
    }
    // 内核问询/审批弹窗帧（store 已按 sessionId 分发，这里只认当前会话）
    if (ev.type == 'question/requested') {
      final q = widget.store.pendingQuestion;
      if (q != null && q.sessionId == widget.store.sessionId) {
        setState(() => _question = q);
      }
      return;
    }
    if (ev.type == 'question/resolved') {
      final rid = ev.data?['rpcId'];
      if (rid != null && _question?.rpcId == rid) setState(() => _question = null);
      return;
    }
    if (ev.type == 'approval/requested') {
      final a = widget.store.pendingApproval;
      if (a != null && a.sessionId == widget.store.sessionId) {
        setState(() => _approval = a);
      }
      return;
    }
    if (ev.type == 'approval/resolved') {
      final aid = ev.data?['approvalId'];
      if (aid != null && _approval?.approvalId == aid) setState(() => _approval = null);
      return;
    }
    // 上下文窗口实时帧：更新圆环数据（无需重进会话）
    if (ev.type == 'session/context') {
      final window = (ev.data?['contextWindow'] as num?)?.toInt();
      if (window != null && window > 0) {
        _usage['contextWindow'] = window;
        setState(() {});
      }
      return;
    }
    // v2.7：会话任务视图更新（后台任务卡片/工具弹层刷新）
    if (ev.type == 'session/jobs') {
      if (mounted) setState(() {});
      return;
    }
    // 关键事件日志（排除高频 chunk，便于排障）
    if (ev.type != 'assistant/chunk' && ev.type != 'tool/call' && ev.type != 'tool/result') {
      AppLog.instance.log('Chat: SSE 事件 ${ev.type} seq=${ev.seq}');
    }
    if (ev.seq != null) {
      if (ev.seq! <= _lastSeq) return;
      _lastSeq = ev.seq!;
    }
    if (ev.type == 'assistant/chunk') {
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
    _scrollToBottom();
  }

  Future<void> _catchup() async {
    // v2.7.2 review(M1)：按本页绑定的会话补拉（此前用全局 sessionId，叠层时旧页会拉到新会话的增量）
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null || _lastSeq <= 0) return;
    try {
      final events = await api.history(id, after: _lastSeq, limit: 100);
      if (!mounted) return;
      setState(() {
        for (final ev in events) {
          if (ev.seq != null && ev.seq! <= _lastSeq) continue;
          if (ev.seq != null) _lastSeq = ev.seq!;
          _appendEvent(ev);
        }
      });
    } catch (_) {}
  }

  /// v2.7.2：拉取本会话排队消息（对齐 PC 端 Queue Dock 数据源 agent.inbox）。
  /// 代数守卫：只应用最新一次请求的结果，防止重叠请求乱序覆盖。
  int _queueRefreshSeq = 0;
  Future<void> _refreshQueue() async {
    final id = _mySessionId ?? widget.store.sessionId;
    if (id == null) return;
    final seq = ++_queueRefreshSeq;
    try {
      final q = await api.queue(id);
      if (!mounted || seq != _queueRefreshSeq) return;
      setState(() {
        _queue = q;
        if (q.isEmpty) _queueCollapsed = true;
      });
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
      await api.updateQueueMessage(id, itemId, {
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
      showToast(context, '${L10n.t('编辑失败：', 'Edit failed: ')}$e');
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
      await api.updateQueueMessage(id, itemId, {'kind': 'remove'});
      // v2.7.2 review：内核 remove 不校验结果——若消息已被 agent 认领（正在执行），
      // 仍返回 accepted:true 但实际没删掉。删除后立即复查队列，还在则明确提示。
      final q = await api.queue(id);
      if (mounted && q.any((r) => r['id'] == itemId)) {
        showToast(context, L10n.t('该消息已被 agent 开始处理，未能删除', 'The agent already picked it up — could not remove'));
      }
      _refreshQueue();
    } catch (e) {
      if (mounted) {
        showToast(context, '${L10n.t('删除失败：', 'Remove failed: ')}$e');
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
      await api.updateQueueMessage(id, itemId, {'kind': 'steer'});
      _refreshQueue();
    } catch (e) {
      if (mounted) {
        showToast(context, '${L10n.t('插话失败：', 'Steer failed: ')}$e');
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
  Widget _buildQueueDock() {
    final rows = _queue.where((r) => r['placement'] != 'steering').toList();
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
              icon: const Icon(Icons.play_arrow, size: 16),
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

  /// 将事件构建为消息条目并插入 out（live 语义：最新在前，insert(0)；
  /// 历史分段：旧→新顺序，追加到末尾）。
  /// [tail] 见 [_appendEvent]：历史页（history=true, tail=false）跳过 chunk、
  /// 不重置 [_draft]/[_streaming]，避免污染正在进行的流式回复。
  void _buildInto(List<_MsgItem> out, ChatEvent ev,
      {bool history = false, bool tail = false}) {
    final d = ev.data;
    switch (ev.type) {
      case 'user/message':
        final text = d?['text'] as String? ?? '';
        // 过滤 dsh 注入的系统上下文快照与后台任务通知（PC 端 GUI 也不显示）
        if (text.contains('Current runtime context') || text.contains('This snapshot supersedes')) {
          AppLog.instance.log('Chat: 过滤快照消息 seq=${ev.seq}');
          return;
        }
        if (text.startsWith('background job ')) {
          AppLog.instance.log('Chat: 过滤后台任务通知 seq=${ev.seq}');
          return;
        }
        final mid = d?['messageId'] as String?;
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
          out.add(_MsgItem.user(text, seq: ev.seq, messageId: mid));
        } else {
          out.insert(0, _MsgItem.user(text, seq: ev.seq, messageId: mid));
        }
      case 'assistant/message':
        var body = d?['text'] as String? ?? '';
        // 过滤系统注入的上下文快照与后台任务通知
        if (body.contains('Current runtime context') || body.contains('This snapshot supersedes')) {
          if (!history || tail) {
            _draft = '';
            _streaming = false;
          }
          return;
        }
        if (body.startsWith('background job ')) {
          if (!history || tail) {
            _draft = '';
            _streaming = false;
          }
          return;
        }
        // 工具阶段中间产物（正文为空的多步消息）：不渲染空气泡，过程由活动条呈现
        if (body.trim().isEmpty) {
          if (!history || tail) {
            _draft = '';
            _streaming = false;
          }
          return;
        }
        final reasoning = (d?['reasoningChars'] as num?)?.toInt() ?? 0;
        final prefix = reasoning > 0 ? L10n.t('（思考 $reasoning 字）\n', '(Thought: $reasoning chars)\n') : '';
        final item = _MsgItem.assistant(prefix + body,
            usage: d?['usage'] as Map<String, dynamic>?,
            seq: ev.seq,
            messageId: d?['messageId'] as String?);
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
        if (history && !tail) break; // 历史页不渲染 chunk：完整文本由 assistant/message 呈现
        final text = d?['text'] as String? ?? '';
        final reasoning = d?['reasoning'] == true;
        if (text.isNotEmpty && !reasoning) {
          _draft += text;
          _streaming = true;
        }
      case 'tool/call':
        // 只驱动活动条（live）；历史加载不重建工具痕迹
        if (!history) {
          final callId = d?['callId'] as String? ?? '';
          final name = d?['name'] as String? ?? L10n.t('工具', 'Tool');
          _activeTools[callId] = name;
          _scheduleActivityFlush();
        }
      case 'tool/result':
        if (!history) {
          final callId = d?['callId'] as String? ?? '';
          _activeTools.remove(callId);
          _scheduleActivityFlush();
        }
      case 'turn/start':
        if (history) {
          out.add(_MsgItem.divider(L10n.t('轮次 ${d?['turn']} 开始', 'Turn ${d?['turn']} started')));
        } else {
          out.insert(0, _MsgItem.divider(L10n.t('轮次 ${d?['turn']} 开始', 'Turn ${d?['turn']} started')));
        }
      case 'turn/end':
        if (!history || tail) {
          _draft = '';
          _streaming = false;
        }
        final reason = (d?['reason'] as Map<String, dynamic>?)?['kind'];
        final item = _MsgItem.divider(
            L10n.t('轮次 ${d?['turn']} 结束${reason != null ? '（$reason）' : ''}',
                'Turn ${d?['turn']} ended${reason != null ? ' ($reason)' : ''}'));
        if (history) {
          out.add(item);
        } else {
          out.insert(0, item);
        }
      default:
        break;
    }
  }

  Future<void> _send([String? preset, String mode = 'followup']) async {
    final text = (preset ?? _inputCtrl.text).trim();
    final id = widget.store.sessionId;
    if (text.isEmpty || id == null || _sending) return;
    AppLog.instance.log('Chat: 发送 → $id : ${text.length > 20 ? '${text.substring(0, 20)}…' : text}${mode == 'steer' ? '（插队）' : ''}');
    // v2.7.2 插队：agent 空闲时插队无意义 → 降级普通发送并提示
    if (mode == 'steer' && widget.store.agentStatus != 'running') {
      showToast(context, L10n.t('agent 空闲，已按普通消息发送', 'Agent idle — sent as a normal message'));
      mode = 'followup';
    }
    // 收起键盘，输入框回到原位
    FocusScope.of(context).unfocus();
    // agent 忙时提示（避免用户以为没反应而重复发送）；插队时不提示排队
    if (widget.store.agentStatus == 'running' && preset == null && mode != 'steer') {
      showToast(context, L10n.t('agent 正在处理上一轮，消息会排队等待', 'The agent is still processing the last turn — your message will be queued'));
    }
    setState(() {
      _sending = true;
      _items.insert(0, _MsgItem.user(text)); // 最新在前：插入头部（视觉底部）
    });
    _inputCtrl.clear();
    _scrollToBottom(force: true);
    try {
      final mid = await api.send(id, text, mode: mode);
      AppLog.instance.log('Chat: 发送成功 mid=$mid');
      if (!mounted) return;
      // v2.7.2：插队成功明确提示（否则和普通发送看起来一样，用户会困惑）
      if (mode == 'steer') {
        showToast(context, L10n.t('已插队：消息将插到 agent 下一步执行', 'Steered: will run at the agent\'s next step'));
      }
      // v2.7.2 review：mounted 检查之后才刷新队列（发送成功=新消息入队）
      _scheduleQueueRefresh();
      setState(() {
        // 按文本定位乐观消息补 messageId（可能已被 SSE 回显合并，此时已是同 id，幂等）
        final idx = _items.indexWhere(
            (m) => m.kind == _MsgKind.user && m.messageId == null && m.text == text);
        if (idx != -1) _items[idx] = _items[idx].copyWith(messageId: mid);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _items.insert(0, _MsgItem.divider('⚠ ${L10n.t('发送失败：', 'Send failed: ')}$e')));
        showToast(context, '${L10n.t('发送失败：', 'Send failed: ')}$e');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 停止（取消）会话当前运行：对齐 PC 端"停止"按钮。
  Future<void> _stop() async {
    final id = widget.store.sessionId;
    if (id == null || _sending) return;
    AppLog.instance.log('Chat: 请求停止会话 $id');
    try {
      await api.stopSession(id);
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
    final sid = widget.store.sessionId;
    if (sid == null) return;
    try {
      await api.jobKill(sid, jobId);
      if (mounted) showToast(context, L10n.t('已请求取消任务', 'Cancel requested'));
    } catch (e) {
      if (mounted) showToast(context, '${L10n.t('取消失败：', 'Cancel failed: ')}$e');
    }
  }

  void _openTools() {
    final sid = widget.store.sessionId;
    if (sid == null) return;
    showSessionToolsSheet(context, widget.store, sid);
  }

  /// 消息操作面板（长按 agent 回复）：复制 / 好的回答 / 有问题的回答 / 在新对话中分支。
  Future<void> _showMessageActions(_MsgItem item) async {
    final id = widget.store.sessionId;
    if (id == null) return;
    final action = await showModalBottomSheet<String>(
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
                  const Icon(Icons.auto_awesome, size: 15, color: Color(0xFF426EFE)),
                  const SizedBox(width: 6),
                  Text(L10n.t('消息操作', 'Message actions'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.content_copy, size: 20),
              title: Text(L10n.t('复制回答', 'Copy answer'), style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('copy'),
            ),
            ListTile(
              leading: const Icon(Icons.thumb_up_alt_outlined, size: 20),
              title: Text(L10n.t('好的回答', 'Good answer'), style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('positive'),
            ),
            ListTile(
              leading: const Icon(Icons.thumb_down_alt_outlined, size: 20),
              title: Text(L10n.t('有问题的回答', 'Bad answer'), style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('negative'),
            ),
            ListTile(
              leading: const Icon(Icons.call_split, size: 20),
              title: Text(L10n.t('在新对话中分支', 'Fork in a new chat'), style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('fork'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
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
        try {
          await api.putFeedback(id, mid, action);
          if (!mounted) return;
          showToast(context, action == 'positive'
              ? L10n.t('已标记：好的回答 ✓', 'Marked: good answer ✓')
              : L10n.t('已标记：有问题的回答 ✓', 'Marked: bad answer ✓'));
        } catch (e) {
          if (!mounted) return;
          showToast(context, '${L10n.t('反馈失败：', 'Feedback failed: ')}$e');
        }
      case 'fork':
        final seq = item.seq;
        if (seq == null) {
          showToast(context, L10n.t('该消息暂不支持分支', 'Forking is not available for this message'));
          return;
        }
        try {
          final childId = await api.forkSession(id, atSeq: seq);
          if (!mounted) return;
          showToast(context, L10n.t('已分支，正在打开新对话…', 'Forked — opening the new chat…'));
          final prevId = widget.store.sessionId;
          await widget.store.setSession(childId);
          widget.store.refreshSessions();
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatScreen(store: widget.store, onTitleChanged: widget.onTitleChanged),
            ),
          );
          // v2.7.2 review(M1)：分支页返回后恢复原会话（否则原聊天页事件被按 sessionId 过滤）
          if (mounted && prevId != null && prevId != childId) {
            await widget.store.setSession(prevId);
          }
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
            _StatusDot(status: store.connState == 'connected' ? store.agentStatus : 'offline'),
          ],
        ),
        actions: [
          // v2.7：会话工具（任务 / 子代理 / 目标）
          IconButton(
            icon: const Icon(Icons.assignment_outlined, size: 20),
            tooltip: L10n.t('任务 / 子代理 / 目标', 'Tasks / Subagents / Goals'),
            onPressed: () {
              final sid = widget.store.sessionId;
              if (sid != null) showSessionToolsSheet(context, widget.store, sid);
            },
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
          // 消息流：live 视图（reverse，最新固定在 offset 0）或历史分段浏览；
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
          // v2.7：进行中任务卡片（有任务才出现，完成自动消失）
          if (!_inHistory && widget.store.hasRunningJobs(widget.store.sessionId ?? ''))
            _JobCard(
              jobs: widget.store.jobsOf(widget.store.sessionId ?? ''),
              onOpen: _openTools,
              onKill: _killJob,
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
          // v2.7.2：队列停靠区（独立于输入框的轻量条，空队列不渲染）
          _buildQueueDock(),
          // composer
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: Theme.of(context).brightness == Brightness.dark ? DshTheme.shadowDark : DshTheme.shadow,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 28,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _Pill(
                            label: store.sessionConfig.model ?? L10n.t('选择模型', 'Select model'),
                            onTap: () => showModelSheet(context, store),
                          ),
                          const SizedBox(width: 6),
                          _Pill(
                            label: _permName(store.sessionConfig.permissionPreset),
                            onTap: () => showPermSheet(context, store),
                          ),
                          // v2.7.2(B 方案)：运行中且输入非空 → 「排队发送」胶囊（与模型/权限同款样式）
                          if (widget.store.agentStatus == 'running' && _inputCtrl.text.trim().isNotEmpty) ...[
                            const SizedBox(width: 6),
                            _Pill(
                              label: L10n.t('排队发送', 'Queue send'),
                              onTap: () => _send(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const SizedBox(height: 4),
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
                        const SizedBox(width: 8),
                        // 上下文窗口占用圆环（对齐 PC 端；数据齐全时才显示）
                        if (_contextRatio != null) ...[
                          _ContextRing(ratio: _contextRatio!),
                          const SizedBox(width: 8),
                        ],
                        // v2.7.2：发送按钮恢复原设计——运行中=停止（对齐 PC 端），空闲=发送；
                        // 长按=插队发送；运行中普通发送走上方「排队发送」胶囊（B 方案）
                        GestureDetector(
                          onTap: _sending
                              ? null
                              : (widget.store.agentStatus == 'running' ? _stop : _send),
                          onLongPress: _sending
                              ? null
                              : () => _send(null, 'steer'),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(color: brand, borderRadius: BorderRadius.circular(9)),
                            child: widget.store.agentStatus == 'running'
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
    String t(num? n) {
      final v = (n ?? 0).toInt();
      if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
      if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
      return '$v';
    }

    final input = (u['inputTokens'] as num?)?.toInt() ?? 0;
    final read = (u['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final write = (u['cacheWriteTokens'] as num?)?.toInt() ?? 0;
    final out = (u['outputTokens'] as num?)?.toInt() ?? 0;
    final billed = input + read + write;
    final hit = billed > 0 ? ((read / billed) * 100).round() : 0;
    return '${L10n.t('本会话：输入 ', 'This session: in ')}${t(input)}${L10n.t(' · 缓存 ', ' · cache ')}${t(read)}${L10n.t(' · 输出 ', ' · out ')}${t(out)}${L10n.t(' · 命中率 ', ' · hit rate ')}$hit%';
  }

  String _permName(String? id) => switch (id) {
        'read-only' => 'Read Only',
        'workspace-write' => 'Workspace Write',
        'danger-full-access' => 'Danger Full Access',
        _ => L10n.t('权限', 'Permission'),
      };

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

  Widget _buildItem(_MsgItem item) {
    switch (item.kind) {
      case _MsgKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: DshColors.line(context),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(item.text, style: const TextStyle(fontSize: 15, height: 1.5)),
          ),
        );
      case _MsgKind.assistant:
        // 长按弹出消息操作：复制 / 好的回答 / 有问题的回答 / 在新对话中分支
        return GestureDetector(
          onLongPress: () => _showMessageActions(item),
          child: _AssistantBubble(text: item.text, usage: item.usage, streaming: false),
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
enum _MsgKind { user, assistant, divider }

class _MsgItem {
  final _MsgKind kind;
  final String text;
  final Map<String, dynamic>? usage;
  final int? seq;
  final String? messageId;
  _MsgItem.user(this.text, {this.seq, this.messageId})
      : kind = _MsgKind.user,
        usage = null;
  _MsgItem.assistant(this.text, {this.usage, this.seq, this.messageId})
      : kind = _MsgKind.assistant;
  _MsgItem.divider(this.text)
      : kind = _MsgKind.divider,
        usage = null,
        seq = null,
        messageId = null;

  _MsgItem copyWith({int? seq, String? messageId}) => _MsgItem.user(text, seq: seq ?? this.seq, messageId: messageId ?? this.messageId);
}

// ── 气泡组件 ──
/// Agent 气泡：Markdown 解析结果按文本缓存（流式时每次重建不重新解析，只解析增量）。
class _AssistantBubble extends StatefulWidget {
  final String text;
  final Map<String, dynamic>? usage;
  final bool streaming;
  const _AssistantBubble({required this.text, this.usage, this.streaming = false});

  @override
  State<_AssistantBubble> createState() => _AssistantBubbleState();
}

class _AssistantBubbleState extends State<_AssistantBubble> {
  String? _parsedFor;
  List<Widget>? _blocks;
  int _parseLogs = 0; // 排障：每个气泡实例最多记 3 次解析日志

  @override
  Widget build(BuildContext context) {
    if (widget.text != _parsedFor) {
      _parsedFor = widget.text;
      _blocks = renderMarkdownBlocks(widget.text.isEmpty ? '…' : widget.text, context);
      if (_parseLogs < 3) {
        _parseLogs++;
        AppLog.instance.log('Chat: bubble 解析 len=${widget.text.length} blocks=${_blocks!.length}');
      }
    }
    final ink3 = DshColors.ink3(context);
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
            ..._blocks!,
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

  String _fmtMsgUsage(Map<String, dynamic> u) {
    String t(num? n) {
      final v = (n ?? 0).toInt();
      if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
      if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
      return '$v';
    }

    final input = (u['inputTokens'] as num?)?.toInt() ?? 0;
    final read = (u['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final write = (u['cacheWriteTokens'] as num?)?.toInt() ?? 0;
    final out = (u['outputTokens'] as num?)?.toInt() ?? 0;
    final total = input + read + write;
    final hit = total > 0 ? ((read / total) * 100).round() : 0;
    return '↑${t(input)} ↓${t(out)} · ${L10n.t('缓存 ', 'cache ')}$hit%';
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
class _JobCard extends StatelessWidget {
  final List<Map<String, dynamic>> jobs;
  final VoidCallback onOpen;
  final void Function(String jobId) onKill;
  const _JobCard({required this.jobs, required this.onOpen, required this.onKill});

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final surface = DshColors.surface(context);
    final running = jobs.where((j) => j['status'] == 'running' || j['status'] == 'stopping').toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.hourglass_top_outlined, size: 15, color: brand),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      running.length > 1
                          ? L10n.t('后台任务 ${running.length} 个进行中', '${running.length} background tasks running')
                          : L10n.t('后台任务进行中', 'Background task running'),
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ink2),
                    ),
                  ),
                  Text(L10n.t('详情 ▸', 'Details ▸'), style: TextStyle(fontSize: 11.5, color: ink3)),
                ],
              ),
            ),
          ),
          for (final j in running.take(2))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 7, color: brand),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      (j['label'] as String? ?? j['id'] as String? ?? L10n.t('任务', 'Task')).toString(),
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: j['status'] == 'stopping' ? null : () => onKill(j['id'] as String? ?? ''),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      j['status'] == 'stopping'
                          ? L10n.t('停止中', 'Stopping')
                          : L10n.t('取消', 'Cancel'),
                      style: TextStyle(fontSize: 11.5, color: j['status'] == 'stopping' ? ink3 : DshColors.danger(context)),
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
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ink2)),
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
