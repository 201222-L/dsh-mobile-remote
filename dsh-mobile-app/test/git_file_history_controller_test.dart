// 文件提交历史控制器的 c3 回归：picker 重开、最近文件持久化、loadingMore 竞态。
import 'dart:async';

import 'package:dsh_mobile_app/git_file_history_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'git_history_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  GitFileHistoryController make(HistoryGitApi api) => GitFileHistoryController(
    api: api,
    sessionId: 'session-1',
    repositoryId: 'repo-1',
  );

  test('reopening the picker clears the previous query and reloads all files', () async {
    final api = HistoryGitApi();
    final controller = make(api);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.pickerOpen, isTrue);
    expect(api.fileQueries, [null]);

    controller.setPickerQuery('b.');
    await Future<void>.delayed(controller.debounce + const Duration(milliseconds: 60));
    expect(api.fileQueries.last, 'b.');
    expect(controller.files, ['lib/b.dart']);

    controller.closePicker();
    controller.openPicker();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // 重开后输入框为空，服务端也必须按“无 q”重新取全量。
    expect(controller.pickerQuery, isEmpty);
    expect(api.fileQueries.last, isNull);
    expect(controller.files, ['lib/a.dart', 'lib/b.dart', 'new-file.txt']);
  });

  test('file prefilled before initialize is persisted to recent files', () async {
    final first = make(HistoryGitApi());
    // 深链场景：selectFile 发生在 initialize 读取 prefs 之前。
    await first.selectFile('lib/a.dart');
    expect(first.selectedPath, 'lib/a.dart');
    await first.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    first.dispose();

    // 重建控制器（同一仓库）后仍能读到该最近文件。
    final second = make(HistoryGitApi());
    addTearDown(second.dispose);
    await second.initialize(autoOpenPickerWhenEmpty: false);
    expect(second.recentFiles, contains('lib/a.dart'));
  });

  test('refresh cancels a stuck load-more spinner', () async {
    final api = HistoryGitApi()..pageOneCount = 20;
    final gate = Completer<GitFileHistoryPage>();
    api.pageTwoGate = gate;

    final controller = make(api);
    addTearDown(controller.dispose);
    await controller.selectFile('lib/a.dart');
    expect(controller.nextCursor, 'cursor-2');

    final more = controller.loadMore();
    expect(controller.loadingMore, isTrue);

    // 刷新会作废 in-flight loadMore：footer spinner 必须收起。
    await controller.refresh();
    expect(controller.loadingMore, isFalse);

    gate.complete(const GitFileHistoryPage());
    await more;
    expect(controller.loadingMore, isFalse);
    expect(controller.loadingHistory, isFalse);
  });
}
