// #24 复核补正回归：详情文本钳制 + 敏感/协议类型的可见性。
//
// 背景（复核实测）：
// 1) 详情端点返回的是**原始事件**（上限 8 MiB），而摘要是 clamp 过的 —— 不钳制会直接把
//    超长工具结果送进 markdown 解析与文本布局；
// 2) 内核真实存在 `session/title-llm-request`（data 含 system prompt 与 messages）与
//    `web/deepseek-search-llm-request`，此前不在任何隐藏集合里 → 会以裸类型名出现在
//    普通模式，并可经详情端点取回原始载荷。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/timeline.dart';

void main() {
  group('clampTimelineDetailText', () {
    test('短文本原样返回', () {
      expect(clampTimelineDetailText('hello'), 'hello');
    });

    test('恰好等于上限不截断', () {
      final exact = 'y' * timelineDetailTextMax;
      expect(clampTimelineDetailText(exact), exact);
    });

    test('超长文本截断、保留前缀并标注总字数', () {
      final long = 'x' * 50000;
      final out = clampTimelineDetailText(long);
      expect(out.length, lessThan(long.length));
      expect(out.startsWith('x' * 1000), isTrue);
      expect(out, contains('详情已截断'));
      expect(out, contains('50000'));
    });
  });

  group('敏感与协议类型的可见性', () {
    test('LLM 请求快照（含 system prompt / messages）在两种模式下都不可见', () {
      for (final t in [
        'session/title-llm-request',
        'web/deepseek-search-llm-request',
        'request/header',
        'system/message',
        'compaction/summary',
      ]) {
        expect(hiddenTimelineTypes.contains(t), isTrue, reason: '$t 必须在隐藏集合里');
        expect(timelineTypeVisibleIn(TimelineMode.ordinary, t), isFalse, reason: '$t 普通模式不可见');
        expect(timelineTypeVisibleIn(TimelineMode.debug, t), isFalse, reason: '$t 调试模式也不可见');
      }
    });

    test('llm-request 按后缀判定：未来厂商变体同样不可见，且不误伤普通类型', () {
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'web/future-provider-llm-request'), isFalse);
      expect(timelineTypeVisibleIn(TimelineMode.debug, 'web/future-provider-llm-request'), isFalse);
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'future/llm-request-note'), isTrue, reason: '只匹配后缀，不误伤');
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'future/visible'), isTrue);
    });

    test('补齐的协议/运行时类型：普通模式隐藏、调试模式可见', () {
      for (final t in [
        'plan/mode',
        'permission/preset',
        'schedule/change',
        'hook/invoked',
        'hook/result',
        'llm/retry',
        'deliverables/presented',
        'tool-workflow/run-start',
        'tool-workflow/run-end',
        'subagent/model-selection-policy',
      ]) {
        expect(timelineTypeVisibleIn(TimelineMode.ordinary, t), isFalse, reason: '$t 普通模式应隐藏');
        expect(timelineTypeVisibleIn(TimelineMode.debug, t), isTrue, reason: '$t 调试模式应可见');
      }
    });

    test('真正未知的新类型仍然保留（事件保真契约：不静默丢弃）', () {
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'future/something-new'), isTrue);
      expect(timelineTypeVisibleIn(TimelineMode.debug, 'future/something-new'), isTrue);
    });
  });

  group('issue #73：plugin:* 插件协议事件只在调试模式展示', () {
    test('plugin:translator/request|result 普通模式隐藏、调试模式可见', () {
      for (final type in [
        'plugin:translator/request',
        'plugin:translator/result',
      ]) {
        expect(pluginEventTypePattern.hasMatch(type), isTrue, reason: type);
        expect(timelineTypeVisibleIn(TimelineMode.ordinary, type), isFalse,
            reason: '$type 普通模式不渲染协议噪声');
        expect(timelineTypeVisibleIn(TimelineMode.debug, type), isTrue,
            reason: '$type 调试模式保留排障能力');
        expect(hiddenTimelineTypes.contains(type), isFalse,
            reason: '$type 不进永隐藏清单（否则调试也看不到）');
        expect(debugOnlyTimelineTypes.contains(type), isFalse,
            reason: '$type 由前缀模式覆盖，不必逐个枚举');
      }
    });

    test('只匹配 plugin: 命名空间，不误伤其它前缀', () {
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'pluginx/request'), isTrue);
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'plugin/request'), isTrue);
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'tool/plugin:foo'), isTrue);
    });

    test('事件仍进 TimelineReducer 模型（seq 游标/去重不受影响），仅标记普通模式过滤', () {
      final reducer = TimelineReducer();
      reducer.apply(ChatEvent(seq: 7, type: 'plugin:translator/request'));
      reducer.apply(ChatEvent(seq: 8, type: 'future/something-new'));
      expect(reducer.items, hasLength(2), reason: '两类事件都必须保留在模型中');
      final plugin = reducer.items.firstWhere((item) => item.type.startsWith('plugin:'));
      expect(plugin.seq, 7);
      expect(plugin.visibleIn(TimelineMode.ordinary), isFalse);
      expect(plugin.visibleIn(TimelineMode.debug), isTrue);
      final future = reducer.items.firstWhere((item) => item.type == 'future/something-new');
      expect(future.visibleIn(TimelineMode.ordinary), isTrue, reason: '未知内核事件保持可见契约');
      expect(future.visibleIn(TimelineMode.debug), isTrue);
    });
  });
}
