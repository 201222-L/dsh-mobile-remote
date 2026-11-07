// issue #53：轮末产出物纯逻辑（模型解析、去重、坐标、行内链接、负缓存）的单元测试。

import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('轮末信号', () {
    test('TurnTail 只在有信号时构造；turnTails 忽略非法 key/值', () {
      expect(TurnTail.fromJson({'changes': true}), const TurnTail(changes: true));
      expect(TurnTail.fromJson({'presented': true}), const TurnTail(presented: true));
      expect(TurnTail.fromJson({'changes': false, 'presented': false}), isNull);
      expect(TurnTail.fromJson(null), isNull);
      final tails = turnTailsFromJson({
        '2': {'changes': true, 'presented': true},
        '3': {'changes': true},
        'x': {'changes': true},
        '4': <String, dynamic>{},
      });
      expect(tails.length, 2);
      expect(tails[2], const TurnTail(changes: true, presented: true));
      expect(tails[3], const TurnTail(changes: true));
    });

    test('ChatEvent 解析 turn/end 的 tail；HistoryPage 解析 turnTails', () {
      final event = ChatEvent.fromJson({
        'seq': 9,
        'type': 'turn/end',
        'data': {
          'turn': 2,
          'reason': {'kind': 'completed'},
          'tail': {'changes': true, 'presented': true},
        },
      });
      expect(event.tail, const TurnTail(changes: true, presented: true));
      final page = HistoryPage(
        events: const [],
        turnTails: const {2: TurnTail(changes: true)},
      );
      expect(page.turnTails[2]?.changes, isTrue);
    });

    test('TurnTailCapabilities：旧插件缺省时 available=false', () {
      expect(const TurnTailCapabilities().available, isFalse);
      final legacy = TurnTailCapabilities.fromJson(null);
      expect(legacy.available, isFalse);
      final current = TurnTailCapabilities.fromJson({
        'version': 1,
        'presented': true,
        'changed': true,
        'changesDiff': false,
      });
      expect(current.available, isTrue);
      expect(current.changed, isTrue);
      expect(current.changesDiff, isFalse);
    });
  });

  group('交付文件声明', () {
    test('deliverableFilesOf 保持事件内下标并跳过空条目', () {
      final files = deliverableFilesOf(42, {
        'files': [
          {'name': 'a.ts', 'display': 'src/a.ts', 'description': '交付'},
          {'name': '', 'display': ''},
          {'name': 'b.pdf'},
        ],
      });
      expect(files.length, 2);
      expect(files[0].name, 'a.ts');
      expect(files[0].display, 'src/a.ts');
      expect(files[0].description, '交付');
      expect(files[0].seq, 42);
      expect(files[0].index, 0);
      expect(files[1].index, 2, reason: '下标是事件 files 数组下标，不能因跳过空条目而重排');
    });

    test('同轮多次 present 按路径去重、说明取最后一次声明', () {
      final merged = mergeDeliverableDeclarations(
        [
          const DeliverableFile(name: 'a.ts', display: 'src/a.ts', description: '旧说明', seq: 1, index: 0),
          const DeliverableFile(name: 'x.png', display: 'x.png', seq: 1, index: 1),
        ],
        [
          const DeliverableFile(name: 'a.ts', display: 'src/a.ts', description: '新说明', seq: 5, index: 0),
          const DeliverableFile(name: 'y.md', display: 'docs/y.md', seq: 5, index: 1),
        ],
      );
      expect(merged.length, 3);
      final a = merged.firstWhere((file) => file.display == 'src/a.ts');
      expect(a.description, '新说明');
      expect(a.seq, 5);
    });
  });

  group('行内链接解析', () {
    final resolver = TurnFileLinkResolver(
      sessionId: 's1',
      presented: const [
        DeliverableFile(name: 'a.ts', display: 'src/a.ts', seq: 10, index: 0),
        DeliverableFile(name: '报告.pdf', display: '~/Documents/报告.pdf', seq: 10, index: 1),
      ],
      changed: const [
        ChangedFile(seq: 20, index: 0, display: 'lib/a.ts', name: 'a.ts', added: 1, deleted: 0),
        ChangedFile(seq: 20, index: 1, display: 'lib/b.ts', name: 'b.ts', added: 1, deleted: 0),
      ],
    );

    test('精确路径优先', () {
      final hit = resolver.resolve('src/a.ts');
      expect(hit?.kind, TurnFileKind.presented);
      expect(hit?.seq, 10);
      final changed = resolver.resolve('lib/b.ts');
      expect(changed?.kind, TurnFileKind.changed);
      expect(changed?.seq, 20);
      expect(changed?.index, 1);
    });

    test('唯一 basename 次之', () {
      final hit = resolver.resolve('报告.pdf');
      expect(hit?.kind, TurnFileKind.presented);
      // `a.ts` 同时出现在 presented 与 changed → 有歧义，不链接。
      expect(resolver.resolve('a.ts'), isNull);
      expect(resolver.resolve('b.ts')?.index, 1, reason: '唯一 basename 命中改动文件');
    });

    test('未记录/歧义不链接', () {
      expect(resolver.resolve('unknown.ts'), isNull);
      expect(resolver.resolve(''), isNull);
      final empty = TurnFileLinkResolver(sessionId: 's1', presented: const []);
      expect(empty.resolve('a.ts'), isNull);
    });
  });

  group('改动摘要与负缓存', () {
    test('ChangesSummary 三态解析 + 文件字段', () {
      final available = ChangesSummary.fromJson({
        'state': 'available',
        'turn': 2,
        'files': [
          {'seq': 7, 'index': 0, 'display': 'src/a.ts', 'name': 'a.ts', 'added': 3, 'deleted': 1},
          {'seq': 7, 'index': 1, 'display': 'bin.dat', 'name': 'bin.dat', 'binary': true},
        ],
        'total': 2,
        'added': 3,
        'deleted': 1,
        'truncated': false,
      });
      expect(available.state, ChangesState.available);
      expect(available.hasFiles, isTrue);
      expect(available.files[0].seq, 7);
      expect(available.files[1].binary, isTrue);
      expect(ChangesSummary.fromJson({'state': 'absent', 'files': []}).state, ChangesState.absent);
      expect(ChangesSummary.fromJson({'state': 'weird'}).state, ChangesState.unavailable);
    });

    test('负结果短 TTL 缓存：unavailable 到期后可重试，available 缓存更久', () async {
      final cache = TurnTailSummaryCache(
        negativeTtl: const Duration(milliseconds: 20),
        availableTtl: const Duration(minutes: 1),
      );
      cache.store(1, ChangesSummary.fromJson({'state': 'unavailable'}));
      cache.store(2, ChangesSummary.fromJson({'state': 'available', 'files': []}));
      expect(cache.lookup(1)?.state, ChangesState.unavailable);
      expect(cache.lookup(2)?.state, ChangesState.available);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cache.lookup(1), isNull, reason: '负结果过期后允许重新拉取');
      expect(cache.lookup(2)?.state, ChangesState.available);
      cache.clear();
      expect(cache.lookup(2), isNull);
    });

    test('图片扩展名判定（仅 png/jpg/webp/gif）', () {
      expect(isPreviewableImageName('a.PNG'), isTrue);
      expect(isPreviewableImageName('a.jpg'), isTrue);
      expect(isPreviewableImageName('a.webp'), isTrue);
      expect(isPreviewableImageName('a.gif'), isTrue);
      expect(isPreviewableImageName('a.pdf'), isFalse);
      expect(isPreviewableImageName('noext'), isFalse);
    });
  });
}
