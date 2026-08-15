// 扫码连接：扫描桌面端 dsh 设置页"连接移动端设备"二维码。
// 二维码内容格式：DSHREMOTE|<电脑地址>|<访问口令>
import 'package:flutter/material.dart';
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
      appBar: AppBar(title: const Text('扫码连接')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
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
                '对准电脑屏幕上 dsh 设置页的\n「连接移动端设备」二维码',
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
