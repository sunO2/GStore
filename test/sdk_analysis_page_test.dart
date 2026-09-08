import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/page/installed_apps/sdk_analysis_page.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页（LibChecker 式多 Tab 分类）测试。
///
/// 注入空规则集使三路分析器短路（无 isolate/FFI 真实 IO），
/// 详情数据（权限/ABI）同样通过测试注入短路；
/// Future 仅经 microtask 完成，可在 testWidgets 的 FakeAsync 内推进。
void main() {
  installed.AppInfo buildApp() => installed.AppInfo(
        name: '测试应用',
        icon: null,
        packageName: 'com.example.test',
        versionName: '1.0.0',
        versionCode: 1,
        builtWith: installed.BuiltWith.native_or_others,
        installedTimestamp: 0,
      );

  /// 注入空的 SDK 规则（三路分析短路）并清理。
  void injectEmptyRules() {
    ApkLibraryAnalyzer.instance.debugSetRules(const []);
    ApkLibraryAnalyzer.instance.debugSetDexRules(const []);
    ApkLibraryAnalyzer.instance.debugSetComponentRules(const []);
    addTearDown(() {
      ApkLibraryAnalyzer.instance.debugSetRules(null);
      ApkLibraryAnalyzer.instance.debugSetDexRules(null);
      ApkLibraryAnalyzer.instance.debugSetComponentRules(null);
    });
  }

  /// 注入合成详情数据（ABI/权限）并清理。
  void injectDetails({
    List<String> abis = const [],
    List<String> permissions = const [],
  }) {
    ApkLibraryAnalyzer.instance.debugSetAbis(abis);
    ApkSourceService.instance.debugSetPermissions(permissions);
    addTearDown(() {
      ApkLibraryAnalyzer.instance.debugSetAbis(null);
      ApkSourceService.instance.debugSetPermissions(null);
    });
  }

  /// 挂载页面并推进 microtask 等待全部异步完成。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SdkAnalysisPage(
          app: buildApp(),
          sourceDir: '/no/such/file.apk',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// 点击 Tab 标签切换到对应分类页（默认展示首个「概览」）。
  Future<void> switchTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('SDK 分析页：加载完成后出现五个 Tab 分类', (tester) async {
    injectEmptyRules();
    injectDetails();

    await tester.pumpWidget(
      MaterialApp(
        home: SdkAnalysisPage(
          app: buildApp(),
          sourceDir: '/no/such/file.apk',
        ),
      ),
    );
    // 首帧：加载态（头部就位，Tab 尚未出现）
    expect(find.byType(SdkAnalysisPage), findsOneWidget);
    expect(find.text('测试应用'), findsOneWidget);
    expect(find.text('com.example.test'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);

    // 推进 microtask，等待全部异步完成
    await tester.pump();
    await tester.pump();

    // 五个 Tab 按序出现
    expect(find.byType(TabBar), findsOneWidget);
    for (final label in ['概览', '原生库', 'DEX 类名', '组件', '权限']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览键值行 + SDK 版本未知降级 + ABI chips', (tester) async {
    injectEmptyRules();
    injectDetails(abis: const ['arm64-v8a', 'armeabi-v7a']);

    await pumpPage(tester);

    // 包名/版本/安装路径
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.example.test'), findsNWidgets(2)); // 头部 + 概览行
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('1.0.0 (1)'), findsOneWidget);
    expect(find.text('安装路径'), findsOneWidget);
    expect(find.text('/no/such/file.apk'), findsOneWidget);
    // SDK 版本解析失败 → 降级为「未知」
    expect(find.text('minSdk'), findsOneWidget);
    expect(find.text('targetSdk'), findsOneWidget);
    expect(find.text('未知'), findsNWidgets(2));
    // ABI 非空 → 渲染 chips
    expect(find.text('ABI 架构'), findsOneWidget);
    expect(find.text('arm64-v8a'), findsOneWidget);
    expect(find.text('armeabi-v7a'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：权限 Tab 无声明时展示空态', (tester) async {
    injectEmptyRules();
    injectDetails();

    await pumpPage(tester);
    await switchTab(tester, '权限');

    expect(find.text('无权限声明'), findsOneWidget);
    // 概览内容已随切页销毁
    expect(find.text('安装路径'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：权限 Tab 渲染权限 chips', (tester) async {
    injectEmptyRules();
    injectDetails(permissions: const ['android.permission.INTERNET']);

    await pumpPage(tester);
    await switchTab(tester, '权限');

    expect(find.text('android.permission.INTERNET'), findsOneWidget);
    expect(find.text('无权限声明'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('groupComponentsByType：按组件类型分组，顺序 Service→Activity→Provider，空类型跳过', () {
    final hits = [
      const ComponentLibraryHit(
        componentName: 'com.a.MonitorService',
        componentType: 1,
        ruleName: 'com.a.MonitorService',
        label: '监控服务',
        isRegex: false,
      ),
      const ComponentLibraryHit(
        componentName: 'com.b.CustomerActivity',
        componentType: 2,
        ruleName: 'com.b.CustomerActivity',
        label: '客户页面',
        isRegex: false,
      ),
      const ComponentLibraryHit(
        componentName: 'com.c.SetupProvider',
        componentType: 4,
        ruleName: 'com.c.SetupProvider',
        label: '配置提供者',
        isRegex: false,
      ),
    ];

    final groups = SdkAnalysisPage.groupComponentsByType(hits);

    // 仅出现的类型按 Service→Activity→Provider 顺序；未出现的类型跳过
    expect(groups.map((g) => g.label).toList(), ['Service', 'Activity', 'Provider']);
    expect(groups.map((g) => g.type).toList(), [1, 2, 4]);
    // 每个分组计数与命中一致（对应页面组头的 count 徽标）
    expect(groups[0].items, hasLength(1));
    expect(groups[1].items, hasLength(1));
    expect(groups[2].items, hasLength(1));
  });

  testWidgets('SDK 分析页：原生库/DEX/组件/权限空态提示', (tester) async {
    injectEmptyRules();
    injectDetails();

    await pumpPage(tester);

    await switchTab(tester, '原生库');
    expect(find.text('未检测到原生库'), findsOneWidget);

    await switchTab(tester, 'DEX 类名');
    expect(find.text('未检测到 DEX 类名'), findsOneWidget);

    await switchTab(tester, '组件');
    expect(find.text('未检测到组件'), findsOneWidget);

    await switchTab(tester, '权限');
    expect(find.text('无权限声明'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}