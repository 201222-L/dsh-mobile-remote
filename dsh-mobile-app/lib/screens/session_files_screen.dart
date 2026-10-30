// 会话文件浏览页（issue #15）：只读浏览当前会话工作目录的目录与文件内容。
//
// 设计约束（见 ADR 0015）：
// - 纯只读；不复用新建文件夹等写操作。
// - 路径夹在会话工作目录内，不提供向上越出。
// - 隐藏 `.git/` 由服务端过滤点开头条目实现（服务端只回非点开头项）。
// - 浏览根就是会话工作目录：不提供工作区选择，也不写回全局工作区筛选状态。
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../md.dart';
import '../session_files_controller.dart';
import '../session_files_logic.dart';
import '../store.dart';
import '../theme.dart';

/// 打开「会话文件浏览」全屏只读页。
///
/// [sessionId] 决定浏览根（该会话的工作目录）；[apiClient] 仅供测试注入。
void openSessionFiles(
  BuildContext context,
  AppStore store,
  String sessionId, {
  SessionFilesController? controller,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SessionFilesScreen(
        store: store,
        sessionId: sessionId,
        controller: controller,
      ),
    ),
  );
}

class SessionFilesScreen extends StatefulWidget {
  const SessionFilesScreen({
    super.key,
    required this.store,
    required this.sessionId,
    this.controller,
  });

  final AppStore store;
  final String sessionId;

  /// 测试可注入；为 null 时页面自己建一个。
  final SessionFilesController? controller;

  @override
  State<SessionFilesScreen> createState() => _SessionFilesScreenState();
}

class _SessionFilesScreenState extends State<SessionFilesScreen> {
  late final SessionFilesController _c;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _c =
        widget.controller ??
        SessionFilesController(
          store: widget.store,
          sessionId: widget.sessionId,
        );
    _ownsController = widget.controller == null;
    _c.addListener(_onChange);
    _c.open();
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    if (_ownsController) _c.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// 页面内部还有"上一层"可回吗（预览中，或已下钻到子目录）。
  ///
  /// 与同栏的 Git 页面（git_browser_sheet.dart 的 PopScope/_back）保持一致的
  /// 「返回是往回走一层，而不是直接离开」范式；此前没有这层拦截，右滑会在
  /// 任意深度直接退出整个页面，用户丢掉已下钻的层级。
  bool get _hasInnerLevel =>
      _c.stage == BrowseStage.preview ||
      (_c.root.isNotEmpty && !_c.atRoot);

  /// 系统返回（手势/返回键）触发的"往回走一层"。
  ///
  /// 只在 [_hasInnerLevel] 为真时被调用：退出预览 → 逐级返回上级目录。
  /// 已经在浏览根时 canPop 为真，交给系统正常退出，不会走到这里。
  void _handleBack() {
    if (_c.stage == BrowseStage.preview) {
      _c.closePreview();
    } else if (_c.root.isNotEmpty && !_c.atRoot) {
      _c.goUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasInnerLevel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(L10n.t('文件', 'Files')),
          actions: [
            IconButton(
              key: const Key('sf-refresh'),
              icon: const Icon(Icons.refresh),
              tooltip: L10n.t('刷新', 'Refresh'),
              onPressed: () => _c.refresh(),
            ),
          ],
        ),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    switch (_c.stage) {
      case BrowseStage.error:
        // 已加载过内容时保留它（只提示原因），避免刷新失败让页面变空。
        if (_c.dirs.isNotEmpty || _c.files.isNotEmpty) {
          return Column(
            children: [_errorBanner(), Expanded(child: _listing())],
          );
        }
        return _errorPane();
      case BrowseStage.loading:
        return const Center(child: CircularProgressIndicator());
      case BrowseStage.listing:
        return _listing();
      case BrowseStage.preview:
        return _preview();
    }
  }

