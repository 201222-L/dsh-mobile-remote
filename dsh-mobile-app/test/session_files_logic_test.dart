// Seam 1：会话文件浏览纯逻辑（路径、二进制判定、截断、行号、面包屑）。
//
// 只断言外部行为：给定字节/路径，函数返回什么。不锁死内部实现。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/session_files_logic.dart';

void main() {
  group('joinBrowsePath', () {
    test('根视图下钻直接返回子项', () {
      expect(joinBrowsePath('', 'home', '/'), 'home');
    });

    test('非根路径用服务端分隔符拼接', () {
      expect(joinBrowsePath('/home/mark', 'projects', '/'), '/home/mark/projects');
    });

    test('父路径已带尾分隔符时不重复', () {
      expect(joinBrowsePath('/home/', 'mark', '/'), '/home/mark');
    });

    test('Windows 分隔符同样处理', () {
      expect(joinBrowsePath(r'C:\Users', 'mark', r'\'), r'C:\Users\mark');
    });
  });

  group('parentBrowsePath', () {
    test('普通路径去掉最后一段', () {
      expect(parentBrowsePath('/home/mark/projects', '/'), '/home/mark');
    });

    test('POSIX 根的上级仍是根', () {
      expect(parentBrowsePath('/home', '/'), '/');
    });

    test('无分隔符时返回空串（根视图）', () {
      expect(parentBrowsePath('home', '/'), '');
    });

    test('带尾分隔符时先归一', () {
      expect(parentBrowsePath('/home/mark/', '/'), '/home');
    });
  });

  group('looksBinary', () {
    test('纯文本不算二进制', () {
      expect(looksBinary(utf8.encode('hello 世界')), isFalse);
    });

    test('含 NUL 字节判为二进制', () {
      expect(looksBinary([0x68, 0x00, 0x69]), isTrue);
    });

    test('空内容不算二进制', () {
      expect(looksBinary(const []), isFalse);
    });
  });

  group('buildPreview', () {
    test('文本内容原样解码且未截断', () {
      final v = buildPreview(utf8.encode('第一行\n第二行'));
      expect(v, isA<PreviewText>());
      v as PreviewText;
      expect(v.text, '第一行\n第二行');
      expect(v.truncated, isFalse);
      expect(v.bytesShown, utf8.encode('第一行\n第二行').length);
    });

    test('二进制给出不可预览原因而不是乱码', () {
      final v = buildPreview([0x00, 0x01, 0x02]);
      expect(v, isA<PreviewUnavailable>());
      expect((v as PreviewUnavailable).reason, contains('二进制'));
    });

    test('超出上限即截断且标注字节数', () {
      final big = List<int>.filled(kPreviewByteLimit + 10, 0x61); // 'a'
      final v = buildPreview(big) as PreviewText;
      expect(v.truncated, isTrue);
      expect(v.bytesShown, kPreviewByteLimit);
      expect(v.text.length, kPreviewByteLimit);
    });

    test('恰好等于上限不截断', () {
      final exact = List<int>.filled(kPreviewByteLimit, 0x61);
      final v = buildPreview(exact) as PreviewText;
      expect(v.truncated, isFalse);
    });

    test('截断切开多字节字符时不抛异常', () {
      // 让最后一个字节落在多字节字符中间
      final head = List<int>.filled(kPreviewByteLimit - 1, 0x61);
      final bytes = [...head, 0xE4, 0xB8]; // 不完整的 3 字节序列
      final v = buildPreview(bytes) as PreviewText;
      expect(v.truncated, isTrue);
      expect(v.text, isNotEmpty);
    });

    test('含 NUL 且解不出像样的 UTF-16 → 仍是二进制', () {
      // PNG 魔数 + 伪随机字节：按 UTF-16 解会得到大量控制字符/非常用区段
      final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      for (var i = 0; i < 512; i++) {
        bytes.add((i * 53 + 7) % 256);
      }
      expect(buildPreview(bytes), isA<PreviewUnavailable>());
    });

    test('含 NUL 但整体是干净的 UTF-16 文本 → 按 UTF-16 展示（有意为之）', () {
      // v3.2.2：无 BOM 的 UTF-16 与"二进制"在字节层面无法绝对区分。
      // 判据改成"试解后像不像文本"：像就按 UTF-16 显示，不像才说二进制。
      final bytes = <int>[];
      for (final unit in '干净的 UTF-16 文本\n'.codeUnits) {
        bytes.add(unit & 0xFF);
        bytes.add((unit >> 8) & 0xFF);
      }
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf16le);
      expect(buildPreview(bytes), isA<PreviewText>());
    });
  });

  group('encoding', () {
    List<int> utf16le(String text, {bool bom = true}) {
      final out = <int>[if (bom) 0xFF, if (bom) 0xFE];
      for (final unit in text.codeUnits) {
        out.add(unit & 0xFF);
        out.add((unit >> 8) & 0xFF);
      }
      return out;
    }

    List<int> utf16be(String text, {bool bom = true}) {
      final out = <int>[if (bom) 0xFE, if (bom) 0xFF];
      for (final unit in text.codeUnits) {
        out.add((unit >> 8) & 0xFF);
        out.add(unit & 0xFF);
      }
      return out;
    }

    test('UTF-8 BOM 被识别并剥离', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('hi')];
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf8);
      final v = buildPreview(bytes) as PreviewText;
      expect(v.text, 'hi');
    });

    test('UTF-16LE BOM 正常解码中文', () {
      final bytes = utf16le('# 标题\n');
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf16le);
      final v = buildPreview(bytes) as PreviewText;
      expect(v.text, '# 标题\n');
    });

    test('UTF-16BE BOM 正常解码中文', () {
      final bytes = utf16be('# 标题\n');
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf16be);
      final v = buildPreview(bytes) as PreviewText;
      expect(v.text, '# 标题\n');
    });

    test('无 BOM 的 ASCII UTF-16LE 也能识别', () {
      final bytes = utf16le('hello world', bom: false);
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf16le);
      expect((buildPreview(bytes) as PreviewText).text, 'hello world');
    });

    test('GBK 字节被识别为 GB18030（平台解码前明确提示）', () {
      final bytes = [0xB1, 0xA8, 0xB8, 0xE6]; // “报告”的 GBK
      expect(detectPreviewEncoding(bytes), PreviewEncoding.gb18030);
      final v = buildPreview(bytes);
      expect(v, isA<PreviewUnavailable>());
      expect((v as PreviewUnavailable).reason, contains('GB18030'));
    });

    test('真正的二进制仍判二进制', () {
      expect(detectPreviewEncoding([0x00, 0x01, 0x02]), PreviewEncoding.binary);
      expect(buildPreview([0x00, 0x01, 0x02]), isA<PreviewUnavailable>());
    });

    test('中文为主的**无 BOM** UTF-16LE 不再被当成二进制（真机回归）', () {
      // 旧启发式只看"高字节为 0 的比例"，中文码元高字节非 0，比例立刻掉下来
      final bytes = utf16le('这一行是中文：你好，世界。混排 English 12345。', bom: false);
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf16le);
      final v = buildPreview(bytes);
      expect(v, isA<PreviewText>());
      expect((v as PreviewText).text, contains('你好'));
    });

    test('无 BOM UTF-16BE 同样靠试解打分识别', () {
      final bytes = utf16be('中文为主的一段话，带 English 与 123。', bom: false);
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf16be);
    });

    test('大段 UTF-8 中文在 4096 字节处被切开，仍判 UTF-8（真机乱码回归）', () {
      // '中' 是 3 字节；4096 % 3 == 1 → 采样正好切在一个汉字中间
      final bytes = utf8.encode('中' * 3000);
      expect(bytes.length, 9000);
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf8);
      final v = buildPreview(bytes);
      expect(v, isA<PreviewText>());
      expect((v as PreviewText).text, startsWith('中中中'));
    });

    test('四字节 emoji 被切开也不误判', () {
      final bytes = utf8.encode('${'😀' * 1200}');
      expect(detectPreviewEncoding(bytes), PreviewEncoding.utf8);
    });

    test('高熵二进制（含 NUL）不会被试解打分误判成 UTF-16', () {
      final bytes = <int>[];
      for (var i = 0; i < 64; i++) {
        bytes.add((i * 37 + 11) % 256);
      }
      bytes[0] = 0;
      expect(detectPreviewEncoding(bytes), PreviewEncoding.binary);
    });
  });

  group('previewLines', () {
    test('按行切分', () {
      expect(previewLines('a\nb\nc'), ['a', 'b', 'c']);
    });

    test('空内容返回一个空行（保证行号 1 存在）', () {
      expect(previewLines(''), ['']);
    });

    test('CRLF 归一为 LF，不留下回车', () {
      expect(previewLines('a\r\nb'), ['a', 'b']);
    });

    test('孤立 CR 也当换行', () {
      expect(previewLines('a\rb'), ['a', 'b']);
    });

    test('末尾换行产生末尾空行', () {
      expect(previewLines('a\n'), ['a', '']);
    });
  });

  group('browseBreadcrumbs', () {
    test('POSIX 绝对路径从根开始逐级', () {
      final c = browseBreadcrumbs('/home/mark/projects', '/');
      expect(c.map((e) => e.label).toList(), ['/', 'home', 'mark', 'projects']);
      expect(c.map((e) => e.path).toList(),
          ['/', '/home', '/home/mark', '/home/mark/projects']);
    });

    test('根路径只有一项', () {
      final c = browseBreadcrumbs('/', '/');
      expect(c.length, 1);
      expect(c.first.label, '/');
    });

    test('空路径没有面包屑', () {
      expect(browseBreadcrumbs('', '/'), isEmpty);
    });

    test('Windows 路径按反斜杠切分', () {
      final c = browseBreadcrumbs(r'C:\Users\mark', r'\');
      expect(c.map((e) => e.label).toList(), ['C:', 'Users', 'mark']);
    });
  });

  group('isWithinRoot（夹在会话工作目录内）', () {
    test('根本身算在内', () {
      expect(isWithinRoot('/home/mark', '/home/mark'), isTrue);
    });

    test('子路径算在内', () {
      expect(isWithinRoot('/home/mark', '/home/mark/projects'), isTrue);
    });

    test('父路径不算在内', () {
      expect(isWithinRoot('/home/mark', '/home'), isFalse);
    });

    test('同前缀但不是子目录不算在内', () {
      expect(isWithinRoot('/home/mark', '/home/mark2'), isFalse);
    });

    test('根为空时不限制（尚未确定浏览根）', () {
      expect(isWithinRoot('', '/anywhere'), isTrue);
    });

    // 真机 bug：Windows 下点进子目录被当成越界（分隔符写死 '/'）
    test('Windows 反斜杠路径：向下是允许的', () {
      expect(isWithinRoot(r'E:\Work\proj', r'E:\Work\proj\sub'), isTrue);
      expect(isWithinRoot(r'E:\Work\proj', r'E:\Work\proj\a\b'), isTrue);
    });

    test('Windows 盘符路径大小写不敏感', () {
      expect(isWithinRoot(r'E:\Work\proj', r'e:\work\PROJ\sub'), isTrue);
      expect(isWithinRoot(r'E:\Work\proj', r'E:\WORK\PROJ'), isTrue);
    });

    test('Windows：同名前缀、上级目录都算越界', () {
      expect(isWithinRoot(r'E:\Work\proj', r'E:\Work\proj2'), isFalse);
      expect(isWithinRoot(r'E:\Work\proj', r'E:\Work'), isFalse);
      expect(isWithinRoot(r'E:\Work\proj', r'D:\Work\proj\sub'), isFalse);
    });

    test('混用分隔符也能正确判定', () {
      expect(isWithinRoot(r'E:\Work\proj', 'E:/Work/proj/sub'), isTrue);
      expect(isWithinRoot('E:/Work/proj', r'E:\Work\proj\sub'), isTrue);
    });
  });

  group('limitDirEntries', () {
    test('未超上限时全部保留且无隐藏计数', () {
      final r = limitDirEntries(['a', 'b'], ['c']);
      expect(r.dirs, ['a', 'b']);
      expect(r.files, ['c']);
      expect(r.hiddenCount, 0);
      expect(r.total, 3);
    });

    test('超过上限时优先保留目录并给出隐藏数与总数', () {
      final dirs = List.generate(kDirEntryRenderLimit + 20, (i) => 'd$i');
      final files = List.generate(10, (i) => 'f$i');
      final r = limitDirEntries(dirs, files);
      expect(r.dirs.length, kDirEntryRenderLimit);
      expect(r.files, isEmpty);
      expect(r.hiddenCount, 30);
      expect(r.total, kDirEntryRenderLimit + 30);
    });

    test('目录占满后仍有余量时分给文件', () {
      final dirs = List.generate(kDirEntryRenderLimit - 5, (i) => 'd$i');
      final files = List.generate(100, (i) => 'f$i');
      final r = limitDirEntries(dirs, files);
      expect(r.dirs.length, kDirEntryRenderLimit - 5);
      expect(r.files.length, 5);
      expect(r.hiddenCount, 95);
    });
  });

  group('isMarkdownPath', () {
    test('识别 .md / .markdown，大小写不敏感', () {
      expect(isMarkdownPath('/work/README.md'), isTrue);
      expect(isMarkdownPath('/work/CHANGELOG.MD'), isTrue);
      expect(isMarkdownPath('/work/notes.markdown'), isTrue);
    });

    test('其它扩展名不算 Markdown', () {
      expect(isMarkdownPath('/work/notes.txt'), isFalse);
      expect(isMarkdownPath('/work/main.dart'), isFalse);
      expect(isMarkdownPath('/work/md'), isFalse);
      expect(isMarkdownPath(''), isFalse);
    });
  });

  group('chunkMarkdownText', () {
    test('空文本不产生分片', () {
      expect(chunkMarkdownText(''), isEmpty);
    });

    test('短文本只有一片且内容不变', () {
      const text = '# 标题\n\n正文一段\n';
      final chunks = chunkMarkdownText(text);
      expect(chunks.length, 1);
      expect(chunks.single, text);
    });

    test('超过上限后在空行处切开，且拼回去与原文一致', () {
      final sb = StringBuffer();
      for (var i = 0; i < 200; i++) {
        sb.write('## 小节 $i\n\n这是第 $i 段正文，用来把体积撑到上限以上。\n\n');
      }
      final text = sb.toString();
      final chunks = chunkMarkdownText(text, maxChars: 500);
      expect(chunks.length, greaterThan(1));
      expect(chunks.join('\n'), text);
      // 每片（除最后）都应接近上限，不该碎成一句一片。
      // 上限按「每行 len+1」累计，而 join('\n') 后比累计值少 1 个换行，故留 10% 余量。
      for (final c in chunks.take(chunks.length - 1)) {
        expect(c.length, greaterThanOrEqualTo(450));
      }
    });

    test('围栏代码块内部不切分', () {
      final code = List.generate(200, (i) => 'line $i // padding').join('\n');
      final text = '前言\n\n```dart\n$code\n```\n\n结尾\n';
      final chunks = chunkMarkdownText(text, maxChars: 200);
      // 代码块必须整块落在同一片里
      final idx = chunks.indexWhere((c) => c.contains('```dart'));
      expect(idx, isNot(-1));
      expect(chunks[idx].contains('line 0'), isTrue);
      expect(chunks[idx].contains('line 199'), isTrue);
      expect(chunks[idx].contains('结尾'), isFalse);
      expect(chunks.join('\n'), text);
    });

    test('没有空行的超长块会被硬切，但仍能拼回原文', () {
      final text = List.generate(500, (i) => 'x' * 40).join('\n');
      final chunks = chunkMarkdownText(text, maxChars: 100);
      expect(chunks.length, greaterThan(1));
      expect(chunks.join('\n'), text);
    });
  });
}
