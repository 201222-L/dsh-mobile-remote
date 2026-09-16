// v3.1.4（issue #13）逻辑单测：轮次结束的兜底补拉判定
// —— 本轮有真人提问、但没有更晚的回复条目（内容被静默吞掉）时必须补拉一次。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('needsTurnEndResync（轮次兜底补拉判定）', () {
    test('有提问、无任何回复 → 需要补拉', () {
      expect(needsTurnEndResync(lastUserSeq: 40, lastAssistantSeq: null), isTrue);
    });

    test('有提问、回复更早（上一轮）→ 需要补拉', () {
      expect(needsTurnEndResync(lastUserSeq: 40, lastAssistantSeq: 27), isTrue);
    });

    test('回复晚于提问 → 正常，不补拉', () {
      expect(needsTurnEndResync(lastUserSeq: 40, lastAssistantSeq: 44), isFalse);
    });

    test('本轮没有真人提问（只有注入/系统消息）→ 不补拉', () {
      expect(needsTurnEndResync(lastUserSeq: null, lastAssistantSeq: null), isFalse);
      expect(needsTurnEndResync(lastUserSeq: null, lastAssistantSeq: 44), isFalse);
    });
  });
}
