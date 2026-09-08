import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/page/installed_apps/sdk_analysis_page.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页的挂载冒烟测试。
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

  testWidgets('SDK 分析页：详情区与空结果展示「未检测到已知 SDK」', (tester) async {
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
    // 首帧：加载态（头部 + loading）
    expect(find.byType(SdkAnalysisPage), findsOneWidget);
    expect(find.text('测试应用'), findsOneWidget);
    expect(find.text('com.example.test'), findsOneWidget);

    // 推进 microtask，等待全部异步完成
    await tester.pump();
    await tester.pump();

    // 详情区：包名/版本/安装路径
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.example.test'), findsNWidgets(2)); // 头部 + 详情行
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('1.0.0 (1)'), findsOneWidget);
    expect(find.text('安装路径'), findsOneWidget);
    expect(find.text('/no/such/file.apk'), findsOneWidget);
    // SDK 版本解析失败 → 降级为「未知」
    expect(find.text('minSdk'), findsOneWidget);
    expect(find.text('targetSdk'), findsOneWidget);
    expect(find.text('未知'), findsNWidgets(2));
    // ABI 为空 → 不渲染 ABI 区块
    expect(find.text('ABI 架构'), findsNothing);
    // 权限为空 → 「无权限声明」
    expect(find.text('权限（0）'), findsOneWidget);
    expect(find.text('无权限声明'), findsOneWidget);
    // SDK 分组为空 → 空态提示
    expect(find.text('未检测到已知 SDK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：注入 ABI 与权限时渲染对应区块', (tester) async {
    injectEmptyRules();
    injectDetails(
      abis: const ['arm64-v8a', 'armeabi-v7a'],
      permissions: const ['android.permission.INTERNET'],
    );

    await pumpPage(tester);

    expect(find.text('ABI 架构'), findsOneWidget);
    expect(find.text('arm64-v8a'), findsOneWidget);
    expect(find.text('armeabi-v7a'), findsOneWidget);
    expect(find.text('权限（1）'), findsOneWidget);
    expect(find.text('android.permission.INTERNET'), findsOneWidget);
    expect(find.text('无权限声明'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
