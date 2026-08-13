import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/detail/widgets.dart';

/// VersionBadge 组件测试（TDD RED 阶段）
///
/// 目标组件（尚不存在，后续任务实现）：
///   `VersionBadge({required String? latestVersion, required String? installedVersion})`
///
/// 行为约定：
/// - 已安装且 versionName == latestVersion → chip 标签 '当前版本 {installedVersion}'，无角标
/// - 已安装且 versionName != latestVersion → chip '当前版本 {installedVersion}' +
///   右上角小胶囊角标显示 latestVersion
/// - 未安装（installedVersion null）→ chip 显示 latestVersion，无角标
/// - 两者都 null → SizedBox.shrink
///
/// 注意（GREEN 阶段可调整）：角标文本断言暂按 `'v{latestVersion}'` 格式编写；
/// 若实现采用其它格式（如仅裸版本号），GREEN 阶段同步修改本文件断言。
Future<void> pumpVersionBadge(
  WidgetTester tester, {
  required String? latestVersion,
  required String? installedVersion,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VersionBadge(
          latestVersion: latestVersion,
          installedVersion: installedVersion,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('已安装且版本相等：chip 显示"当前版本 {version}"，无角标', (tester) async {
    await pumpVersionBadge(tester, latestVersion: '1.0.0', installedVersion: '1.0.0');

    // chip 标签
    expect(find.text('当前版本 1.0.0'), findsOneWidget);
    // 无角标（相等时不显示 latest 胶囊）
    expect(find.text('v1.0.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已安装且版本不等：chip + 右上角小胶囊角标显示 latestVersion', (tester) async {
    await pumpVersionBadge(tester, latestVersion: '2.0.0', installedVersion: '1.0.0');

    // chip 标签：当前版本 + 已安装版本
    expect(find.text('当前版本 1.0.0'), findsOneWidget);
    // 角标：'v{latestVersion}'（格式假设，GREEN 阶段可调整）
    expect(find.text('v2.0.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未安装（installedVersion null）：chip 直接显示 latestVersion，无角标', (tester) async {
    await pumpVersionBadge(tester, latestVersion: '2.0.0', installedVersion: null);

    // chip 显示 latestVersion
    expect(find.text('2.0.0'), findsOneWidget);
    // 无"当前版本"前缀、无角标
    expect(find.text('当前版本 2.0.0'), findsNothing);
    expect(find.text('v2.0.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两者都 null：渲染 SizedBox.shrink（无任何内容）', (tester) async {
    await pumpVersionBadge(tester, latestVersion: null, installedVersion: null);

    // 渲染为 SizedBox.shrink
    expect(
      find.descendant(of: find.byType(VersionBadge), matching: find.byType(SizedBox)),
      findsOneWidget,
    );
    // 无任何文本内容
    expect(
      find.descendant(of: find.byType(VersionBadge), matching: find.byType(Text)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
