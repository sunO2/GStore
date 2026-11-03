import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';

/// Todo 15 — 详情信息区动态标签渲染（D1a）。
///
/// 锁定三件事：
/// 1. `AppInfoSection` 泛化渲染 `detail.labels`：**顺序 = 列表顺序**，值逐条可见，
///    `icon` 可选（有则渲染对应图标，无则不凭空造图标）。
/// 2. 展示型区块（version/developer/package/channel）**来自 labels**：labels 非空时
///    不再走固定键推导（固定键的旧值不得出现）。
/// 3. labels 为空时安全：回落到固定键基础行，且结构化 downloads/readme 照常渲染、
///    不抛异常（空列表不合成任何标签）。
class _LabelsDetailInfo implements IDetailInfo {
  _LabelsDetailInfo({
    this.labelsValue = const [],
    this.sectionsValue = const [],
    this.downloadsValue = const [],
    this.readmeValue,
    this.versionValue,
    this.developerValue,
    this.channelIdValue = '',
    this.packageNameValue = '',
    this.projectUrlValue,
    this.extraValue = const {},
  });

  final List<AppLabel> labelsValue;
  final List<DetailSection> sectionsValue;
  final List<DownloadInfo> downloadsValue;
  final String? readmeValue;
  final String? versionValue;
  final String? developerValue;
  final String channelIdValue;
  final String packageNameValue;
  final String? projectUrlValue;
  final Map<String, dynamic> extraValue;

