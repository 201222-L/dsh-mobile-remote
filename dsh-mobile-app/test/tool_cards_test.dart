// issue #54（M3 Batch 1）：工具卡纯逻辑（摘要解析、折叠行/统计/退出码/命中数、fail-open）。

import 'package:dsh_mobile_app/tool_cards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolCallSummary 解析', () {
    test('command 字段与缺省', () {
      final bash = ToolCallSummary.fromJson({
        'kind': 'command',
        'tool': 'bash',
        'command': 'ls -la',
        'workdir': 'src',
        'background': true,
        'description': 'List files',
      });
      expect(bash?.kind, ToolCardKind.command);
      expect(bash?.command, 'ls -la');
      expect(bash?.workdir, 'src');
      expect(bash?.background, isTrue);
      expect(bash?.description, 'List files');
      final minimal = ToolCallSummary.fromJson({'kind': 'command', 'tool': 'pwsh'});
      expect(minimal?.command, isNull);
      expect(minimal?.renderable, isFalse, reason: '缺 command → 回退通用卡');
    });

    test('file 字段：read 行范围 / write sizeKb+diff / edit added-deleted', () {
      final read = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'read',
        'filePath': 'src/a.ts',
        'offset': 2,
        'limit': 40,
      });
      expect(read?.filePath, 'src/a.ts');
      expect(read?.offset, 2);
      expect(read?.limit, 40);
      final write = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'write',
        'filePath': 'src/new.ts',
        'sizeKb': 3,
        'diff': '--- /dev/null\n+++ b/src/new.ts\n@@ -0,0 +1,1 @@\n+hi\n',
      });
      expect(write?.sizeKb, 3);
      expect(toolHasInlineDiff(write!), isTrue);
      final edit = ToolCallSummary.fromJson({
        'kind': 'file',
        'tool': 'edit',
        'filePath': 'src/a.ts',
        'sizeKb': 1,
        'added': 2,
        'deleted': 1,
        'diffTruncated': true,
      });
      expect(edit?.added, 2);
      expect(edit?.deleted, 1);
      expect(edit?.diffTruncated, isTrue);
      expect(toolHasInlineDiff(edit!), isFalse);
    });

    test('search/web/image 字段；失败字段逐项降级', () {
      final grep = ToolCallSummary.fromJson({
        'kind': 'search',
        'tool': 'grep',
        'pattern': 'foo',
        'path': 'lib',
        'include': '*.ts',
      });
      expect(grep?.pattern, 'foo');
      expect(grep?.path, 'lib');
      expect(grep?.include, '*.ts');
      final web = ToolCallSummary.fromJson({
        'kind': 'web',
        'tool': 'web_fetch',
        'url': 'https://x.test',
      });
      expect(web?.url, 'https://x.test');
      final image = ToolCallSummary.fromJson({
        'kind': 'image',
        'tool': 'read_image',
        'filePath': 'p.png',
      });
      expect(image?.filePath, 'p.png');
      // 非法 kind/tool/字段类型：整卡或单字段降级，不抛错。
      expect(ToolCallSummary.fromJson({'kind': 'mystery', 'tool': 'x'}), isNull);
      expect(ToolCallSummary.fromJson({'kind': 'command'}), isNull);
      expect(ToolCallSummary.fromJson(null), isNull);
      final weird = ToolCallSummary.fromJson({
        'kind': 'command',
        'tool': 'bash',
        'command': 42,
        'background': 'yes',
      });
      expect(weird?.command, isNull);
      expect(weird?.background, isFalse);
    });
  });

  group('ToolResultSummary 与展示文案', () {
    test('退出码/信号/停止/命中数解析（空对象为 null）', () {
      expect(ToolResultSummary.fromJson({'exitCode': 2})?.exitCode, 2);
      expect(ToolResultSummary.fromJson({'signal': 'SIGTERM'})?.signal, 'SIGTERM');
      expect(ToolResultSummary.fromJson({'stopped': 'cancelled'})?.stopped, 'cancelled');
      expect(ToolResultSummary.fromJson({'resultCount': 3})?.resultCount, 3);
      expect(ToolResultSummary.fromJson(<String, dynamic>{}), isNull);
      expect(ToolResultSummary.fromJson(null), isNull);
    });

    test('折叠行主文案', () {
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.command, tool: 'bash', command: 'ls')),
        '\$ ls',
      );
      expect(
        toolFoldText(const ToolCallSummary(
          kind: ToolCardKind.file,
          tool: 'read',
          filePath: 'src/a.ts',
          offset: 2,
          limit: 4,
        )),
        'src/a.ts · 行 2–5',
      );
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.search, tool: 'grep', pattern: 'foo', path: 'lib')),
        'foo · lib',
      );
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.web, tool: 'web_fetch', url: 'https://x')),
        'https://x',
      );
      expect(
        toolFoldText(const ToolCallSummary(kind: ToolCardKind.image, tool: 'read_image', filePath: 'p.png')),
        'p.png',
      );
    });

    test('文件统计 / 退出码胶囊 / 命中数胶囊', () {
      expect(
        toolFileStats(const ToolCallSummary(
          kind: ToolCardKind.file,
          tool: 'edit',
          filePath: 'a.ts',
          sizeKb: 2,
          added: 3,
          deleted: 1,
        )),
        '2KB · +3 −1',
      );
      expect(toolFileStats(const ToolCallSummary(kind: ToolCardKind.command, tool: 'bash')), isNull);
      expect(toolExitBadge(const ToolResultSummary(exitCode: 0)), isNull);
      expect(toolExitBadge(const ToolResultSummary(exitCode: 2)), 'exit 2');
      expect(toolExitBadge(const ToolResultSummary(signal: 'SIGTERM', exitCode: 2)), 'signal: SIGTERM');
      expect(toolExitBadge(const ToolResultSummary(stopped: 'cancelled')), '已停止');
      final grep = const ToolCallSummary(kind: ToolCardKind.search, tool: 'grep', pattern: 'foo');
      expect(toolResultCountBadge(grep, const ToolResultSummary(resultCount: 7)), '7 个匹配');
      expect(toolResultCountBadge(grep, null), isNull);
    });
  });
}
