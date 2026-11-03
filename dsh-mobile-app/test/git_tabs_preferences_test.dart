import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile_app/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Git tabs default to all current views in product order', () async {
    final store = AppStore();
    await store.loadPrefs();

    expect(store.gitTabs, ['branches', 'graph', 'worktree']);
  });

  test('Git tab visibility and order persist across app restarts', () async {
    final store = AppStore();
    await store.loadPrefs();
    await store.setGitTabs(['worktree', 'branches']);

    final restored = AppStore();
    await restored.loadPrefs();

    expect(restored.gitTabs, ['worktree', 'branches']);
  });

  test('invalid saved tabs recover to the default selection', () async {
    SharedPreferences.setMockInitialValues({
      'dsh_mr_git_tabs': '["graph","graph","unknown"]',
    });
    final store = AppStore();

    await store.loadPrefs();

    expect(store.gitTabs, ['branches', 'graph', 'worktree']);
  });

  test('tab preferences require one to three unique known tabs', () async {
    final store = AppStore();
    await store.loadPrefs();

    await expectLater(store.setGitTabs([]), throwsArgumentError);
    await expectLater(
      store.setGitTabs(['branches', 'graph', 'worktree', 'other']),
      throwsArgumentError,
    );
    await expectLater(
      store.setGitTabs(['graph', 'graph']),
      throwsArgumentError,
    );
    await expectLater(store.setGitTabs(['other']), throwsArgumentError);
  });

  test(
    'file history is an optional known tab and defaults stay unchanged',
    () async {
      expect(AppStore.gitTabIds, [
        'branches',
        'graph',
        'worktree',
        'fileHistory',
      ]);
      final store = AppStore();
      await store.loadPrefs();
      expect(store.gitTabs, ['branches', 'graph', 'worktree']);

      await store.setGitTabs(['fileHistory']);
      expect(store.gitTabs, ['fileHistory']);

      final restored = AppStore();
      await restored.loadPrefs();
      expect(restored.gitTabs, ['fileHistory']);

      // 仍然最多 3 个：四个候选不能全选。
      await expectLater(
        store.setGitTabs(['branches', 'graph', 'worktree', 'fileHistory']),
        throwsArgumentError,
      );
      await expectLater(
        store.setGitTabs(['fileHistory', 'fileHistory']),
        throwsArgumentError,
      );
      await expectLater(
        store.setGitTabs(['fileHistory', 'unknown']),
        throwsArgumentError,
      );
    },
  );
}
