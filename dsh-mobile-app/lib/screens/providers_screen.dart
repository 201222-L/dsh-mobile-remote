// 模型提供商管理页（v2.6）：与 PC 端 设置→模型 同一配置通道。
// 列表：搜索 + 已连接（卡片）/ 未配置（默认折叠紧凑行）；
// 点击可编辑 baseURL / API Key / 模型目录 / 探测模型。
import 'package:flutter/material.dart';
import '../api.dart';
import '../l10n.dart';
import '../store.dart';
import '../theme.dart';
import '../toast.dart';

/// Phase 2：统一打开「模型提供商」管理页（设置页与模型弹层共用入口）。
void openProviders(BuildContext context, AppStore store) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ProvidersScreen(store: store)),
  );
}

class ProvidersScreen extends StatefulWidget {
  final AppStore store;
  const ProvidersScreen({super.key, required this.store});

  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  List<Map<String, dynamic>>? _providers;
  String? _error;
  String _query = '';
  bool _dormantExpanded = false;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _providers = null;
      _error = null;
    });
    try {
      final list = await api.llmProviders();
      if (!mounted) return;
      setState(() => _providers = list);
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      // 旧插件没有 /api/llm-providers 端点（404 not-found）：给出可操作的提示
      if (msg.contains('not-found') || msg.contains('404')) {
        setState(() => _error = L10n.t('电脑端插件版本过旧：缺少「模型提供商」接口。\n请升级 dsh-mobile-remote 插件后重启桌面端（已配置的模型不受影响）。', 'The desktop plugin is outdated: the "Model Providers" API is missing.\nPlease upgrade the dsh-mobile-remote plugin and restart the desktop app (configured models are unaffected).'));
      } else {
        setState(() => _error = msg);
      }
    }
  }

  bool _match(Map<String, dynamic> p, String q) {
    if (q.isEmpty) return true;
    final name = (p['name'] as String? ?? '').toLowerCase();
    final id = (p['id'] as String? ?? '').toLowerCase();
    return name.contains(q) || id.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(L10n.t('模型提供商', 'Model Providers'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text('$_error', style: TextStyle(fontSize: 13, color: ink2, height: 1.5), textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(onPressed: _load, child: Text(L10n.t('重试', 'Retry'))),
                ],
              ),
            )
          : _providers == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    children: [
                      Text(
                        L10n.t('与 PC 端「设置 → 模型」同一配置通道；手机修改即时生效，两端一致。', 'Same configuration channel as "Settings → Model" on the desktop; changes on your phone apply instantly on both ends.'),
                        style: TextStyle(fontSize: 12, color: ink3, height: 1.5),
                      ),
                      const SizedBox(height: 10),
                      // 搜索框
                      TextField(
                        controller: _searchCtrl,
                        style: const TextStyle(fontSize: 14),
                        onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                        decoration: InputDecoration(
                          hintText: L10n.t('搜索提供商（名称 / ID）', 'Search providers (name / ID)'),
                          hintStyle: TextStyle(fontSize: 13, color: ink3),
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 16),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() => _query = '');
                                  },
                                ),
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: line)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: line)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildSections(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSections() {
    final all = _providers ?? [];
    final live = all.where((p) => p['dormant'] != true && _match(p, _query)).toList();
    final dormant = all.where((p) => p['dormant'] == true && _match(p, _query)).toList();
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    if (live.isEmpty && dormant.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(child: Text(L10n.t('没有匹配的提供商', 'No matching providers'), style: TextStyle(fontSize: 13, color: ink3))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (live.isNotEmpty) ...[
          _sectionHeader('${L10n.t('已连接（', 'Connected (')}${live.length}${L10n.t('）', ')')}'),
          for (final p in live) _ProviderCard(provider: p, onEdit: () => _openEditor(p)),
          const SizedBox(height: 6),
        ],
        if (dormant.isNotEmpty) ...[
          // 未配置区：默认折叠
          InkWell(
            onTap: () => setState(() => _dormantExpanded = !_dormantExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
              child: Row(
                children: [
                  Icon(_dormantExpanded ? Icons.expand_more : Icons.expand_less, size: 18, color: ink2),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${L10n.t('未配置提供商（', 'Not configured (')}${dormant.length}${L10n.t('）', ')')}',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: ink2),
                    ),
                  ),
                  Text(_dormantExpanded ? L10n.t('收起', 'Collapse') : L10n.t('展开', 'Expand'), style: TextStyle(fontSize: 11.5, color: ink3)),
                ],
              ),
            ),
          ),
          if (_dormantExpanded)
            for (final p in dormant) _DormantRow(provider: p, onEdit: () => _openEditor(p)),
        ],
      ],
    );
  }

  Widget _sectionHeader(String text) {
    final ink2 = DshColors.ink2(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: ink2)),
    );
  }

  void _openEditor(Map<String, dynamic> p) {
    final ns = p['settingsNs'] as String?;
    if (ns == null || ns.isEmpty) {
      showToast(context, L10n.t('该提供商由内核内置，配置入口在 PC 端', 'This provider is built into the kernel; configure it on the desktop app.'));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _ProviderEditor(
        provider: p,
        onSaved: () {
          Navigator.of(ctx).pop();
          showToast(context, L10n.t('已保存', 'Saved'));
          _load();
        },
      ),
    );
  }
}

