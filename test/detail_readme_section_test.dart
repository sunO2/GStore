import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/image/app_image.dart';
import 'package:gstore/core/image/app_image_loader.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 1×1 RGBA 透明 PNG（可被 Flutter 解码）。
final Uint8List kPngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

/// ReadmeSection 截图内嵌测试
///
/// 验证"截图统一收纳进详情区"：
/// - 有截图时渲染横向滑动列表（与 Markdown 文本同容器）
/// - 无截图时仅渲染文本（GitHub 等渠道行为不变）
/// - 仅有截图无正文时仍渲染截图
/// - 点击截图弹出全屏预览（InteractiveViewer + 页码）
class _FakeDetailInfo implements IDetailInfo {
  String? readmeValue;
  List<ScreenshotInfo>? screenshotsValue;

  @override
  String get packageName => 'com.example.app';
  @override
  String get appName => '测试应用';
  @override
  String get icon => '';
  @override
  String get description => '';
  @override
  String get appId => 'com.example.app';
  @override
  String get name => appName;
  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
  @override
  String get channelId => 'vivo';
  @override
  ChannelType get channelType => ChannelType.vivo;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => null;
  @override
  String? get projectUrl => null;
  @override
  List<DownloadInfo> get downloads => const [];
  @override
  List<DetailSection> get sections => const [DetailSection.readme];
  @override
  Map<String, dynamic> get extra => const {};
  @override
  String? get readme => readmeValue;
  @override
  List<ScreenshotInfo>? get screenshots => screenshotsValue;
  @override
  String? get changelog => null;
  @override
  List<String>? get permissions => null;
  @override
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

Future<void> pumpReadme(WidgetTester tester, _FakeDetailInfo info) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReadmeSection(info: info),
        ),
      ),
    ),
  );
  // AppLoading 占位是无限动画，用固定时长 pump 而非 pumpAndSettle
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() {
    // README 图片走 AppImageLoader（新链路），注入 MockClient 返回 1×1 PNG
    AppImageLoader.instance.debugClient = MockClient((request) async {
      return http.Response.bytes(
        kPngBytes,
        200,
        headers: const {'content-type': 'image/png'},
      );
    });
    AppImageLoader.instance.clearCache();
  });

  testWidgets('有截图+正文：横向列表与 Markdown 同容器渲染', (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '# 标题\n详细介绍文本'
      ..screenshotsValue = [
        ScreenshotInfo(url: 'https://example.com/s1.png'),
        ScreenshotInfo(url: 'https://example.com/s2.png'),
        ScreenshotInfo(url: 'https://example.com/s3.png'),
      ];

    await pumpReadme(tester, info);

    // 标题
    expect(find.text('详细介绍'), findsOneWidget);
    // 截图横向列表（3 张卡片，视口内全部可见）
    expect(find.byType(CachedNetworkImage), findsNWidgets(3));
    // Markdown 正文渲染（标题 + 段落）
    expect(find.text('标题'), findsOneWidget);
    expect(find.textContaining('详细介绍文本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无截图：仅渲染 Markdown 文本（GitHub 渠道行为不变）', (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '纯文本介绍';

    await pumpReadme(tester, info);

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.text('详细介绍'), findsOneWidget);
    expect(find.textContaining('纯文本介绍'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅有截图无正文：仍渲染截图区', (tester) async {
    final info = _FakeDetailInfo()
      ..screenshotsValue = [ScreenshotInfo(url: 'https://example.com/s1.png')];

    await pumpReadme(tester, info);

    expect(find.text('详细介绍'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图与正文都为空：整块不渲染', (tester) async {
    final info = _FakeDetailInfo();

    await pumpReadme(tester, info);

    expect(find.text('详细介绍'), findsNothing);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('loading: true → 轻量占位（卡片标题 + AppLoading），不渲染正文/截图', (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '# 标题\n详细介绍文本'
      ..screenshotsValue = [
        ScreenshotInfo(url: 'https://example.com/s1.png'),
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReadmeSection(info: info, loading: true),
          ),
        ),
      ),
    );
    // AppLoading 是无限动画，用固定时长 pump 而非 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 100));

    // 占位可见：卡片标题保持稳定 + 加载指示
    expect(find.text('详细介绍'), findsOneWidget);
    expect(find.byType(AppLoading), findsOneWidget);
    // 真实内容不渲染
    expect(find.text('标题'), findsNothing);
    expect(find.textContaining('详细介绍文本'), findsNothing);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading: false（默认）→ 真实内容照常渲染，无加载指示', (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '纯文本介绍';

    await pumpReadme(tester, info);

    expect(find.text('详细介绍'), findsOneWidget);
    expect(find.byType(AppLoading), findsNothing);
    expect(find.textContaining('纯文本介绍'), findsOneWidget);
  });

  testWidgets('点击截图弹出全屏预览（缩放 + 页码），关闭后消失', (tester) async {
    final info = _FakeDetailInfo()
      ..screenshotsValue = [
        ScreenshotInfo(url: 'https://example.com/s1.png'),
        ScreenshotInfo(url: 'https://example.com/s2.png'),
      ];

    await pumpReadme(tester, info);

    expect(find.byType(InteractiveViewer), findsNothing);

    // 点击第一张截图
    await tester.tap(find.byType(CachedNetworkImage).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    // 关闭
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('README markdown 图片 → AppImage（新链路），与截图 CachedNetworkImage 区分',
      (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '![icon](https://example.com/icon.png)'
      ..screenshotsValue = [
        ScreenshotInfo(url: 'https://example.com/s1.png'),
        ScreenshotInfo(url: 'https://example.com/s2.png'),
      ];

    await pumpReadme(tester, info);
    // 图片下载完成（mock 无延迟，额外推一帧让异步 load 完成）
    await tester.pump(const Duration(milliseconds: 100));

    // README 图片：新链路 AppImage 渲染（内部 Image）
    expect(find.byType(AppImage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppImage), matching: find.byType(Image)),
      findsOneWidget,
    );
    // 截图：仍是 CachedNetworkImage（未迁移），与 README 图片互不干扰
    expect(find.byType(CachedNetworkImage), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('README 表格与代码块渲染不回归（MarkdownBody 语法支持）', (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '# 标题\n\n| 列A | 列B |\n|---|---|\n| 1 | 2 |\n\n'
          '```dart\nfinal x = 1;\n```';

    await pumpReadme(tester, info);

    // 表格：Material Table + 单元格文本
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // 代码块：_CodeBlockWidget 工具栏（复制）+ 代码文本
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('final x = 1;'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
