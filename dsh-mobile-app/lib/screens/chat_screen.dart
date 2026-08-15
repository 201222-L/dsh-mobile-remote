// 对话页：消息流（Markdown/流式/工具折叠/token 用量）+ 上翻加载 + 快捷动作 + composer
import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../md.dart';
import 'sheets.dart';

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
  final List<_MsgItem> _items = [];
  final Map<String, _ToolRow> _toolRows = {};
  String _draft = '';
  bool _streaming = false;
  int _lastSeq = 0;
  int _earliestSeq = 0;
  bool _loadingMore = false;
  bool _sending = false;
  String? _title;
  Map<String, dynamic> _usage = {};
  bool _usageLoaded = false;
  Timer? _draftTimer; // 流式草稿节流刷新（chunk 合并，避免每帧全量重建）

  @override
  void initState() {
    super.initState();
    for (final s in widget.store.sessions) {
      if (s.id == widget.store.sessionId) {
        _title = s.label;
        break;
      }
    }
    widget.store.onChatEvent = _handleEvent;
    _load();
    if (widget.initialSend != null && widget.initialSend!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(widget.initialSend!));
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    widget.store.onChatEvent = null;
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 滚动到底部。force=true 时无条件滚（初始加载/发送后），
  /// 否则仅当用户在底部附近（上翻阅读时不打扰）。
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      if (force || pos.maxScrollExtent - pos.pixels < 220) {
        _scrollCtrl.jumpTo(pos.maxScrollExtent);
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

  Future<void> _load() async {
    final id = widget.store.sessionId;
    if (id == null) return;
    try {
      final events = await api.history(id, limit: 100);
      if (!mounted) return;
      setState(() {
        _items.clear();
        _toolRows.clear();
        _draft = '';
        _streaming = false;
        for (final ev in events) {
          _appendEvent(ev, history: true);
        }
        if (events.isNotEmpty) {
          _lastSeq = events.last.seq ?? _lastSeq;
          _earliestSeq = events.first.seq ?? 0;
        }
      });
      _scrollToBottom(force: true); // 初始定位到最新消息
      _refreshUsage();
      widget.store.refreshSessionConfig();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('该会话暂不可用：$e')));
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _loadMore() async {
    final id = widget.store.sessionId;
    if (id == null || _loadingMore || _earliestSeq <= 0) return;
    _loadingMore = true;
    try {
      final events = await api.history(id, before: _earliestSeq, limit: 100);
      if (!mounted) return;
      setState(() {
        for (final ev in events) {
          if (ev.seq != null && ev.seq! <= _lastSeq && _items.any((m) => m.seq == ev.seq)) continue;
          if (ev.seq != null) _lastSeq = _lastSeq > ev.seq! ? _lastSeq : ev.seq!;
          _appendEvent(ev, history: true);
        }
        if (events.isNotEmpty) _earliestSeq = events.first.seq ?? 0;
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
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
    if (ev.type == '_catchup') {
      _catchup();
      return;
    }
    if (ev.type == 'agent/status') {
      setState(() {});
      return;
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
      }
      return;
    }
    if (ev.type == 'assistant/message' || ev.type == 'turn/end') {
      _draftTimer?.cancel();
      _draftTimer = null;
    }
    setState(() => _appendEvent(ev));
    _scrollToBottom();
  }

  Future<void> _catchup() async {
    final id = widget.store.sessionId;
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

  void _appendEvent(ChatEvent ev, {bool history = false}) {
    final d = ev.data;
    switch (ev.type) {
      case 'user/message':
        final text = d?['text'] as String? ?? '';
        // 过滤 dsh 注入的系统上下文快照（PC 端 GUI 也不显示）
        if (text.contains('Current runtime context') || text.contains('This snapshot supersedes')) return;
        final mid = d?['messageId'] as String?;
        // 去重（SSE 回显 vs 本地乐观添加）：
        // 1) 已有同 messageId 的消息 → 直接跳过（回显已完成渲染，同文本连发也不误并）
        if (mid != null && _items.any((m) => m.kind == _MsgKind.user && m.messageId == mid)) return;
        final last = _items.isNotEmpty ? _items.last : null;
        // 2) 最后一条是本地乐观添加（messageId 尚未赋值）且文本一致 → 合并为一条
        if (!history &&
            last != null &&
            last.kind == _MsgKind.user &&
            last.messageId == null &&
            last.text.trim() == text.trim()) {
          _items[_items.length - 1] = last.copyWith(seq: ev.seq, messageId: mid);
        } else {
          _items.add(_MsgItem.user(text, seq: ev.seq, messageId: mid));
        }
      case 'assistant/message':
        var body = d?['text'] as String? ?? '';
        // 过滤系统注入的上下文快照
        if (body.contains('Current runtime context') || body.contains('This snapshot supersedes')) {
          _draft = '';
          _streaming = false;
          return;
        }
        final reasoning = (d?['reasoningChars'] as num?)?.toInt() ?? 0;
        final prefix = reasoning > 0 ? '（思考 $reasoning 字）\n' : '';
        _items.add(_MsgItem.assistant(prefix + body,
            usage: d?['usage'] as Map<String, dynamic>?, seq: ev.seq));
        _draft = '';
        _streaming = false;
      case 'assistant/chunk':
        final text = d?['text'] as String? ?? '';
        final reasoning = d?['reasoning'] == true;
        if (text.isNotEmpty && !reasoning) {
          _draft += text;
          _streaming = true;
        }
      case 'tool/call':
        final callId = d?['callId'] as String? ?? '';
        _toolRows.putIfAbsent(callId, () => _ToolRow(name: d?['name'] as String? ?? ''));
      case 'tool/result':
        final callId = d?['callId'] as String? ?? '';
        final row = _toolRows.putIfAbsent(callId, () => _ToolRow(name: d?['name'] as String? ?? ''));
        row.done = true;
        row.isError = d?['isError'] == true;
        if (d?['text'] != null) row.body = d!['text'] as String;
        _items.add(_MsgItem.tool(row));
      case 'turn/start':
        _items.add(_MsgItem.divider('轮次 ${d?['turn']} 开始'));
      case 'turn/end':
        _draft = '';
        _streaming = false;
        final reason = (d?['reason'] as Map<String, dynamic>?)?['kind'];
        _items.add(_MsgItem.divider('轮次 ${d?['turn']} 结束${reason != null ? '（$reason）' : ''}'));
      default:
        break;
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _inputCtrl.text).trim();
    final id = widget.store.sessionId;
    if (text.isEmpty || id == null || _sending) return;
    // 收起键盘，输入框回到原位
    FocusScope.of(context).unfocus();
    // agent 忙时提示（避免用户以为没反应而重复发送）
    if (widget.store.agentStatus == 'running' && preset == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('agent 正在处理上一轮，消息会排队等待')));
    }
    setState(() {
      _sending = true;
      _items.add(_MsgItem.user(text));
    });
    _inputCtrl.clear();
    _scrollToBottom(force: true);
    try {
      final mid = await api.send(id, text);
      if (!mounted) return;
      setState(() {
        if (_items.isNotEmpty && _items.last.kind == _MsgKind.user) {
          _items[_items.length - 1] = _items.last.copyWith(messageId: mid);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _items.add(_MsgItem.divider('⚠ 发送失败：$e')));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
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
            Text(_title ?? '会话', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            _StatusDot(status: store.connState == 'connected' ? store.agentStatus : 'offline'),
          ],
        ),
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
          // 消息流
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.pixels < 80) _loadMore();
                return false;
              },
              child: ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                itemCount: _items.length + (_streaming || _draft.isNotEmpty ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return _AssistantBubble(text: _draft, streaming: true);
                  }
                  return _buildItem(_items[index]);
                },
              ),
            ),
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
                            label: store.sessionConfig.model ?? '选择模型',
                            onTap: () => showModelSheet(context, store),
                          ),
                          const SizedBox(width: 6),
                          _Pill(
                            label: _permName(store.sessionConfig.permissionPreset),
                            onTap: () => showPermSheet(context, store),
                          ),
                        ],
                      ),
                    ),
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
                              hintText: '回复 agent…',
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
                        GestureDetector(
                          onTap: _sending ? null : () => _send(),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(color: brand, borderRadius: BorderRadius.circular(9)),
                            child: _sending
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
    return '本会话：输入 ${t(input)} · 缓存 ${t(read)} · 输出 ${t(out)} · 命中率 $hit%';
  }

  String _permName(String? id) => switch (id) {
        'read-only' => 'Read Only',
        'workspace-write' => 'Workspace Write',
        'danger-full-access' => 'Danger Full Access',
        _ => '权限',
      };

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
        return _AssistantBubble(text: item.text, usage: item.usage, streaming: false);
      case _MsgKind.tool:
        return _ToolBubble(row: item.toolRow!, show: widget.store.showTools);
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
enum _MsgKind { user, assistant, tool, divider }