/// 已连接提供商卡片（信息密度高：状态 / baseURL / 密钥 / 模型数）。
class _ProviderCard extends StatelessWidget {
  final Map<String, dynamic> provider;
  final VoidCallback onEdit;
  const _ProviderCard({required this.provider, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final ok = DshColors.ok(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final surface = DshColors.surface(context);
    final baseURL = provider['baseURL'] as String?;
    final keyConfigured = provider['keyConfigured'] == true;
    final catalogModels = provider['catalogModels'] as List?;
    final subs = <String>[
      provider['id'] as String? ?? '',
      if (baseURL != null && baseURL.isNotEmpty) baseURL,
      keyConfigured ? L10n.t('密钥已配置', 'API key set') : L10n.t('未设置密钥', 'No API key set'),
      if (catalogModels != null) '${L10n.t('目录 ', 'Catalog: ')}${catalogModels.length}${L10n.t(' 个模型', ' models')}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        provider['name'] as String? ?? provider['id'] as String? ?? '',
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: ok.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(L10n.t('已连接', 'Connected'), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: ok)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subs.join(' · '),
                  style: TextStyle(fontSize: 11.5, color: ink3, height: 1.45),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.edit_outlined, size: 18, color: ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 未配置提供商紧凑行（状态点 + 名称 + ID）。
class _DormantRow extends StatelessWidget {
  final Map<String, dynamic> provider;
  final VoidCallback onEdit;
  const _DormantRow({required this.provider, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final warn = DshColors.warn(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: line.withValues(alpha: 0.5), width: 0.5)),
        ),
        child: Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: warn, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                provider['name'] as String? ?? provider['id'] as String? ?? '',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(provider['id'] as String? ?? '', style: TextStyle(fontSize: 11.5, color: ink3)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: ink3),
          ],
        ),
      ),
    );
  }
}

class _ProviderEditor extends StatefulWidget {
  final Map<String, dynamic> provider;
  final VoidCallback onSaved;
  const _ProviderEditor({required this.provider, required this.onSaved});

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final TextEditingController _baseCtrl;
  final _keyCtrl = TextEditingController();
  final _modelIdCtrl = TextEditingController();
  bool _busy = false;
  String? _status;
  List<Map<String, dynamic>>? _discovered;
  final List<Map<String, dynamic>> _models = [];

  bool get _isPiAiStyle => (widget.provider['settingsPath'] as List? ?? []).isNotEmpty;

