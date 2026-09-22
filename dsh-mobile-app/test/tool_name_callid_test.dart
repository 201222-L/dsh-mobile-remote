import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/timeline.dart';

/// v3.1.5 修复回归：**调用 id 不是工具名**。
///
/// 真机现象：历史回放里已结束的工具卡标题显示裸 `call_00_...`，而进行中的那张正常显示
/// `pwsh`。根因是服务端 `tool/result` 摘要在拿不到工具名时用 callId 兜底写进 `name`，
/// 而 App 的合并规则 `data['name'] ?? … ?? current?.name` 让结果事件覆盖了调用事件
/// 学到的真名——只有带结果的调用在历史里才有 `tool/result`，所以恰好呈现
/// 「历史=裸 id / 实时=真名」这种只有一边坏的分裂现象。
ChatEvent ev(int seq, String type, [Map<String, dynamic>? data, bool detail = true]) =>
    ChatEvent(seq: seq, type: type, data: data, detailAvailable: detail);

void main() {
  test('tool/result 的 name 等于 callId 时不得夺走 tool/call 学到的真名', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(2763, 'tool/call', {
      'callId': 'call_00_qsoESVurH3mUUP2nJzQ63823',
      'name': 'pwsh',
      'arguments': '{"command":"git status"}',
    }));
    expect(reducer.tools['call_00_qsoESVurH3mUUP2nJzQ63823']?.name, 'pwsh');
    expect(reducer.items.single.toolName, 'pwsh');

    // 服务端旧行为：结果事件把 callId 当 name 下发
    reducer.apply(ev(2764, 'tool/result', {
      'callId': 'call_00_qsoESVurH3mUUP2nJzQ63823',
      'name': 'call_00_qsoESVurH3mUUP2nJzQ63823',
      'isError': false,
      'text': 'ok',
    }));

    expect(reducer.tools['call_00_qsoESVurH3mUUP2nJzQ63823']?.name, 'pwsh',
        reason: '结果事件只能补充结果，不能改写工具名');
    expect(reducer.items.single.toolName, 'pwsh', reason: '卡片标题必须仍是工具名，而不是裸 callId');
    expect(reducer.items.single.status, 'success');
    expect(reducer.items.single.text, 'ok');
  });

  test('结果带真实错误名（如 UserQuestionError）时仍然采用', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'tool/call', {'callId': 'c-ask', 'name': 'ask_user_question'}));
    reducer.apply(ev(2, 'tool/result', {'callId': 'c-ask', 'name': 'UserQuestionError', 'isError': true, 'text': 'cancelled'}));
    expect(reducer.tools['c-ask']?.name, 'UserQuestionError',
        reason: '错误名是有效语义，不能被「跳过 callId」的规则误伤');
    expect(reducer.items.single.toolName, 'UserQuestionError');
  });

  test('无前置调用时，name == callId 视为未知并回落「工具」，绝不显示裸 id', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'tool/result', {'callId': 'call_orphan', 'name': 'call_orphan', 'text': 'orphan result'}));
    final name = reducer.tools['call_orphan']?.name;
    expect(name, isNot('call_orphan'));
    expect(name, '工具');
    expect(reducer.items.single.toolName, '工具');
  });

  test('timelineToolNameOf：name / toolCall 双别名，且跳过等于 callId 的值', () {
    expect(timelineToolNameOf({'name': 'pwsh'}, callId: 'c1', fallback: '工具'), 'pwsh');
    expect(timelineToolNameOf({'toolCall': 'shell'}, callId: 'c1', fallback: '工具'), 'shell');
    expect(timelineToolNameOf({'name': 'c1'}, callId: 'c1', fallback: '工具'), '工具');
    // name 是 callId 但别名有真名时，仍应取到真名
    expect(timelineToolNameOf({'name': 'c1', 'toolCall': 'read_file'}, callId: 'c1', fallback: '工具'), 'read_file');
    expect(timelineToolNameOf(null, callId: 'c1', fallback: '工具'), '工具');
    expect(timelineToolNameOf({'name': ''}, callId: 'c1', fallback: '工具'), '工具');
  });

  test('历史回放整体不变量：所有工具卡标题都不是 callId，且与实时路径一致', () {
    final history = TimelineReducer();
    final live = TimelineReducer();
    final records = [
      ev(1, 'tool/call', {'callId': 'call_a', 'name': 'pwsh', 'arguments': '{}'}),
      ev(2, 'tool/result', {'callId': 'call_a', 'name': 'call_a', 'text': 'done'}),
      ev(3, 'tool/call', {'callId': 'call_b', 'name': 'read_image', 'arguments': '{}'}),
      ev(4, 'tool/result', {'callId': 'call_b', 'name': 'call_b', 'text': 'done'}),
    ];
    for (final record in records) {
      history.apply(record);
      live.apply(record);
    }
    final titles = history.items
        .where((item) => item.kind == TimelineItemKind.tool)
        .map((item) => item.toolName)
        .toList();
    expect(titles, ['pwsh', 'read_image']);
    expect(titles.any((title) => (title ?? '').startsWith('call_')), isFalse);
    expect(history.items.map((i) => i.toolName), live.items.map((i) => i.toolName));
  });
}
