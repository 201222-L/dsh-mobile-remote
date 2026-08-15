// DSH Mobile App — 手机远程操作 DeepSeek Harness
// 数据模型
class Session {
  final String id;
  final String? title;
  final String? cwd;
  final int createdAt;
  final bool archived;
  final int? lastActivity;
  Session({
    required this.id,
    this.title,
    this.cwd,
    required this.createdAt,
    this.archived = false,
    this.lastActivity,
  });
  factory Session.fromJson(Map<String, dynamic> j) => Session(
        id: j['id'] as String,
        title: j['title'] as String?,
        cwd: j['cwd'] as String?,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        archived: j['archived'] as bool? ?? false,
        lastActivity: (j['lastActivity'] as num?)?.toInt(),
      );
  String get label => (title != null && title!.trim().isNotEmpty) ? title! : '新会话';
  /// 排序键：最近活跃优先，无活跃记录回退创建时间。
  int get sortKey => lastActivity ?? createdAt;
}

class CatalogModel {
  final String provider;
  final String id;
  final String name;
  final String? description;
  final int? contextWindow;
  CatalogModel({required this.provider, required this.id, required this.name, this.description, this.contextWindow});
  factory CatalogModel.fromJson(Map<String, dynamic> j) => CatalogModel(
        provider: j['provider'] as String? ?? 'deepseek-official',
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        description: j['description'] as String?,
        contextWindow: (j['contextWindow'] as num?)?.toInt(),
      );
}

class AgentPreset {
  final String id;
  final String name;
  final String description;
  AgentPreset({required this.id, required this.name, required this.description});
  factory AgentPreset.fromJson(Map<String, dynamic> j) => AgentPreset(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        description: j['description'] as String? ?? '',
      );
}

class PermissionPreset {
  final String id;
  final String name;
  final String description;
  PermissionPreset({required this.id, required this.name, required this.description});
  factory PermissionPreset.fromJson(Map<String, dynamic> j) => PermissionPreset(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        description: j['description'] as String? ?? '',
      );
}

class Catalog {
  final List<CatalogModel> models;
  final List<String> reasoningEfforts;
  final List<PermissionPreset> permissionPresets;
  final List<AgentPreset> agentPresets;
  final Map<String, dynamic> defaults;
  Catalog({
    required this.models,
    required this.reasoningEfforts,
    required this.permissionPresets,
    required this.agentPresets,
    required this.defaults,
  });
  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
        models: (j['models'] as List? ?? []).map((e) => CatalogModel.fromJson(e as Map<String, dynamic>)).toList(),
        reasoningEfforts: (j['reasoningEfforts'] as List? ?? []).map((e) => e as String).toList(),
        permissionPresets: (j['permissionPresets'] as List? ?? []).map((e) => PermissionPreset.fromJson(e as Map<String, dynamic>)).toList(),
        agentPresets: (j['agentPresets'] as List? ?? []).map((e) => AgentPreset.fromJson(e as Map<String, dynamic>)).toList(),
        defaults: (j['defaults'] as Map<String, dynamic>?) ?? {},
      );
}

class SessionConfig {
  final String? model;
  final String? reasoningEffort;
  final String? permissionPreset;
  final String? agentPreset;
  SessionConfig({this.model, this.reasoningEffort, this.permissionPreset, this.agentPreset});
  factory SessionConfig.fromJson(Map<String, dynamic> j) => SessionConfig(
        model: j['model'] as String?,
        reasoningEffort: j['reasoningEffort'] as String?,
        permissionPreset: j['permissionPreset'] as String?,
        agentPreset: j['agentPreset'] as String?,
      );
}

class AppNotification {
  final String id;
  final String kind;
  final String sessionId;
  final String title;
  final String detail;
  final int time;
  final bool unread;
  AppNotification({
    required this.id,
    required this.kind,
    required this.sessionId,
    required this.title,
    required this.detail,
    required this.time,
    required this.unread,
  });
  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        kind: j['kind'] as String,
        sessionId: j['sessionId'] as String,
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        time: (j['time'] as num?)?.toInt() ?? 0,
        unread: j['unread'] as bool? ?? false,
      );
}

// 消息流事件（服务端摘要格式）
class ChatEvent {
  final int? seq;
  final String type;
  final Map<String, dynamic>? data;
  ChatEvent({this.seq, required this.type, this.data});
  factory ChatEvent.fromJson(Map<String, dynamic> j) => ChatEvent(
        seq: (j['seq'] as num?)?.toInt(),
        type: j['type'] as String,
        data: j['data'] as Map<String, dynamic>?,
      );
}

// ── 内核问询/审批弹窗（question/requested · approval/requested，与 PC 端同一通道） ──

class AskOption {
  final String label;
  final String? description;
  AskOption({required this.label, this.description});
  factory AskOption.fromJson(Map<String, dynamic> j) =>
      AskOption(label: j['label'] as String? ?? '', description: j['description'] as String?);
}

class AskQuestion {
  final String id;
  final String question;
  final String? header;
  final String? detail;
  final List<AskOption> options;
  final bool multiSelect;
  final Map<String, dynamic>? intent; // { kind: 'plan-review', approve: 'label' }
  AskQuestion({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.options = const [],
    this.multiSelect = false,
    this.intent,
  });
  factory AskQuestion.fromJson(Map<String, dynamic> j) => AskQuestion(
        id: j['id'] as String? ?? '',
        question: j['question'] as String? ?? '',
        header: j['header'] as String?,
        detail: j['detail'] as String?,
        options: (j['options'] as List? ?? [])
            .map((o) => AskOption.fromJson(o as Map<String, dynamic>))
            .toList(),
        multiSelect: j['multiSelect'] == true,
        intent: j['intent'] as Map<String, dynamic>?,
      );
}

/// question/requested 帧整体：rpcId 用于应答回写。
class QuestionRequest {
  final String rpcId;
  final String sessionId;
  final List<AskQuestion> questions;
  QuestionRequest({required this.rpcId, required this.sessionId, required this.questions});
}

/// approval/requested 帧整体：工具权限审批。
class ApprovalRequest {
  final String rpcId;
  final String sessionId;
  final String approvalId;
  final String toolName;
  final String? callId;
  final String? reason;
  ApprovalRequest({
    required this.rpcId,
    required this.sessionId,
    required this.approvalId,
    required this.toolName,
    this.callId,
    this.reason,
  });
}
