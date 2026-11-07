// issue #53（§6.22 / issue 正文 §3）：本轮改动单文件 diff 页（最小闭环）。
//
// 数据：`/m/api/changes/diff?sessionId&turn&index`，宿主 hunks 已由插件渲染成统一
// diff 文本（≤512 KiB，超出显式 truncated）。页面复用 GitFileViewer 的差异模式；
// 本轮文件切换器只做「上一个/下一个」，不引入完整 review tab（非目标）。

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../theme.dart';
import '../turn_tail.dart';
import '../widgets/git_file_viewer.dart';

class TurnChangesDiffScreen extends StatefulWidget {
  const TurnChangesDiffScreen({
    super.key,
    required this.api,
    required this.sessionId,
    required this.turn,
    required this.files,
    this.initialIndex = 0,
  });

  final Api api;
  final String sessionId;
  final int turn;
  final List<ChangedFile> files;
  final int initialIndex;

  @override
  State<TurnChangesDiffScreen> createState() => _TurnChangesDiffScreenState();
}

class _TurnChangesDiffScreenState extends State<TurnChangesDiffScreen> {
  late int _index;
  bool _loading = true;
  String? _error;
  ChangesDiff? _diff;

  /// issue #60 R10：请求代际。切文件后旧响应（成功/失败/loading 收尾）一律丢弃，
  /// 不允许把 A 的 diff 显示在 B 的标题下。
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.files.isEmpty ? 0 : widget.files.length - 1);
    _load();
  }

  Future<void> _load() async {
    if (widget.files.isEmpty) {
      setState(() {
        _loading = false;
        _error = L10n.t('本轮没有可对比的文件', 'No changed files in this turn');
      });
      return;
    }
    final generation = ++_loadGeneration;
    final fileIndex = widget.files[_index].index;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final diff = await widget.api.changesDiff(
        widget.sessionId,
        widget.turn,
        fileIndex,
      );
      // 只有仍是当前请求代际（且文件下标未变）时才允许回写。
      if (!mounted || generation != _loadGeneration) return;
      _diff = diff;
      _loading = false;
      setState(() {});
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      _error = L10n.t('无法读取对比：$e', 'Cannot load diff: $e');
      _loading = false;
      setState(() {});
    }
  }

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.files.length) return;
    setState(() {
      _index = next;
      _diff = null;
      _loading = true;
      _error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.files.isEmpty ? null : widget.files[_index];
    final display = file?.display ?? L10n.t('本轮改动', 'Turn changes');
    return Scaffold(
      appBar: AppBar(
        title: Text(display, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('turn-diff-prev'),
            icon: const Icon(Icons.chevron_left),
            tooltip: L10n.t('上一个文件', 'Previous file'),
            onPressed: _index > 0 ? () => _move(-1) : null,
          ),
          Center(
            child: Text(
              widget.files.isEmpty ? '0/0' : '${_index + 1}/${widget.files.length}',
              style: TextStyle(fontSize: 12, color: DshColors.ink2(context)),
            ),
          ),
          IconButton(
            key: const Key('turn-diff-next'),
            icon: const Icon(Icons.chevron_right),
            tooltip: L10n.t('下一个文件', 'Next file'),
            onPressed: _index < widget.files.length - 1 ? () => _move(1) : null,
          ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    final diff = _diff;
    final file = widget.files.isEmpty ? null : widget.files[_index];
    final notice = diff == null
        ? null
        : diff.isBinary
        ? L10n.t('二进制文件，无法以文本对比', 'Binary file: no text diff')
        : diff.isOversized
        ? L10n.t('文件过大，无法对比', 'File too large to diff')
        : null;
    if (_loading && diff == null) {
      return GitFileViewer(
        key: const Key('turn-diff-viewer'),
        mode: GitFileViewerMode.diff,
        path: file?.display,
        loading: true,
        keys: const GitFileViewerKeys(prefix: 'turn-diff'),
      );
    }
    if (_error != null && diff == null) {
      return GitFileViewer(
        key: const Key('turn-diff-viewer'),
        mode: GitFileViewerMode.diff,
        path: file?.display,
        error: _error,
        onRetry: _load,
        keys: const GitFileViewerKeys(prefix: 'turn-diff'),
      );
    }
    return Column(
      children: [
        if (diff?.coarse == true)
          Container(
            width: double.infinity,
            color: DshColors.brandSoft(context),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              L10n.t(
                '逐行对比超时，已退化为整文件替换',
                'Line diff timed out: showing whole-file replacement',
              ),
              style: TextStyle(fontSize: 11.5, color: DshColors.ink2(context)),
            ),
          ),
        Expanded(
          child: GitFileViewer(
            key: const Key('turn-diff-viewer'),
            mode: GitFileViewerMode.diff,
            path: file?.display,
            diff: diff?.diff ?? '',
            binary: diff?.isBinary ?? false,
            notice: notice,
            truncated: diff?.truncated ?? false,
            truncatedMessage: L10n.t(
              '对比较大，仅显示前 512 KiB',
              'Diff is large: showing first 512 KiB',
            ),
            keys: const GitFileViewerKeys(prefix: 'turn-diff'),
          ),
        ),
      ],
    );
  }
}
