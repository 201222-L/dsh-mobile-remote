// 统一的 Git 文件/差异查看器（issue #42）。
//
// 背景：文件内容浏览（/api/files）与 git diff 预览（/api/git/preview）原本是
// 两套独立组件、两套交互；本组件把「行号源码 / Markdown 预览切换 / diff 折叠 /
// 横向滚动 / 复制」收敛到一处，两个入口只负责把各自的数据适配成
// [GitFileViewerMode.content] 或 [GitFileViewerMode.diff]。
//
// 行号在两种模式下都提供：content 模式是单侧行号；diff 模式按 hunk header 的
// 起始行解析出旧/新两侧行号（删除行只有旧侧、新增行只有新侧），与 US6
// 「文件内容与 diff 共享行号交互」一致。
//
// 上限沿用既有约定：内容 256 KiB（[kGitFileViewerContentLimit]，由取数侧按
// 前缀读取截断）、差异 512 KiB（[kGitFileViewerDiffLimit]，由宿主返回
// truncated 标记）；组件本身不重新拉取数据。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../md.dart';
import '../session_files_logic.dart';
import '../theme.dart';
import '../toast.dart';

/// 文件内容模式的安全上限（字节）：与取数侧的 `kPreviewByteLimit` 同源，
/// 由调用方按该上限读取前缀并在 [GitFileViewer.truncated] 标记。
const int kGitFileViewerContentLimit = kPreviewByteLimit;

/// diff 模式的安全上限（字节）：宿主侧按该上限截断并返回 `truncated: true`，
/// App 不重新拼接或二次截断已加载的 diff。
const int kGitFileViewerDiffLimit = 512 * 1024;

enum GitFileViewerMode { content, diff }

/// 组件内部可测试的稳定 Key；不同入口用不同 [prefix] 保持既有测试键。
class GitFileViewerKeys {
  const GitFileViewerKeys({this.prefix = 'git-file-viewer', this.modePrefix});

  final String prefix;

  /// 「预览/源码」按钮的键前缀；默认同 [prefix]，适配既有页面测试键。
  final String? modePrefix;

  Key get surface => Key('$prefix-surface');
  Key get sourceList => Key('$prefix-source');
  Key get markdownList => Key('$prefix-md');
  Key get modeToggle => Key('$prefix-mode');
  Key modeButton({required bool rendered}) =>
      Key('${modePrefix ?? prefix}-mode-${rendered ? 'rendered' : 'source'}');
  Key get truncated => Key('$prefix-truncated');
  Key get unavailable => Key('$prefix-unavailable');
  Key get error => Key('$prefix-error');
  Key get retry => Key('$prefix-retry');
  Key get copy => Key('$prefix-copy');
  Key get empty => Key('$prefix-empty');

  /// diff 模式的行（含折叠后仍保持原始行号下标）与旧/新行号列。
  Key diffLine(int index) => Key('$prefix-diff-line-$index');
  Key diffLineOldNumber(int index) => Key('$prefix-old-$index');
  Key diffLineNewNumber(int index) => Key('$prefix-new-$index');

  /// 长段未改动行的折叠/展开按钮。
  Key contextFold(int id) => Key('$prefix-context-fold-$id');
}

/// 只读的 Git 文件内容 / 差异查看器。
///
/// 状态优先级：加载中（无数据）→ 错误（无数据）→ 不可预览（binary/notice）→
/// 正常内容。顶层操作（如「提交历史」）通过 [topActions] 注入；返回按钮等由
/// 调用方通过 [leading] 注入，组件不持有导航职责。
class GitFileViewer extends StatefulWidget {
  const GitFileViewer({
    super.key,
    required this.mode,
    this.title,
    this.path,
    this.oldPath,
    this.content = '',
    this.diff = '',
    this.encodingLabel,
    this.truncated = false,
    this.truncatedMessage,
    this.binary = false,
    this.notice,
    this.emptyMessage,
    this.loading = false,
    this.error,
    this.onRetry,
    this.leading,
    this.topActions = const <Widget>[],
    this.rawAddedContent = false,
    this.keys = const GitFileViewerKeys(),
  });

  final GitFileViewerMode mode;

  /// 标题（无 [path] 时展示）；一般直接用 [path]。
  final String? title;

  /// 当前文件路径（仓库相对或工作区绝对，由调用方决定）。
  final String? path;

  /// 重命名前的旧路径（diff/内容头显示 `old → new`）。
  final String? oldPath;

  /// [GitFileViewerMode.content] 的已加载文本。
  final String content;

  /// [GitFileViewerMode.diff] 的已加载 unified diff 文本。
  final String diff;

  /// 编码提示（如 `UTF-8` / `GB18030`）；为空则不展示。
  final String? encodingLabel;

