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

    test('截断后的前缀里含 NUL 仍判为二进制', () {
      final bytes = [...List<int>.filled(10, 0x61), 0x00, ...List<int>.filled(kPreviewByteLimit, 0x62)];
      expect(buildPreview(bytes), isA<PreviewUnavailable>());
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
}
