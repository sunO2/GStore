import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';

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
}
