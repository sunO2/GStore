import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/page/detail/widgets.dart';

/// AppInfoSection 测试（TDD RED：组件尚未实现）
///
/// 验证可折叠"应用信息" Section：
/// - SectionCard(title: '应用信息', icon: Icons.info_outline, trailing: 展开/收起按钮)
/// - 默认收起：仅渲染基础行（包名/当前版本/开发者/渠道，_InfoRow，非空才显示）
/// - 展开：+ 项目主页行 + 统计 StatTag chips（info.buildStatTags() fallback statistics）
/// - 无可展开内容（无项目主页且无统计）时隐藏展开按钮
/// - 全部为空 → SizedBox.shrink
class _FakeDetailInfo implements IDetailInfo {
  String packageNameValue;
  String? versionValue;
  String? developerValue;
  String? channelIdValue;
  String? projectUrlValue;
  List<StatTag> statTags;
  StatisticsInfo? statisticsValue;

  _FakeDetailInfo({
    this.packageNameValue = 'com.example.app',
    this.versionValue,
    this.developerValue,
    this.channelIdValue,
    this.projectUrlValue,
    this.statTags = const [],
    this.statisticsValue,
  });

  @override
  String get packageName => packageNameValue;
  @override
  String get appName => '测试应用';
  @override
  String get icon => '';
  @override
  String get description => '';
  @override
  String get appId => packageName;
  @override
  String get name => appName;
  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
  @override
  String get channelId => channelIdValue ?? '';
  @override
  ChannelType get channelType => ChannelType.github;
  @override
  String? get version => versionValue;
  @override
  String? get developer => developerValue;
  @override
  String? get projectUrl => projectUrlValue;
  @override
  List<DownloadInfo> get downloads => const [];
  @override
  List<DetailSection> get sections => const [DetailSection.statistics];
  @override
  Map<String, dynamic> get extra => {
        if (packageNameValue.isNotEmpty) 'packageName': packageNameValue,
        if (versionValue != null) 'version': versionValue,
        if (developerValue != null) 'developer': developerValue,
        if (channelIdValue != null) 'channelId': channelIdValue,
        if (projectUrlValue != null) 'projectUrl': projectUrlValue,
      };
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

Future<void> _pumpAppInfo(WidgetTester tester, _FakeDetailInfo info) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AppInfoSection(info: info),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('标题 "应用信息" + Icons.info_outline 渲染', (tester) async {
    final info = _FakeDetailInfo(
      versionValue: '1.0.24',
      developerValue: 'OpenSource Team',
      channelIdValue: 'github',
      projectUrlValue: 'https://github.com/sunO2/GStore',
    );

    await _pumpAppInfo(tester, info);

    expect(find.text('应用信息'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认收起：基础行（包名/当前版本/开发者/渠道）存在，统计 chips 不存在', (tester) async {
    final info = _FakeDetailInfo(
      versionValue: '1.0.24',
      developerValue: 'OpenSource Team',
      channelIdValue: 'github',
      statTags: [StatTag.stars(1234), StatTag.forks(56)],
    );

    await _pumpAppInfo(tester, info);

    // 基础行 label + value
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.example.app'), findsOneWidget);
    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('1.0.24'), findsOneWidget);
    expect(find.text('开发者'), findsOneWidget);
    expect(find.text('OpenSource Team'), findsOneWidget);
    expect(find.text('渠道'), findsOneWidget);
    expect(find.text('github'), findsOneWidget);
    // 展开内容不可见：统计 chips 与项目主页
    expect(find.byIcon(Icons.star_rounded), findsNothing);
    expect(find.text('项目主页'), findsNothing);
    // 存在可展开内容 → 展开按钮可见
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击展开按钮 → 统计 chips 与项目主页出现、图标变 expand_less；再点收起', (tester) async {
    final info = _FakeDetailInfo(
      versionValue: '1.0.24',
      developerValue: 'OpenSource Team',
      channelIdValue: 'github',
      projectUrlValue: 'https://github.com/sunO2/GStore',
      statTags: [StatTag.stars(1234), StatTag.forks(56)],
    );

    await _pumpAppInfo(tester, info);

    // 展开
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    // 项目主页行
    expect(find.text('项目主页'), findsOneWidget);
    expect(find.text('https://github.com/sunO2/GStore'), findsOneWidget);
    // 统计 chips（stars/forks）
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.text('1.2k'), findsOneWidget);
    expect(find.byIcon(Icons.call_split), findsOneWidget);
    expect(find.text('56'), findsOneWidget);
    // 图标切换为收起
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);

    // 收起
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star_rounded), findsNothing);
    expect(find.text('项目主页'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'buildStatTags 为空 → 无可展开内容（fallback 已移除）',
      (tester) async {
    final info = _FakeDetailInfo(
      channelIdValue: 'vivo',
      statisticsValue: StatisticsInfo(downloads: 10000, rating: 4.8),
    );

    await _pumpAppInfo(tester, info);

    // buildStatTags() 为空 → 无 tags，无 projectUrl → 无可展开内容
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);
    expect(find.byIcon(Icons.cloud_download_outlined), findsNothing);
    expect(find.byIcon(Icons.grade), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无可展开内容（无项目主页且无统计）→ 隐藏展开按钮', (tester) async {
    final info = _FakeDetailInfo(
      versionValue: '1.0.24',
      developerValue: 'OpenSource Team',
      channelIdValue: 'github',
    );

    await _pumpAppInfo(tester, info);

    // 基础行仍显示
    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('1.0.24'), findsOneWidget);
    // 无可展开内容 → 无展开/收起按钮
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部为空 → 无 "应用信息"（SizedBox.shrink）', (tester) async {
    final info = _FakeDetailInfo(
      packageNameValue: '',
      versionValue: null,
      developerValue: null,
      channelIdValue: null,
      projectUrlValue: null,
    );

    await _pumpAppInfo(tester, info);

    expect(find.text('应用信息'), findsNothing);
    expect(find.byType(AppInfoSection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅渠道非空 → 不 shrink，显示渠道行（回归）', (tester) async {
    final info = _FakeDetailInfo(
      packageNameValue: '',
      versionValue: null,
      developerValue: null,
      channelIdValue: 'github',
      projectUrlValue: null,
    );

    await _pumpAppInfo(tester, info);

    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('github'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开动画：AnimatedSize/AnimatedRotation 存在，展开完成后内容可见且箭头旋转', (tester) async {
    final info = _FakeDetailInfo(
      versionValue: '1.0.24',
      projectUrlValue: 'https://github.com/sunO2/GStore',
      statTags: [StatTag.stars(1234)],
    );

    await _pumpAppInfo(tester, info);

    // 折叠/旋转动画组件存在（默认收起：0 turns）
    expect(find.byType(AnimatedRotation), findsOneWidget);
    expect(find.byType(AnimatedSize), findsOneWidget);
    final rotation =
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
    expect(rotation.turns, 0.0);

    // 展开：固定 pump 推进动画（勿 pumpAndSettle）
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    await tester.pump(AppAnimation.medium);
    await tester.pump(AppAnimation.medium);

    // 展开内容可见 + 箭头已旋转 0.5
    expect(find.text('项目主页'), findsOneWidget);
    expect(find.text('https://github.com/sunO2/GStore'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    final rotated =
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
    expect(rotated.turns, 0.5);
    expect(tester.takeException(), isNull);
  });
}
