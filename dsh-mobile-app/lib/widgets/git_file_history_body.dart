// 文件提交历史的共享 UI（issue #42）。
//
// Git 管理里的「文件历史」tab 与未启用该 tab 时深链打开的独立历史视图都渲染
// 这个 body；数据与交互状态全部在 [GitFileHistoryController] 里。
//
// 交互：顶部文件 chip（选择/更换文件、刷新）→ 分页历史列表（状态徽标、短 OID、
// 作者、相对时间；点按进提交详情，长按复制 OID）。
//
// 选择文件有两个入口：宿主注入 [GitFileHistoryBody.onBrowseFiles] 时，主按钮
// 打开会话文件浏览器（选中文件后回到本历史视图），内联搜索选择器降级为
// 「搜索文件」次要入口；未注入时保持旧行为（主按钮即内联选择器）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../fmt.dart';
import '../git_file_history_controller.dart';
import '../git_models.dart';
import '../l10n.dart';
import '../theme.dart';
import '../toast.dart';

/// 历史 body 的可测试 Key（不同 surface 可换 prefix）。
class GitFileHistoryKeys {
  const GitFileHistoryKeys({this.prefix = 'git-history'});

  final String prefix;

  Key get root => Key(prefix);
  Key get fileChip => Key('$prefix-file');
  Key get changeFile => Key('$prefix-change');
  Key get refresh => Key('$prefix-refresh');
  Key get picker => Key('$prefix-picker');
  Key get search => Key('$prefix-search');
  Key get cancelPicker => Key('$prefix-cancel');
  Key get pickerList => Key('$prefix-files');
  Key fileRow(String path) => Key('$prefix-file-$path');
  Key recentRow(String path) => Key('$prefix-recent-$path');
  Key row(String oid) => Key('$prefix-row-$oid');
  Key statusBadge(String oid) => Key('$prefix-status-$oid');
  Key get empty => Key('$prefix-empty');
  Key get chooseFile => Key('$prefix-choose');
  Key get error => Key('$prefix-error');
  Key get retry => Key('$prefix-retry');
  Key get list => Key('$prefix-list');
  Key get truncated => Key('$prefix-truncated');
  Key get loadMore => Key('$prefix-load-more');

  /// 次要入口：打开内联搜索选择器（主入口改为会话文件浏览器时）。
  Key get searchFiles => Key('$prefix-search-files');
  Key get searchFilesEmpty => Key('$prefix-search-empty');
}

/// 文件历史共享 body。
class GitFileHistoryBody extends StatefulWidget {
  const GitFileHistoryBody({
    super.key,
    required this.controller,
    this.onOpenCommitDiff,
    this.onBrowseFiles,
    this.autoOpenPickerWhenEmpty = true,
    this.keys = const GitFileHistoryKeys(),
  });

  final GitFileHistoryController controller;

  /// 点历史行：直接打开该文件在该提交上的 diff（由宿主实现跳转）。
  final ValueChanged<String>? onOpenCommitDiff;

  /// 主「选择/更换文件」入口：打开会话文件浏览器（选择后回到原历史视图）。
  ///
  /// 为 null 时保持旧行为（内联搜索选择器）；非 null 时内联选择器降级为
  /// 「搜索文件」次要入口，仍可随时打开。
  final Future<void> Function()? onBrowseFiles;

  /// 无预填文件时是否自动打开一次选择器（深链不触发）。
  final bool autoOpenPickerWhenEmpty;

  final GitFileHistoryKeys keys;

  @override
  State<GitFileHistoryBody> createState() => _GitFileHistoryBodyState();
}