  /// 内容/差异是否被安全上限截断。
  final bool truncated;

  /// 截断提示文案；为空时按模式给默认提示。
  final String? truncatedMessage;

  /// 二进制文件（无可展示文本）。
  final bool binary;

  /// 自定义不可预览/空态说明（优先于 [binary] 的默认文案）。
  final String? notice;

  /// 正常内容为空时的提示；为空则内容模式保留一个空行（沿用旧预览行为）。
  final String? emptyMessage;

  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  /// 头栏左侧控件（如返回按钮）。
  final Widget? leading;

  /// 头栏右侧操作（如「提交历史」按钮）。
  final List<Widget> topActions;

  /// diff 是否为「未跟踪文件的原始内容」：每一行按新增行展示，且保留空行与
  /// 看起来像 diff 元数据的普通源码行（与旧工作区预览一致）。
  final bool rawAddedContent;

  final GitFileViewerKeys keys;

  @override
  State<GitFileViewer> createState() => _GitFileViewerState();
}

class _GitFileViewerState extends State<GitFileViewer> {
  bool _rendered = true;
  String _cachedContent = '';
  String? _cachedPathKey;
  List<String> _markdownChunks = const [];
  List<String> _sourceLines = const [];
  final Set<int> _expandedContextRuns = <int>{};
  String _diffCacheKey = '';

  bool get _isMarkdown => isMarkdownPath(widget.path ?? widget.title ?? '');

