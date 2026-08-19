// 底部弹层组：模型与推理 / 权限预设（含风险确认）/ 新建会话 / 目录选择 / 新建文件夹 / 执行动作
import 'package:flutter/material.dart';
import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'providers_screen.dart';

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
            // 内容区可滚动：条目多（如大量自定义预设）时不再溢出
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
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
  // v2.6：按提供商分组显示（组名来自 catalog.providers，与 PC 端目录同源）
  final providerNames = <String, String>{};
  final dormantIds = <String>{};
  for (final p in cat.providers) {
    providerNames[p.id] = p.name;
    if (p.dormant) dormantIds.add(p.id);
  }
  final groups = <String, List<CatalogModel>>{};
  final groupOrder = <String>[];
  for (final m in cat.models) {
    final pid = m.provider;
    if (!groups.containsKey(pid)) {
      groups[pid] = [];
      groupOrder.add(pid);
    }
    groups[pid]!.add(m);
  }
  final sheetChildren = <Widget>[
    for (final pid in groupOrder) ...[
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(
          providerNames[pid] ?? pid,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DshColors.ink2(context)),
        ),
      ),
      ...groups[pid]!.map((model) => _sheetItem(
            context,
            name: model.name,
            sub: model.id,
            active: store.sessionConfig.provider == model.provider && store.sessionConfig.model == model.id,
            onTap: () {
              final msgr = ScaffoldMessenger.of(context);
              Navigator.of(context).pop();
              store
                  .applySessionConfig({'provider': model.provider, 'model': model.id})
                  .then((_) => _toast(msgr, L10n.t('已切换模型', 'Model switched')))
                  .catchError((e) => _toast(msgr, '${L10n.t('切换失败：', 'Switch failed: ')}$e'));
            },
          )),
    ],
    // 未配置提供商收敛为一条入口（不再逐条列出）
    if (dormantIds.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: InkWell(
          onTap: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ProvidersScreen(store: store)),
            );
          },
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${L10n.t('还有 ', '')}${dormantIds.length}${L10n.t(' 个提供商未配置', ' more providers not configured')}',
                  style: TextStyle(fontSize: 12.5, color: DshColors.ink3(context)),
                ),
              ),
              Text(L10n.t('前往设置 ➜', 'Go to Settings ➜'), style: TextStyle(fontSize: 12, color: DshColors.brand(context))),
            ],
          ),
        ),
      ),
  ];
  showSheet(context, L10n.t('模型与推理', 'Model & Reasoning'), [
    ...sheetChildren,
    const SizedBox(height: 10),
    Text(L10n.t('推理强度', 'Reasoning Effort'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                      .catchError((err) => _toast(msgr, '${L10n.t('切换失败：', 'Switch failed: ')}$err'));
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
    Text(L10n.t('与桌面端模型目录一致', 'Same model catalog as the desktop app'), textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
  ]);
}

// ── 权限预设（danger 需风险确认） ──
void showPermSheet(BuildContext context, AppStore store) {
  final cat = store.catalog;
  if (cat == null) return;
  showSheet(context, L10n.t('权限预设', 'Permission Presets'), [
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
                .catchError((e) => _toast(msgr, '${L10n.t('切换失败：', 'Switch failed: ')}$e'));
          },
        )),
    Text(L10n.t('选择完全访问需确认风险', 'Selecting Full Access requires a risk confirmation'), textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: DshColors.ink3(context))),
  ]);
}

