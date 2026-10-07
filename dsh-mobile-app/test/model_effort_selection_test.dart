import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/sheets.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = Catalog.fromJson({
    'defaults': {'provider': 'desktop', 'model': 'default-model'},
    'models': [
      {
        'provider': 'a',
        'id': 'alpha',
        'name': 'Alpha',
        'reasoning': {
          'defaultEffort': 'off',
          'efforts': [
            {'id': 'off', 'name': 'Disabled', 'description': 'No reasoning'},
            {'id': 'high', 'name': 'High'},
          ],
        },
      },
      {
        'provider': 'b',
        'id': 'beta',
        'name': 'Beta',
        'reasoning': {
          'defaultEffort': 'medium',
          'efforts': [
            {'id': 'medium', 'name': 'Medium'},
          ],
        },
      },
      {'provider': 'c', 'id': 'plain', 'name': 'Plain'},
    ],
  });

  test(
    '目录按模型解析推理能力；无 reasoning 即不支持显式强度',
    () {
      expect(catalog.models[0].reasoning!.defaultEffort, 'off');
      expect(catalog.models[0].reasoning!.efforts.first.name, 'Disabled');
      expect(
        catalog.models[0].reasoning!.efforts.first.description,
        'No reasoning',
      );
      expect(catalog.models[1].reasoning!.efforts.single.id, 'medium');
      expect(catalog.models[2].reasoning, isNull);
    },
  );

  test('新建会话默认取电脑部署选择，不借用当前会话', () {
    final existing = SessionConfig.fromJson({
      'provider': 'different',
      'model': 'current',
      'reasoningEffort': 'high',
    });
    final draft = NewSessionModelDraft();
    expect(draft.createFields, isEmpty);
    expect(existing.model, 'current');
    draft.selectModel(catalog.models.first);
    expect(draft.createFields, {'provider': 'a', 'model': 'alpha'});
    expect(existing.model, 'current');
  });

  test(
    'off 与跟随默认不同；切换模型清除旧强度',
    () {
      final draft = NewSessionModelDraft()..selectModel(catalog.models.first);
      draft.selectEffort('off');
      expect(draft.createFields, {
        'provider': 'a',
        'model': 'alpha',
        'reasoningEffort': 'off',
      });
      draft.selectEffort(null);
      expect(draft.createFields, {'provider': 'a', 'model': 'alpha'});
      draft.selectEffort('high');
      draft.selectModel(catalog.models[1]);
      expect(draft.createFields, {'provider': 'b', 'model': 'beta'});
      expect(() => draft.selectEffort('high'), throwsArgumentError);
      draft.selectModel(catalog.models[2]);
      expect(draft.createFields, {'provider': 'c', 'model': 'plain'});
      expect(() => draft.selectEffort('off'), throwsArgumentError);
      draft.selectModel(null);
      expect(draft.createFields, isEmpty);
    },
  );

  test('目录变动时禁止失效模型或强度二次提交后静默降级', () {
    final draft = NewSessionModelDraft()..selectModel(catalog.models.first);
    draft.selectEffort('high');
    final refreshed = Catalog.fromJson({
      'models': [
        {'provider': 'a', 'id': 'alpha', 'name': 'Alpha', 'reasoning': {
          'defaultEffort': 'off',
          'efforts': [{'id': 'off', 'name': 'Off'}],
        }},
      ],
    });
    draft.reconcile(refreshed);
    expect(draft.needsEffortReselection, isTrue);
    expect(() => draft.createFields, throwsStateError);
    draft.selectEffort(null); // 用户明确确认采用该模型默认
    expect(draft.createFields, {'provider': 'a', 'model': 'alpha'});
    draft.reconcile(Catalog.fromJson({'models': []}));
    expect(draft.needsModelReselection, isTrue);
    expect(() => draft.createFields, throwsStateError);
    draft.selectModel(null); // 用户明确确认切回部署默认
    expect(draft.createFields, isEmpty);
  });

  test('会话配置能读取内核具体化的 off 强度', () {
    final config = SessionConfig.fromJson({'reasoningEffort': 'off'});
    expect(config.reasoningEffort, 'off');
  });

  testWidgets(
    '草稿选择器只显示当前模型等级且不修改现有会话',
    (tester) async {
      final store = AppStore()
        ..catalog = catalog
        ..sessionConfig = SessionConfig(
          provider: 'b',
          model: 'beta',
          reasoningEffort: 'medium',
        );
      final draft = NewSessionModelDraft();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModelSheet(context, store, draft: draft),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.text('推理强度'), findsNothing);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('跟随模型默认'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Medium'), findsNothing);
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();
      expect(draft.createFields, {
        'provider': 'a',
        'model': 'alpha',
        'reasoningEffort': 'off',
      });
      expect(store.sessionConfig.model, 'beta');
      expect(store.sessionConfig.reasoningEffort, 'medium');
      await tester.tap(find.text('Plain'));
      await tester.pumpAndSettle();
      expect(find.text('推理强度'), findsNothing);
      expect(find.text('此模型不提供推理强度选择'), findsOneWidget);
      expect(draft.createFields, {'provider': 'c', 'model': 'plain'});
      expect(store.sessionConfig.model, 'beta');
    },
  );
}
