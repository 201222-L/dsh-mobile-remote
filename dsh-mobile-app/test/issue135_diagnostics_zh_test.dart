// issue #135：环境诊断输出中文化（纯文本渲染单测）。
//
// 覆盖：
//   1. 新增 metrics（mobileOldestAgeMs/mobileOldestIdleMs/mobileStalled/mobileEvicted/
//      mobileRejected）中文名；
//   2. 新 checks（sseConnections/hostCapabilities/hostGeneration/appAlignment/pluginUpdate/
//      appArtifact/currentRelease*/updateTarget/updateDir）中文名；
//   3. services pluginManager/hmr；
//   4. 已知 key 只显示中文（不再 `中文（key）`）；未知 key 原样 fallback；
//   5. 运行形态/常用状态值友好化（cli→命令行 / 网页、ok→正常、up-to-date→已是最新、
//      config→配置、npm 保留），版本号/路径/IP 不丢；
//   6. 英文模式不回归。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue135_diagnostics_zh_test.dart

import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture() => {
  'runtime': {
    'form': 'cli',
    'host': '192.168.1.5',
    'port': 3080,
    'cwd': '/home/user/project',
    'authEnabled': true,
    'metrics': {
      'mobileOnline': 1,
      'mobileOldestAgeMs': 1234,
      'mobileOldestIdleMs': 500,
      'mobileStalled': 0,
      'mobileEvicted': 2,
      'mobileRejected': 1,
      'futureMetric': 7,
    },
  },
  'services': {
    'webServer': true,
    'pluginManager': true,
    'hmr': false,
    'futureService': true,
  },
  'checks': {
    'sseConnections': '1 / 8 · 最旧 1s · stalled 0 · 累计驱逐 0',
    'hostCapabilities': {
      'jobs.callerShape': 'ok',
      'settings.read': 'drift',
      'future.cap': 'weird token',
    },
    'hostGeneration': {'jobsCaller': 'sessionId'},
    'appAlignment': {
      'state': 'ok',
      'appVersion': '3.5.1',
      'hint': 'see https://host/ready and ok',
    },
    'pluginUpdate': {
      'state': 'up-to-date',
      'installShape': 'npm',
      'message': 'path /home/user/config',
    },
    'appArtifact': 'ready(some-reason)',
    'currentRelease': 'current 123456789abc…',
    'currentReleaseHealth': 'ok',
    'updateTarget': 'target 123456789abc…',
    'updateDir': 'config(not-ready)',
    'approvalMode': 'both',
    'futureCheck': 'weird',
    'extraPath': '/home/user/config/npm',
    'extraUrl': 'https://host/ready',
  },
  'notes': <String>[],
  'plugin': {'name': 'dsh-mobile-remote', 'version': '3.5.1'},
};