class _GitFileHistoryBodyState extends State<GitFileHistoryBody> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(
      widget.controller.initialize(
        autoOpenPickerWhenEmpty: widget.autoOpenPickerWhenEmpty,
      ),
    );
  }

  @override
  void didUpdateWidget(GitFileHistoryBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(
        widget.controller.initialize(
          autoOpenPickerWhenEmpty: widget.autoOpenPickerWhenEmpty,
        ),
      );
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter <= 240) {
      unawaited(widget.controller.loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.keys;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Column(
          key: keys.root,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fileBar(controller),
            const Divider(height: 1),
            if (controller.pickerOpen) _pickerPanel(controller),
            Expanded(child: _historyBody(controller)),
          ],
        );
      },
    );
  }

  bool get _hasBrowser => widget.onBrowseFiles != null;

  /// 主入口：优先会话文件浏览器；未注入时退回内联搜索选择器。
  Future<void> _chooseFile() async {
    final browse = widget.onBrowseFiles;
    if (browse == null) {
      _openPicker();
      return;
    }
    await browse();
  }

  /// 打开选择器前清空上次搜索词（controller 在选完文件后会重置 query）。
  void _openPicker() {
    _search.clear();
    widget.controller.openPicker();
  }

  Widget _fileBar(GitFileHistoryController controller) {
    final selected = controller.selectedPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Icon(Icons.history, size: 18, color: DshColors.ink3(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              selected ?? L10n.t('未选择文件', 'No file selected'),
              key: widget.keys.fileChip,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: DshColors.ink2(context)),
            ),
          ),
          if (selected != null)
            IconButton(
              key: widget.keys.refresh,
              tooltip: L10n.t('刷新历史', 'Refresh history'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => unawaited(controller.refresh()),
            ),
          TextButton.icon(
            key: widget.keys.changeFile,
            onPressed: () => unawaited(_chooseFile()),
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(
              selected == null
                  ? L10n.t('选择文件', 'Choose file')
                  : L10n.t('更换文件', 'Change file'),
            ),
          ),
          if (_hasBrowser)
            IconButton(
              key: widget.keys.searchFiles,
              tooltip: L10n.t('搜索文件', 'Search files'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.search, size: 20),
              onPressed: _openPicker,
            ),
        ],
      ),
    );
  }

  // ── 文件选择器 ──

  Widget _pickerPanel(GitFileHistoryController controller) {
    return Container(
      key: widget.keys.picker,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: DshColors.brandSoft(context),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: widget.keys.search,
                  controller: _search,
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: L10n.t('搜索仓库文件', 'Search tracked files'),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: controller.setPickerQuery,
                ),
              ),
              TextButton(
                key: widget.keys.cancelPicker,
                onPressed: () {
                  _search.clear();
                  controller.closePicker();
                },
                child: Text(L10n.t('取消', 'Cancel')),
              ),
            ],
          ),
          const SizedBox(height: 6),
            SizedBox(height: 220, child: _fileResults(controller)),
          ],
        ),
      ),
    ),
    );
  }

  Widget _fileResults(GitFileHistoryController controller) {
    if (controller.loadingFiles) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.filesError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              controller.filesError!,
              key: Key('${widget.keys.prefix}-files-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => unawaited(controller.retry()),
              child: Text(L10n.t('重试', 'Retry')),
            ),
          ],
        ),
      );
    }
    final queryEmpty = controller.pickerQuery.trim().isEmpty;
    final recent = queryEmpty ? controller.recentFiles : const <String>[];
    final rows = queryEmpty
        ? controller.files.where((path) => !recent.contains(path)).toList()
        : controller.files;
    if (recent.isEmpty && rows.isEmpty) {
      return Center(
        child: Text(
          queryEmpty
              ? L10n.t('仓库里没有已跟踪文件', 'No tracked files in this repository')
              : L10n.t('没有匹配的文件', 'No matching files'),
          key: Key('${widget.keys.prefix}-files-empty'),
        ),
      );
    }
    final items = <Object>[
      if (recent.isNotEmpty) const _PickerSection('recent'),
      ...recent,
      if (rows.isNotEmpty) _PickerSection(queryEmpty ? 'all' : 'results'),
      ...rows,
      if (controller.filesTruncated) const _PickerSection('truncated'),
    ];
    return ListView.builder(
      key: widget.keys.pickerList,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is _PickerSection) {
          return switch (item.kind) {
            'recent' => _pickerHeader(
              L10n.t('最近使用', 'Recent files'),
              const Key('git-history-recent-section'),
            ),
            'results' => _pickerHeader(
              L10n.t('搜索结果', 'Results'),
              const Key('git-history-results-section'),
            ),
            'all' => _pickerHeader(
              L10n.t('全部文件', 'All files'),
              const Key('git-history-all-section'),
            ),
            _ => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                L10n.t(
                  '文件较多，仅显示前 ${controller.files.length} 个',
                  'Many files: showing first ${controller.files.length}',
                ),
                style: TextStyle(
                  fontSize: 11.5,
                  color: DshColors.ink3(context),
                ),
              ),
            ),
          };
        }
        final path = item as String;
        final isRecent = queryEmpty && controller.recentFiles.contains(path);
        return ListTile(
          key: isRecent
              ? widget.keys.recentRow(path)
              : widget.keys.fileRow(path),
          dense: true,
          leading: Icon(
            isRecent ? Icons.history : Icons.description_outlined,
            size: 18,
          ),
          title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => unawaited(controller.selectFile(path)),
        );
      },
    );
  }

  Widget _pickerHeader(String label, Key key) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: DshColors.ink3(context),
      ),
    ),
  );

  // ── 历史列表 ──

  Widget _historyBody(GitFileHistoryController controller) {
    if (!controller.hasFile) return _guidedEmpty();
    if (controller.loadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.historyError != null && controller.entries.isEmpty) {
      return _errorCard(
        message: controller.historyError!,
        onRetry: () => unawaited(controller.retry()),
      );
    }
    if (controller.isPathInvalid) {
      return _errorCard(
        message: L10n.t(
          '路径不在仓库内，或不是文件路径',
          'Path is outside the repository or is not a file',
        ),
        onRetry: () => unawaited(_chooseFile()),
        retryLabel: L10n.t('重新选择文件', 'Choose another file'),
      );
    }
    if (controller.entries.isEmpty) {
      if (controller.isUntracked) {
        return _emptyState(
          // not-tracked 覆盖“未跟踪”与“已在 HEAD 删除/改名”两种情形。
          L10n.t(
            '该文件不在当前 HEAD（未跟踪或已删除）',
            'File is not in the current HEAD (untracked or deleted)',
          ),
          action: () => unawaited(_chooseFile()),
          actionLabel: L10n.t('重新选择文件', 'Choose another file'),
        );
      }
      if (controller.isEmptyRepository) {
        return _emptyState(
          L10n.t('仓库还没有提交', 'Repository has no commits'),
          action: () => unawaited(_chooseFile()),
          actionLabel: L10n.t('重新选择文件', 'Choose another file'),
        );
      }
      return _emptyState(
        L10n.t('该文件暂无提交历史', 'No commit history for this file'),
        action: () => unawaited(_chooseFile()),
        actionLabel: L10n.t('重新选择文件', 'Choose another file'),
      );
    }
    final entries = controller.entries;
    return ListView.builder(
      key: widget.keys.list,
      controller: _scroll,
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == entries.length) return _historyFooter(controller);
        return _historyRow(context, entries[index]);
      },
    );
  }

  Widget _historyRow(BuildContext context, GitFileHistoryEntry entry) {
    final theme = Theme.of(context);
    return ListTile(
      key: widget.keys.row(entry.oid),
      onTap: () => widget.onOpenCommitDiff?.call(entry.oid),
      onLongPress: () => _copyOid(context, entry.oid),
      leading: _StatusBadge(
        key: widget.keys.statusBadge(entry.oid),
        status: entry.status,
      ),
      title: Text(
        entry.subject,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(
        [
          entry.shortOid,
          entry.author,
          relTime(entry.timestamp * 1000),
        ].where((part) => part.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  Widget _historyFooter(GitFileHistoryController controller) {
    final error = controller.historyError;
    if (error != null && controller.entries.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              error,
              key: widget.keys.error,
              textAlign: TextAlign.center,
            ),
            TextButton(
              key: widget.keys.retry,
              onPressed: () => unawaited(controller.retry()),
              child: Text(L10n.t('重试', 'Retry')),
            ),
          ],
        ),
      );
    }
    if (controller.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (controller.nextCursor != null) {
      return Center(
        child: TextButton(
          key: widget.keys.loadMore,
          onPressed: () => unawaited(controller.loadMore()),
          child: Text(L10n.t('加载更多…', 'Load more…')),
        ),
      );
    }
    if (controller.truncated) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            L10n.t(
              '仅显示最近 ${controller.entries.length} 条提交',
              'Showing latest ${controller.entries.length} commits',
            ),
            key: widget.keys.truncated,
            style: TextStyle(
              fontSize: 12,
              color: DshColors.ink3(context),
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 12);
  }

  Future<void> _copyOid(BuildContext context, String oid) async {
    await Clipboard.setData(ClipboardData(text: oid));
    if (!context.mounted) return;
    showToast(context, L10n.t('已复制 OID', 'OID copied'));
  }

  // ── 空态 / 错误 ──

  /// 全屏空态的统一外壳：可滚动，避免选择器展开压缩可视高度时溢出。
  Widget _centeredScroll(Widget child) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [child]),
    ),
  );

  Widget _guidedEmpty() {
    return _centeredScroll(
      Column(
        key: widget.keys.empty,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 40, color: DshColors.ink3(context)),
          const SizedBox(height: 12),
          Text(
            L10n.t(
              '选择一个文件，查看它的提交历史',
              'Choose a file to see its commit history',
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: widget.keys.chooseFile,
            onPressed: () => unawaited(_chooseFile()),
            icon: const Icon(Icons.folder_open),
            label: Text(L10n.t('选择文件', 'Choose file')),
          ),
          if (_hasBrowser) ...[
            const SizedBox(height: 4),
            TextButton(
              key: widget.keys.searchFilesEmpty,
              onPressed: _openPicker,
              child: Text(L10n.t('搜索文件', 'Search files')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyState(
    String message, {
    VoidCallback? action,
    String? actionLabel,
  }) {
    return _centeredScroll(
      Column(
        key: widget.keys.empty,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 36, color: DshColors.ink3(context)),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          if (action != null && actionLabel != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: action, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }

  Widget _errorCard({
    required String message,
    required VoidCallback onRetry,
    String? retryLabel,
  }) {
    return _centeredScroll(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 36,
            color: DshColors.danger(context),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            key: widget.keys.error,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: widget.keys.retry,
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(retryLabel ?? L10n.t('重试', 'Retry')),
          ),
        ],
      ),
    );
  }
}

/// 选择器列表里的分组标记。
class _PickerSection {
  const _PickerSection(this.kind);
  final String kind;
}

/// 历史行左侧的状态徽标（宿主返回 A/M/D/R/C/T）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'A' => DshColors.ok(context),
      'D' => DshColors.danger(context),
      'R' => DshColors.brand(context),
      'C' || 'T' => DshColors.warn(context),
      _ => DshColors.ink3(context),
    };
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
