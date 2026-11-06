import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/download/download_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: [MemoryConfigStorage(), MemoryConfigStorage()],
    );
    ConfigRegistry.registerAll(ConfigService.instance);
    resetProxyForTest();
  });

  tearDown(() {
    resetProxyForTest();
  });

  /// 打开统一「下载设置」弹层（从宿主页面按钮触发，模拟真实入口）。
  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDownloadSettingsSheet(context),
                child: const Text('打开下载设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开下载设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹层展示传输与网络/代理全部设置项', (tester) async {
    await pumpSheet(tester);

    expect(find.text('下载设置'), findsOneWidget);
    expect(find.text('多段下载'), findsOneWidget);
    expect(find.text('最大并发下载数'), findsOneWidget);
    expect(find.text('仅WiFi下载'), findsOneWidget);
    expect(find.text('最大重试次数'), findsOneWidget);
    expect(find.text('GitHub 代理'), findsOneWidget);
    expect(find.text('下载自动使用代理'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 代理输入框无边框（主题默认会注入 OutlineInputBorder）。
    final proxyField = tester.widget<TextField>(find.byType(TextField).first);
    final decoration = proxyField.decoration!;
    expect(decoration.border, InputBorder.none);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
  });

  testWidgets('点击「仅WiFi下载」开关写入 download.wifi_only', (tester) async {
    await pumpSheet(tester);

    await tester.tap(find.text('仅WiFi下载'));
    await tester.pumpAndSettle();

    expect(
      await ConfigService.instance.getT<bool>(ConfigKeys.downloadWifiOnly),
      isTrue,
    );
  });

  testWidgets('点击输入框不弹预设列表，点右侧箭头才弹出', (tester) async {
    await pumpSheet(tester);

    // 点击输入框：只聚焦编辑，不出现预设项。
    final field = find.byType(TextField).first;
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(find.text('https://v4.gh-proxy.org/'), findsNothing);

    // 点右侧箭头：预设列表出现。
    final arrow = find.byIcon(TablerIcons.chevron_down);
    await tester.ensureVisible(arrow);
    await tester.pumpAndSettle();
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    expect(find.text('https://v4.gh-proxy.org/'), findsOneWidget);
  });

  testWidgets('未修改时「应用代理」置灰，修改后高亮可点', (tester) async {
    await pumpSheet(tester);

    final applyButton = find.byKey(const Key('download_settings_apply_proxy'));
    expect(tester.widget<TextButton>(applyButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'https://example.com');
    await tester.pumpAndSettle();

    expect(tester.widget<TextButton>(applyButton).onPressed, isNotNull);
  });

  testWidgets('输入代理并点击「应用代理」归一化保存', (tester) async {
    await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'https://example.com');
    await tester.pumpAndSettle();

    final applyButton = find.text('应用代理');
    await tester.ensureVisible(applyButton);
    await tester.tap(applyButton);
    await tester.pumpAndSettle();

    expect(getProxy(), 'https://example.com/');
  });
}
