import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_view_settings.dart';
import 'package:gstore/page/web/web_view_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WebViewSettingsStore.instance.debugReset();
  });

  testWidgets('展示搜索/显示/内容/隐私分区', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WebViewSettingsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('浏览器设置'), findsOneWidget);
    for (final title in ['搜索', '显示']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('默认搜索引擎'), findsOneWidget);
    expect(find.text('夜间模式'), findsOneWidget);
    expect(find.text('主页来源'), findsOneWidget);

    // 下面的分区在首屏之外，滚到底再断言。
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    for (final title in ['内容', '隐私与数据', '其他']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('清除浏览数据'), findsOneWidget);
  });

  testWidgets('切换夜间模式立即持久化', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WebViewSettingsPage()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SwitchListTile, '夜间模式'));
    await tester.pumpAndSettle();

    expect(WebViewSettingsStore.instance.settings.nightMode, isTrue);
  });

  testWidgets('切换默认搜索引擎', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WebViewSettingsPage()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('默认搜索引擎'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('百度'));
    await tester.pumpAndSettle();

    expect(
      WebViewSettingsStore.instance.settings.searchEngine,
      WebSearchEngine.baidu,
    );
    expect(find.text('百度'), findsOneWidget);
  });

  testWidgets('字体大小滑杆改变缩放值', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WebViewSettingsPage()),
    );
    await tester.pumpAndSettle();

    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    // 新增「主页」分区把滑杆推到首屏之外，先滚到可见再拖。
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(WebViewSettingsStore.instance.settings.textZoom, greaterThan(100));
  });
}
