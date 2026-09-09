import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/qr_tool/view.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zxing2/qrcode.dart';

/// mock path_provider：getApplicationDocumentsPath 返回临时目录
/// （保存图片测试注入，避免污染真实文档目录）
class _FakePathProvider extends PathProviderPlatform {
  final String path;
  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// 二维码工具页测试：
/// 输入 → 实时 QrImageView；AppBar 清除 → 占位；
/// 历史防抖（输入停顿 900ms 后 chip 出现）→ 点击回填/清空；
/// 长按二维码 → 确认框 → 临时目录写入 PNG + 相册结果提示（gal seam 注入成败，
/// 不触发真实系统相册；runAsync 驱动真实异步光栅化与文件 IO）。
void main() {
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() {
    // shared_preferences 注入空初始值，避免真实平台通道 MissingPluginException
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('qr_tool_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // 相册 seam 默认走真实 gal（测试内显式注入成败）
    QrToolPage.debugGallerySucceeds = null;
    // 相机 seam 默认走真实 availableCameras（测试内切换到识别模式时注入失败路径）
    QrToolPage.debugAvailableCameras = null;
  });

  tearDown(() {
    QrToolPage.debugGallerySucceeds = null;
    QrToolPage.debugAvailableCameras = null;
    PathProviderPlatform.instance = originalPathProvider;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 挂载页面并注册 AppDialogs 所需的全局 navigator / scaffoldMessenger key。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const QrToolPage(),
      ),
    );
    // 等 initState 异步加载历史完成
    await tester.pump();
  }

  testWidgets('输入文本后实时生成二维码，AppBar 清除后恢复占位', (tester) async {
    await pumpPage(tester);
    // 初始：无内容 → 占位；FAB 悬浮清除存在（恒可点）
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byTooltip('清除'), findsOneWidget);

    // 输入 → QrImageView 出现（布局无溢出）
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('输入内容后生成二维码'), findsNothing);
    expect(tester.takeException(), isNull, reason: '键盘/布局不应产生 overflow');

    // FAB 清除 → 占位恢复
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('输入停顿 900ms 后出现历史 chip，点击回填输入并重新生成二维码', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    // 防抖期内（未满 800ms）：历史区不出现
    expect(find.text('历史记录'), findsNothing);

    // 推进防抖计时（900ms > 800ms）→ 历史写入，chip 出现
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'hello'), findsOneWidget);

    // FAB 清除输入 → 占位
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    // 点击历史 chip → 回填输入并重新生成二维码
    await tester.tap(find.widgetWithText(ActionChip, 'hello'));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller!.text, 'hello');
  });

  testWidgets('清空历史按钮移除历史 chips', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '历史A');
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.widgetWithText(ActionChip, '历史A'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text('历史记录'), findsNothing);
  });

  testWidgets('长按保存成功：写入临时目录 qr_codes 并提示已保存到相册', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '保存我');
    await tester.pump(const Duration(milliseconds: 900));

    // 注入相册成功（不触发真实 gal）
    QrToolPage.debugGallerySucceeds = true;

    // 长按二维码 → 确认框
    await tester.longPress(find.byType(QrImageView));
    await tester.pumpAndSettle();
    expect(find.text('保存二维码'), findsOneWidget);

    // 点「保存」确认。真实异步链（QrPainter.toImageData 引擎光栅化 + 文件 IO）
    // 的续体挂在 fake 微任务队列上：交替 runAsync（推进真实事件循环）与 pump
    // （冲刷 fake 微任务续体），驱动完整保存流程。
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300)); // SnackBar 入场

    final qrDir = Directory('${tempDir.path}/qr_codes');
    expect(qrDir.existsSync(), isTrue, reason: '应在临时目录创建 qr_codes');
    final files = qrDir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.png'));

    // 新增：保存的 PNG 应为白色圆角背景（非透明）——解码取中心像素断言 alpha 不透明。
    // 真实引擎解码必须在 runAsync（真实事件循环）中执行。
    final centerAlpha = await tester.runAsync(() async {
      final bytes = await files.single.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final data = await frame.image
          .toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      expect(data, isNotNull, reason: '保存的 PNG 应可解码');
      // 512×512 rawRgba：中心像素 (256,256) 的 alpha 通道
      const stride = 512 * 4;
      return data!.getUint8(256 * stride + 256 * 4 + 3);
    });
    expect(centerAlpha, greaterThanOrEqualTo(200),
        reason: '中心像素应不透明（白底圆角背景，非透明输出）');

    expect(find.textContaining('已保存到相册'), findsOneWidget);
  });

  testWidgets('相册写入失败：提示失败但应用目录文件保留', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '失败我');
    await tester.pump(const Duration(milliseconds: 900));

    // 注入相册失败（不触发真实 gal）
    QrToolPage.debugGallerySucceeds = false;

    await tester.longPress(find.byType(QrImageView));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300)); // SnackBar 入场

    expect(find.textContaining('保存到相册失败'), findsOneWidget);
    // 应用目录落盘保留（相册失败不删文件）
    final qrDir = Directory('${tempDir.path}/qr_codes');
    expect(qrDir.existsSync(), isTrue);
    expect(qrDir.listSync().whereType<File>().toList(), hasLength(1));
  });

  testWidgets('分段胶囊默认「生成」；切换到「识别」相机不可用显示占位不崩溃', (tester) async {
    await pumpPage(tester);

    // 分段胶囊出现，默认生成模式（短标签移动端：生成|识别）
    expect(find.widgetWithText(AppSegmentedButton<QrToolMode>, '生成'), findsOneWidget);
    expect(find.widgetWithText(AppSegmentedButton<QrToolMode>, '识别'), findsOneWidget);
    expect(find.text('输入内容后生成二维码'), findsOneWidget);

    // 注入相机不可用（测试环境平台通道未注册，真实 availableCameras 会挂起；
    // 注入后确定性走初始化失败路径）
    QrToolPage.debugAvailableCameras =
        () async => throw CameraException('noCamera', 'test');

    // 切换到识别：初始化失败 → 保持在识别模式显示「相机不可用」占位（不崩溃）
    await tester.tap(find.text('识别'));
    await tester.pump(); // 重建：扫描区 loading
    await tester.pump(); // 注入的 availableCameras 抛异常 → catch 置占位
    await tester.pump(); // 重建占位
    expect(find.text('相机不可用'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '相机不可用时不应崩溃');

    // 切回生成模式 → 生成占位恢复（相机释放路径不抛异常）
    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zxing2 解码合成二维码：RGBLuminanceSource + GlobalHistogramBinarizer 可识别 qr_flutter 生成的二维码', (tester) async {
    // 真实引擎光栅化必须在 runAsync（真实事件循环）中执行
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      // QrPainter 只画黑色模块、背景透明 → 先铺白底，保证直方图有亮暗分布
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 200, 200),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      QrPainter(
        data: 'HELLO-ZXING2',
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ).paint(canvas, const Size(200, 200));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 200);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();

      // 与识别模式同一解码路径：RGBA Int32 像素 → RGBLuminanceSource → 二值化 → 解码
      final source = RGBLuminanceSource(
        200,
        200,
        byteData!.buffer.asInt32List(),
      );
      final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
      final result = QRCodeReader().decode(bitmap);
      expect(result.text, 'HELLO-ZXING2');
    });
  });
}
