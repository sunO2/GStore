import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/image/app_image_loader.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/view.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 详情页区块顺序 widget 测试（问题1：下载列表跳位）。
///
/// 验证 _buildSections 的固定顺序语义：基础区块 → downloads → readme。
/// - detail.sections 先到 readme（如 ETag 304 近瞬时完成）、downloads 后到 →
///   渲染时下载区块仍固定位于 README 之前（不再随 sections 到达顺序跳动）
/// - downloadsLoading 期间（downloads 尚未注入 sections）→ 下载骨架仍固定位于
///   README 之前（加载中/加载后位置一致）
///
/// 直接预注册 DetailLogic 并注入构造的 detail（绕过 loadDetail 的时序竞争，
/// 精准构造"sections 含 readme 不含 downloads"场景）。
class _FakeSectionOrderDetail implements IDetailInfo {
  List<DetailSection> sectionsValue = const [];
  List<DownloadInfo> downloadsValue = const [];
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
  String get appId => 'owner/repo';
  @override
  String get name => appName;
  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
  @override
  String get channelId => 'github';
  @override
  ChannelType get channelType => ChannelType.github;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => 'owner';
  @override
  String? get projectUrl => 'https://github.com/owner/repo';
  @override
  List<DownloadInfo> get downloads => downloadsValue;
  @override
  List<DetailSection> get sections => sectionsValue;
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

void main() {
  setUp(() {
    // DetailLogic 经 ModuleManager 注册表取用（channel/aggregate 服务）
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
    ModuleManager.instance
        .bind<IAggregateService>(AppAggregatorManager.instance);
    // README 图片走 AppImageLoader，注入 MockClient 返回 1×1 PNG 避免真实网络
    AppImageLoader.instance.debugClient = MockClient((request) async {
      return http.Response.bytes(
        kPngBytes,
        200,
        headers: const {'content-type': 'image/png'},
      );
    });
    AppImageLoader.instance.clearCache();
  });

  /// 预注册 DetailLogic 并 pump 详情页（onReady 空参数会把 errorMessage 置
  /// '缺少参数'，pump 后清掉保证正文渲染）。
  Future<DetailLogic> pumpDetailPage(
    WidgetTester tester,
    _FakeSectionOrderDetail detail,
  ) async {
    final logic = DetailLogic();
    logic.state.detailInfo = detail;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 页面经 detailStateProvider 取状态：注入测试 logic 同款状态，
          // 使 DetailPage 渲染的 detailInfo 与测试注入的同一实例。
          detailStateProvider.overrideWith((ref) => logic.state),
        ],
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
          home: const DetailPage(),
        ),
      ),
    );
    // 页面 start（post-frame microtask）已把 errorMessage 置 '缺少参数' → 清掉，正文生效
    logic.state.errorMessage = '';
    await tester.pump();
    return logic;
  }

  testWidgets('sections 先到 readme、downloads 非空 → 下载区块固定位于 README 之上',
      (tester) async {
    final detail = _FakeSectionOrderDetail()
      ..sectionsValue = const [DetailSection.readme]
      ..downloadsValue = [
        DownloadInfo(
          url: 'https://example.com/a.apk',
          name: 'a.apk',
          version: '1.2.0',
          size: 12345,
        ),
      ]
      ..readmeValue = '# 说明\nREADME 正文';

    await pumpDetailPage(tester, detail);

    // 两个区块都已渲染（非 loading 分支）
    expect(find.byType(DownloadsSection), findsOneWidget);
    expect(find.byType(ReadmeSection), findsOneWidget);

    final downloadsDy = tester.getTopLeft(find.byType(DownloadsSection)).dy;
    final readmeDy = tester.getTopLeft(find.byType(ReadmeSection)).dy;
    expect(downloadsDy, lessThan(readmeDy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('downloadsLoading=true（downloads 空）→ 下载骨架仍位于 README 之上',
      (tester) async {
    final detail = _FakeSectionOrderDetail()
      ..sectionsValue = const [DetailSection.readme]
      ..readmeValue = '# 说明\nREADME 正文';

    final logic = await pumpDetailPage(tester, detail);
    // 加载中态：downloads 尚未注入 sections、列表仍空 → 骨架占位
    logic.state.downloadsLoading = true;
    await tester.pump();

    // 下载骨架（loading 分支）仍在渲染
    expect(find.byType(DownloadsSection), findsOneWidget);
    expect(find.byType(ReadmeSection), findsOneWidget);

    final downloadsDy = tester.getTopLeft(find.byType(DownloadsSection)).dy;
    final readmeDy = tester.getTopLeft(find.byType(ReadmeSection)).dy;
    expect(downloadsDy, lessThan(readmeDy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('基础区块（developer）→ downloads → readme 顺序保持', (tester) async {
    final detail = _FakeSectionOrderDetail()
      ..sectionsValue = const [
        DetailSection.developer,
        DetailSection.readme,
      ]
      ..downloadsValue = [
        DownloadInfo(
          url: 'https://example.com/a.apk',
          name: 'a.apk',
          version: '1.2.0',
        ),
      ]
      ..readmeValue = '# 说明\nREADME 正文';

    await pumpDetailPage(tester, detail);

    final developerDy = tester.getTopLeft(find.byType(DeveloperSection)).dy;
    final downloadsDy = tester.getTopLeft(find.byType(DownloadsSection)).dy;
    final readmeDy = tester.getTopLeft(find.byType(ReadmeSection)).dy;
    expect(developerDy, lessThan(downloadsDy));
    expect(downloadsDy, lessThan(readmeDy));
    expect(tester.takeException(), isNull);
  });
}
