// 更新决策纯逻辑单测（update_core.dart）——覆盖 spec「版本比较/防降级/manifest 与 release 解析」。
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/update_core.dart';

void main() {
  group('parseAppVersion', () {
    test('标准版本', () {
      final v = parseAppVersion('3.0.0');
      expect(v, isNotNull);
      expect(v!.major, 3);
      expect(v.minor, 0);
      expect(v.patch, 0);
      expect(v.build, 0);
    });

    test('v 前缀 + build 后缀', () {
      final v = parseAppVersion('v3.0.0+8');
      expect(v!.toString(), '3.0.0+8');
    });

    test('仅 build 后缀', () {
      expect(parseAppVersion('3.1.2+7')!.build, 7);
    });

    test('显式 +0 仍保留 build 语义', () {
      final v = parseAppVersion('3.1.2+0')!;
      expect(v.build, 0);
      expect(v.buildSet, isTrue);
      expect(v.toString(), '3.1.2+0');
    });

    test('非法输入返回 null', () {
      expect(parseAppVersion(''), isNull);
      expect(parseAppVersion('abc'), isNull);
      expect(parseAppVersion('3.0'), isNull);
      expect(parseAppVersion('3.0.0.1'), isNull);
      expect(parseAppVersion('3.-1.0'), isNull);
      expect(parseAppVersion('3.0.0+'), isNull);
    });
  });

  group('verdictFor 版本判定', () {
    test('同版本不提示（本地 3.0.0+7 vs release v3.0.0 无 build）', () {
      final local = parseAppVersion('3.0.0+7')!;
      final remote = parseAppVersion('v3.0.0')!;
      expect(verdictFor(local: local, remote: remote), UpdateVerdict.upToDate);
    });

    test('同版本 build 更大 → 更新', () {
      final local = parseAppVersion('3.0.0+7')!;
      final remote = parseAppVersion('3.0.0+8')!;
      expect(verdictFor(local: local, remote: remote), UpdateVerdict.updateAvailable);
    });

    test('小版本升级 → 更新', () {
      final local = parseAppVersion('3.0.0+999')!;
      final remote = parseAppVersion('3.1.0')!;
      expect(verdictFor(local: local, remote: remote), UpdateVerdict.updateAvailable);
    });

    test('远端低于本地 → 异常（防降级）', () {
      final local = parseAppVersion('3.1.0')!;
      final remote = parseAppVersion('3.0.0+1')!;
      expect(verdictFor(local: local, remote: remote), UpdateVerdict.remoteOlder);
    });
  });

  group('candidateFromGithubRelease', () {
    test('挑 DSH-Remote-*.apk 资产并映射字段', () {
      final release = {
        'tag_name': 'v3.0.0',
        'assets': [
          {'name': 'dsh-mobile-remote-v3.0.0.tgz', 'size': 3081701},
          {'name': 'DSH-Remote-v3.0.0.apk', 'size': 72026882, 'browser_download_url': 'https://x/DSH-Remote-v3.0.0.apk'},
        ],
      };
      final c = candidateFromGithubRelease(release);
      expect(c, isNotNull);
      expect(c!.version, '3.0.0');
      expect(c.downloadUrl, 'https://x/DSH-Remote-v3.0.0.apk');
      expect(c.sizeBytes, 72026882);
      expect(c.sha256, isNull);
      expect(c.source, 'GitHub');
    });

    test('非 HTTPS 下载地址 → null', () {
      expect(
        candidateFromGithubRelease({
          'tag_name': 'v3.0.0',
          'assets': [
            {'name': 'DSH-Remote-v3.0.0.apk', 'browser_download_url': 'http://x/app.apk'},
          ],
        }),
        isNull,
      );
    });

    test('无 APK 资产 → null', () {
      final release = {
        'tag_name': 'v3.0.0',
        'assets': [
          {'name': 'dsh-mobile-remote-v3.0.0.tgz', 'size': 1},
        ],
      };
      expect(candidateFromGithubRelease(release), isNull);
    });

    test('非法 tag → null', () {
      final release = {
        'tag_name': 'not-a-version',
        'assets': [
          {'name': 'DSH-Remote-x.apk', 'browser_download_url': 'https://x/a.apk'},
        ],
      };
      expect(candidateFromGithubRelease(release), isNull);
    });
  });

  group('candidateFromHostManifest', () {
    test('字段全映射 + baseUrl 去尾斜杠', () {
      final c = candidateFromHostManifest(
        {
          'version': '3.0.0+8',
          'apk': 'DSH-Remote-v3.0.0.apk',
          'sha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'notes': '修复若干问题',
        },
        baseUrl: 'http://192.168.1.10:3080/m/',
      );
      expect(c!.version, '3.0.0+8');
      expect(c.downloadUrl, 'http://192.168.1.10:3080/m/api/update/apk');
      expect(c.sha256, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(c.notes, '修复若干问题');
      expect(c.source, '主机');
    });

    test('缺少 sha256 → null（主机源必须完整性校验）', () {
      expect(
        candidateFromHostManifest({'version': '3.0.0', 'apk': 'a.apk'}, baseUrl: 'http://h/m'),
        isNull,
      );
    });

    test('size 字段映射（确认弹窗显示真实大小）', () {
      final c = candidateFromHostManifest(
        {'version': '3.1.0+8', 'apk': 'a.apk', 'size': 75497472, 'sha256': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
        baseUrl: 'http://h/m',
      );
      expect(c!.sizeBytes, 75497472);
    });

    test('非法版本 → null', () {
      expect(
        candidateFromHostManifest({'version': 'x', 'apk': 'a.apk'}, baseUrl: 'http://h/m'),
        isNull,
      );
    });
  });

  group('hostApiBase（检查与下载同 base，挂载路径不硬编码 /m）', () {
    test('默认挂载路径', () {
      expect(hostApiBase(baseUrl: 'http://192.168.1.10:3080', mountPath: '/m'),
          'http://192.168.1.10:3080/m');
    });

    test('自定义挂载路径（bootstrap 权威校正后）', () {
      expect(hostApiBase(baseUrl: 'http://192.168.1.10:3080', mountPath: '/dsh-remote'),
          'http://192.168.1.10:3080/dsh-remote');
    });

    test('空路径回退 /m、baseUrl 去尾斜杠', () {
      expect(hostApiBase(baseUrl: 'http://h:3080/', mountPath: ''), 'http://h:3080/m');
      expect(hostApiBase(baseUrl: 'http://h:3080/', mountPath: '/'), 'http://h:3080/m');
    });
  });
}