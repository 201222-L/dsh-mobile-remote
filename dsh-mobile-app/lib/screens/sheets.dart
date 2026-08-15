// 底部弹层组：模型与推理 / 权限预设（含风险确认）/ 新建会话 / 目录选择 / 新建文件夹 / 执行动作
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../theme.dart';

/// 通用底部弹层容器（对齐网页端 sheet：圆角顶、拖拽把手、标题）。
void showSheet(BuildContext context, String title, List<Widget> children) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: DshColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DshTheme.radiusLg)),
    ),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: DshColors.line(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    ),
  );
}

/// 通用单项选择弹层（用于设置页修改默认 Agent 预设 / 默认权限预设）。
void showChoiceSheet(
  BuildContext context, {
  required String title,
  required List<({String id, String name, String? sub})> items,
  required String? selectedId,
  required void Function(String id) onPick,
  String? footnote,
}) {
  showSheet(context, title, [
    for (final it in items)
      _sheetItem(
        context,
        name: it.name,
        sub: it.sub,
        active: selectedId == it.id,
        onTap: () {
          Navigator.of(context).pop();
          onPick(it.id);
        },
      ),
    if (footnote != null)
      Text(footnote, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
  ]);
}

Widget _sheetItem(BuildContext context, {required String name, String? sub, bool active = false, required VoidCallback onTap}) {
  final ink3 = DshColors.ink3(context);
  final brand = DshColors.brand(context);
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(sub, style: TextStyle(fontSize: 11.5, color: ink3)),
                  ),
              ],
            ),
          ),
          if (active)
            Icon(Icons.check, size: 18, color: brand)
          else
            const SizedBox(width: 18),
        ],
      ),
    ),
  );
}

// ── 模型与推理 ──
void showModelSheet(BuildContext context, AppStore store) {
  final cat = store.catalog;
  if (cat == null) return;
  showSheet(context, '模型与推理', [
    ...cat.models.map((model) => _sheetItem(
          context,
          name: model.name,
          sub: model.id,
          active: store.sessionConfig.model == model.id,
          onTap: () {
            final msgr = ScaffoldMessenger.of(context);
            Navigator.of(context).pop();
            store
                .applySessionConfig({'provider': model.provider, 'model': model.id})
                .then((_) => _toast(msgr, '已切换模型'))
                .catchError((e) => _toast(msgr, '切换失败：$e'));
          },
        )),
    const SizedBox(height: 10),
    const Text('推理强度', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 10),
    Row(
      children: [
        for (final e in cat.reasoningEfforts)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () {
                  final msgr = ScaffoldMessenger.of(context);
                  Navigator.of(context).pop();
                  store
                      .applySessionConfig({'reasoningEffort': e})
                      .catchError((err) => _toast(msgr, '切换失败：$err'));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: store.sessionConfig.reasoningEffort == e ? DshColors.brand(context) : null,
                    border: Border.all(color: DshColors.line(context)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    e,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: store.sessionConfig.reasoningEffort == e ? Colors.white : DshColors.ink2(context),
                      fontWeight: store.sessionConfig.reasoningEffort == e ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
    const SizedBox(height: 8),
    Text('与桌面端模型目录一致', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
  ]);
}

// ── 权限预设（danger 需风险确认） ──
void showPermSheet(BuildContext context, AppStore store) {
  final cat = store.catalog;
  if (cat == null) return;
  showSheet(context, '权限预设', [
    ...cat.permissionPresets.map((p) => _sheetItem(
          context,
          name: p.name,
          sub: p.description,
          active: store.sessionConfig.permissionPreset == p.id,
          onTap: () {
            final msgr = ScaffoldMessenger.of(context);
            Navigator.of(context).pop();
            if (p.id == 'danger-full-access') {
              _showDangerConfirm(context, store);
              return;
            }
            store
                .applySessionConfig({'permissionPreset': p.id})
                .catchError((e) => _toast(msgr, '切换失败：$e'));
          },
        )),
    Text('选择完全访问需确认风险', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
  ]);
}

void _showDangerConfirm(BuildContext context, AppStore store) {
  showSheet(context, '⚠ 风险确认', [
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
      child: Text(
        '完全访问将允许 agent 在电脑上执行任何操作，包括修改或删除工作区以外的文件。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 14, height: 1.6, color: DshColors.ink2(context)),
      ),
    ),
    Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              showPermSheet(context, store);
            },
            child: const Text('取消'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DshColors.danger(context)),
            onPressed: () {
              final msgr = ScaffoldMessenger.of(context);
              Navigator.of(context).pop();
              store
                  .applySessionConfig({'permissionPreset': 'danger-full-access', 'confirmDanger': true})
                  .then((_) => _toast(msgr, '已启用完全访问'))
                  .catchError((e) => _toast(msgr, '切换失败：$e'));
            },
            child: const Text('我理解风险，启用'),
          ),
        ),
      ],
    ),
  ]);
}

