import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// 输入 → 实时 QrImageView；清空 → 占位；复制 → 剪贴板 + SnackBar；
/// 长按二维码 → 确认框 → 临时目录写入 PNG（runAsync 驱动真实异步光栅化与文件 IO）；
/// 历史记录 → chip 出现/点击回填/清空。
void main() {
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() {
    // shared_preferences 注入空初始值，避免真实平台通道 MissingPluginException
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('qr_tool_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // Clipboard.setData 走 SystemChannels.platform：测试环境 mock 为直接成功，
    // 供「复制」用例推进（AppDialogs SnackBar 呈现需要 scaffoldMessengerKey）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
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

  testWidgets('输入文本后实时生成二维码，清空后恢复占位', (tester) async {
    await pumpPage(tester);
    // 初始：无内容 → 占位
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    // 输入 → QrImageView 出现（布局无溢出）
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('输入内容后生成二维码'), findsNothing);
    expect(tester.takeException(), isNull, reason: '键盘/布局不应产生 overflow');

    // 清除 → 占位恢复
    await tester.tap(find.text('清除'));
    await tester.pump();
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('复制按钮写入剪贴板并弹 SnackBar', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '复制我');
    await tester.pump();

    await tester.tap(find.text('复制'));
    await tester.pump(); // Clipboard.setData 异步
    await tester.pump(const Duration(milliseconds: 300)); // SnackBar 入场

    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('输入内容后出现历史 chip，点击回填输入并重新生成二维码', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    // 历史区出现，chip 显示输入内容
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'hello'), findsOneWidget);

    // 清空输入 → 占位
    await tester.tap(find.text('清除'));
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
    await tester.pump();
    expect(find.widgetWithText(ActionChip, '历史A'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text('历史记录'), findsNothing);
  });

  testWidgets('长按二维码确认后保存图片写入临时目录 qr_codes 并提示路径', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '保存我');
    await tester.pump();

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
    expect(find.textContaining('已保存到'), findsOneWidget);
  });
}
