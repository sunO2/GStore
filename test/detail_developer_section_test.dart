import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';

/// DeveloperSection 测试
///
/// 验证开发者信息行：
/// - 每行 [xs icon + onSurfaceVariant label + onSurface value]
/// - 项目主页 value 用 primary 色
/// - 四字段（developer/projectUrl/version/channelId）全空才隐藏
class _FakeDetailInfo implements IDetailInfo {
  String? developerValue;
  String? projectUrlValue;
  String? versionValue;
  String channelIdValue = '';

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
  List<DetailSection> get sections => const [DetailSection.developer];
  @override
  Map<String, dynamic> get extra => {
        if (developerValue != null) 'developer': developerValue,
        if (projectUrlValue != null) 'projectUrl': projectUrlValue,
        if (versionValue != null) 'version': versionValue,
        if (channelIdValue.isNotEmpty) 'channelId': channelIdValue,
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
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

Future<void> pumpDeveloper(WidgetTester tester, _FakeDetailInfo info) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DeveloperSection(info: info),
        ),
      ),
    ),
  );
}

/// 取某行 value 文本的 style
TextStyle? _textStyle(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style;

void main() {
  testWidgets('四字段齐全：渲染 开发者/项目主页/版本/渠道 四行', (tester) async {
    final info = _FakeDetailInfo()
      ..developerValue = 'OpenSource Team'
      ..projectUrlValue = 'https://github.com/sunO2/GStore'
      ..versionValue = '1.0.24'
      ..channelIdValue = 'github';

    await pumpDeveloper(tester, info);

    final colorScheme =
        Theme.of(tester.element(find.byType(DeveloperSection))).colorScheme;

    // 标题 + 行标签（开发者出现 2 次：Section 标题 + 行 label）
    expect(find.text('开发者'), findsNWidgets(2));
    expect(find.byIcon(Icons.person_outline), findsWidgets);
    // 各行 value
    expect(find.text('OpenSource Team'), findsOneWidget);
    expect(find.text('https://github.com/sunO2/GStore'), findsOneWidget);
    expect(find.text('1.0.24'), findsOneWidget);
    expect(find.text('github'), findsOneWidget);
    // 项目主页 value 用 primary 色，其余 onSurface
    expect(_textStyle(tester, 'https://github.com/sunO2/GStore')?.color,
        colorScheme.primary);
    expect(_textStyle(tester, 'OpenSource Team')?.color, colorScheme.onSurface);
    expect(_textStyle(tester, '1.0.24')?.color, colorScheme.onSurface);
    expect(_textStyle(tester, 'github')?.color, colorScheme.onSurface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅 developer 非空：只渲染开发者一行', (tester) async {
    final info = _FakeDetailInfo()..developerValue = '仅开发者';

    await pumpDeveloper(tester, info);

    expect(find.text('仅开发者'), findsOneWidget);
    expect(find.text('项目主页'), findsNothing);
    expect(find.text('版本'), findsNothing);
    expect(find.text('渠道'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('四字段全空：整块不渲染', (tester) async {
    final info = _FakeDetailInfo();

    await pumpDeveloper(tester, info);

    expect(find.text('开发者'), findsNothing);
    expect(find.byType(DeveloperSection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