  @override
  void initState() {
    super.initState();
    _baseCtrl = TextEditingController(text: widget.provider['baseURL'] as String? ?? '');
    _models.addAll((widget.provider['catalogModels'] as List? ?? []).map((m) => Map<String, dynamic>.from(m as Map)));
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final ns = widget.provider['settingsNs'] as String? ?? '';
    final base = _baseCtrl.text.trim();
    if (base.isEmpty) {
      setState(() => _status = L10n.t('请先填写 baseURL', 'Please enter a baseURL first'));
      return;
    }
    setState(() {
      _busy = true;
      _status = L10n.t('探测中…', 'Probing…');
      _discovered = null;
    });
    try {
      final models = await api.probeLlmProvider(
        settingsNs: ns,
        baseURL: base,
        apiKey: _keyCtrl.text.trim().isEmpty ? null : _keyCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _discovered = models;
        _status = '${L10n.t('探测成功：', 'Probe succeeded: ')}${models.length}${L10n.t(' 个模型', ' models')}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '${L10n.t('探测失败：', 'Probe failed: ')}$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adoptAll() {
    final existing = _models.map((m) => m['id']).toSet();
    final added = <Map<String, dynamic>>[];
    for (final m in _discovered ?? []) {
      if (!existing.contains(m['id'])) {
        added.add(Map<String, dynamic>.from(m));
        existing.add(m['id']);
      }
    }
    setState(() {
      _models.addAll(added);
      _status = added.isEmpty ? L10n.t('没有新模型（已全部在列表）', 'No new models (all are already in the list)') : '${L10n.t('已采用 ', 'Adopted ')}${added.length}${L10n.t(' 个模型', ' models')}';
    });
  }

  void _addModel() {
    final id = _modelIdCtrl.text.trim();
    if (id.isEmpty) return;
    if (_models.any((m) => m['id'] == id)) {
      setState(() => _status = '${L10n.t('模型已存在：', 'Model already exists: ')}$id');
      return;
    }
    setState(() {
      _models.add({'id': id, 'name': id});
      _modelIdCtrl.clear();
      _status = '${L10n.t('已添加：', 'Added: ')}$id';
    });
  }

  void _removeModel(String id) {
    setState(() => _models.removeWhere((m) => m['id'] == id));
  }

  Future<void> _save() async {
    final ns = widget.provider['settingsNs'] as String? ?? '';
    final base = _baseCtrl.text.trim();
    if (base.isEmpty) {
      setState(() => _status = L10n.t('baseURL 不能为空', 'baseURL cannot be empty'));
      return;
    }
    if (_isPiAiStyle && _models.isEmpty) {
      setState(() => _status = L10n.t('请至少添加一个模型（探测采用或手动输入模型 ID）', 'Please add at least one model (adopt from probe or enter a model ID manually)'));
      return;
    }
    setState(() {
      _busy = true;
      _status = L10n.t('保存中…', 'Saving…');
    });
    try {
      await api.saveLlmProvider(
        provider: widget.provider['id'] as String? ?? '',
        settingsNs: ns,
        baseURL: base,
        apiKey: _keyCtrl.text.trim().isEmpty ? null : _keyCtrl.text.trim(),
        models: _models.isEmpty ? null : _models,
        api: 'openai-completions',
        displayName: widget.provider['name'] as String?,
      );
      if (!mounted) return;
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '${L10n.t('保存失败：', 'Save failed: ')}$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeKey() async {
    final ns = widget.provider['settingsNs'] as String? ?? '';
    setState(() {
      _busy = true;
      _status = L10n.t('清除中…', 'Clearing…');
    });
    try {
      await api.saveLlmProvider(
        provider: widget.provider['id'] as String? ?? '',
        settingsNs: ns,
        removeKey: true,
      );
      if (!mounted) return;
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '${L10n.t('清除失败：', 'Clear failed: ')}$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = DshColors.ink(context);
    final ink2 = DshColors.ink2(context);
    final ink3 = DshColors.ink3(context);
    final line = DshColors.line(context);
    final surface = DshColors.surface(context);
    final brand = DshColors.brand(context);
    final danger = DshColors.danger(context);
    final p = widget.provider;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  p['name'] as String? ?? p['id'] as String? ?? '',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text(p['id'] as String? ?? '', style: TextStyle(fontSize: 12, color: ink3)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseCtrl,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'baseURL',
                hintText: 'https://api.deepseek.com',
                labelStyle: TextStyle(fontSize: 13, color: ink3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: line)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: line)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keyCtrl,
              obscureText: true,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                labelText: p['keyConfigured'] == true ? L10n.t('API Key（已配置，留空不修改）', 'API Key (set — leave empty to keep)') : 'API Key',
                labelStyle: TextStyle(fontSize: 13, color: ink3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: line)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: line)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _probe,
                    child: Text(L10n.t('探测模型', 'Probe Models'), style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(L10n.t('保存', 'Save'), style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
            if (p['keyConfigured'] == true) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _removeKey,
                child: Text(L10n.t('清除已存密钥', 'Clear saved key'), style: TextStyle(fontSize: 12.5, color: danger)),
              ),
            ],
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_status!, style: TextStyle(fontSize: 12, color: ink2, height: 1.4)),
              ),
            if (_discovered != null && _discovered!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(L10n.t('探测到的模型：', 'Discovered models:'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ink)),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _adoptAll,
                    child: Text(L10n.t('全部采用', 'Adopt All'), style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: surface,
                  border: Border.all(color: line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    for (final m in _discovered!)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(Icons.smart_toy_outlined, size: 14, color: brand),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                (m['name'] as String? ?? m['id'] as String? ?? '').toString(),
                                style: const TextStyle(fontSize: 12.5),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(m['id'] as String? ?? '', style: TextStyle(fontSize: 11, color: ink3)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text('${L10n.t('模型目录（', 'Model catalog (')}${_models.length}${L10n.t('）', ')')}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ink)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _modelIdCtrl,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: L10n.t('手动输入模型 ID', 'Enter a model ID manually'),
                      hintStyle: TextStyle(fontSize: 12.5, color: ink3),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line)),
                    ),
                    onSubmitted: (_) => _addModel(),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _addModel,
                  child: Text(L10n.t('添加', 'Add'), style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
            if (_models.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(L10n.t('未添加模型', 'No models added'), style: TextStyle(fontSize: 11.5, color: ink3)),
              )
            else
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: surface,
                  border: Border.all(color: line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    for (final m in _models)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(Icons.model_training, size: 14, color: brand),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                (m['name'] as String? ?? m['id'] as String? ?? '').toString(),
                                style: const TextStyle(fontSize: 12.5),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(m['id'] as String? ?? '', style: TextStyle(fontSize: 11, color: ink3)),
                            InkWell(
                              onTap: () => _removeModel(m['id'] as String? ?? ''),
                              borderRadius: BorderRadius.circular(6),
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(Icons.close, size: 14, color: ink3),
                              ),
                            ),
                          ],
                        ),
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
