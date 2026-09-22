// issue #15「复制整段对话」的纯函数单测：顺序 / 跳过空行 / 角色标注。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/chat_copy.dart';

void main() {
  test('按时间正序拼接：角色标注 + 行间空行', () {
    expect(conversationText([('你', '你好'), ('助手', '收到')]), '你：你好\n\n助手：收到');
  });

  test('空白正文的行被跳过（图像占位 / 轮次分隔条不导出）', () {
    expect(conversationText([('你', '你好'), ('', ''), ('助手', '   ')]), '你：你好');
  });

  test('正文内部换行保留，首尾空白去掉', () {
    expect(conversationText([('助手', '  第一行\n第二行  ')]), '助手：第一行\n第二行');
  });

  test('全部为空 → 空串（调用方据此提示「没有可复制内容」）', () {
    expect(conversationText([('你', ''), ('助手', '\n')]), '');
  });

  test('注入行按调用方给的标签导出（不伪装成真人发言）', () {
    expect(conversationText([('系统注入', 'runtime context'), ('你', '好')]), '系统注入：runtime context\n\n你：好');
  });
}
