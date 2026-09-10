import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/qr_tool/view.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('输入文本后实时生成二维码，下滑清空后恢复占位', (tester) async {
    await pumpPage(tester);
    // 初始：无内容 → 占位（FAB 清除已移除，清空由下滑手势承担）
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    // 输入 → QrImageView 出现（布局无溢出）
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('输入内容后生成二维码'), findsNothing);
    expect(tester.takeException(), isNull, reason: '键盘/布局不应产生 overflow');

    // 下滑手势（起点在预览区）→ 清空 → 占位恢复
    await tester.dragFrom(
      const Offset(120, 80), // 预览区（flex 2 顶部）
      const Offset(0, 160),
    );
    await tester.pump();
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('输入停顿 900ms 后写入历史；上滑弹出历史 sheet，点击回填输入并重新生成二维码', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    // 防抖期内（未满 800ms）：页面内不再常驻历史区
    expect(find.text('历史记录'), findsNothing);

    // 推进防抖计时（900ms > 800ms）→ 历史写入
    await tester.pump(const Duration(milliseconds: 900));

    // 下滑手势（起点在预览区）→ 清除输入 → 占位
    await tester.dragFrom(
      const Offset(120, 80), // 预览区（flex 2 顶部）
      const Offset(0, 160),
    );
    await tester.pump();
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    // 上滑手势 → 弹出历史 bottom sheet；点击历史项回填输入并重新生成二维码
    await tester.drag(
      find.byType(TextField),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('历史记录'), findsOneWidget);
    await tester.tap(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller!.text, 'hello');
  });

  testWidgets('上滑弹出历史 sheet，清空按钮移除历史记录', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '历史A');
    await tester.pump(const Duration(milliseconds: 900));

    // 上滑 → 历史 sheet 出现，点击「清空」→ sheet 关闭、历史清空
    await tester.drag(
      find.byType(TextField),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('历史记录'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('历史记录'), findsNothing);

    // 再次上滑：历史为空 → 提示「暂无历史记录」，不弹空列表
    await tester.drag(
      find.byType(TextField),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无'), findsWidgets);
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

  test('rotateLumaToPreview：顺时针 90°×4 还原，宽高交换正确', () {
    // 2×3 图案：行 0 = [1,2]，行 1 = [3,4]，行 2 = [5,6]（行优先）
    // 顺时针 90° → 3×2：列变行，新行 0 = 原末列向上逐行 = [2,4,6] ...
    // 用「旋转 4 次 = 原图」这一不变量验证宽高交换与像素迁移正确。
    final src = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    var data = src;
    var cw = 2, ch = 3;
    for (var t = 1; t <= 4; t++) {
      final (out, w, h) = QrToolPage.rotateLumaToPreview(
        data,
        cw,
        ch,
        quarterTurns: 1,
      );
      // 每次顺时针 90°：宽高互换
      expect(w, ch);
      expect(h, cw);
      data = out;
      cw = w;
      ch = h;
    }
    expect(cw, 2, reason: '旋转 4 次宽应还原为 2');
    expect(ch, 3, reason: '旋转 4 次高应还原为 3');
    expect(data, src, reason: '旋转 4 次像素应逐点还原');
  });

  test('rotateLumaToPreview：顺时针 90° 单次迁移正确', () {
    // 2×2：a=1 b=2 / c=3 d=4 → 顺时针 90° → c=3 a=1 / d=4 b=2 → [3,1,4,2]
    final src = Uint8List.fromList([1, 2, 3, 4]);
    final (out, w, h) = QrToolPage.rotateLumaToPreview(src, 2, 2, quarterTurns: 1);
    expect(w, 2);
    expect(h, 2);
    expect(out, Uint8List.fromList([3, 1, 4, 2]));
  });

  test('rotateLumaToPreview：水平镜像翻转 X 顺序', () {
    // 2×2：a=1 b=2 / c=3 d=4 → 水平镜像 → b=2 a=1 / d=4 c=3 → [2,1,4,3]
    final src = Uint8List.fromList([1, 2, 3, 4]);
    final (out, w, h) = QrToolPage.rotateLumaToPreview(
      src,
      2,
      2,
      quarterTurns: 0,
      mirrorX: true,
    );
    expect(w, 2);
    expect(h, 2);
    expect(out, Uint8List.fromList([2, 1, 4, 3]));
  });

  test('rotateLumaToPreview：RGBA（4 字节/像素）旋转不破坏通道顺序', () {
    // 1×2 两个像素：上=红(255,0,0,255)、下=蓝(0,0,255,255)
    // 顺时针 90°（1×2 → 2×1）：顶部旋转到右侧 → 左=蓝、右=红，
    // 每个像素内 RGBA 通道顺序保持不变。
    final src = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]);
    final (out, w, h) = QrToolPage.rotateLumaToPreview(
      src,
      1,
      2,
      quarterTurns: 1,
      bytesPerPixel: 4,
    );
    expect(w, 2);
    expect(h, 1);
    expect(out, Uint8List.fromList([0, 0, 255, 255, 255, 0, 0, 255]),
        reason: '左=原下(蓝)、右=原上(红)，通道顺序保持 RGBA');
  });

  testWidgets('左滑切换为识别模式；README：scan 模式输入框 readOnly', (tester) async {
    await pumpPage(tester);
    // 初始为「生成」模式，输入框可编辑
    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().readOnly, isFalse);

    // 左滑（水平 >80px，方向锁定水平）→ 切换为「识别」
    await tester.drag(find.byType(TextField), const Offset(-150, 0));
    await tester.pump();
    // 识别模式：输入框只读；相机 seam 失败 → 占位不崩溃
    await tester.pump();
    expect(field().readOnly, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下滑清空输入框（起点在预览区；输入区起点不触发）', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '下滑清空我');
    await tester.pump();

    // 起点在预览区（页面上半部分）下滑 → 清空输入
    await tester.dragFrom(
      const Offset(120, 80), // 预览区（flex 2 顶部）
      const Offset(0, 160),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('长按输入框出现复制菜单，点击复制内容（识别模式）', (tester) async {
    // 识别模式输入框 readOnly + 有内容 → 长按弹出自定义「复制」菜单 → 复制全文
    final clipboardLog = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardLog.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    QrToolPage.debugAvailableCameras =
        () async => throw CameraException('noCamera', 'test');
    await pumpPage(tester);
    // 切到识别模式（readOnly）
    await tester.tap(find.text('识别'));
    await tester.pump();
    // 注入识别结果（直接设置 controller 文本，等价于识别成功回填）
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.text = '扫码结果-ABC';
    await tester.pump();

    // 长按输入框 → 自定义菜单「复制」出现；点击复制
    await tester.longPress(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(clipboardLog, contains('扫码结果-ABC'));
  });
}
