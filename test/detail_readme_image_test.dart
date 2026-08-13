import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/image/app_image.dart';
import 'package:gstore/core/image/app_image_loader.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---- fixture ----

const String kBadgeUrl =
    'https://img.shields.io/badge/build-passing-brightgreen';
const String kPngUrl = 'https://example.com/icon.png';
const String k404Url = 'https://example.com/missing.png';

/// 1×1 RGBA 透明 PNG（标准魔数 + 有效 CRC + zlib 流，可被 Flutter 解码）。
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

/// 100×20 SVG 文本（固有高度 20，用于验证 badge 钳制到 30）。
final Uint8List kSvgBytes = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="20">'
  '<rect width="100" height="20" fill="red"/></svg>',
);

/// 通过公开入口 [ReadmeSection] 驱动私有 [_ReadmeImage]。
class _FakeDetailInfo implements IDetailInfo {
  String? readmeValue;

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
  List<ScreenshotInfo>? get screenshots => null;
  @override
  String? get changelog => null;
  @override
  List<String>? get permissions => null;
  @override
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

/// 构造按 URL 分发响应的 MockClient；[onRequest] 回调收到请求计数。
/// 延迟 300ms：保证 Html 解析完成后图片仍处于加载中（可断言 placeholder）。
MockClient buildMockClient({void Function(int count)? onRequest}) {
  var count = 0;
  final mock = MockClient((request) async {
    count++;
    onRequest?.call(count);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final url = request.url.toString();
    switch (url) {
      case kBadgeUrl:
        return http.Response.bytes(
          kSvgBytes,
          200,
          headers: const {'content-type': 'image/svg+xml'},
        );
      case kPngUrl:
        return http.Response.bytes(
          kPngBytes,
          200,
          headers: const {'content-type': 'image/png'},
        );
      default:
        return http.Response('Not Found', 404);
    }
  });
  return mock;
}

/// 测试面宽 800 → maxWidth = 800 - AppSpacing.lg*2 = 768。
const double kDisplayWidth = 768;

/// 固定 pump（AppLoading 占位与 Snackbar 为无限/定时动画，勿 pumpAndSettle）。
Future<void> pumpReadme(WidgetTester tester, _FakeDetailInfo info) async {
  await tester.pumpWidget(
    GetMaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReadmeSection(info: info),
        ),
      ),
    ),
  );
  // Html 解析 + 图片下载（300ms 延迟）各自推进
  await tester.pump(const Duration(milliseconds: 100));
}

