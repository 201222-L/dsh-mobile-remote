// DSH Mobile App — API 客户端（对接 dsh-mobile-remote 插件的 /m 接口）
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'logger.dart';
import 'models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// 全局 API 单例
final Api api = Api();

class Api {
  String baseUrl = '';
  String token = '';
  /// 电脑端插件版本（bootstrap 返回，设置页「版本」展示用）。
  String pluginVersion = '';
  /// 电脑的全部候选地址（局域网 IP / Tailscale IP / 127.0.0.1）。
  /// 连接失败时按顺序轮换（外出自动切 Tailscale，回家自动切回局域网）。
  List<String> baseUrls = [];
  static const _kBase = 'dsh_mr_base';
  static const _kToken = 'dsh_mr_token';
  static const _kUrls = 'dsh_mr_urls';
  static const _kPluginVer = 'dsh_mr_plugin_ver';
  static const _maxUrls = 8;

  /// 共享 HTTP 客户端：SSE 重连复用同一连接池，避免每次 new Client 泄漏
  /// socket/定时器导致内存耗尽闪退。
  final http.Client _client = http.Client();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_kBase) ?? '';
    token = prefs.getString(_kToken) ?? '';
    pluginVersion = prefs.getString(_kPluginVer) ?? ''; // 上次连接时记录，断线也可见
    final urls = prefs.getStringList(_kUrls) ?? [];
    if (urls.isNotEmpty) {
      baseUrls = urls.map(_normBase).where((u) => u.isNotEmpty).toList();
      if (!baseUrls.contains(baseUrl)) baseUrls.insert(0, baseUrl);
    } else if (baseUrl.isNotEmpty) {
      baseUrls = [baseUrl];
    }
  }

  Future<void> save({required String base, required String token}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBase, base);
    await prefs.setString(_kToken, token);
    baseUrl = base;
    // 修复：旧版把候选地址表重置为单条。若新地址恰好不可达（如扫到蒲公英 IP
    // 而手机组网没开），连回退的机会都没有。现改为：新地址置首，保留旧候选作兜底。
    final merged = <String>[_normBase(base)];
    for (final u in baseUrls) {
      final n = _normBase(u);
      if (n.isNotEmpty && n != merged.first && merged.length < _maxUrls) merged.add(n);
    }
    baseUrls = merged;
    await prefs.setStringList(_kUrls, baseUrls);
    this.token = token;
  }

  /// 规范化地址：去尾部斜杠与 /m 后缀。
  static String _normBase(String s) {
    var base = s.trim();
    if (base.isEmpty) return '';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/m')) base = base.substring(0, base.length - 2);
    return base;
  }

  /// 合并新收集到的地址（去重、去回环置后、上限裁剪），当前可用地址保持第一位。
  void mergeUrls(List<String> urls) {
    final seen = <String>{};
    final merged = <String>[_normBase(baseUrl)];
    seen.add(merged.first);
    for (final u in urls) {
      final n = _normBase(u);
      if (n.isEmpty) continue;
      // 排除回环与链路本地地址（含带端口形式）：手机均不可达
      final host = Uri.tryParse(n)?.host ?? '';
      if (host == '127.0.0.1' || host == 'localhost' || host == '::1') continue;
      if (host.startsWith('169.254.')) continue;
      if (seen.add(n)) merged.add(n);
    }
    if (merged.length > _maxUrls) merged.removeRange(_maxUrls, merged.length);
    baseUrls = merged;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_kUrls, baseUrls);
      } catch (_) {}
    }());
  }

  /// 探测某地址是否可达（独立临时客户端，不动全局 baseUrl）。
  /// 返回 null 表示可达；否则返回错误描述。
  Future<String?> probeBase(String base) async {
    try {
      final probe = Api()
        ..baseUrl = base
        ..token = token;
      await probe.getJson('/api/bootstrap');
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 吸收 bootstrap 响应：合并服务器全部地址 + 记录插件版本（持久化，断线也可见）。
  void absorbBootstrap(Map<String, dynamic> d) {
    final urls = (d['server']?['urls'] as List?)?.map((u) => u.toString()).toList() ?? const <String>[];
    mergeUrls(urls);
    final p = d['plugin'];
    if (p is Map && p['version'] is String) {
      pluginVersion = p['version'] as String;
      unawaited(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kPluginVer, pluginVersion);
        } catch (_) {}
      }());
    }
  }

  /// 连接成功后收集电脑全部地址（/api/bootstrap 的 server.urls 含 Tailscale/ZeroTier 等虚拟网段 IP）。
  Future<void> collectUrls() async {
    try {
      final d = await getJson('/api/bootstrap');
      absorbBootstrap(d);
      AppLog.instance.log('地址收集完成：共 ${baseUrls.length} 个 → ${baseUrls.join(' , ')}');
    } catch (_) {
      // 收集失败不影响当前连接
    }
  }

  /// 连接失败时轮换到下一个候选地址；返回是否发生了切换。
  bool rotateBaseUrl() {
    if (baseUrls.length < 2) return false;
    final cur = _normBase(baseUrl);
    final idx = baseUrls.indexOf(cur);
    if (idx < 0) return false;
    final next = baseUrls[(idx + 1) % baseUrls.length];
    if (next == cur) return false;
    baseUrl = next;
    // 持久化新活动地址（失败不影响内存态切换）
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kBase, baseUrl);
      } catch (_) {}
    }());
    return true;
  }

  /// 插件路由挂在 basePath（默认 /m）下，所有 API 需带 /m 前缀。
  /// 用户填的地址可能带或不带 /m 结尾，统一规范化。
  Uri _uri(String path) {
    var base = baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.endsWith('/m')) base = base.substring(0, base.length - 2);
    return Uri.parse('$base/m$path');
  }

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token.isNotEmpty) 'x-mobile-token': token,
      };

  Future<Map<String, dynamic>> getJson(String path, {Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final res = await _client.get(_uri(path), headers: _headers).timeout(timeout);
      return _decode(res);
    } catch (e) {
      AppLog.instance.log('GET $path 失败: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    try {
      final res = await _client
          .post(_uri(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      return _decode(res);
    } catch (e) {
      AppLog.instance.log('POST $path 失败: $e');
      rethrow;
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException((body['detail'] as String?) ?? (body['error'] as String?) ?? 'HTTP ${res.statusCode}');
    }
    return body;
  }

  // ── 业务接口 ──
  Future<Catalog> catalog() async => Catalog.fromJson(await getJson('/api/catalog'));
  Future<SessionConfig> sessionConfig(String sessionId) async =>
      SessionConfig.fromJson((await getJson('/api/session-config?sessionId=${Uri.encodeQueryComponent(sessionId)}'))['config'] as Map<String, dynamic>? ?? {});
  Future<void> updateSessionConfig(String sessionId, Map<String, dynamic> patch) async {
    await postJson('/api/session-config', {'sessionId': sessionId, ...patch});
  }

  // ── v2.6：模型提供商（与 PC 端 设置→模型 同一配置通道） ──
  /// 提供商列表（含 dormant 未激活项、baseURL、密钥状态）。
  Future<List<Map<String, dynamic>>> llmProviders() async {
    final data = await getJson('/api/llm-providers');
    return (data['providers'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  /// 探测端点模型列表（凭据一次性使用，不存储）。
  Future<List<Map<String, dynamic>>> probeLlmProvider({
    required String settingsNs,
    required String baseURL,
    String? apiKey,
    String? protocol,
  }) async {
    final data = await postJson('/api/llm-providers/probe', {
      'settingsNs': settingsNs,
      'baseURL': baseURL,
      if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
      if (protocol != null && protocol.isNotEmpty) 'protocol': protocol,
    });
    return (data['models'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  /// 保存提供商配置（baseURL / API Key / 模型目录）。
  /// [removeKey] 为 true 时清除已存密钥；[models] 为模型列表（[{id, name?}] 或字符串）。
  Future<void> saveLlmProvider({
    required String provider,
    required String settingsNs,
    String? baseURL,
    String? apiKey,
    List<Map<String, dynamic>>? models,
    String? api,
    String? displayName,
    bool removeKey = false,
  }) async {
    await postJson('/api/llm-providers', {
      'provider': provider,
      'settingsNs': settingsNs,
      if (baseURL != null && baseURL.isNotEmpty) 'baseURL': baseURL,
      if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
      if (models != null && models.isNotEmpty) 'models': models,
      if (api != null && api.isNotEmpty) 'api': api,
      if (displayName != null && displayName.isNotEmpty) 'displayName': displayName,
      if (removeKey) 'removeKey': true,
    });
  }
  Future<List<Session>> sessions() async {
    final data = await getJson('/api/sessions');
    return (data['sessions'] as List? ?? []).map((e) => Session.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 标记会话被打开（服务端记录活跃时间，用于"最近会话"排序）。失败静默。
  Future<void> touchSession(String sessionId) async {
    try {
      await postJson('/api/sessions/touch', {'sessionId': sessionId});
    } catch (_) {
      // 旧版插件无此端点：不影响打开会话
    }
  }

  /// 归档 / 恢复会话（服务端持久化）。
  Future<void> archiveSession(String sessionId, {required bool archive}) async {
    await postJson(archive ? '/api/sessions/archive' : '/api/sessions/unarchive', {'sessionId': sessionId});
  }

  /// 停止（取消）会话当前运行：对齐 PC 端"停止"按钮（映射 session.cancel）。
  Future<void> stopSession(String sessionId) async {
    await postJson('/api/sessions/stop', {'sessionId': sessionId});
  }

  /// 在新对话中分支（映射内核 session.fork，atSeq 锚定切点），返回子会话 id。
  Future<String> forkSession(String sessionId, {int? atSeq}) async {
    final r = await postJson('/api/sessions/fork', {
      'sessionId': sessionId,
      'atSeq': ?atSeq,
    });
    return r['sessionId'] as String? ?? '';
  }

  /// 消息反馈（👍/👎）：直接写内核 messageFeedback 服务（与 PC 端同一份数据）。
  Future<void> putFeedback(String sessionId, String messageId, String rating) async {
    await postJson('/api/feedback', {'sessionId': sessionId, 'messageId': messageId, 'rating': rating});
  }

  Future<Map<String, dynamic>> createSession(Map<String, dynamic> body) async => await postJson('/api/sessions', body);
  Future<String> send(String sessionId, String text) async {
    final r = await postJson('/api/send', {'sessionId': sessionId, 'text': text});
    return r['messageId'] as String? ?? '';
  }
  /// 拉历史。移动端默认取最近 100 条（服务端 limit 截断取尾部=最近的），
  /// 避免一次解析/渲染数百条事件导致手机卡死。
  Future<List<ChatEvent>> history(String sessionId, {int? after, int? before, int limit = 100}) async {
    final params = 'sessionId=${Uri.encodeQueryComponent(sessionId)}'
        '${after != null ? '&after=$after' : ''}${before != null ? '&before=$before' : ''}&limit=$limit';
    final data = await getJson('/api/history?$params');
    return (data['events'] as List? ?? []).map((e) => ChatEvent.fromJson(e as Map<String, dynamic>)).toList();
  }
  Future<List<AppNotification>> notifications() async {
    final data = await getJson('/api/notifications');
    return (data['items'] as List? ?? []).map((e) => AppNotification.fromJson(e as Map<String, dynamic>)).toList();
  }
  Future<void> markNotifsRead({List<String>? ids, bool all = false}) async {
    await postJson('/api/notifications/read', all ? {'all': true} : {'ids': ids ?? []});
  }
  /// 删除通知记录：指定 id 列表或全部（插件端 /notifications/delete，桌面端重启后生效）。
  Future<void> deleteNotifs({List<String>? ids, bool all = false}) async {
    await postJson('/api/notifications/delete', all ? {'all': true} : {'ids': ids ?? []});
  }
  /// 回答内核问询/审批（kind: question | approval | cancel），走与 PC 端 GUI 相同的 respond 通道。
  Future<Map<String, dynamic>> respond({
    required String kind,
    required String rpcId,
    required String sessionId,
    List<Map<String, dynamic>>? answers,
    String? approvalId,
    String? outcome,
  }) async {
    final body = <String, dynamic>{'kind': kind, 'rpcId': rpcId, 'sessionId': sessionId};
    if (answers != null) body['answers'] = answers;
    if (approvalId != null) body['approvalId'] = approvalId;
    if (outcome != null) body['outcome'] = outcome;
    return await postJson('/api/respond', body);
  }
  Future<double?> balance() async {
    try {
      final data = await getJson('/api/balance');
      final infos = data['balance']?['balance_infos'] as List? ?? [];
      if (infos.isEmpty) return null;
      final total = (infos.first as Map<String, dynamic>)['total_balance'];
      return total is num ? total.toDouble() : double.tryParse(total.toString());
    } on ApiException {
      rethrow;
    }
  }

  /// 余额详情（含币种/可用标记），查询失败返回 null。
  Future<Map<String, dynamic>?> balanceInfo() async {
    try {
      // 余额是电脑端代查官方 API，链路可能慢（官方接口抖动 + 组网隧道延迟），放宽到 25 秒
      final data = await getJson('/api/balance', timeout: const Duration(seconds: 25));
      final infos = data['balance']?['balance_infos'] as List? ?? [];
      if (infos.isEmpty) return null;
      final first = infos.first as Map<String, dynamic>;
      final total = first['total_balance'];
      return {
        'total': total is num ? total.toDouble() : double.tryParse(total.toString()) ?? 0,
        'currency': first['currency'] ?? 'CNY',
        'available': first['is_available'] ?? true,
      };
    } on ApiException {
      rethrow;
    }
  }

  /// 修改默认配置（Agent 预设 / 权限预设，作用于之后新建的会话）。
  Future<void> updateDefaults({String? agentPreset, String? permissionPreset}) async {
    await postJson('/api/defaults', {
      'agentPreset': ?agentPreset,
      'permissionPreset': ?permissionPreset,
    });
  }

  /// 会话 token 用量统计（服务端聚合）+ 上下文窗口（request/context 事件，PC 圆环同源）。
  Future<Map<String, dynamic>> usage(String sessionId) async {
    final data = await getJson('/api/usage?sessionId=${Uri.encodeQueryComponent(sessionId)}');
    return {
      ...(data['usage'] as Map<String, dynamic>? ?? {}),
      if (data['contextWindow'] != null) 'contextWindow': data['contextWindow'],
    };
  }

  /// 移动端动作注册表（插件提供）。
  Future<List<Map<String, dynamic>>> actions() async {
    final data = await getJson('/api/actions');
    return (data['actions'] as List? ?? []).map((e) => e as Map<String, dynamic>).toList();
  }

  /// 执行一个动作。
  Future<void> invokeAction(String id, Map<String, dynamic> args) async {
    await postJson('/api/actions/${Uri.encodeQueryComponent(id)}/invoke', {'args': args});
  }

  /// 已注册工作区列表：[{path, title?}]。
  Future<List<Map<String, dynamic>>> workspaces() async {
    final data = await getJson('/api/workspaces');
    return (data['workspaces'] as List? ?? []).map((e) => e as Map<String, dynamic>).toList();
  }

  /// 目录浏览：path 为空返回盘符；否则返回子目录名列表。
  Future<List<String>> directories(String path) async {
    final data = await getJson('/api/directories?path=${Uri.encodeQueryComponent(path)}');
    return (data['dirs'] as List? ?? []).map((e) => e.toString()).toList();
  }

  /// 新建文件夹。
  Future<void> createDirectory({String? path, required String name}) async {
    await postJson('/api/directories', {'path': path, 'name': name});
  }

  Future<Map<String, dynamic>?> diagnostics() async {
    try {
      return await getJson('/api/diagnostics');
    } catch (_) {
      return null;
    }
  }

  /// SSE 全量帧流（session/event + agent/status + hello），不做会话过滤。
  /// 帧格式与网页端一致：{type: "hello"|"session/event"|"agent/status", ...}。
  /// 解析：StringBuffer 累积，每 chunk 处理全部完整帧，剩余部分保留。
  /// （旧实现 while 循环内不更新缓冲区，收到 ≥2 帧后同一帧无限处理 → 死循环）
  /// SSE 保活回调：收到服务器心跳（`: ping` 注释行）或任何数据帧时触发。
  /// 用于连接存活性看门狗（网络静默丢包时 TCP 不会立刻报错，靠心跳超时强制重连）。
  void Function()? onSseKeepalive;

  Stream<Map<String, dynamic>> eventsRaw() {
    final controller = StreamController<Map<String, dynamic>>();
    final req = http.Request('GET', _uri('/api/events'));
    req.headers.addAll(_headers);
    // 连接超时：地址不可达但"黑洞"（不拒绝也不响应，如组网 IP 在手机端隧道关闭时）会让
    // send() 永久挂起，旧版因此卡死在 connecting 状态、看门狗与地址轮换全部失效。
    // 8 秒足够（正常服务器毫秒级回响应），失败越快轮换越快。
    _client.send(req).timeout(const Duration(seconds: 8)).then((res) async {
      if (res.statusCode != 200) {
        controller.addError(ApiException('SSE HTTP ${res.statusCode}'));
        controller.close();
        return;
      }
      final stream = res.stream.transform(utf8.decoder);
      final buf = StringBuffer();
      await for (final chunk in stream) {
        buf.write(chunk);
        var s = buf.toString();
        var idx = s.indexOf('\n\n');
        while (idx >= 0) {
          final frame = s.substring(0, idx);
          s = s.substring(idx + 2);
          idx = s.indexOf('\n\n');
          if (frame.startsWith('data: ')) {
            onSseKeepalive?.call();
            try {
              controller.add(jsonDecode(frame.substring(6)) as Map<String, dynamic>);
            } catch (_) {/* 忽略坏帧 */}
          } else if (frame.trim() == ': ping') {
            onSseKeepalive?.call();
          }
        }
        buf
          ..clear()
          ..write(s);
      }
      controller.close();
    }).catchError((e) {
      controller.addError(e);
      controller.close();
    });
    return controller.stream;
  }

  /// SSE 事件流：返回可取消的事件流（session/event 摘要帧）
  Stream<ChatEvent> events(String sessionId) {
    final controller = StreamController<ChatEvent>();
    final req = http.Request('GET', _uri('/api/events'));
    req.headers.addAll(_headers);
    _client.send(req).then((res) async {
      if (res.statusCode != 200) {
        controller.addError(ApiException('SSE HTTP ${res.statusCode}'));
        controller.close();
        return;
      }
      final stream = res.stream.transform(utf8.decoder);
      final buf = StringBuffer();
      await for (final chunk in stream) {
        buf.write(chunk);
        var s = buf.toString();
        var idx = s.indexOf('\n\n');
        while (idx >= 0) {
          final frame = s.substring(0, idx);
          s = s.substring(idx + 2);
          idx = s.indexOf('\n\n');
          if (frame.startsWith('data: ')) {
            try {
              final f = jsonDecode(frame.substring(6)) as Map<String, dynamic>;
              if (f['type'] == 'session/event' && f['sessionId'] == sessionId) {
                controller.add(ChatEvent.fromJson(f['event'] as Map<String, dynamic>));
              }
            } catch (_) {/* 忽略坏帧 */}
          }
        }
        buf
          ..clear()
          ..write(s);
      }
      controller.close();
    }).catchError((e) {
      controller.addError(e);
      controller.close();
    });
    return controller.stream;
  }
}
