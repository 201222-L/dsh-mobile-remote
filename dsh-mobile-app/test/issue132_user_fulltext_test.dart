// issue #132：长用户消息“查看全文”无效 + 入口移入消息卡内 + 成功后隐藏。
//
// 需求（GitLab #132）：
//   - 入口在用户消息气泡**内部底部**，固定 36dp footer 槽；短消息/仅图片/注入不显示；
//   - 加载中 footer 转圈「加载全文…」；成功后正文变完整、入口隐藏（槽保留 → 卡片高度不变）；
//   - 旧插件（rc.5）详情没有 canonical `data.text`：必须显式错误 + 重试 + toast，
//     不得静默当成功；能力缺失/网络失败/413 同样显式错误 + 重试；
//   - 完整正文仍在 320dp 内层滚动，不撑高外层时间线；显式 `detailLoaded`，不再用
//     `text.length >= 2000` 把已加载状态判回截断；
//   - 退出/重进按摘要重建 → 重新显示截断正文 + 入口。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue132_user_fulltext_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _session = 'session-132';
const String _versionError = '宿主机版本过旧，无法读取完整正文';
const String _genericError = '完整正文加载失败，请重试';
const String _endMarker = 'END-OF-USER-MESSAGE';

final String _summary = 'H' * 2000;
final String _full = '$_summary\n$_endMarker';

Map<String, dynamic> _turnStart(int turn) => {
  'seq': 1,
  'type': 'turn/start',
  'data': {'turn': turn},
  'time': 1000,
};

Map<String, dynamic> _userEvent({
  required String text,
  bool detailAvailable = true,
  Map<String, dynamic>? detail,
  List<Map<String, dynamic>> images = const [],
  String? sourceKind = 'user',
}) => {
  'seq': 2,
  'type': 'user/message',
  'data': {
    'messageId': 'u1',
    'text': text,
    'sourceKind': sourceKind,
    if (images.isNotEmpty) 'images': images,
  },
  if (detailAvailable)
    'detail':
        detail ?? {'available': true, 'seq': 2, 'textChars': _full.length},
  'time': 1100,
};

List<Map<String, dynamic>> _historyEvents({
  required String userText,
  bool detailAvailable = true,
  Map<String, dynamic>? detail,
  List<Map<String, dynamic>> images = const [],
  String? sourceKind = 'user',
}) => [
  _turnStart(1),
  _userEvent(
    text: userText,
    detailAvailable: detailAvailable,
    detail: detail,
    images: images,
    sourceKind: sourceKind,
  ),
  {
    'seq': 3,
    'type': 'assistant/message',
    'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '收到'},
    'time': 1200,
  },
  {
    'seq': 4,
    'type': 'turn/end',
    'data': {
      'turn': 1,
      'reason': {'kind': 'completed'},
    },
    'time': 1300,
  },
];

Map<String, dynamic> _detailEvent(String text) => {
  'seq': 2,
  'type': 'user/message',
  'data': {'messageId': 'u1', 'text': text, 'sourceKind': 'user'},
};

/// rc.5 现状：详情只回原始事件（data 无 canonical `text`）。
Map<String, dynamic> _legacyDetailEvent(String text) => {
  'seq': 2,
  'type': 'user/message',
  'data': {
    'messageId': 'u1',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

class _Backend {
  _Backend({required this.events, this.capabilityDetail = true});

  final List<Map<String, dynamic>> events;
  final bool capabilityDetail;
  int detailRequests = 0;

  /// 逐次消费的详情响应；为空时返回 500（测试必须显式声明预期）。
  final List<Future<http.Response> Function()> detailResponses = [];
  Completer<void>? detailGate;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue132.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: capabilityDetail,
      unknownEvents: true,
      callCorrelation: true,
    );

  http.Response json(Map<String, dynamic> body, {int status = 200}) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  http.Response okEvent(Map<String, dynamic> event) =>
      json({'ok': true, 'event': event});

  http.Response fail({
    String code = 'event-detail-unavailable',
    int status = 500,
  }) => json({'ok': false, 'error': code}, status: status);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/m/api/history') {
      return json({'ok': true, 'events': events, 'hasMore': false});
    }
    if (path == '/m/api/event-detail') {
      detailRequests += 1;
      final gate = detailGate;
      if (gate != null) await gate.future;
      if (detailResponses.isNotEmpty) {
        return detailResponses.removeAt(0)();
      }
      return fail();
    }
    if (path == '/m/api/queue') return json({'ok': true, 'rows': <Object>[]});
    if (path == '/m/api/todos') return json({'ok': true, 'todos': <Object>[]});
    if (path == '/m/api/session-config') {
      return json({'ok': true, 'config': <String, dynamic>{}});
    }
    return json({'ok': true});
  }
}

