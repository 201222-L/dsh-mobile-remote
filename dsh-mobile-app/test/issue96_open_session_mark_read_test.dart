// issue #96：点系统通知进会话后，该会话的未读一直不标已读。
//
// 根因：`AppStore.markSessionNotifsRead` 只在缓存**为空**时才重拉服务端列表；
// 缓存非空、但不含"刚点进来的这条通知"（App 在后台收到的、或重连前拿到的旧列表）时，
// 过滤结果为空 → 直接 return → 一条都不标。累积很快就是几十条。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/store.dart';

Map<String, dynamic> _notifJson(
  String id,
  String sessionId, {
  bool unread = true,
}) => {
  'id': id,
  'kind': 'turn',
  'sessionId': sessionId,
  'title': '标题 $id',
  'detail': '',
  'time': 1,
  'unread': unread,
};

void main() {
  late HttpServer server;
  late List<String> events; // 'GET' | 'POST:<ids>'
  late List<Map<String, dynamic>> served;

  setUp(() async {
    // TestWidgetsFlutterBinding 默认把所有 HTTP 请求短路成 400——这里是本机
    // loopback 假服务端，必须显式恢复真实 HttpClient（与 chat_copy_widget_test 同款）。
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    events = [];
    served = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.method == 'GET' && req.uri.path.endsWith('/notifications')) {
        events.add('GET');
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'items': served}))
          ..close();
        return;
      }
      if (req.method == 'POST' &&
          req.uri.path.endsWith('/notifications/read')) {
        final body = await utf8.decoder.bind(req).join();
        final ids = ((jsonDecode(body) as Map)['ids'] as List).cast<String>();
        events.add('POST:${ids.join(',')}');
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}))
          ..close();
        return;
      }
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}))
        ..close();
    });
    api.baseUrl = 'http://127.0.0.1:${server.port}';
    api.token = '';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('缓存非空但不含该会话 → 先重拉，再标该会话全部未读', () async {
    final store = AppStore();
    store.notifs = [
      AppNotification.fromJson(_notifJson('other-1', 'session-other')),
    ];
    served = [
      _notifJson('other-1', 'session-other'),
      _notifJson('n-1', 'session-1'),
      _notifJson('n-2', 'session-1'),
    ];

    await store.markSessionNotifsRead('session-1');

    expect(events.first, 'GET', reason: '缓存未命中时必须重拉一次服务端');
    expect(
      events.where((e) => e.startsWith('POST:')).toList(),
      ['POST:n-1,n-2'],
      reason: '该会话的两条未读都要标，不能因为缓存里没有就跳过',
    );
  });

  test('缓存已命中 → 不做多余拉取，直接标已读', () async {
    final store = AppStore();
    store.notifs = [AppNotification.fromJson(_notifJson('n-1', 'session-1'))];
    served = [_notifJson('n-1', 'session-1', unread: false)];

    await store.markSessionNotifsRead('session-1');

    expect(events.first, 'POST:n-1', reason: '缓存命中时第一个请求就应该是标已读');
  });

  test('确实没有未读 → 不发 mark 请求', () async {
    final store = AppStore();
    store.notifs = [];
    served = [_notifJson('n-1', 'session-1', unread: false)];

    await store.markSessionNotifsRead('session-1');

    expect(events.where((e) => e.startsWith('POST:')), isEmpty);
  });
}
