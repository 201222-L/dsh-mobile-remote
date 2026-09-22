import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/timeline.dart';

ChatEvent ev(int seq, String type, [Map<String, dynamic>? data, bool detail = true]) =>
    ChatEvent(seq: seq, type: type, data: data, detailAvailable: detail);

void main() {
  test('history/live-shaped delivery converges and tool call/result share callId', () {
    TimelineReducer history = TimelineReducer();
    TimelineReducer live = TimelineReducer();
    final records = [
      ev(1, 'user/message', {'text': 'inspect'}),
      ev(2, 'tool/call', {'callId': 'c1', 'name': 'read_file', 'arguments': '{"path":"a"}'}),
      ev(3, 'tool/result', {'callId': 'c1', 'isError': false, 'text': 'ok'}),
      ev(4, 'future/event', {'value': 42}),
    ];
    for (final record in records) {
      history.apply(record);
      live.apply(record);
    }
    expect(history.items.map((i) => i.type), live.items.map((i) => i.type));
    expect(history.tools['c1']?.status, 'success');
    expect(history.tools['c1']?.result, 'ok');
    expect(history.items.where((i) => i.kind == TimelineItemKind.tool), hasLength(1));
    expect(history.items.any((i) => i.type == 'future/event'), isTrue);
  });

  test('reversed history moves a settled tool card back to invocation position', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(3, 'tool/result', {'callId': 'reverse', 'text': 'done'}));
    reducer.apply(ev(2, 'tool/call', {'callId': 'reverse', 'name': 'shell', 'arguments': 'ls'}));
    expect(reducer.items.single.callId, 'reverse');
    expect(reducer.items.single.status, 'success');
    expect(reducer.items.single.seq, 2);
    // 结果已在模型中：详情指针仍指向信息量更大的结果事件，不被调用事件覆盖
    expect(reducer.tools['reverse']?.detailSeq, 3);
  });

  test('assistant/live-chunk uses canonical callId and is not historical surface', () {
    final reducer = TimelineReducer();
    expect(reducer.apply(ev(20, 'assistant/live-chunk', {'callId': 'c2', 'toolCall': 'shell', 'argumentsDelta': 'ls'})), isTrue);
    expect(reducer.tools['c2']?.arguments, 'ls');
    expect(reducer.items.where((i) => i.kind == TimelineItemKind.tool), hasLength(1));
  });

  test('tool/call 的完整 arguments 替换流式 delta，而不是追加（参数不得重复）', () {
    final reducer = TimelineReducer();
    // 实时路径：先来 tool-call-delta 建立卡片，再来 tool/call 携带整串实参
    // （内核 appendToolCall 落盘的就是 block.arguments 整串）。
    reducer.apply(ev(1, 'assistant/live-chunk', {'callId': 'c9', 'toolCall': 'shell', 'argumentsDelta': '{"comm'}));
    expect(reducer.tools['c9']?.arguments, '{"comm');
    reducer.apply(ev(2, 'tool/call', {'callId': 'c9', 'name': 'shell', 'arguments': '{"command":"ls"}'}));
    expect(reducer.tools['c9']?.arguments, '{"command":"ls"}');
    expect(reducer.items.where((i) => i.kind == TimelineItemKind.tool), hasLength(1));
  });

  test('锚点 seq 取调用事件：delta 先到也不会让历史/实时错位', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'assistant/live-chunk', {'callId': 'c3', 'toolCall': 'shell', 'argumentsDelta': 'ls'}));
    reducer.apply(ev(5, 'tool/call', {'callId': 'c3', 'name': 'shell', 'arguments': 'ls'}));
    expect(reducer.tools['c3']?.seq, 5);
    expect(reducer.items.singleWhere((i) => i.kind == TimelineItemKind.tool).seq, 5);
    // 反向顺序（调用先到、delta 后到）必须保持调用位置
    final late = TimelineReducer();
    late.apply(ev(1, 'tool/call', {'callId': 'c4', 'name': 'shell', 'arguments': 'ls'}));
    late.apply(ev(2, 'assistant/live-chunk', {'callId': 'c4', 'argumentsDelta': '-la'}));
    expect(late.tools['c4']?.seq, 1);
  });

  test('detailSeq 只指向 durable 事件（call/result），不指向历史里不存在的 delta', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'assistant/live-chunk', {'callId': 'c5', 'toolCall': 'shell', 'argumentsDelta': 'ls'}));
    reducer.apply(ev(5, 'tool/call', {'callId': 'c5', 'name': 'shell', 'arguments': 'ls'}));
    expect(reducer.tools['c5']?.detailSeq, 5);
    reducer.apply(ev(9, 'tool/result', {'callId': 'c5', 'text': 'ok'}));
    expect(reducer.tools['c5']?.detailSeq, 9);
    expect(reducer.tools['c5']?.latestSeq, 9);
  });

  test('tool/result 保留图片元数据；文件元数据不再下发（issue #1 需求变更）', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'tool/result', {
      'callId': 'c6',
      'text': 'ok',
      'images': [{'attachmentId': 'att-1', 'mediaType': 'image/png'}],
    }));
    expect(reducer.tools['c6']?.files, isEmpty);
    expect(reducer.tools['c6']?.images.single['attachmentId'], 'att-1');
  });

  test('duplicate sequence is ignored and missing call id is explicitly incomplete', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'tool/call', {'name': 'shell', 'arguments': 'ls'}));
    reducer.apply(ev(1, 'tool/call', {'name': 'shell', 'arguments': 'ls'}));
    expect(reducer.items.where((i) => i.kind == TimelineItemKind.tool), hasLength(1));
    expect(reducer.tools.keys.single, startsWith('unavailable-'));
  });

  test('ordinary mode marks runtime injections while debug mode keeps them visible', () {
    final ordinary = TimelineReducer();
    final debug = TimelineReducer();
    final injection = ev(1, 'user/message', {
      'text': 'Current runtime context: secret',
      'sourceKind': 'plugin',
    });
    ordinary.apply(injection);
    debug.apply(injection);
    expect(ordinary.items.single.visibleIn(TimelineMode.ordinary), isFalse);
    expect(debug.items.single.visibleIn(TimelineMode.debug), isTrue);
  });

  test('协议元数据普通模式折叠但保留在模型中；重建/压缩快照两种模式都不进模型', () {
    final ordinary = TimelineReducer();
    final debug = TimelineReducer();
    final records = [
      ev(1, 'model/selection', {'model': 'x'}),
      ev(2, 'compaction/summary', {'summary': 'SNAPSHOT'}),
      ev(3, 'assistant/attempt', {'stream': []}),
      ev(4, 'compaction/end', {'compactionId': 'cmp'}),
    ];
    for (final record in records) {
      ordinary.apply(record);
      debug.apply(record);
    }
    // 协议元数据保留（seq/详情指针不丢），只是普通模式不渲染
    expect(ordinary.items.map((i) => i.type), ['model/selection']);
    expect(ordinary.items.single.visibleIn(TimelineMode.ordinary), isFalse);
    expect(debug.items.map((i) => i.type), ['model/selection']);
    expect(debug.items.single.visibleIn(TimelineMode.debug), isTrue);
  });

  test('durable 审批事件普通模式可见且有可读标题（历史回放）', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(1, 'approval/asked', {'toolName': 'shell', 'reason': '需要授权'}));
    final item = reducer.items.single;
    expect(item.visibleIn(TimelineMode.ordinary), isTrue);
    expect(item.title, isNot('approval/asked'));
  });

  test('unknown event preserves detail availability and raw summary data', () {
    final reducer = TimelineReducer();
    reducer.apply(ev(9, 'new/visible-event', {'nested': {'answer': 7}}));
    final item = reducer.items.single;
    expect(item.kind, TimelineItemKind.event);
    expect(item.detailAvailable, isTrue);
    expect(item.data['nested'], {'answer': 7});
  });

  test('详情正文只认服务端规范化 text，绝不从 content 拼接 reasoning（issue #1 需求变更）', () {
    // 服务端给了规范化正文：直接采用。
    expect(timelineDetailText({'text': 'VISIBLE-BODY'}), 'VISIBLE-BODY');
    // 未给（旧服务端 / 非 assistant）：返回 null，调用方保持原正文——
    // 不得回退到递归拼接 message.content（那会把 reasoning 并进正文，使思维链重复）。
    expect(
      timelineDetailText({
        'message': {
          'content': [
            {'type': 'reasoning', 'text': 'THINKING-CHAIN'},
            {'type': 'text', 'text': 'VISIBLE-BODY'},
          ],
        },
      }),
      isNull,
    );
    expect(timelineDetailText(const {}), isNull);
    expect(timelineDetailText({'text': 42}), isNull);
  });

  test('详情增量判定：textChars 大于可见正文长度才提示有增量', () {
    expect(timelineHasTextIncrement(200, 71), isTrue);
    expect(timelineHasTextIncrement(71, 71), isFalse); // 与摘要相同 → 普通模式不显示加载入口
    expect(timelineHasTextIncrement(70, 71), isFalse);
    expect(timelineHasTextIncrement(null, 71), isFalse); // 无提示（旧服务端/非 assistant）→ 不显示
  });

  test('assistant 事件把详情长度提示带入时间线模型', () {
    final reducer = TimelineReducer();
    reducer.apply(ChatEvent(
      seq: 1,
      type: 'assistant/message',
      data: {'text': 'BODY'},
      detailAvailable: true,
      detailTextChars: 500,
    ));
    expect(reducer.items.single.detailTextChars, 500);
    expect(timelineHasTextIncrement(reducer.items.single.detailTextChars, 4), isTrue);
  });
}