void _showDangerConfirm(BuildContext context, AppStore store) {
  showSheet(context, L10n.t('⚠ 风险确认', '⚠ Risk Confirmation'), [
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
      child: Text(
        L10n.t('完全访问将允许 agent 在电脑上执行任何操作，包括修改或删除工作区以外的文件。', 'Full Access lets the agent perform any operation on this computer, including modifying or deleting files outside the workspace.'),
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
            child: Text(L10n.t('取消', 'Cancel')),
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
                  .then((_) => _toast(msgr, L10n.t('已启用完全访问', 'Full Access enabled')))
                  .catchError((e) => _toast(msgr, '${L10n.t('切换失败：', 'Switch failed: ')}$e'));
            },
            child: Text(L10n.t('我理解风险，启用', 'Enable — I understand the risk')),
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
  // 默认工作目录 = 当前选中的工作区（未选时回退第一个已注册工作区）。
  // v2.7.1：用已规范化的 store.workspaces 匹配（api.workspaces() 原始路径大小写/斜杠
  // 与 workspacePath 不一致会导致匹配失败，永远回退到第一个工作区）。
  var ws = store.workspaces;
  if (ws.isEmpty) {
    try {
      final raw = await api.workspaces();
      ws = raw.map((w) => {...w, 'path': AppStore.normPath(w['path'] as String? ?? '')}).toList();
    } catch (_) {}
  }
  if (ws.isNotEmpty) {
    final selected = store.workspacePath;
    pendingDir = (selected != null && ws.any((w) => w['path'] == selected))
        ? selected
        : ws.first['path'] as String?;
  }
  if (!context.mounted) return;

  Future<void> doCreate() async {
    final preset = pendingMode ?? store.catalog?.defaults['agentPreset'] ?? 'standard';
    final name = switch (preset) {
      'standard' => L10n.t('标准模式', 'Standard'),
      'code' => L10n.t('PTC 模式', 'PTC Mode'),
      'minimal' => L10n.t('极简模式', 'Minimal'),
      'cordis' => L10n.t('创造模式', 'Creative'),
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
      _toast(msgr, '${L10n.t('已用「', 'Created session: ')}$name${L10n.t('」新建会话', '')}');
      await onCreated(created['sessionId'] as String);
    } catch (e) {
      if (context.mounted) _toast(ScaffoldMessenger.of(context), '${L10n.t('新建失败：', 'Failed to create: ')}$e');
    }
  }

  // 弹层内状态用 StatefulBuilder 驱动
  // 目录未加载（启动时 PC 忙/超时常见）：先补拉，而不是静默无反应
  var cat = store.catalog;
  if (cat == null) {
    cat = await store.refreshCatalog();
    if (!context.mounted) return;
  }
  if (cat == null) {
    _toast(ScaffoldMessenger.of(context), L10n.t('模型目录加载失败，请检查连接后下拉刷新重试', 'Failed to load the model catalog. Check the connection and pull to refresh.'));
    return;
  }
  final catalog = cat; // 非空最终引用，供弹层闭包使用
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
                Text(L10n.t('新建会话', 'New Session'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                // 预设列表可滚动（预设多时不溢出）；取消/创建按钮固定在底部
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...catalog.agentPresets.map((p) => _sheetItem(
                              context,
                              name: p.name,
                              sub: p.description,
                              active: (pendingMode ?? catalog.defaults['agentPreset']) == p.id,
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
                                      Text(L10n.t('工作目录', 'Working Directory'), style: const TextStyle(fontSize: 14)),
                                      Text(
                                        pendingDir ?? L10n.t('默认（当前工作区）', 'Default (current workspace)'),
                                        style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                Text(L10n.t('选择 ▸', 'Choose ▸'), style: TextStyle(fontSize: 12, color: DshColors.brand(context))),
                              ],
                            ),
                          ),
                        ),
                        // v2.7.1：模型与推理入口（新建会话时选模型/调推理强度；选择写入 sessionConfig，
                        // doCreate 会带上）
                        InkWell(
                          onTap: () {
                            showModelSheet(context, store);
                            // showModelSheet 选择后 pop 返回，刷新本弹层显示当前值
                            Future<void>.delayed(const Duration(milliseconds: 400), () {
                              if (sheetCtx.mounted) refresh();
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
                            child: Row(
                              children: [
                                Icon(Icons.smart_toy_outlined, size: 15, color: DshColors.ink3(context)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(L10n.t('模型与推理强度', 'Model & Reasoning Effort'), style: const TextStyle(fontSize: 14)),
                                      Text(
                                        '${store.sessionConfig.model ?? L10n.t('选择模型', 'Select model')}'
                                        ' · ${store.sessionConfig.reasoningEffort ?? 'max'}',
                                        style: TextStyle(fontSize: 11.5, color: DshColors.ink3(context)),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                Text(L10n.t('选择 ▸', 'Choose ▸'), style: TextStyle(fontSize: 12, color: DshColors.brand(context))),
                              ],
                            ),
                          ),
                        ),
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
                        child: Text(L10n.t('取消', 'Cancel')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(onPressed: doCreate, child: Text(L10n.t('创建会话', 'Create Session'))),
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
      error = '${L10n.t('读取失败：', 'Failed to read: ')}$e';
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
            Text(L10n.t('选择工作目录', 'Choose Working Directory'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    current.isEmpty ? L10n.t('根目录（选择盘符）', 'Root (choose a drive)') : current,
                    style: TextStyle(fontSize: 12.5, color: ink2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _goUp,
                  child: Text(L10n.t('上级 ▸', 'Up ▸'), style: TextStyle(fontSize: 12, color: brand)),
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
                                child: Text(L10n.t('已注册工作区', 'Registered Workspaces'), style: TextStyle(fontSize: 11, color: ink3)),
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
                                  child: Text(L10n.t('所有盘符', 'All Drives'), style: TextStyle(fontSize: 11, color: ink3)),
                                ),
                            ],
                            if (dirs.isEmpty && !loading && error == null)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 20),
                                child: Center(
                                  child: Text(L10n.t('没有子目录', 'No subdirectories'), style: TextStyle(fontSize: 13, color: ink3)),
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
              child: Text(L10n.t('＋ 新建文件夹', '+ New Folder')),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(L10n.t('取消', 'Cancel')),
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
                    child: Text(L10n.t('选这里', 'Select Here')),
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
            Text(L10n.t('新建文件夹', 'New Folder'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: L10n.t('文件夹名称', 'Folder Name'), hintText: L10n.t('如：my-project', 'e.g. my-project')),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    child: Text(L10n.t('取消', 'Cancel')),
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
                        if (sheetCtx.mounted) _toast(ScaffoldMessenger.of(sheetCtx), '${L10n.t('创建失败：', 'Failed to create: ')}$e');
                      }
                    },
                    child: Text(L10n.t('创建', 'Create')),
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
  showSheet(context, action['title'] as String? ?? L10n.t('执行动作', 'Execute Action'), [
    if (fields.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(L10n.t('直接执行，无需参数', 'Runs directly, no parameters needed'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: DshColors.ink2(context))),
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
            child: Text(L10n.t('取消', 'Cancel')),
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
                _toast(msgr, '${L10n.t('已发送给 agent：', 'Sent to agent: ')}${action['title']}');
              } catch (e) {
                _toast(msgr, '${L10n.t('执行失败：', 'Execution failed: ')}$e');
              }
            },
            child: Text(L10n.t('执行', 'Execute')),
          ),
        ),
      ],
    ),
  ]);
}

void _toast(ScaffoldMessengerState messenger, String text) {
  // 与全局 showToast 一致的短滞留 + 悬浮样式
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(milliseconds: 1600),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
}
