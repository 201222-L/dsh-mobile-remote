// 对话操作栏顺序的持久化与「新增动作」迁移。
//
// 背景：rail 的动作集合在 issue #15 从 3 项变为 4 项（新增 'files'）。旧设备上
// 存的是 3 项顺序，必须被判为无效并回退默认，而不是原样恢复出一个缺项的顺序。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile_app/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认顺序包含文件入口，且 Git 之后紧跟它', () async {
    final store = AppStore();
    await store.loadPrefs();

    expect(store.conversationActionOrder, [
      'git',
      'files',
      'session_tools',
      'copy',
    ]);
    expect(AppStore.conversationActionIds, contains('files'));
  });

  test('自定义顺序跨启动持久化', () async {
    final store = AppStore();
    await store.loadPrefs();
    await store.setConversationActionOrder([
      'copy',
      'files',
      'session_tools',
      'git',
    ]);

    final restored = AppStore();
    await restored.loadPrefs();

    expect(restored.conversationActionOrder, [
      'copy',
      'files',
      'session_tools',
      'git',
    ]);
  });

  test('旧版 3 项顺序被判无效并回退到含 files 的新默认', () async {
    // 升级前设备上真实存在的值
    SharedPreferences.setMockInitialValues({
      'dsh_mr_conversation_action_order': '["git","session_tools","copy"]',
    });
    final store = AppStore();

    await store.loadPrefs();

    expect(store.conversationActionOrder, [
      'git',
      'files',
      'session_tools',
      'copy',
    ]);
  });

  test('未知动作或多/少项都判无效并回退默认', () async {
    for (final raw in [
      '["git","files","session_tools","unknown"]',
      '["git","files"]',
      '["git","files","files","copy"]',
    ]) {
      SharedPreferences.setMockInitialValues({
        'dsh_mr_conversation_action_order': raw,
      });
      final store = AppStore();
      await store.loadPrefs();
      expect(
        store.conversationActionOrder,
        ['git', 'files', 'session_tools', 'copy'],
        reason: '$raw 应回退默认',
      );
    }
  });

  test('写入必须覆盖全部动作，否则拒绝', () async {
    final store = AppStore();
    await store.loadPrefs();

    await expectLater(
      store.setConversationActionOrder(['git', 'files']),
      throwsArgumentError,
    );
    await expectLater(
      store.setConversationActionOrder(['git', 'files', 'session_tools', 'nope']),
      throwsArgumentError,
    );
  });
}
