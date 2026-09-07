import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/page/installed_apps/sdk_analysis_page.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页的挂载冒烟测试。
///
/// 注入空规则集使三路分析器短路（无 isolate/FFI 真实 IO），
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

  testWidgets('SDK 分析页：加载中 → 空结果展示「未检测到已知 SDK」', (tester) async {
    // 空规则注入：analyzeNativeLibraries / analyzeDexLibraries / analyzeComponents
    // 均在加载规则后短路返回空列表，避免真实 APK 文件与 FFI 依赖。
    ApkLibraryAnalyzer.instance.debugSetRules(const []);
    ApkLibraryAnalyzer.instance.debugSetDexRules(const []);
    ApkLibraryAnalyzer.instance.debugSetComponentRules(const []);
    addTearDown(() {
      ApkLibraryAnalyzer.instance.debugSetRules(null);
      ApkLibraryAnalyzer.instance.debugSetDexRules(null);
      ApkLibraryAnalyzer.instance.debugSetComponentRules(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SdkAnalysisPage(
          app: buildApp(),
          sourceDir: '/no/such/file.apk',
        ),
      ),
    );
    // 首帧：加载态
    expect(find.byType(SdkAnalysisPage), findsOneWidget);
    expect(find.text('测试应用'), findsOneWidget);
    expect(find.text('com.example.test'), findsOneWidget);

    // 推进 microtask，等待三路分析完成
    await tester.pump();
    await tester.pump();

    expect(find.text('未检测到已知 SDK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