/// pumpReadme 后再推 400ms，保证图片加载完成。
Future<void> pumpReadmeLoaded(WidgetTester tester, _FakeDetailInfo info) async {
  await pumpReadme(tester, info);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    AppImageLoader.instance.debugClient = buildMockClient();
    AppImageLoader.instance.clearCache();
  });

  testWidgets('shields.io badge → SvgPicture，高度钳制 30（非固有 20/全屏区）',
      (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '![badge]($kBadgeUrl)';

    await pumpReadmeLoaded(tester, info);

    // 新链路：markdown 图片 → imageBuilder → _ReadmeImage → AppImage
    expect(find.byType(AppImage), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    final size = tester.getSize(find.byType(SvgPicture));
    // 宽度：768 显示区，flutter_markdown_plus 行内排版有 2px 收窄，容差 4
    expect(size.width, closeTo(kDisplayWidth, 4));
    expect(size.height, 30); // 钳制高度，非 SVG 固有 20 或全屏 614.4
    expect(tester.takeException(), isNull);
  });

  testWidgets('.png 绝对 URL → 渲染 Image，固有 1×1 tight 不放大（不再撑满显示区）',
      (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '![icon]($kPngUrl)';

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(Image), findsOneWidget);
    final size = tester.getSize(find.byType(Image));
    // 无 HTML 尺寸 + 1×1 固有尺寸（ImageDescriptor）→ tight clamp 不放大
    expect(size, const Size(1, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('<img width="200" height="100"> → 渲染尺寸 200x100（HTML 优先）',
      (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '<img src="$kPngUrl" width="200" height="100">';

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(Image), findsOneWidget);
    final size = tester.getSize(find.byType(Image));
    expect(size, const Size(200, 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('<img width="150px"> → 仅宽度生效（px 后缀剥离），高度 loose 固有',
      (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '<img src="$kBadgeUrl" width="150px">';

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(SvgPicture), findsOneWidget);
    final size = tester.getSize(find.byType(SvgPicture));
    expect(size.width, closeTo(150, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('<img height="100"> → 仅高度生效（"xH" title），宽度等比补全',
      (tester) async {
    final info = _FakeDetailInfo()
      ..readmeValue = '<img src="$kPngUrl" height="100">';

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(Image), findsOneWidget);
    final size = tester.getSize(find.byType(Image));
    // 1×1 固有 + 高度 100 → 宽度等比补全 100（clamp ≤ 768）
    expect(size, const Size(100, 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('<img> 无 width/height → 预处理无 title → 固有 1×1 tight 不放大',
      (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '<img src="$kPngUrl">';

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(Image), findsOneWidget);
    final size = tester.getSize(find.byType(Image));
    expect(size, const Size(1, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTML img 相对路径：渠道层 resolveReadmeImageUrls 绝对化（含代理）后正常渲染',
      (tester) async {
    // 模拟渠道层（GitHubChannel）预处理：相对路径 → rawBaseUrl 绝对化
    const rawBase = 'https://raw.githubusercontent.com/o/r/main/';
    final readme = resolveReadmeImageUrls('<img src="screenshots/a.png">', rawBase);
    expect(readme, contains(rawBase));
    // github 域名 → _ReadmeImage 加默认代理前缀；mock 对任意 URL 返回 PNG
    AppImageLoader.instance.debugClient = MockClient((request) async {
      expect(request.url.toString(), startsWith('https://gh-proxy.org/'));
      return http.Response.bytes(
        kPngBytes,
        200,
        headers: const {'content-type': 'image/png'},
      );
    });
    final info = _FakeDetailInfo()..readmeValue = readme;

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载完成前 placeholder 隐藏（hideOnLoading）→ 加载完成后图片显示',
      (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '![badge]($kBadgeUrl)';

    await pumpReadme(tester, info); // Html 已解析，下载（300ms）未完成

    // 内嵌默认 hideOnLoading: true → 无占位（无转圈）
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('404 → 内嵌隐藏（无 broken_image 图标）', (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '![x]($k404Url)';

    await pumpReadmeLoaded(tester, info);

    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按图片 → Clipboard.setData(原始 URL)', (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '![badge]($kBadgeUrl)';

    await pumpReadmeLoaded(tester, info);

    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        // 永不完成：_copyUrl 停在 await Clipboard.setData，
        // 不会走到 AppDialogs.showSuccess（Get.snackbar 在测试环境
        // 因 GetX 4.7.2 overlayContext 与新版 Flutter LookupBoundary
        // 不兼容而抛异步异常，只能从源头截断）
        return Completer<ByteData?>().future;
      },
    );

    await tester.longPress(find.byType(SvgPicture));
    await tester.pump(const Duration(milliseconds: 100));

    final setData =
        calls.firstWhere((c) => c.method == 'Clipboard.setData');
    expect((setData.arguments as Map)['text'], kBadgeUrl);

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('点击图片 → 全屏预览（InteractiveViewer）出现', (tester) async {
    final info = _FakeDetailInfo()..readmeValue = '![icon]($kPngUrl)';

    await pumpReadmeLoaded(tester, info);

    expect(find.byType(InteractiveViewer), findsNothing);

    await tester.tap(find.byType(Image));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存去重：列表 badge 加载后打开全屏预览（同 URL）→ 请求数保持 1',
      (tester) async {
    var requestCount = 0;
    AppImageLoader.instance.debugClient =
        buildMockClient(onRequest: (count) => requestCount = count);
    final info = _FakeDetailInfo()..readmeValue = '![badge]($kBadgeUrl)';

    await pumpReadmeLoaded(tester, info);
    expect(requestCount, 1);

    // 预览复用同 URL → AppImage 命中 AppImageLoader 缓存，无第二次请求
    await tester.tap(find.byType(SvgPicture));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(requestCount, 1);
    expect(find.byType(SvgPicture), findsNWidgets(2)); // 列表 + 预览各一
    expect(tester.takeException(), isNull);
  });
}
