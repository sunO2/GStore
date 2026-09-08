import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/qr_tool/view.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
/// 保存图片 → 临时目录写入 PNG（runAsync 驱动真实异步光栅化与文件 IO）。
void main() {
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() {
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
  }

  testWidgets('输入文本后实时生成二维码，清空后恢复占位', (tester) async {
    await pumpPage(tester);
    // 初始：无内容 → 占位
    expect(find.text('输入内容后生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    // 输入 → QrImageView 出现
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('输入内容后生成二维码'), findsNothing);

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

  testWidgets('保存图片写入临时目录 qr_codes 并提示路径', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '保存我');
    await tester.pump();

    // runAsync：QrPainter.toImageData 光栅化 + 文件写入均为真实异步
    await tester.runAsync(() async {
      await tester.tap(find.text('保存图片'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (Directory('${tempDir.path}/qr_codes').existsSync()) break;
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final qrDir = Directory('${tempDir.path}/qr_codes');
    expect(qrDir.existsSync(), isTrue, reason: '应在临时目录创建 qr_codes');
    final files = qrDir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.png'));
    expect(find.textContaining('已保存到'), findsOneWidget);
  });
}