void main() {
  tearDown(() => L10n.lang = 'zh');

  group('#135 名称映射', () {
    test('新 metrics 均有中文名', () {
      const keys = [
        'mobileOldestAgeMs',
        'mobileOldestIdleMs',
        'mobileStalled',
        'mobileEvicted',
        'mobileRejected',
      ];
      for (final key in keys) {
        final name = diagnosticMetricName(key);
        expect(name, isNot(key), reason: '$key 缺中文名');
        expect(
          RegExp(r'[\u4e00-\u9fa5]').hasMatch(name),
          isTrue,
          reason: '$key → $name 应为中文',
        );
      }
    });

    test('新 checks 与服务中文名', () {
      for (final key in const [
        'sseConnections',
        'hostCapabilities',
        'hostGeneration',
        'appAlignment',
        'pluginUpdate',
        'appArtifact',
        'currentRelease',
        'currentReleaseHealth',
        'updateTarget',
        'updateDir',
      ]) {
        final name = diagnosticItemName('checks', key);
        expect(name, isNot(key), reason: '$key 缺中文名');
      }
      expect(diagnosticItemName('services', 'pluginManager'), contains('插件'));
      expect(diagnosticItemName('services', 'hmr'), contains('热更新'));
    });

    test('未知 key 原样 fallback', () {
      expect(diagnosticMetricName('futureMetric'), 'futureMetric');
      expect(diagnosticItemName('checks', 'futureCheck'), 'futureCheck');
      expect(diagnosticItemName('services', 'futureService'), 'futureService');
    });
  });

  group('#135 诊断文本', () {
    test('已知项无重复英文 key，新增项/状态值中文化，版本路径 IP 保留', () {
      final text = buildDiagnosticsText(_fixture());

      // 运行形态/常用状态值
      expect(text, contains('运行形态: 命令行 / 网页'));
      expect(text, isNot(contains('cli · ')));
      expect(text, contains('192.168.1.5:3080'));
      expect(text, contains('/home/user/project'));
      expect(text, contains('dsh-mobile-remote v3.5.1'));

      // 新 metrics：中文名 + 值；不再 `key（key）`
      expect(text, contains('最旧连接年龄（毫秒） = 1234'));
      expect(text, contains('最久未写连接（毫秒） = 500'));
      expect(text, contains('停滞连接 = 0'));
      expect(text, contains('累计驱逐连接 = 2'));
      expect(text, contains('累计拒绝连接 = 1'));
      expect(text, isNot(contains('mobileOldestAgeMs（mobileOldestAgeMs）')));
      expect(
        text,
        isNot(contains('mobileOldestAgeMs = 1234')),
        reason: '已知 metrics 不应再显示原始 key',
      );

      // 新 checks：中文名，且不再重复 raw key
      expect(text, contains('SSE 连接 = '));
      expect(text, contains('停滞'), reason: 'sseConnections 摘要里的 stalled 应友好化');
      expect(text, isNot(contains('sseConnections')));
      expect(text, contains('宿主能力 = '));
      expect(text, contains('状态漂移'), reason: 'hostCapabilities 的 drift 应友好化');
      expect(text, contains('宿主代际 = '));
      expect(text, contains('按会话'));
      expect(text, contains('两端版本对齐 = '));
      expect(text, contains('插件更新 = '));
      expect(text, contains('已是最新'));
      expect(text, contains('App 分发包 = '));
      expect(text, contains('当前发布健康 = 正常'));
      expect(text, contains('更新目标 = 目标 '));
      expect(text, contains('更新目录 = 配置（未就绪）'));
      expect(text, contains('npm'), reason: 'npm 源保留原词');

      // approvalMode 值走中文，不带英文前缀
      expect(text, contains('审批策略：双端同卡，先答生效'));
      expect(text, isNot(contains('both · 双端同卡')));

      // services
      expect(text, contains('插件管理（免重启更新）'));
      expect(text, contains('热更新（HMR）'));

      // 未知 key 保留 fallback（可复制排障）
      expect(text, contains('futureMetric = 7'));
      expect(text, contains('futureCheck = weird'));

      // review P2：路径/URL/未知嵌套值必须原样；不得被状态词替换破坏
      expect(text, contains('/home/user/config/npm'));
      expect(text, isNot(contains('/home/user/配置/npm')));
      expect(text, contains('https://host/ready'));
      expect(text, isNot(contains('https://host/就绪')));
      expect(text, contains('future.cap: weird token'));
      expect(text, contains('see https://host/ready and ok'));
      expect(text, contains('path /home/user/config'));
    });

    test('英文模式保留英文名称，不回退重复 key', () {
      L10n.lang = 'en';
      final text = buildDiagnosticsText(_fixture());

      expect(text, contains('Mode: CLI / Web'));
      expect(text, contains('Phone connections = 1'));
      expect(text, contains('Oldest connection age (ms) = 1234'));
      expect(text, contains('SSE connections = '));
      expect(text, isNot(contains('SSE 连接')));
      expect(text, contains('Host capabilities = '));
      expect(text, contains('Plugin update = '));
      expect(text, contains('up to date'));
      expect(text, contains('Update dir = config'));
      expect(text, contains('futureMetric = 7'));
      expect(text, contains('/home/user/config/npm'));
      expect(text, contains('https://host/ready'));
      expect(text, isNot(contains('cli · ')));
    });

    test('desktop 运行形态无英文前缀', () {
      expect(diagnosticFormText('desktop'), '桌面版');
      expect(diagnosticFormText('cli'), '命令行 / 网页');
      L10n.lang = 'en';
      expect(diagnosticFormText('desktop'), 'DSH Desktop');
      expect(diagnosticFormText('cli'), 'CLI / Web');
    });

    test('检测失败保持明确文案', () {
      expect(buildDiagnosticsText(null), '检测失败');
      L10n.lang = 'en';
      expect(buildDiagnosticsText(null), 'Check failed');
    });
  });
}
