import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
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

/// 模型字段与 extra 解耦的假实现（模拟 LocalDb/GitHub 渐进路径：
/// extra 为纯存储 map，不含 version/packageName/channelId 镜像）
class _SplitDetailInfo implements IDetailInfo {
  String packageNameValue;
  String? versionValue;
  String? developerValue;
  String channelIdValue;
  String? projectUrlValue;
  Map<String, dynamic> extraValue;
  List<StatTag> statTags;
  StatisticsInfo? statisticsValue;

  _SplitDetailInfo({
    this.packageNameValue = '',
    this.versionValue,
    this.developerValue,
    this.channelIdValue = '',
    this.projectUrlValue,
    this.extraValue = const {},
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
  String get appId => packageName.isEmpty ? 'test-app' : packageName;
  @override
  String get name => appName;
  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
  @override
  String get channelId => channelIdValue;
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
  Map<String, dynamic> get extra => extraValue;
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

Future<void> _pumpAny(WidgetTester tester, IDetailInfo info) async {
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
      'buildStatTags 为空 → fallback 到 statistics 构建统计 chips（e59d0c4 误删已恢复）',
      (tester) async {
    final info = _FakeDetailInfo(
      channelIdValue: 'vivo',
      statisticsValue: StatisticsInfo(downloads: 10000, rating: 4.8),
    );

    await _pumpAppInfo(tester, info);

    // buildStatTags() 为空但 statistics 非空 → 兜底生成 tags → 可展开
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    // 展开后可见下载量/评分 chips
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    expect(find.byIcon(Icons.grade), findsOneWidget);
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

  // ── e59d0c4 回归锁定：模型字段优先，extra 兜底 ──

  testWidgets('回归①：extra 无键时回落模型字段——当前版本/包名/渠道行渲染（修复前红）',
      (tester) async {
    final info = _SplitDetailInfo(
      packageNameValue: 'com.example.app',
      versionValue: '1.2.3',
      channelIdValue: 'localdb',
    );

    await _pumpAny(tester, info);

    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.example.app'), findsOneWidget);
    expect(find.text('渠道'), findsOneWidget);
    expect(find.text('localdb'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回归②：extra 有键（JS 渠道代理）→ 三行照常渲染（extra 路径不回归）',
      (tester) async {
    final proxy = JsChannelDetailProxy({
      'version': '2.0.0',
      'packageName': 'com.via.extra',
      'channelId': 'js_x',
    });

    await _pumpAny(tester, proxy);

    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.via.extra'), findsOneWidget);
    expect(find.text('渠道'), findsOneWidget);
    expect(find.text(ChannelType.custom.code), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回归③：模型字段与 extra 皆空 → 基础行不渲染（SizedBox.shrink 分支）',
      (tester) async {
    final info = _SplitDetailInfo();

    await _pumpAny(tester, info);

    expect(find.text('应用信息'), findsNothing);
    expect(find.byType(AppInfoSection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
