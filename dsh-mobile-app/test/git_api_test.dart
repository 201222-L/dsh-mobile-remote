import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('GitReadApi sends encoded session-scoped GET requests', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(jsonEncode({'available': true}), 200);
      }
      if (request.url.path.endsWith('/repository')) {
        return http.Response(
          jsonEncode({'repositoryId': 'repo', 'name': 'p'}),
          200,
        );
      }
      if (request.url.path.endsWith('/branches')) {
        return http.Response(jsonEncode({'branches': []}), 200);
      }
      if (request.url.path.endsWith('/worktree')) {
        return http.Response(
          jsonEncode({
            'repositoryId': 'repo&1',
            'snapshotId': 'worktree-snap',
            'staged': [],
            'unstaged': [],
            'untracked': [],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/preview')) {
        return http.Response(
          jsonEncode({
            'repositoryId': 'repo&1',
            'kind': 'unstaged',
            'path': 'a b.txt',
            'diff': '-old\n+new\n',
            'truncated': false,
            'binary': false,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/graph')) {
        return http.Response(
          jsonEncode({'snapshotId': 'snap', 'commits': [], 'tips': []}),
          200,
        );
      }
      return http.Response(
        jsonEncode({'oid': 'abc', 'files': [], 'filesTotal': 0}),
        200,
      );
    });
    final GitReadApi value = Api(client: client)
      ..baseUrl = 'https://host.example'
      ..path = '/m';

    await value.capabilities('session / one');
    await value.repository('session / one');
    await value.branches('session / one', 'repo&1');
    await value.graph(
      'session / one',
      'repo&1',
      const [GitGraphTip(name: 'refs/heads/a b', tipOid: 'abc')],
      snapshotId: 'snapshot/1',
      cursor: 'cursor+1',
      limit: 25,
    );
    await value.commitDetails(
      'session / one',
      'repo&1',
      'abc/def',
      filesCursor: 'files+1',
      filesLimit: 10,
    );
    final workspace = await value.worktree('session / one', 'repo&1');
    final preview = await value.preview(
      'session / one',
      'repo&1',
      kind: 'unstaged',
      snapshotId: 'worktree-snap',
      path: 'a b.txt',
    );

    expect(workspace.snapshotId, 'worktree-snap');
    expect(preview.diff, '-old\n+new\n');
    expect(requests, hasLength(7));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(requests[0].url.path, '/m/api/git/capabilities');
    expect(requests[0].url.queryParameters['sessionId'], 'session / one');
    expect(requests[2].url.queryParameters['repositoryId'], 'repo&1');
    expect(jsonDecode(requests[3].url.queryParameters['tips']!) as List, [
      {'name': 'refs/heads/a b', 'tipOid': 'abc'},
    ]);
    expect(requests[3].url.queryParameters['snapshotId'], 'snapshot/1');
    expect(requests[3].url.queryParameters['cursor'], 'cursor+1');
    expect(requests[3].url.queryParameters['limit'], '25');
    expect(requests[4].url.queryParameters['oid'], 'abc/def');
    expect(requests[4].url.queryParameters['filesCursor'], 'files+1');
    expect(requests[4].url.queryParameters['filesLimit'], '10');
    expect(requests[5].url.path, '/m/api/git/worktree');
    expect(requests[5].url.queryParameters['sessionId'], 'session / one');
    expect(requests[5].url.queryParameters['repositoryId'], 'repo&1');
    expect(requests[6].url.path, '/m/api/git/preview');
    expect(requests[6].url.queryParameters['kind'], 'unstaged');
    expect(requests[6].url.queryParameters['snapshotId'], 'worktree-snap');
    expect(requests[6].url.queryParameters['path'], 'a b.txt');
  });
}
