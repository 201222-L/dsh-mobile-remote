// 扫码连接：扫描桌面端 dsh 设置页"连接移动端设备"二维码。
// 二维码内容格式：DSHREMOTE|<电脑地址>|<访问口令>
import 'package:flutter/material.dart';
import 'l10n.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanScreen extends StatefulWidget {
  final void Function(String base, String token) onScanned;
  const ScanScreen({super.key, required this.onScanned});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;

  static final _pattern = RegExp(r'^DSHREMOTE\|(.+?)\|(.*)$');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null) return;
    final m = _pattern.firstMatch(code);
    if (m == null) return; // 非本 App 二维码：忽略继续扫
    _done = true;
    widget.onScanned(m.group(1)!, m.group(2)!);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.t('扫码连接', 'Scan to Connect'))),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // v3.0.0 review：相机权限被拒/硬件异常时给出引导（黑屏兜底，不再无声失败）
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined, size: 42, color: Colors.white70),
                    const SizedBox(height: 12),
                    Text(
                      L10n.t('无法启动相机（权限被拒或设备不支持）\n请在系统设置中允许相机权限后重试',
                          'Camera unavailable (permission denied or unsupported).\nAllow camera permission in system settings and try again'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(L10n.t('返回', 'Back')),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 取景框提示
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black.withValues(alpha: 0.7),
              padding: const EdgeInsets.all(16),
              child: Text(
                L10n.t('对准电脑屏幕上 dsh 设置页的\n「连接移动端设备」二维码', 'Point at the "Connect mobile device" QR code\non the dsh settings page on your computer'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
