// issue #74 纯规则：工具结果图片聚合（折叠层入口的计数与去重）。
import 'package:dsh_mobile_app/tool_images.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> img(String id, {String? name}) => {
      'attachmentId': id,
      'mediaType': 'image/png',
      'name': ?name,
    };

void main() {
  test('空来源 → 空集合 / 0 张', () {
    expect(collectToolImages(const []), isEmpty);
    expect(countToolImages(const []), 0);
    expect(collectToolImages([<Map<String, dynamic>>[]]), isEmpty);
  });

  test('按 attachmentId 去重，保留首次出现顺序', () {
    final a = img('sha256:a');
    final b = img('sha256:b');
    final out = collectToolImages([
      [a, b],
      [img('sha256:a'), img('sha256:c')],
    ]);
    expect(out.map((e) => e['attachmentId']), ['sha256:a', 'sha256:b', 'sha256:c']);
    expect(countToolImages([
      [a],
      [a, a],
      [b, a],
    ]), 2);
  });

  test('缺 attachmentId 时按 path / name 去重', () {
    final byPath = {'path': '/tmp/a.png', 'mediaType': 'image/png'};
    final byName = {'name': 'b.png', 'mediaType': 'image/png'};
    final out = collectToolImages([
      [byPath, byName],
      [
        {'path': '/tmp/a.png'},
        {'name': 'b.png'},
      ],
    ]);
    expect(out, hasLength(2));
    expect(toolImageDedupKey(byPath), 'path:/tmp/a.png');
    expect(toolImageDedupKey(byName), 'name:b.png');
  });

  test('无任何标识的图片元数据不计数（fail-open，不制造死入口）', () {
    expect(toolImageDedupKey({'mediaType': 'image/png'}), isNull);
    expect(
      countToolImages([
        [
          {'mediaType': 'image/png'},
        ],
      ]),
      0,
    );
  });
}