// ── 新建会话 ──
Future<void> showNewSessionSheet(
  BuildContext context,
  AppStore store,
  Future<void> Function(String sessionId) onCreated,
) async {
  String? pendingMode;
  String? pendingDir;
  // 默认工作目录 = 第一个已注册工作区
  try {
    final ws = await api.workspaces();
    if (ws.isNotEmpty) pendingDir = ws.first['path'] as String?;
  } catch (_) {}
  if (!context.mounted) return;

  Future<void> doCreate() async {
    final preset = pendingMode ?? store.catalog?.defaults['agentPreset'] ?? 'standard';
    final name = switch (preset) {
      'standard' => '标准模式',
      'code' => 'PTC 模式',
      'minimal' => '极简模式',
      'cordis' => '创造模式',
      _ => preset,
    };
    try {
      final created = await api.createSession({
        'preset': preset,
        'cwd': ?pendingDir,
        'model': store.sessionConfig.model ?? 'deepseek-v4-flash',
        'reasoningEffort': store.sessionConfig.reasoningEffort ?? 'max',
        'permissionPreset': store.catalog?.defaults['permissionPreset'] ?? 'workspace-write',
      });
      if (!context.mounted) return;
      final msgr = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      _toast(msgr, '已用「$name」新建会话');
      await onCreated(created['sessionId'] as String);
    } catch (e) {
      if (context.mounted) _toast(ScaffoldMessenger.of(context), '新建失败：$e');
    }
  }

  // 弹层内状态用 StatefulBuilder 驱动
  final cat = store.catalog;
  if (cat == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: DshColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DshTheme.radiusLg)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) {
        void refresh() => setSheet(() {});
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: DshColors.line(context), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('新建会话', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                ...cat.agentPresets.map((p) => _sheetItem(
                      context,
                      name: p.name,
                      sub: p.description,
                      active: (pendingMode ?? cat.defaults['agentPreset']) == p.id,
                      onTap: () {
                        pendingMode = p.id;
                        refresh();
                      },
                    )),
                InkWell(
                  onTap: () => showDirPicker(context, store, (path) {
                    pendingDir = path;
                    refresh();
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined, size: 15, color: DshColors.ink3(context)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('工作目录', style: TextStyle(fontSize: 14)),
                              Text(
                                pendingDir ?? '默认（当前工作区）',
                                style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Text('选择 ▸', style: TextStyle(fontSize: 12, color: DshColors.brand(context))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(onPressed: doCreate, child: const Text('创建会话')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ── 目录选择器（StatefulWidget：initState 即加载，修复旧版无限转圈） ──
Future<void> showDirPicker(
  BuildContext context,
  AppStore store,
  void Function(String path) onPicked,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: DshColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DshTheme.radiusLg)),
    ),
    builder: (_) => _DirPickerSheet(onPicked: onPicked),
  );
}

class _DirPickerSheet extends StatefulWidget {
  final void Function(String path) onPicked;
  const _DirPickerSheet({required this.onPicked});

  @override
  State<_DirPickerSheet> createState() => _DirPickerSheetState();
}

class _DirPickerSheetState extends State<_DirPickerSheet> {
  final dirStack = <String>[];
  String current = '';
  List<String> dirs = [];
  List<Map<String, dynamic>> workspaces = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load('');
  }

  Future<void> load(String path) async {
    setState(() {
      current = path;
      loading = true;
      error = null;
      dirs = [];
    });
    try {
      if (path.isEmpty) {
        try {
          workspaces = await api.workspaces();
        } catch (_) {
          workspaces = [];
        }
        dirs = await api.directories('');
      } else {
        workspaces = [];
        dirs = await api.directories(path);
      }
    } catch (e) {
      error = '读取失败：$e';
    }
    if (mounted) setState(() => loading = false);
  }

  void _goUp() {
    if (dirStack.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    load(dirStack.removeLast());
  }

  void _openDir(String name) {
    if (current.isEmpty) {
      dirStack.add('');
      load(name);
    } else {
      dirStack.add(current);
      load(current.endsWith('\\') ? current + name : '$current\\$name');
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = DshColors.brand(context);
    final danger = DshColors.danger(context);
    final ink3 = DshColors.ink3(context);
    final ink2 = DshColors.ink2(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: DshColors.line(context), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 12),
            const Text('选择工作目录', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    current.isEmpty ? '根目录（选择盘符）' : current,
                    style: TextStyle(fontSize: 12.5, color: ink2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _goUp,
                  child: Text('上级 ▸', style: TextStyle(fontSize: 12, color: brand)),
                ),
              ],
            ),
            SizedBox(
              height: 320,
              child: loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : error != null
                      ? Center(child: Text(error!, style: TextStyle(fontSize: 13, color: danger)))
                      : ListView(
                          children: [
                            if (current.isEmpty && workspaces.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Text('已注册工作区', style: TextStyle(fontSize: 11, color: ink3)),
                              ),
                              for (final w in workspaces)
                                InkWell(
                                  onTap: () {
                                    widget.onPicked(w['path'] as String);
                                    Navigator.of(context).pop();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                                    child: Row(
                                      children: [
                                        Icon(Icons.star_border, size: 15, color: ink3),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(w['path'] as String? ?? '', style: const TextStyle(fontSize: 13.5)),
                                              if (w['title'] != null)
                                                Text(w['title'] as String,
                                                    style: TextStyle(fontSize: 11, color: ink3)),
                                            ],
                                          ),
                                        ),
                                        Icon(Icons.chevron_right, size: 16, color: ink3),
                                      ],
                                    ),
                                  ),
                                ),
                              if (workspaces.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Text('所有盘符', style: TextStyle(fontSize: 11, color: ink3)),
                                ),
                            ],
                            if (dirs.isEmpty && !loading && error == null)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 20),
                                child: Center(
                                  child: Text('没有子目录', style: TextStyle(fontSize: 13, color: ink3)),
                                ),
                              ),
                            for (final name in dirs)
                              InkWell(
                                onTap: () => _openDir(name),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                                  child: Row(
                                    children: [
                                      Icon(Icons.folder_outlined, size: 15, color: ink3),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(name,
                                            style: const TextStyle(fontSize: 13.5),
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      Icon(Icons.chevron_right, size: 16, color: ink3),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _showNewFolder(context, current, (createdPath) {
                load(createdPath);
              }),
              child: const Text('＋ 新建文件夹'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      if (current.isNotEmpty) {
                        widget.onPicked(current);
                      }
                      Navigator.of(context).pop();
                    },
                    child: const Text('选这里'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void _showNewFolder(BuildContext context, String current, void Function(String) onCreated) {
  final ctrl = TextEditingController();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: DshColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DshTheme.radiusLg)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: DshColors.line(context), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 12),
            const Text('新建文件夹', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '文件夹名称', hintText: '如：my-project'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      final name = ctrl.text.trim();
                      if (name.isEmpty) return;
                      final parent = current.isEmpty ? null : current;
                      try {
                        await api.createDirectory(path: parent, name: name);
                        if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                        onCreated(parent ?? name);
                      } catch (e) {
                        if (sheetCtx.mounted) _toast(ScaffoldMessenger.of(sheetCtx), '创建失败：$e');
                      }
                    },
                    child: const Text('创建'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// ── 执行动作 ──
void showActionSheet(BuildContext context, Map<String, dynamic> action) {
  final fields = (action['fields'] as List? ?? []).map((e) => e as Map<String, dynamic>).toList();
  final ctrls = {for (final f in fields) f['key'] as String: TextEditingController()};
  showSheet(context, action['title'] as String? ?? '执行动作', [
    if (fields.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('直接执行，无需参数', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: DshColors.ink2(context))),
      ),
    for (final f in fields)
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: ctrls[f['key'] as String],
          decoration: InputDecoration(
            labelText: f['label'] as String? ?? f['key'] as String,
            hintText: f['placeholder'] as String? ?? '',
          ),
        ),
      ),
    const SizedBox(height: 4),
    Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            onPressed: () async {
              final msgr = ScaffoldMessenger.of(context);
              final args = {for (final f in fields) f['key'] as String: ctrls[f['key'] as String]!.text};
              Navigator.of(context).pop();
              try {
                await api.invokeAction(action['id'] as String, args);
                _toast(msgr, '已发送给 agent：${action['title']}');
              } catch (e) {
                _toast(msgr, '执行失败：$e');
              }
            },
            child: const Text('执行'),
          ),
        ),
      ],
    ),
  ]);
}

void _toast(ScaffoldMessengerState messenger, String text) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));
}
