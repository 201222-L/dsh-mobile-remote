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
}
