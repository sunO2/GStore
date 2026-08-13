import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';

/// DownloadsSection 分块加载 loading 态测试
///
/// 验证：
/// - loading: true → 骨架占位（卡片标题 + AppLoading），不渲染列表项/计数
/// - loading: false（默认）非空下载 → 列表项 + 计数徽标，无加载指示
/// - loading: false 空下载 → 空态文案
class _FakeDetailInfo implements IDetailInfo {
  List<DownloadInfo> downloadsValue = const [];

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
  String get channelId => 'github';
  @override
  ChannelType get channelType => ChannelType.github;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => null;
  @override
  String? get projectUrl => null;
  @override
  List<DownloadInfo> get downloads => downloadsValue;
  @override
  List<DetailSection> get sections => const [DetailSection.downloads];
  @override
  Map<String, dynamic> get extra => const {};
  @override
  String? get readme => null;
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

Future<void> pumpDownloads(
  WidgetTester tester,
  _FakeDetailInfo info, {
  bool loading = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DownloadsSection(info: info, loading: loading),
        ),
      ),
    ),
  );
  // AppLoading 占位是无限动画，用固定时长 pump 而非 pumpAndSettle
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('loading: true → 骨架占位（卡片标题 + AppLoading），不渲染列表项/计数', (tester) async {
    final info = _FakeDetailInfo()
      ..downloadsValue = [
        DownloadInfo(
          url: 'https://example.com/a.apk',
          name: 'app-1.0.0.apk',
          version: '1.0.0',
        ),
      ];

    await pumpDownloads(tester, info, loading: true);

    // 占位可见：卡片标题保持稳定 + 加载指示（3 行骨架各一个）
    expect(find.text('下载文件'), findsOneWidget);
    expect(find.byType(AppLoading), findsNWidgets(3));
    // 真实内容不渲染（列表项/计数徽标）
    expect(find.text('app-1.0.0.apk'), findsNothing);
    expect(find.text('1 个文件'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading: false（默认）非空下载 → 列表项 + 计数徽标，无加载指示', (tester) async {
    final info = _FakeDetailInfo()
      ..downloadsValue = [
        DownloadInfo(
          url: 'https://example.com/a.apk',
          name: 'app-1.0.0.apk',
          version: '1.0.0',
        ),
      ];

    await pumpDownloads(tester, info);

    expect(find.text('下载文件'), findsOneWidget);
    expect(find.text('1 个文件'), findsOneWidget);
    expect(find.text('app-1.0.0.apk'), findsOneWidget);
    expect(find.byType(AppLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading: false 空下载 → 空态文案（无加载指示）', (tester) async {
    final info = _FakeDetailInfo();

    await pumpDownloads(tester, info);

    expect(find.text('下载文件'), findsOneWidget);
    expect(find.text('该应用暂无可下载文件'), findsOneWidget);
    expect(find.byType(AppLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