Future<void> _finish(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 900));
  store.dispose();
}

Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  Size size = const Size(390, 844),
  bool dark = false,
  double textScale = 1.0,
  String keySuffix = 'main',
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)];
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? DshTheme.forSkin(DshSkin.dsh, Brightness.dark) : null,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: ChatScreen(
            key: ValueKey<String>('issue132-$keySuffix'),
            store: store,
            apiClient: backend.api,
            onTitleChanged: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 200));
  return store;
}

Future<void> _pumpDetail(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _footerFor(int seq) => find.byKey(userDetailFooterKeyFor(seq));
Finder _bubbleFor(int seq) => find.byKey(userMessageBubbleKeyFor(seq));

void main() {
  testWidgets('成功：入口在气泡内底部；加载中转圈；成功后隐藏且卡片高度不变', (tester) async {
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailGate = Completer<void>();
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(_full)),
    );
    final store = await _mount(tester, backend);

    final bubble = _bubbleFor(2);
    final footer = _footerFor(2);
    expect(bubble, findsOneWidget);
    expect(footer, findsOneWidget, reason: '长消息应在气泡内部有固定 footer 槽');
    expect(
      find.descendant(of: bubble, matching: footer),
      findsOneWidget,
      reason: '入口必须在用户气泡内部底部，不能挂在气泡外',
    );
    expect(tester.getSize(footer).height, userDetailFooterHeight);
    final heightBefore = tester.getSize(bubble).height;
    final maxScrollBefore = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .maxScrollExtent;

    await tester.tap(find.text('查看全文'));
    await tester.pump();
    // 响应被 Completer 挂起：只 pump 一帧就应看到加载态。
    expect(find.text('加载全文…'), findsOneWidget);
    expect(backend.detailRequests, 1);
    expect(find.text('查看全文'), findsNothing);
    expect(
      find.descendant(
        of: bubble,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
      reason: '加载中 footer 内应有转圈',
    );

    backend.detailGate!.complete();
    await _pumpDetail(tester);
    expect(find.textContaining(_endMarker), findsOneWidget, reason: '完整正文必须可达');
    expect(find.text('查看全文'), findsNothing, reason: '成功后入口必须隐藏');
    expect(find.text('加载全文…'), findsNothing);
    expect(_footerFor(2), findsOneWidget, reason: '槽保留（内容清空）以维持卡片高度');
    expect(tester.getSize(_footerFor(2)).height, userDetailFooterHeight);
    expect(
      tester.getSize(bubble).height,
      closeTo(heightBefore, 0.5),
      reason: '成功加载后卡片高度不得变化（槽 maintainSize）',
    );
    expect(
      tester.getSize(bubble).height,
      lessThanOrEqualTo(
        // 320dp 正文 + 36dp footer + 气泡内边距 16 + 外边距 4。
        transcriptBodyMaxHeight + userDetailFooterHeight + 20 + 0.5,
      ),
      reason: '完整正文仍受 320dp 上限约束',
    );
    expect(
      find.descendant(of: bubble, matching: find.byType(SingleChildScrollView)),
      findsOneWidget,
      reason: '完整正文在卡内滚动，不撑高外层时间线',
    );
    final pos = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    expect(
      pos.maxScrollExtent,
      lessThanOrEqualTo(maxScrollBefore + 0.5),
      reason: '入口隐藏/正文更新不得新增大段外层滚动高度',
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('声明 textChars=5000 但 canonical 只有 2500：incomplete，不隐藏入口', (
    tester,
  ) async {
    final partial = '$_summary\nPARTIAL-END';
    final backend = _Backend(
      events: _historyEvents(
        userText: _summary,
        detail: {'available': true, 'seq': 2, 'textChars': 5000},
      ),
    );
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(partial)),
    );
    final store = await _mount(tester, backend);
    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);

    final footer = _footerFor(2);
    expect(
      find.descendant(of: footer, matching: find.text('详情正文不完整，请重试')),
      findsOneWidget,
      reason: 'canonical 少于声明的 textChars 时必须显式 incomplete，不得当成功',
    );
    expect(
      find.descendant(of: footer, matching: find.text('重试')),
      findsOneWidget,
    );
    expect(
      find.textContaining('PARTIAL-END'),
      findsOneWidget,
      reason: '已拿到的更长部分可以展示，但仍保留入口',
    );
    expect(find.text('查看全文'), findsNothing, reason: '保留 footer，不回到入口态');
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('canonical 覆盖声明 textChars：才可标记完整并隐藏入口', (tester) async {
    final complete = '$_summary\nCOVERS-DECLARED-LENGTH';
    final backend = _Backend(
      events: _historyEvents(
        userText: _summary,
        detail: {'available': true, 'seq': 2, 'textChars': complete.length},
      ),
    );
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(complete)),
    );
    final store = await _mount(tester, backend);
    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);

    expect(find.textContaining('COVERS-DECLARED-LENGTH'), findsOneWidget);
    expect(find.text('查看全文'), findsNothing);
    expect(find.text('详情正文不完整，请重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('canonical 超过 20k 渲染上限：不得虚假成功，footer 保留受限态', (tester) async {
    final over = '${'X' * 20500}\n$_endMarker';
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(over)),
    );
    final store = await _mount(tester, backend);

    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    final footer = _footerFor(2);
    expect(
      find.descendant(
        of: footer,
        matching: find.textContaining('正文超过 20000 字'),
      ),
      findsOneWidget,
      reason: '被 20k 渲染上限截断时必须显式受限态，不能隐藏入口当成功',
    );
    expect(
      find.descendant(of: footer, matching: find.text('重试')),
      findsOneWidget,
    );
    expect(find.text(_endMarker), findsNothing, reason: '>20k 的尾部不可达；不得宣称完整');
    expect(find.text('查看全文'), findsNothing, reason: '受限态保留 footer，不回到入口');
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('缺 textChars + canonical 与摘要等长：显式 no-growth，不无条件成功', (
    tester,
  ) async {
    final complete = 'H' * 2000;
    final backend = _Backend(
      events: _historyEvents(
        userText: complete,
        detail: {'available': true, 'seq': 2},
      ),
    );
    // 旧插件/未来插件都可能没有 textChars；服务端返回与摘要等长的 canonical
    // （恰好 2000 字的完整消息也是这种形状）——无法确认完整性，必须显式报错。
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(complete)),
    );
    final store = await _mount(tester, backend);

    expect(find.text('查看全文'), findsOneWidget);
    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    final footer = _footerFor(2);
    expect(
      find.descendant(of: footer, matching: find.text('无法确认正文是否完整，请重试')),
      findsOneWidget,
      reason: '缺少 textChars 且无增长时必须显式 no-growth，不得隐藏入口',
    );
    expect(
      find.descendant(of: footer, matching: find.text('重试')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('旧插件 rc.5：详情无 canonical text → 显式错误 + 重试 + toast，不静默成功', (
    tester,
  ) async {
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailResponses.add(
      () async => backend.okEvent(_legacyDetailEvent(_full)),
    );
    backend.detailResponses.add(
      () async => backend.okEvent(_legacyDetailEvent(_full)),
    );
    final store = await _mount(tester, backend);

    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    expect(backend.detailRequests, 1);
    final footer = _footerFor(2);
    expect(
      find.descendant(of: footer, matching: find.text(_versionError)),
      findsOneWidget,
      reason: '旧插件必须显式提示版本过旧，而不是保留截断正文当成功',
    );
    expect(
      find.descendant(of: footer, matching: find.text('重试')),
      findsOneWidget,
    );
    expect(
      find.text(_versionError),
      findsWidgets,
      reason: '除 footer 外还应有 toast 提示',
    );
    expect(find.textContaining(_endMarker), findsNothing, reason: '不得把截断正文当完整');

    await tester.tap(find.text('重试'));
    await _pumpDetail(tester);
    expect(backend.detailRequests, 2, reason: '错误态必须允许重试');
    expect(
      find.descendant(of: footer, matching: find.text(_versionError)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('网络失败后重试成功：错误 → 重试 → 全文可达且入口隐藏', (tester) async {
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailResponses.add(
      () async => backend.fail(code: 'event-detail-unavailable', status: 500),
    );
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(_full)),
    );
    final store = await _mount(tester, backend);

    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    expect(backend.detailRequests, 1);
    expect(
      find.descendant(of: _footerFor(2), matching: find.text(_genericError)),
      findsOneWidget,
      reason: '网络失败必须显式错误（不静默）',
    );
    expect(
      find.descendant(of: _footerFor(2), matching: find.text('重试')),
      findsOneWidget,
    );

    await tester.tap(find.text('重试'));
    await _pumpDetail(tester);
    expect(backend.detailRequests, 2);
    expect(find.textContaining(_endMarker), findsOneWidget);
    expect(find.text('查看全文'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('详情 413：显式错误 + 重试，不出现点击无反应', (tester) async {
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailResponses.add(
      () async => backend.fail(code: 'payload-too-large', status: 413),
    );
    final store = await _mount(tester, backend);

    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    expect(
      find.descendant(of: _footerFor(2), matching: find.text(_genericError)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _footerFor(2), matching: find.text('重试')),
      findsOneWidget,
    );
    expect(find.text('查看全文'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('能力不支持：点入口显式错误 + 重试（不得静默 return）', (tester) async {
    final backend = _Backend(
      events: _historyEvents(userText: _summary),
      capabilityDetail: false,
    );
    final store = await _mount(tester, backend);

    expect(_footerFor(2), findsOneWidget, reason: '能力缺失也应有入口以便给出解释');
    await tester.tap(find.text('查看全文'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.detailRequests, 0, reason: '能力缺失不得发请求');
    expect(
      find.descendant(of: _footerFor(2), matching: find.text('当前连接不支持读取完整正文')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _footerFor(2), matching: find.text('重试')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('短消息 / 仅图片 / 注入消息：不出现 footer 槽', (tester) async {
    // 短消息（即便服务端声明 detail）。
    final shortBackend = _Backend(
      events: _historyEvents(
        userText: '短问题',
        detail: {'available': true, 'seq': 2, 'textChars': 3},
      ),
    );
    final shortStore = await _mount(tester, shortBackend, keySuffix: 'short');
    expect(find.text('查看全文'), findsNothing);
    expect(_footerFor(2), findsNothing);
    await _finish(tester, shortStore);

    // 仅图片（正文为空）。
    final imageOnlyBackend = _Backend(
      events: _historyEvents(
        userText: '',
        images: [
          {
            'attachmentId': 'sha256:img',
            'mediaType': 'image/png',
            'width': 10,
            'height': 10,
            'name': 'a.png',
          },
        ],
      ),
    );
    final imageStore = await _mount(tester, imageOnlyBackend, keySuffix: 'img');
    expect(find.text('查看全文'), findsNothing);
    expect(_footerFor(2), findsNothing);
    await _finish(tester, imageStore);

    // 注入消息（sourceKind != user）——普通模式不渲染成用户气泡，也不得有入口。
    final injectedBackend = _Backend(
      events: _historyEvents(userText: _summary, sourceKind: 'plugin'),
    );
    final injectedStore = await _mount(
      tester,
      injectedBackend,
      keySuffix: 'inj',
    );
    expect(find.text('查看全文'), findsNothing);
    expect(_footerFor(2), findsNothing);
    await _finish(tester, injectedStore);
  });

  testWidgets('退出重进：按摘要重建后重新显示截断正文 + 入口', (tester) async {
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailResponses.add(
      () async => backend.okEvent(_detailEvent(_full)),
    );
    final store = await _mount(tester, backend, keySuffix: 'first');
    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    expect(find.textContaining(_endMarker), findsOneWidget);
    expect(find.text('查看全文'), findsNothing);
    await _finish(tester, store);

    // 重新进入（新的 ChatScreen/Store，从 /history 的摘要重建）。
    final store2 = await _mount(tester, backend, keySuffix: 'second');
    expect(find.text('查看全文'), findsOneWidget, reason: '退出重进后应按摘要重新显示入口');
    expect(find.textContaining(_endMarker), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, store2);
  });

  testWidgets('320dp + 深色 + 1.5× 字号：错误态 footer 不溢出且槽高固定', (tester) async {
    final backend = _Backend(events: _historyEvents(userText: _summary));
    backend.detailResponses.add(
      () async => backend.okEvent(_legacyDetailEvent(_full)),
    );
    final store = await _mount(
      tester,
      backend,
      size: const Size(320, 640),
      dark: true,
      textScale: 1.5,
      keySuffix: 'narrow',
    );

    await tester.tap(find.text('查看全文'));
    await _pumpDetail(tester);
    expect(_footerFor(2), findsOneWidget);
    expect(tester.getSize(_footerFor(2)).height, userDetailFooterHeight);
    expect(
      find.descendant(of: _footerFor(2), matching: find.text('重试')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull, reason: '320dp/深色/1.5× 错误态不得溢出');
    final theme = Theme.of(tester.element(find.byType(ChatScreen)));
    expect(theme.brightness, Brightness.dark);
    await _finish(tester, store);
  });
}
