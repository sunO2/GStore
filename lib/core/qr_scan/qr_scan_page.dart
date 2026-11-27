import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'qr_scanner_view.dart';

/// 独立全屏扫码页：识别成功返回文本，取消返回 null。
///
/// 其他功能推荐使用：
/// ```dart
/// final text = await QrScanPage.scan(context);
/// if (text != null) { ... }
/// ```
/// 需要嵌入自定义布局时直接使用 [QrScannerView]。
class QrScanPage extends StatelessWidget {
  const QrScanPage({
    super.key,
    this.title = '扫描二维码',
    this.availableCameras,
  });

  final String title;

  /// 测试/宿主注入相机枚举；null 走真实 availableCameras。
  final Future<List<CameraDescription>> Function()? availableCameras;

  /// 测试注入：扫码结果（null = 走真实相机扫码）。非 null 时 [scan] 直接返回
  /// 该结果，不打开相机页，便于验证宿主页面的回填逻辑。
  @visibleForTesting
  static Future<String?> Function()? debugScanResult;

  static Future<String?> scan(
    BuildContext context, {
    String title = '扫描二维码',
    Future<List<CameraDescription>> Function()? availableCameras,
  }) {
    final injected = debugScanResult;
    if (injected != null) return injected();
    return Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => QrScanPage(
          title: title,
          availableCameras: availableCameras,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: QrScannerView(
              onResult: (text) => Navigator.of(context).pop(text),
              availableCameras: availableCameras,
            ),
          ),
        ),
      ),
    );
  }
}
