import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';

/// StatisticsSection 测试
///
/// 验证统计信息 Section：
/// - GitHub 场景：info.buildStatTags() 返回 stars/forks → 渲染对应 chips
/// - vivo 场景：buildStatTags 为空时 fallback 到 statistics.buildStatTags()
/// - 两者皆空 → 整块不渲染
/// - chip 复用 StatTag 自带颜色工厂（背景/边框/文本色）
class _FakeDetailInfo implements IDetailInfo {
  List<StatTag> statTags;
  StatisticsInfo? statisticsValue;

  _FakeDetailInfo({this.statTags = const [], this.statisticsValue});

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
  List<DownloadInfo> get downloads => const [];
  @override
  List<DetailSection> get sections => const [DetailSection.statistics];
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
  StatisticsInfo? get statistics => statisticsValue;
  @override
  List<StatTag> buildStatTags() => statTags;
}

Future<void> pumpStatistics(WidgetTester tester, _FakeDetailInfo info) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatisticsSection(info: info),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('GitHub 场景：buildStatTags 返回 stars/forks → 渲染 chips',
      (tester) async {
    final info = _FakeDetailInfo(
      statTags: [StatTag.stars(1234), StatTag.forks(56)],
    );

    await pumpStatistics(tester, info);

    // Section 标题 + 图标
    expect(find.text('统计信息'), findsOneWidget);
    expect(find.byIcon(Icons.query_stats), findsOneWidget);
    // stars chip（1.2k）与 forks chip（56）
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.text('1.2k'), findsOneWidget);
    expect(find.byIcon(Icons.call_split), findsOneWidget);
    expect(find.text('56'), findsOneWidget);

    // chip 背景色复用 StatTag 自带颜色工厂
    final starChip = tester.widget<Container>(
      find
          .ancestor(
              of: find.byIcon(Icons.star_rounded),
              matching: find.byType(Container))
          .first,
    );
    expect(
      (starChip.decoration! as BoxDecoration).color,
      StatTag.stars(1234).backgroundColor,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('vivo 场景：buildStatTags 为空时 fallback 到 statistics.buildStatTags()',
      (tester) async {
    final info = _FakeDetailInfo(
      statisticsValue: StatisticsInfo(downloads: 10000, rating: 4.8),
    );

    await pumpStatistics(tester, info);

    expect(find.text('统计信息'), findsOneWidget);
    // downloads（1.0万）与 rating（4.8）chip
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    expect(find.text('1.0万'), findsOneWidget);
    expect(find.byIcon(Icons.grade), findsOneWidget);
    expect(find.text('4.8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('buildStatTags 与 statistics 皆空 → 整块不渲染', (tester) async {
    final info = _FakeDetailInfo();

    await pumpStatistics(tester, info);

    expect(find.text('统计信息'), findsNothing);
    expect(find.byType(StatisticsSection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