  bool get _hasPayload =>
      widget.mode == GitFileViewerMode.diff
          ? widget.diff.isNotEmpty
          : widget.content.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _syncContentCaches();
    _diffCacheKey = _diffKey();
  }

  @override
  void didUpdateWidget(GitFileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.path != widget.path ||
        oldWidget.mode != widget.mode) {
      _syncContentCaches();
      _rendered = true;
    }
    final key = _diffKey();
    if (key != _diffCacheKey) {
      _diffCacheKey = key;
      _expandedContextRuns.clear();
    }
  }

  String _diffKey() =>
      '${widget.mode}\u0000${widget.path}\u0000${widget.diff.length}\u0000'
      '${widget.diff.hashCode}';

  /// 内容分片/源码行只在数据变化时算一次：256 KiB 文本每帧重切会卡死 UI。
  void _syncContentCaches() {
    final pathKey = widget.path ?? widget.title;
    if (_cachedContent == widget.content && _cachedPathKey == pathKey) return;
    _cachedContent = widget.content;
    _cachedPathKey = pathKey;
    _sourceLines = previewLines(widget.content);
    _markdownChunks = _isMarkdown
        ? chunkMarkdownText(widget.content)
        : const [];
  }

  void _copy(BuildContext context) {
    final text = widget.mode == GitFileViewerMode.diff
        ? widget.diff
        : widget.content;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    showToast(context, L10n.t('已复制内容', 'Content copied'));
  }

  @override
  Widget build(BuildContext context) {
    final hasPayload = _hasPayload;
    // 状态 body 也挂在同一 header 下：leading（返回）与 topActions（提交历史）
    // 在任何状态都保持可见，不因加载/错误/二进制而丢失入口。
    final Widget body;
    if (widget.loading && !hasPayload) {
      body = const Center(child: CircularProgressIndicator());
    } else if (widget.error != null && !hasPayload) {
      body = _errorState(context);
    } else if (widget.binary || widget.notice != null) {
      body = _unavailableState(context);
    } else {
      body = _body(context);
    }
    return Column(
      key: widget.keys.surface,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_showHeader) _header(context),
        if (_showHeader) const Divider(height: 1),
        if (widget.truncated && hasPayload) _truncatedBanner(context),
        Expanded(child: body),
      ],
    );
  }

  bool get _showHeader =>
      widget.leading != null ||
      widget.topActions.isNotEmpty ||
      (widget.path ?? widget.title ?? '').isNotEmpty ||
      (widget.encodingLabel ?? '').isNotEmpty ||
      _isMarkdown;

  String get _displayPath {
    final path = widget.path ?? widget.title ?? '';
    final oldPath = widget.oldPath;
    if (oldPath == null || oldPath.isEmpty || oldPath == path) return path;
    return '$oldPath → $path';
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: [
          if (widget.leading != null) widget.leading!,
          Expanded(
            child: Text(
              _displayPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: DshColors.ink2(context)),
            ),
          ),
          if ((widget.encodingLabel ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                widget.encodingLabel!,
                style: TextStyle(
                  fontSize: 11,
                  color: DshColors.ink3(context),
                ),
              ),
            ),
          if (_isMarkdown) _modeToggle(),
          ...widget.topActions,
          IconButton(
            key: widget.keys.copy,
            tooltip: L10n.t('复制内容', 'Copy content'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 18),
            onPressed: _hasPayload ? () => _copy(context) : null,
          ),
        ],
      ),
    );
  }

  /// 「预览 / 源码」切换：仅对 Markdown 内容出现（与旧会话文件页一致）。
  Widget _modeToggle() {
    Widget item({required bool rendered, required String zh, required String en}) {
      final active = _rendered == rendered;
      return TextButton(
        key: widget.keys.modeButton(rendered: rendered),
        onPressed: () {
          if (_rendered == rendered) return;
          setState(() => _rendered = rendered);
        },
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          L10n.t(zh, en),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? DshColors.ink(context) : DshColors.ink3(context),
            decoration: active ? TextDecoration.underline : null,
          ),
        ),
      );
    }

    return Row(
      key: widget.keys.modeToggle,
      mainAxisSize: MainAxisSize.min,
      children: [
        item(rendered: true, zh: '预览', en: 'Preview'),
        item(rendered: false, zh: '源码', en: 'Source'),
      ],
    );
  }

  Widget _truncatedBanner(BuildContext context) {
    final message =
        widget.truncatedMessage ??
        (widget.mode == GitFileViewerMode.diff
            ? L10n.t(
                '差异已截断，仅显示安全上限内的内容',
                'Diff truncated at the safety limit.',
              )
            : L10n.t(
                '内容已截断，仅显示安全上限内的部分',
                'Content truncated at the safety limit.',
              ));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: DshColors.brandSoft(context),
      child: Text(
        message,
        key: widget.keys.truncated,
        style: TextStyle(fontSize: 12, color: DshColors.ink2(context)),
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.error!,
              key: widget.keys.error,
              textAlign: TextAlign.center,
            ),
            if (widget.onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: widget.keys.retry,
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(L10n.t('重试', 'Retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _unavailableState(BuildContext context) {
    final message =
        widget.notice ??
        (widget.binary
            ? L10n.t(
                '二进制文件不提供行级预览',
                'Binary files have no line preview',
              )
            : L10n.t('没有可显示的内容', 'Nothing to display'));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          key: widget.keys.unavailable,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (widget.mode == GitFileViewerMode.diff) return _diffBody(context);
    return _contentBody(context);
  }

  Widget _contentBody(BuildContext context) {
    if (widget.content.isEmpty && widget.emptyMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyMessage!,
            key: widget.keys.empty,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_isMarkdown && _rendered) {
      return ListView.builder(
        key: widget.keys.markdownList,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
        itemCount: _markdownChunks.length,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: renderMarkdownBlocks(_markdownChunks[i], ctx),
          ),
        ),
      );
    }
    return ListView.builder(
      key: widget.keys.sourceList,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _sourceLines.length,
      itemBuilder: (ctx, i) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: DshColors.ink3(ctx),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _sourceLines[i],
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _diffBody(BuildContext context) {
    final lines = _parseDiffLines();
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyMessage ??
                L10n.t(
                  '没有可显示的行级差异',
                  'No line changes to display',
                ),
            key: widget.keys.empty,
          ),
        ),
      );
    }
    return ListView(
      key: widget.keys.sourceList,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: _diffWidgets(context, lines),
    );
  }

  /// 解析 unified diff：跳过文件头/索引行，保留 hunk 标记与增删/上下文行。
  ///
  /// 同时按 hunk header（`@@ -a,b +c,d @@`）为每行算出旧/新行号：上下文行两边
  /// 都递增，删除行只进旧侧，新增行只进新侧；hunk header 行本身不显示行号。
  /// 未跟踪文件返回原始内容而不是 patch：每行按新增行展示（新侧行号），保留
  /// 空行与看起来像 diff 元数据的普通源码行，只忽略末尾换行产生的空哨兵。
  List<_DiffLineData> _parseDiffLines() {
    if (widget.diff.isEmpty) return const [];
    final rawLines = widget.diff.split('\n');
    final lines = <_DiffLineData>[];
    var inHunk = false;
    var oldLine = 0;
    var newLine = 0;
    var addedCount = 0;
    for (var rawIndex = 0; rawIndex < rawLines.length; rawIndex++) {
      final line = rawLines[rawIndex];
      if (widget.rawAddedContent) {
        if (rawIndex == rawLines.length - 1 &&
            line.isEmpty &&
            widget.diff.endsWith('\n')) {
          continue;
        }
        addedCount++;
        lines.add(
          _DiffLineData(marker: '+', text: line, newNumber: addedCount),
        );
        continue;
      }
      if (line.isEmpty ||
          line.startsWith('diff --git ') ||
          line.startsWith('index ') ||
          line.startsWith('Binary files ')) {
        continue;
      }
      if (line.startsWith('@@')) {
        inHunk = true;
        final header = _hunkHeader.firstMatch(line);
        if (header != null) {
          oldLine = int.parse(header.group(1)!);
          newLine = int.parse(header.group(3)!);
        }
        lines.add(_DiffLineData(marker: '@', text: line));
        continue;
      }
      if (line.startsWith('\\')) continue;
      if (!inHunk && (line.startsWith('--- ') || line.startsWith('+++ '))) {
        continue;
      }
      if (line.startsWith('+')) {
        lines.add(
          _DiffLineData(
            marker: '+',
            text: line.substring(1),
            newNumber: newLine++,
          ),
        );
      } else if (line.startsWith('-')) {
        lines.add(
          _DiffLineData(
            marker: '-',
            text: line.substring(1),
            oldNumber: oldLine++,
          ),
        );
      } else if (line.startsWith(' ')) {
        lines.add(
          _DiffLineData(
            marker: ' ',
            text: line.substring(1),
            oldNumber: oldLine++,
            newNumber: newLine++,
          ),
        );
      }
    }
    return lines;
  }

  List<Widget> _diffWidgets(BuildContext context, List<_DiffLineData> lines) {
    final result = <Widget>[];
    var index = 0;
    var runId = 0;
    while (index < lines.length) {
      if (lines[index].marker != ' ') {
        result.add(_diffLine(context, lines[index], lineIndex: index));
        index++;
        continue;
      }
      final start = index;
      while (index < lines.length && lines[index].marker == ' ') {
        index++;
      }
      final length = index - start;
      if (length <= 6) {
        for (var i = start; i < index; i++) {
          result.add(_diffLine(context, lines[i], lineIndex: i));
        }
        continue;
      }
      final id = runId++;
      final expanded = _expandedContextRuns.contains(id);
      final visible = expanded
          ? List.generate(length, (offset) => start + offset)
          : [
              ...List.generate(3, (offset) => start + offset),
              ...List.generate(3, (offset) => index - 3 + offset),
            ];
      for (final lineIndex in visible.where((lineIndex) => lineIndex < index)) {
        result.add(_diffLine(context, lines[lineIndex], lineIndex: lineIndex));
      }
      result.add(
        TextButton.icon(
          key: widget.keys.contextFold(id),
          onPressed: () => setState(() {
            if (expanded) {
              _expandedContextRuns.remove(id);
            } else {
              _expandedContextRuns.add(id);
            }
          }),
          icon: Icon(
            expanded ? Icons.unfold_less : Icons.unfold_more,
            size: 18,
          ),
          label: Text(
            expanded
                ? L10n.t('折叠未改动行', 'Fold unchanged lines')
                : L10n.t(
                    '展开 ${math.max(0, length - 6)} 行未改动',
                    'Expand ${math.max(0, length - 6)} unchanged lines',
                  ),
          ),
        ),
      );
    }
    return result;
  }

  Widget _diffLine(
    BuildContext context,
    _DiffLineData line, {
    int? lineIndex,
  }) {
    final color = switch (line.marker) {
      '+' => DshColors.ok(context),
      '-' => DshColors.danger(context),
      '@' => DshColors.ink3(context),
      _ => DshColors.ink(context),
    };
    final background = switch (line.marker) {
      '+' => DshColors.ok(context).withValues(alpha: .10),
      '-' => DshColors.danger(context).withValues(alpha: .10),
      _ => Colors.transparent,
    };
    final numberStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11,
      color: DshColors.ink3(context),
    );
    return Container(
      key: lineIndex == null ? null : widget.keys.diffLine(lineIndex),
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(
              line.oldNumber?.toString() ?? '',
              key: lineIndex == null
                  ? null
                  : widget.keys.diffLineOldNumber(lineIndex),
              textAlign: TextAlign.right,
              style: numberStyle,
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 34,
            child: Text(
              line.newNumber?.toString() ?? '',
              key: lineIndex == null
                  ? null
                  : widget.keys.diffLineNewNumber(lineIndex),
              textAlign: TextAlign.right,
              style: numberStyle,
            ),
          ),
          SizedBox(
            width: 20,
            child: Text(
              line.marker == ' ' ? ' ' : line.marker,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                line.text,
                softWrap: false,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行 diff（已解析出行号）：[oldNumber]/[newNumber] 为 null 表示该侧不存在。
class _DiffLineData {
  const _DiffLineData({
    required this.marker,
    required this.text,
    this.oldNumber,
    this.newNumber,
  });

  final String marker;
  final String text;
  final int? oldNumber;
  final int? newNumber;
}

/// unified diff hunk header：`@@ -oldStart,oldCount +newStart,newCount @@`。
final RegExp _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