  // ── 目录列表 ──
  Widget _listing() {
    return Column(
      key: const Key('sf-listing'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _rootBar(),
        _breadcrumbBar(),
        if (_c.hiddenCount > 0) _truncationNotice(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final d in _c.dirs)
                ListTile(
                  key: Key('sf-dir-$d'),
                  leading: const Icon(Icons.folder, size: 20),
                  title: Text(d),
                  onTap: () => _c.openDir(d),
                ),
              for (final f in _c.files)
                ListTile(
                  key: Key('sf-file-$f'),
                  leading: const Icon(Icons.description_outlined, size: 20),
                  title: Text(f),
                  onTap: () => _c.openFile(f),
                ),
              if (_c.dirs.isEmpty && _c.files.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    L10n.t('这个目录是空的', 'This directory is empty'),
                    style: TextStyle(color: DshColors.ink3(context)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 浏览根提示：会话工作目录。只读展示——浏览范围由会话决定，不在这里切换。
  Widget _rootBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        key: const Key('sf-root'),
        children: [
          Icon(Icons.work_outline, size: 16, color: DshColors.ink3(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _c.root,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: DshColors.ink2(context)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumbBar() {
    final crumbs = _c.breadcrumbs;
    return SizedBox(
      height: 40,
      child: ListView(
        key: const Key('sf-breadcrumb'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var i = 0; i < crumbs.length; i++) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: DshColors.ink3(context),
              ),
            TextButton(
              key: Key('sf-crumb-${crumbs[i].path}'),
              onPressed: i == crumbs.length - 1
                  ? null
                  : () => _c.jumpTo(crumbs[i].path),
              child: Text(crumbs[i].label),
            ),
          ],
        ],
      ),
    );
  }

  Widget _truncationNotice() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        L10n.t(
          '条目较多，仅显示前 ${_c.dirs.length + _c.files.length} 项，共 ${_c.totalEntries} 项',
          'Many entries: showing first ${_c.dirs.length + _c.files.length} of ${_c.totalEntries}',
        ),
        key: const Key('sf-truncated-dir'),
        style: TextStyle(fontSize: 12, color: DshColors.warn(context)),
      ),
    );
  }

  // ── 文件预览 ──
  Widget _preview() {
    final v = _c.preview;
    return Column(
      key: const Key('sf-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              IconButton(
                key: const Key('sf-preview-back'),
                icon: const Icon(Icons.arrow_back),
                tooltip: L10n.t('返回目录', 'Back to directory'),
                onPressed: () => _c.closePreview(),
              ),
              Expanded(
                child: Text(
                  _c.previewPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: DshColors.ink2(context)),
                ),
              ),
              if (_c.previewIsMarkdown) _viewModeToggle(),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _previewBody(v)),
      ],
    );
  }

  Widget _previewBody(PreviewVerdict? v) {
    if (v is PreviewUnavailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            v.reason,
            key: const Key('sf-preview-unavailable'),
            textAlign: TextAlign.center,
            style: TextStyle(color: DshColors.ink2(context)),
          ),
        ),
      );
    }
    if (v is! PreviewText) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (v.truncated) _truncatedNotice(v),
        Expanded(
          child: _c.previewMode == PreviewMode.rendered && _c.previewIsMarkdown
              ? _markdownBody()
              : _sourceBody(),
        ),
      ],
    );
  }

  Widget _truncatedNotice(PreviewText v) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: DshColors.brandSoft(context),
      child: Text(
        L10n.t(
          '文件较大，仅显示前 ${v.bytesShown ~/ 1024} KiB',
          'File is large: showing first ${v.bytesShown ~/ 1024} KiB',
        ),
        key: const Key('sf-preview-truncated'),
        style: TextStyle(fontSize: 12, color: DshColors.ink2(context)),
      ),
    );
  }

  /// Markdown 渲染：按分片懒加载，只有可见分片才会真正建 Widget。
  ///
  /// 不能把 256KB 的全文一次交给 `renderMarkdownBlocks`——它会一口气返回上万个
  /// Widget（`md.dart:64`），手机直接卡死。分片在控制器里按块边界切好。
  Widget _markdownBody() {
    final chunks = _c.previewChunks;
    return ListView.builder(
      key: const Key('sf-preview-md'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
      itemCount: chunks.length,
      itemBuilder: (ctx, i) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: renderMarkdownBlocks(chunks[i], ctx),
        ),
      ),
    );
  }

  /// 源码视图：行号 + 自动换行 + 按行懒加载（6 万行也只建可见的那几行）。
  Widget _sourceBody() {
    final lines = _c.previewSourceLines;
    return ListView.builder(
      key: const Key('sf-preview-source'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: lines.length,
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
              lines[i],
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 「预览 / 源码」切换：仅对 Markdown 文件出现。
  Widget _viewModeToggle() {
    Widget item(PreviewMode mode, String zh, String en, Key key) {
      final active = _c.previewMode == mode;
      return TextButton(
        key: key,
        onPressed: () => _c.setPreviewMode(mode),
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
            color: active
                ? DshColors.ink(context)
                : DshColors.ink3(context),
            decoration: active ? TextDecoration.underline : null,
          ),
        ),
      );
    }

    return Row(
      key: const Key('sf-preview-mode'),
      mainAxisSize: MainAxisSize.min,
      children: [
        item(PreviewMode.rendered, '预览', 'Preview', const Key('sf-mode-rendered')),
        item(PreviewMode.source, '源码', 'Source', const Key('sf-mode-source')),
      ],
    );
  }

  // ── 错误 ──
  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      color: DshColors.brandSoft(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _c.errorReason,
              key: const Key('sf-error-banner'),
              style: TextStyle(fontSize: 12.5, color: DshColors.ink2(context)),
            ),
          ),
          TextButton(
            key: const Key('sf-retry'),
            onPressed: () => _c.retry(),
            child: Text(L10n.t('重试', 'Retry')),
          ),
        ],
      ),
    );
  }

  Widget _errorPane() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 40,
              color: DshColors.ink3(context),
            ),
            const SizedBox(height: 12),
            Text(
              _c.errorReason,
              key: const Key('sf-error'),
              textAlign: TextAlign.center,
              style: TextStyle(color: DshColors.ink2(context)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('sf-retry'),
              onPressed: () => _c.retry(),
              child: Text(L10n.t('重试', 'Retry')),
            ),
          ],
        ),
      ),
    );
  }
}