  @override
  List<AppLabel> get labels => labelsValue;
  @override
  String get packageName => packageNameValue;
  @override
  String get appName => '测试应用';
  @override
  String get icon => '';
  @override
  String get description => '';
  @override
  String get appId => packageNameValue.isEmpty ? 'test-app' : packageNameValue;
  @override
  String get name => appName;
  @override
  bool get isValid => appName.isNotEmpty;
  @override
  String get channelId => channelIdValue;
  @override
  ChannelType get channelType => ChannelType.custom;
  @override
  String? get version => versionValue;
  @override
  String? get developer => developerValue;
  @override
  String? get projectUrl => projectUrlValue;
  @override
  List<DownloadInfo> get downloads => downloadsValue;
  @override
  List<DetailSection> get sections => sectionsValue;
  @override
  Map<String, dynamic> get extra => {
        ...extraValue,
        if (readmeValue != null) 'readme': readmeValue,
      };
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

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  group('dynamic labels render in the detail info region', () {
    testWidgets('labels render generically: values visible, order = list order',
        (tester) async {
      final info = _LabelsDetailInfo(
        labelsValue: const [
          AppLabel(key: 'version', label: '版本', value: '1.2.3'),
          AppLabel(key: 'developer', label: '开发者', value: 'Alice'),
          AppLabel(key: 'package', label: '包名', value: 'com.x.y'),
          AppLabel(key: 'channel', label: '渠道', value: 'github'),
        ],
      );

      await _pump(tester, AppInfoSection(info: info));

      // 每条 label 的展示名与值都可见（不是"只有区块存在"）
      expect(find.text('版本'), findsOneWidget);
      expect(find.text('1.2.3'), findsOneWidget);
      expect(find.text('开发者'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('包名'), findsOneWidget);
      expect(find.text('com.x.y'), findsOneWidget);
      expect(find.text('渠道'), findsOneWidget);
      expect(find.text('github'), findsOneWidget);

      // 顺序 = 列表顺序（版本 → 开发者 → 包名 → 渠道）
      expect(_top(tester, '版本'), lessThan(_top(tester, '开发者')));
      expect(_top(tester, '开发者'), lessThan(_top(tester, '包名')));
      expect(_top(tester, '包名'), lessThan(_top(tester, '渠道')));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'icon is optional: known name renders its icon, null renders none',
        (tester) async {
      final info = _LabelsDetailInfo(
        labelsValue: const [
          AppLabel(key: 'version', label: '版本', value: '1.2.3', icon: 'tag'),
          AppLabel(key: 'developer', label: '开发者', value: 'Alice'),
        ],
      );

      await _pump(tester, AppInfoSection(info: info));

      // icon: 'tag' → 渲染 tag 图标
      expect(find.byIcon(TablerIcons.tag), findsOneWidget);
      // 无 icon 的 label 不凭空造图标（未用到的 user 图标不得出现）
      expect(find.byIcon(TablerIcons.user), findsNothing);
      expect(find.text('开发者'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('display-only regions are sourced from labels, not fixed keys',
        (tester) async {
      // 固定键值（version/developer/channel）与 labels 冲突：labels 必须胜出
      final info = _LabelsDetailInfo(
        versionValue: '9.9.9',
        developerValue: 'FIXED-DEV',
        channelIdValue: 'FIXED-CHANNEL',
        packageNameValue: 'com.fixed.pkg',
        labelsValue: const [
          AppLabel(key: 'version', label: '版本', value: '1.2.3'),
          AppLabel(key: 'developer', label: '开发者', value: 'LABEL-DEV'),
        ],
      );

      await _pump(tester, AppInfoSection(info: info));

      // labels 的值出现
      expect(find.text('1.2.3'), findsOneWidget);
      expect(find.text('LABEL-DEV'), findsOneWidget);
      // labels 未覆盖的基础字段由模型补齐：包名/渠道仍然可见
      expect(find.text('com.fixed.pkg'), findsOneWidget);
      expect(find.text('FIXED-CHANNEL'), findsOneWidget);
      // labels 已覆盖的字段不再用固定键旧值覆盖
      expect(find.text('9.9.9'), findsNothing);
      expect(find.text('FIXED-DEV'), findsNothing);
      expect(find.text('当前版本'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('empty labels keep structured sections safe', () {
    testWidgets(
        'download-backed info tags render only platform (size/count moved to downloads)',
        (tester) async {
      final info = _LabelsDetailInfo(
        packageNameValue: 'com.example.app',
        downloadsValue: [
          DownloadInfo(
            url: 'https://x/app.apk',
            name: 'app.apk',
            size: 1024,
            platform: 'arm64-v8a',
            downloadCount: 12000,
            publishedAt: DateTime(2025, 1, 2),
          ),
        ],
      );

      await _pump(tester, AppInfoSection(info: info));

      expect(find.text('平台 arm64-v8a'), findsOneWidget);
      expect(find.text('安装包 1.0 KB'), findsNothing);
      expect(find.text('下载量 1.2万'), findsNothing);
      expect(find.text('发布 2025-01-02'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('下载区头部显示仓库最近更新时间（文件无发布时间时兜底）', (tester) async {
      final info = _LabelsDetailInfo(
        packageNameValue: 'com.example.app',
        extraValue: const {'pushedAt': '2025-01-02T00:00:00Z'},
        downloadsValue: [
          DownloadInfo(url: 'https://x/app.apk', name: 'app.apk'),
        ],
      );

      await _pump(tester, DownloadsSection(info: info));

      expect(find.textContaining('更新于'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'empty labels: AppInfoSection falls back + structured downloads/readme render, no error',
        (tester) async {
      final info = _LabelsDetailInfo(
        // labels 为空
        labelsValue: const [],
        packageNameValue: 'com.example.app',
        versionValue: '1.0.0',
        developerValue: 'OpenSource',
        channelIdValue: 'github',
        projectUrlValue: 'https://example.com/app',
        sectionsValue: const [DetailSection.downloads, DetailSection.readme],
        readmeValue: '# 标题\n详细介绍文本',
        downloadsValue: [
          DownloadInfo(url: 'https://x/y/demo.apk', name: 'demo.apk'),
        ],
      );

      await _pump(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppInfoSection(info: info),
            DownloadsSection(info: info),
            ReadmeSection(info: info),
          ],
        ),
      );
      // 让 postFrame 占位切换（不依赖 README 后台 isolate 完成）
      await tester.pump();
      await tester.pump();

      // 空 labels → 固定键基础行回落（无标签也不丢信息）
      expect(find.text('包名'), findsOneWidget);
      expect(find.text('com.example.app'), findsOneWidget);
      expect(find.text('当前版本'), findsOneWidget);
      expect(find.text('1.0.0'), findsOneWidget);

      // 结构化 downloads 照常渲染
      expect(find.byType(DownloadsSection), findsOneWidget);
      expect(find.text('下载文件'), findsOneWidget);
      expect(find.text('demo.apk'), findsOneWidget);

      // 结构化 readme 照常渲染（卡片标题在占位/完成态均存在）
      expect(find.byType(ReadmeSection), findsOneWidget);
      expect(find.text('详细介绍'), findsOneWidget);

      // 空 labels 不抛异常、不合成标签
      expect(tester.takeException(), isNull);
    });
  });
}