class _MsgItem {
  final _MsgKind kind;
  final String text;
  final Map<String, dynamic>? usage;
  final int? seq;
  final String? messageId;
  final _ToolRow? toolRow;
  _MsgItem.user(this.text, {this.seq, this.messageId})
      : kind = _MsgKind.user,
        usage = null,
        toolRow = null;
  _MsgItem.assistant(this.text, {this.usage, this.seq})
      : kind = _MsgKind.assistant,
        messageId = null,
        toolRow = null;
  _MsgItem.tool(this.toolRow)
      : kind = _MsgKind.tool,
        text = '',
        usage = null,
        seq = null,
        messageId = null;
  _MsgItem.divider(this.text)
      : kind = _MsgKind.divider,
        usage = null,
        seq = null,
        messageId = null,
        toolRow = null;

  _MsgItem copyWith({int? seq, String? messageId}) => _MsgItem.user(text, seq: seq ?? this.seq, messageId: messageId ?? this.messageId);
}

class _ToolRow {
  String name;
  String body = '';
  bool done = false;
  bool isError = false;
  _ToolRow({required this.name});
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

  @override
  Widget build(BuildContext context) {
    if (widget.text != _parsedFor) {
      _parsedFor = widget.text;
      _blocks = renderMarkdownBlocks(widget.text.isEmpty ? '…' : widget.text, context);
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
    return '↑${t(input)} ↓${t(out)} · 缓存 $hit%';
  }
}

class _ToolBubble extends StatelessWidget {
  final _ToolRow row;
  final bool show;
  const _ToolBubble({required this.row, required this.show});

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();
    final ink2 = DshColors.ink2(context);
    final ok = DshColors.ok(context);
    final danger = DshColors.danger(context);
    final line = DshColors.line(context);
    final surface = DshColors.surface(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(DshTheme.radiusSm),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        title: Row(
          children: [
            Expanded(
              child: Text(
                row.name,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (row.done)
              Text(
                row.isError ? '失败' : '完成',
                style: TextStyle(fontSize: 11.5, color: row.isError ? danger : ok),
              ),
          ],
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              row.body,
              style: TextStyle(fontSize: 12.5, color: ink2, height: 1.5),
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
