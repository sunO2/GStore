import 'dart:collection';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';

import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/page/installed_apps/sdk_analysis_page.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页（LibChecker 式多 Tab 分类）测试。
///
/// 注入空规则集使三路分析器短路（无 isolate/FFI 真实 IO），
/// 详情数据（权限/ABI/全量原生库/应用详情/组件清单）同样通过测试注入短路；
/// Future 仅经 microtask 完成，可在 testWidgets 的 FakeAsync 内推进。
/// 「原生库 tab 全量 .so」测试使用真实假 APK（zip）+ compute，
/// 通过 runAsync 轮询（参考 detail_readme_section_test）等待 isolate 结果。
void main() {
  // Clipboard.setData 走 SystemChannels.platform：测试环境 mock 为直接成功，
  // 供「长按复制」用例推进（AppDialogs snaker 呈现需要 scaffoldMessengerKey）。
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

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

  /// 注入合成详情数据（ABI/权限/全量原生库/全量 DEX/应用详情/组件清单/
  /// 构建版本/ELF 16KB 扫描）并清理。
  void injectDetails({
    List<String> abis = const [],
    List<String> permissions = const [],
    List<NativeAbiLibs> fullLibs = const [],
    List<DexFile> dexFiles = const [],
    InstalledAppDetail detail = const InstalledAppDetail(),
    ApkComponents? components,
    BuildVersionInfo buildVersions = const BuildVersionInfo(),
    ApkElfScanResult elfScan = const ApkElfScanResult(soFiles: []),
    ApkSignatureSchemes? schemes,
    ApkFeatures? features,
    ApkManifestInfo? manifest,
    List<RuleHit>? staticActionHits,
    ({List<ComponentStateDetail> components, List<PermissionStateDetail> permissions})?
        componentsDetail = const (components: [], permissions: []),
  }) {
    ApkLibraryAnalyzer.instance.debugSetAbis(abis);
    ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(fullLibs);
    ApkLibraryAnalyzer.instance.debugSetDexFilesFull(dexFiles);
    ApkLibraryAnalyzer.instance.debugSetBuildVersions(buildVersions);
    ApkSourceService.instance.debugSetPermissions(permissions);
    ApkSourceService.instance.debugSetInstalledAppDetail(detail);
    ApkSourceService.instance.debugSetComponentsDetail(componentsDetail);
    SdkAnalysisPage.debugSetComponents(components);
    SdkAnalysisPage.debugSetElfScan(elfScan);
    SdkAnalysisPage.debugSetSignatureSchemes(schemes);
    SdkAnalysisPage.debugSetFeatures(features);
    SdkAnalysisPage.debugSetManifest(manifest);
    SdkAnalysisPage.debugSetStaticActionHits(staticActionHits);
    addTearDown(() {
      ApkLibraryAnalyzer.instance.debugSetAbis(null);
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(null);
      ApkLibraryAnalyzer.instance.debugSetDexFilesFull(null);
      ApkLibraryAnalyzer.instance.debugSetBuildVersions(null);
      ApkSourceService.instance.debugSetPermissions(null);
      ApkSourceService.instance.debugSetInstalledAppDetail(null);
      ApkSourceService.instance.debugSetComponentsDetail(null);
      SdkAnalysisPage.debugSetComponents(null);
      SdkAnalysisPage.debugSetElfScan(null);
      SdkAnalysisPage.debugSetSignatureSchemes(null);
      SdkAnalysisPage.debugSetFeatures(null);
      SdkAnalysisPage.debugSetManifest(null);
      SdkAnalysisPage.debugSetStaticActionHits(null);
    });
  }

  /// 挂载页面并推进 microtask 等待全部异步完成。
  /// 注册 AppDialogs 所需的全局 navigator / scaffoldMessenger key，
  /// 使弹窗与 SnackBar 提示可在测试宿主内呈现。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
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
  /// Tab 数量较多需横向滚动，先 ensureVisible 再点击。
  Future<void> switchTab(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// 反复推进真实异步 + 刷新帧直到 TabBar 出现（分析完成），
  /// 避免 fake-async 时钟下 compute isolate 永不完成。
  Future<void> pumpUntilTabBar(WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(TabBar).evaluate().isNotEmpty) return;
    }
    fail('SDK 分析页加载超时（TabBar 未出现）');
  }

  /// 生成包含指定条目的假 APK（zip，同步写盘——FakeAsync 内不可 await 真实 IO）。
  /// 条目形如 `lib/arm64-v8a/libx.so`；可用冒号后缀 `lib/x86/liby.so:2048`
  /// 指定该文件的 zip 解压后字节数（默认 4，与内容字节数一致）。
  String buildFakeApkSync(List<String> entries) {
    final dir = Directory.systemTemp.createTempSync('gstore_sdk_page_test');
    final archive = Archive();
    for (final entry in entries) {
      final parts = entry.split(':');
      final name = parts.first;
      final size = parts.length > 1 ? int.parse(parts[1]) : 4;
      archive.addFile(ArchiveFile(name, size, List<int>.filled(size, 1)));
    }
    final bytes = ZipEncoder().encode(archive)!;
    File('${dir.path}/fake.apk').writeAsBytesSync(bytes);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return '${dir.path}/fake.apk';
  }

  testWidgets('SDK 分析页：加载完成后出现七个 Tab 分类', (tester) async {
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

    // 七个 Tab 按序出现
    expect(find.byType(TabBar), findsOneWidget);
    for (final label in [
      '概览',
      '原生库',
      'DEX 类名',
      '组件',
      '权限',
      '签名',
      'meta 数据',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览键值行 + SDK 版本未知降级 + ABI chips', (tester) async {
    injectEmptyRules();
    injectDetails(abis: const ['arm64-v8a', 'armeabi-v7a']);

    await pumpPage(tester);

    // 包名/安装路径（版本已移至头部徽标行，概览不再重复）
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.example.test'), findsNWidgets(2)); // 头部 + 概览行
    expect(find.text('安装路径'), findsOneWidget);
    expect(find.text('/no/such/file.apk'), findsOneWidget);
    // 头部概览徽标：版本(code) / SDK 摘要
    expect(find.text('1.0.0 (1)'), findsOneWidget);
    expect(find.text('SDK 未知 – 未知'), findsOneWidget);
    // 新增行（详情为空 → 全部「未知」）
    expect(find.text('主 Activity'), findsOneWidget);
    expect(find.text('安装时间'), findsOneWidget);
    expect(find.text('最近更新'), findsOneWidget);
    // SDK 版本解析失败 + 详情缺失 → 共 15 处「未知」降级
    // （主 Activity/安装时间/最近更新/minSdk/targetSdk + 新增
    // UID/共享 UID/安装来源/数据目录 + Kotlin/Gradle/Java/Compose/AGP 构建版本 +
    // 16KB 对齐（无 ELF 扫描数据）；APK 大小/版本已移至头部徽标）
    expect(find.text('minSdk'), findsOneWidget);
    expect(find.text('targetSdk'), findsOneWidget);
    expect(find.text('未知'), findsNWidgets(15));
    // ABI 非空 → 渲染 chips
    expect(find.text('ABI 架构'), findsOneWidget);
    expect(find.text('arm64-v8a'), findsOneWidget);
    expect(find.text('armeabi-v7a'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览展示主 Activity/APK 大小/安装时间与详情 SDK 版本', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        mainActivity: 'com.example.MainActivity',
        apkSize: 13107200, // 12.5 * 1024 * 1024 → 12.5 MB
        firstInstallTime: 0,
        lastUpdateTime: 0,
        minSdk: 24,
        targetSdk: 34,
      ),
    );

    await pumpPage(tester);

    expect(find.text('主 Activity'), findsOneWidget);
    expect(find.text('com.example.MainActivity'), findsOneWidget);
    // APK 大小已移至头部徽标行（唯一展示）
    expect(find.text('12.5 MB'), findsOneWidget);
    // 安装时间/最近更新为 0 → 未知；minSdk/targetSdk 回退详情值；
    // 新增系统行（UID/共享 UID/安装来源/数据目录）与构建版本行
    // （Kotlin/Gradle/Java/Compose/AGP）详情缺失 + 16KB 对齐（无 ELF 扫描数据） → 未知
    expect(find.text('未知'), findsNWidgets(12));
    expect(find.text('24'), findsOneWidget);
    expect(find.text('34'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览展示 Kotlin/Gradle/Java 构建版本，缺失降级未知', (tester) async {
    injectEmptyRules();
    injectDetails(
      buildVersions: const BuildVersionInfo(
        kotlinVersion: '2.0.20',
        gradleVersion: '8.7',
        javaVersion: '17',
      ),
    );

    await pumpPage(tester);

    // 三行标签 + 注入的版本值
    expect(find.text('Kotlin'), findsOneWidget);
    expect(find.text('Gradle'), findsOneWidget);
    expect(find.text('Java'), findsOneWidget);
    expect(find.text('2.0.20'), findsOneWidget);
    expect(find.text('8.7'), findsOneWidget);
    expect(find.text('17'), findsOneWidget);
    // 构建版本全部命中 → 此轮无构建版本相关的「未知」
    // （其余 detail/系统行 + Compose/AGP 缺失 + 16KB 对齐缺失 → 12 处未知；
    // APK 大小/版本已移至头部徽标）
    expect(find.text('未知'), findsNWidgets(12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览安装/更新时间按 yyyy-MM-dd 格式化', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        firstInstallTime: 1704412800000, // 2024-01-05 00:00 UTC
        lastUpdateTime: 1717200000000, // 2024-06-01 00:00 UTC
      ),
    );

    await pumpPage(tester);

    expect(find.text('2024-01-05'), findsOneWidget);
    expect(find.text('2024-06-01'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：原生库 tab 展示全量 .so 按 ABI 分组，命中高亮 vs 未命中平淡，行尾展示文件大小', (tester) async {
    final apkPath = buildFakeApkSync([
      'lib/arm64-v8a/libmatched.so', // 命中 → 4 B
      'lib/arm64-v8a/libplain.so:1572864', // 未命中 → 1.5 MB
      'lib/x86/libother.so:3072', // 未命中 → 3.0 KB
      'classes.dex',
      'AndroidManifest.xml',
    ]);

    // 只注入原生库规则：libmatched.so 命中；DEX/组件规则保持空 → 短路
    ApkLibraryAnalyzer.instance.debugSetRules([
      NativeLibraryRule(
        name: 'libmatched.so',
        label: '匹配 SDK',
        type: 0,
        isRegexRule: false,
      ),
    ]);
    ApkLibraryAnalyzer.instance.debugSetDexRules(const []);
    ApkLibraryAnalyzer.instance.debugSetComponentRules(const []);
    ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(null); // 走真实扫描
    addTearDown(() {
      ApkLibraryAnalyzer.instance.debugSetRules(null);
      ApkLibraryAnalyzer.instance.debugSetDexRules(null);
      ApkLibraryAnalyzer.instance.debugSetComponentRules(null);
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SdkAnalysisPage(app: buildApp(), sourceDir: apkPath),
      ),
    );
    // compute isolate + 真实 zip 扫描：runAsync 轮询直到加载完成
    await pumpUntilTabBar(tester);

    await switchTab(tester, '原生库');

    // ABI 分组头（各 `.so` 一条）
    expect(find.text('arm64-v8a'), findsOneWidget);
    expect(find.text('x86'), findsOneWidget);
    expect(find.text('libmatched.so'), findsOneWidget);
    expect(find.text('libplain.so'), findsOneWidget);
    expect(find.text('libother.so'), findsOneWidget);
    // 命中行：SDK 标签可见（高亮样式走 _buildItem）
    expect(find.text('匹配 SDK'), findsOneWidget);
    // 未命中行副标题：libplain / libother 各一处
    expect(find.text('未匹配规则'), findsNWidgets(2));
    // 行尾文件大小（_formatBytes）：命中行与未命中行均展示
    expect(find.text('4 B'), findsOneWidget); // 命中行 libmatched.so
    expect(find.text('1.5 MB'), findsOneWidget); // 未命中行 libplain.so
    expect(find.text('3.0 KB'), findsOneWidget); // 未命中行 libother.so
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：原生库 .so 行展示 16KB 对齐徽标（命中/未命中），概览汇总', (tester) async {
    injectEmptyRules();
    injectDetails(
      fullLibs: const [
        NativeAbiLibs(abi: 'arm64-v8a', soFiles: [
          NativeSoFile(name: 'libok.so', size: 4096),
          NativeSoFile(name: 'libbad.so', size: 8192),
        ]),
      ],
      elfScan: const ApkElfScanResult(soFiles: [
        ElfSoInfo(
          abi: 'arm64-v8a',
          soName: 'libok.so',
          minPageSize: 16384,
          aligned16Kb: true,
        ),
        ElfSoInfo(
          abi: 'arm64-v8a',
          soName: 'libbad.so',
          minPageSize: 4096,
          aligned16Kb: false,
        ),
      ]),
    );

    await pumpPage(tester);

    // 概览汇总：1 个不兼容 / 2 个
    expect(find.text('16KB 对齐'), findsOneWidget);
    expect(find.text('1 个不兼容 / 2 个'), findsOneWidget);

    // 原生库 tab：仅 16KB 对齐的行展示「16KB」胶囊（libok.so），
    // 未对齐（libbad.so）与数据缺失不展示。
    await switchTab(tester, '原生库');
    expect(find.text('libok.so'), findsOneWidget);
    expect(find.text('libbad.so'), findsOneWidget);
    expect(find.text('16KB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：16KB 数据缺失时原生库行无徽标、概览汇总未知', (tester) async {
    injectEmptyRules();
    injectDetails(
      fullLibs: const [
        NativeAbiLibs(abi: 'arm64-v8a', soFiles: [
          NativeSoFile(name: 'libplain.so', size: 4096),
        ]),
      ],
      // elfScan 默认空 → 不注入
    );

    await pumpPage(tester);

    // 概览汇总「未知」
    expect(find.text('16KB 对齐'), findsOneWidget);
    expect(find.text('未知'), findsWidgets);

    await switchTab(tester, '原生库');
    expect(find.text('libplain.so'), findsOneWidget);
    // 无 16KB 胶囊
    expect(find.text('16KB'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：组件 tab 展示全部组件区段并按类型计数', (tester) async {
    injectEmptyRules();
    injectDetails(
      components: const ApkComponents(
        packageName: 'com.example.test',
        minSdk: '24',
        targetSdk: '34',
        services: ['com.example.Svc'],
        activities: ['com.example.ActA', 'com.example.ActB'],
        receivers: [],
        providers: ['com.example.Prov'],
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, '组件');

    // 全部组件区段 + 全局计数（1+2+1=4）
    expect(find.text('全部组件'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    // 类型分组头（空类型不出现）
    expect(find.text('Service'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Provider'), findsOneWidget);
    expect(find.text('Receiver'), findsNothing);
    // 类型计数徽标：Activity 为 2
    expect(find.text('2'), findsOneWidget);
    // 组件名全部列出
    expect(find.text('com.example.Svc'), findsOneWidget);
    expect(find.text('com.example.ActA'), findsOneWidget);
    expect(find.text('com.example.ActB'), findsOneWidget);
    expect(find.text('com.example.Prov'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：签名 tab 列出证书主题与 SHA-256 指纹', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        signatures: [
          SignatureInfo(
            algorithm: 'SHA256withRSA',
            subject: 'CN=Google, O=Android',
            sha256: 'aa:bb:cc:dd',
            sha1: '11:22:33:44',
          ),
        ],
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, '签名');

    expect(find.text('CN=Google, O=Android'), findsOneWidget);
    expect(find.textContaining('aa:bb:cc:dd'), findsOneWidget);
    expect(find.text('SHA256withRSA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：签名主体长文本完整换行不截断', (tester) async {
    const longSubject =
        'CN=Android Debug, OU=Android Department, O=Example Inc, '
        'L=Mountain View, ST=California, C=US';
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        signatures: [
          SignatureInfo(
            algorithm: 'SHA256withRSA',
            subject: longSubject,
            sha256: 'aa:bb:cc:dd',
            sha1: '11:22:33:44',
          ),
        ],
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, '签名');

    // 完整主题文本整段渲染（非单行省略）
    expect(find.text(longSubject), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：点击签名卡片打开签名详情弹窗并关闭', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        signatures: [
          SignatureInfo(
            algorithm: 'SHA256withRSA',
            subject: 'CN=Google, O=Android',
            sha256: 'aa:bb:cc:dd',
            sha1: '11:22:33:44',
          ),
        ],
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, '签名');

    await tester.tap(find.text('CN=Google, O=Android'));
    await tester.pumpAndSettle();

    // 详情弹窗：标题 + 全字段（主题/算法/SHA-256/SHA-1）
    expect(find.text('签名详情'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('算法'), findsOneWidget);
    expect(find.text('SHA-256'), findsOneWidget);
    expect(find.text('SHA-1'), findsOneWidget);
    expect(find.text('CN=Google, O=Android'), findsNWidgets(2)); // 卡片 + 弹窗
    // 弹窗内值独立成段（卡片内为 'SHA-256 aa:bb:cc:dd' 拼接文本）
    expect(find.text('aa:bb:cc:dd'), findsOneWidget);
    expect(find.text('11:22:33:44'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('签名详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：长按签名卡片复制完整证书并弹出 SnackBar', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        signatures: [
          SignatureInfo(
            algorithm: 'SHA256withRSA',
            subject: 'CN=Google, O=Android',
            sha256: 'aa:bb:cc:dd',
            sha1: '11:22:33:44',
          ),
        ],
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, '签名');

    await tester.longPress(find.text('CN=Google, O=Android'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：长按 meta 键药丸复制键并弹出 SnackBar', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        metaData: {
          'flavor': 'release',
        },
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, 'meta 数据');

    await tester.longPress(find.text('flavor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：DEX 类名 tab 展示全量 DEX 文件名称与格式化大小', (tester) async {
    injectEmptyRules();
    injectDetails(
      dexFiles: const [
        DexFile(name: 'classes.dex', size: 1024), // 1.0 KB
        DexFile(name: 'classes2.dex', size: 1572864), // 1.5 MB
      ],
    );

    await pumpPage(tester);
    await switchTab(tester, 'DEX 类名');

    // 规则命中为空、全量 DEX 非空 → 仅「DEX 文件」区段（非空态）
    expect(find.text('DEX 文件'), findsOneWidget);
    expect(find.text('未检测到 DEX 类名'), findsNothing);
    expect(find.text('classes.dex'), findsOneWidget);
    expect(find.text('classes2.dex'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('1.5 MB'), findsOneWidget);
    // 计数徽标为 2
    expect(find.text('2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：DEX 文件行展示模块读出的类数量', (tester) async {
    injectEmptyRules();
    injectDetails(
      dexFiles: const [
        DexFile(name: 'classes.dex', size: 1024, classCount: 523),
        // 未知类数量（-1）时不追加后缀，仅展示大小
        DexFile(name: 'classes2.dex', size: 2048),
      ],
    );

    await pumpPage(tester);
    await switchTab(tester, 'DEX 类名');

    expect(find.text('1.0 KB · 523 类'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览系统信息行默认降级（未知/否）', (tester) async {
    injectEmptyRules();
    injectDetails();

    await pumpPage(tester);

    expect(find.text('UID'), findsOneWidget);
    expect(find.text('共享 UID'), findsOneWidget);
    expect(find.text('安装来源'), findsOneWidget);
    expect(find.text('是否系统应用'), findsOneWidget);
    expect(find.text('是否调试'), findsOneWidget);
    expect(find.text('数据目录'), findsOneWidget);
    // 系统行 UID/共享 UID/安装来源/数据目录 + 构建版本行 Kotlin/Gradle/Java
    // + Compose/AGP 缺失 + 16KB 对齐（无 ELF 扫描数据） → 未知（版本/包名/APK 大小等行不叠加）
    expect(find.text('未知'), findsNWidgets(15));
    expect(find.text('是'), findsNothing);
    expect(find.text('否'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：概览系统信息行展示真实 detail 值', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        uid: 10123,
        sharedUserId: 'com.android.shared',
        installer: 'com.android.vending',
        isSystemApp: true,
        isDebuggable: false,
        dataDir: '/data/data/com.example.test',
      ),
    );

    await pumpPage(tester);

    expect(find.text('10123'), findsOneWidget);
    expect(find.text('com.android.shared'), findsOneWidget);
    expect(find.text('com.android.vending'), findsOneWidget);
    expect(find.text('是'), findsOneWidget);
    expect(find.text('否'), findsOneWidget);
    expect(find.text('/data/data/com.example.test'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SDK 分析页：meta 数据 tab 键值行展示（键排序）', (tester) async {
    injectEmptyRules();
    injectDetails(
      detail: const InstalledAppDetail(
        metaData: {
          'flavor': 'release',
          'channel': 'play',
        },
      ),
    );

    await pumpPage(tester);
    await switchTab(tester, 'meta 数据');

    expect(find.text('meta 数据'), findsNWidgets(2)); // TabBar 标签 + 组头
    expect(find.text('channel'), findsOneWidget);
    expect(find.text('play'), findsOneWidget);
    expect(find.text('flavor'), findsOneWidget);
    expect(find.text('release'), findsOneWidget);
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

  testWidgets('SDK 分析页：各 Tab 空态提示', (tester) async {
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

    await switchTab(tester, '签名');
    expect(find.text('无签名信息'), findsOneWidget);

    await switchTab(tester, 'meta 数据');
    expect(find.text('无 meta-data'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('InstalledAppDetail.fromJson：兼容 MethodChannel 的 HashMap<Object?, Object?> 嵌套签名（回归）', () {
    // MethodChannel 解码嵌套 map 的类型是 HashMap<Object?, Object?>，
    // 曾因 whereType<Map<String, dynamic>>() 的 reified 检查全部被过滤 → 签名恒为空。
    final rawSignature = HashMap<Object?, Object?>.from({
      'algorithm': 'SHA256withRSA',
      'subject': 'CN=MethodChannel',
      'sha256': 'ab:cd:ef:01',
      'sha1': '11:22:33:44',
    });

    final detail = InstalledAppDetail.fromJson({
      'signatures': <Object?>[rawSignature],
      'metaData': <Object?, Object?>{},
    });

    expect(detail.signatures, hasLength(1));
    expect(detail.signatures.single.subject, 'CN=MethodChannel');
    expect(detail.signatures.single.algorithm, 'SHA256withRSA');
    expect(detail.signatures.single.sha256, 'ab:cd:ef:01');
    expect(detail.signatures.single.sha1, '11:22:33:44');
  });

  test('InstalledAppDetail.fromJson：多签名证书全部保留（并列签名者 / 轮换历史）', () {
    // 回归：此前 Android 侧只用已废弃的 GET_SIGNATURES，取不到「多签名者」与
    // 「签名轮换历史」，导致有多个签名的应用只展示 1 张证书。
    final detail = InstalledAppDetail.fromJson({
      'signingShape': 'rotation',
      'signatures': <Object?>[
        HashMap<Object?, Object?>.from({
          'subject': 'CN=Old',
          'sha256': 'aa:aa',
          'kind': 'history',
        }),
        HashMap<Object?, Object?>.from({
          'subject': 'CN=Current',
          'sha256': 'bb:bb',
          'kind': 'current',
        }),
      ],
    });

    expect(detail.signingShape, 'rotation');
    expect(detail.signatures, hasLength(2));
    expect(detail.signatures.first.kind, 'history');
    expect(detail.signatures.first.isHistory, isTrue);
    expect(detail.signatures.last.kind, 'current');
    expect(detail.signatures.last.isHistory, isFalse);
  });

  test('InstalledAppDetail.fromJson：旧版通道无 signingShape/kind 时降级为单证书', () {
    final detail = InstalledAppDetail.fromJson({
      'signatures': <Object?>[
        HashMap<Object?, Object?>.from({'subject': 'CN=Legacy'}),
      ],
    });

    expect(detail.signingShape, 'single');
    expect(detail.signatures.single.kind, '');
    expect(detail.signatures.single.isHistory, isFalse);
  });

  group('快捷启动（深链）提取与展示', () {
    ApkManifestInfo sampleManifest() => const ApkManifestInfo(
          packageName: 'com.example.demo',
          components: [
            ManifestComponent(
              kind: 'activity',
              name: 'com.example.demo.MainActivity',
              // 仅 LAUNCHER、无 data → 不应计入深链
              intentFilters: [
                ManifestIntentFilter(
                  actions: ['android.intent.action.MAIN'],
                  categories: ['android.intent.category.LAUNCHER'],
                ),
              ],
            ),
            ManifestComponent(
              kind: 'activity',
              name: 'com.example.demo.DeepActivity',
              intentFilters: [
                // 自定义 scheme + pathPrefix
                ManifestIntentFilter(
                  actions: ['android.intent.action.VIEW'],
                  categories: ['android.intent.category.BROWSABLE'],
                  data: [
                    ManifestIntentData(
                      scheme: 'myapp',
                      host: 'open',
                      pathPrefix: '/detail',
                    ),
                    // 与 DeepService 的 URI 相同但来源组件不同 → 两条都要保留
                    ManifestIntentData(scheme: 'myapp', host: 'open'),
                  ],
                ),
                // App Links：https + autoVerify，同一 filter 下两条并列 data
                ManifestIntentFilter(
                  actions: ['android.intent.action.VIEW'],
                  autoVerify: true,
                  data: [
                    ManifestIntentData(
                      scheme: 'https',
                      host: 'www.example.com',
                      pathPattern: '/p/[0-9]+',
                    ),
                    ManifestIntentData(
                      scheme: 'https',
                      host: 'm.example.com',
                      port: '8443',
                    ),
                  ],
                ),
              ],
            ),
            ManifestComponent(
              kind: 'service',
              name: 'com.example.demo.DeepService',
              intentFilters: [
                ManifestIntentFilter(
                  data: [ManifestIntentData(scheme: 'myapp', host: 'open')],
                ),
                // 与 DeepActivity 完全重复的数据 → 保留（来源组件不同）
                ManifestIntentFilter(
                  data: [ManifestIntentData(scheme: 'myapp', host: 'open')],
                ),
              ],
            ),
          ],
        );

    test('intentDataToUri：各路径取值与边界', () {
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(scheme: 'myapp', host: 'open', path: '/a'),
        ),
        'myapp://open/a',
      );
      // pathPrefix 补 * 表示前缀匹配
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(
            scheme: 'myapp',
            host: 'open',
            pathPrefix: '/detail',
          ),
        ),
        'myapp://open/detail*',
      );
      // 精确 path 优先于 pathPrefix
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(
            scheme: 'myapp',
            host: 'open',
            path: '/exact',
            pathPrefix: '/prefix',
          ),
        ),
        'myapp://open/exact',
      );
      // pathPattern 正则原样保留
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(
            scheme: 'https',
            host: 'a.com',
            pathPattern: '/p/[0-9]+',
          ),
        ),
        'https://a.com/p/[0-9]+',
      );
      // 带端口、无路径
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(scheme: 'https', host: 'a.com', port: '8443'),
        ),
        'https://a.com:8443',
      );
      // 仅有 scheme（自定义 scheme 的常见写法）
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(scheme: 'alipays'),
        ),
        'alipays://',
      );
      // scheme/host 全空 → 不是深链
      expect(
        SdkAnalysisPage.intentDataToUri(
          const ManifestIntentData(mimeType: 'image/png'),
        ),
        isNull,
      );
    });

    test('quickLaunchEntries：排除无 data、按 scheme 排序、标签正确', () {
      final entries = SdkAnalysisPage.quickLaunchEntries(sampleManifest());

      // LAUNCHER 无 data 被排除 → 3 条自定义 + 2 条 https = 5 条
      expect(entries, hasLength(5));
      expect(entries.every((e) => e.uri.isNotEmpty), isTrue);

      // 排序：https 在 myapp 之前（按 scheme 字典序）
      expect(entries.first.scheme, 'https');
      expect(entries.first.uri, 'https://m.example.com:8443');
      expect(entries.first.tags, contains('App Links'));
      expect(entries.first.autoVerify, isTrue);
      expect(entries.first.viewAction, isTrue);

      // App Links 条目不应同时出现 Web 标签
      expect(entries.first.tags, isNot(contains('Web')));

      // myapp 组内按 URI 排序：'myapp://open' 在前，带 pathPrefix 的在后
      final custom =
          entries.firstWhere((e) => e.uri == 'myapp://open/detail*');
      expect(custom.tags, contains('自定义 scheme'));
      expect(custom.tags, contains('BROWSABLE'));
      expect(custom.componentName, 'com.example.demo.DeepActivity');

      // 同一 URI 不同来源组件 → 两条都保留
      final sameUri = entries.where((e) => e.uri == 'myapp://open').toList();
      expect(sameUri, hasLength(2));
      expect(
        sameUri.map((e) => e.componentName).toSet(),
        {'com.example.demo.DeepActivity', 'com.example.demo.DeepService'},
      );
    });

    test('quickLaunchEntries：相同 (URI, 组件) 去重', () {
      const manifest = ApkManifestInfo(
        components: [
          ManifestComponent(
            kind: 'activity',
            name: 'com.a.B',
            intentFilters: [
              // 同一组件上重复声明同一 data → 只保留一条
              ManifestIntentFilter(
                data: [ManifestIntentData(scheme: 'myapp', host: 'open')],
              ),
              ManifestIntentFilter(
                data: [ManifestIntentData(scheme: 'myapp', host: 'open')],
              ),
            ],
          ),
        ],
      );
      final entries = SdkAnalysisPage.quickLaunchEntries(manifest);
      expect(entries, hasLength(1));
    });

    test('quickLaunchEntries：无 manifest 返回空', () {
      expect(SdkAnalysisPage.quickLaunchEntries(null), isEmpty);
    });

    test('groupQuickLaunchByScheme：按 scheme 分段且保持顺序', () {
      final groups =
          SdkAnalysisPage.groupQuickLaunchByScheme(
              SdkAnalysisPage.quickLaunchEntries(sampleManifest()));
      expect(groups.map((g) => g.scheme).toList(), ['https', 'myapp']);
      expect(groups.first.items, hasLength(2));
      expect(groups.last.items, hasLength(3));
    });

    testWidgets('概览：快捷启动卡片按 scheme 分段展示 URI 与来源组件', (tester) async {
      injectEmptyRules();
      injectDetails(manifest: sampleManifest());

      await pumpPage(tester);
      // 卡片在概览下方，滚动到可见
      await tester.drag(find.text('包名'), const Offset(0, -900));
      await tester.pumpAndSettle();

      expect(find.text('快捷启动'), findsOneWidget);
      expect(find.text('5'), findsWidgets); // 计数徽标
      // scheme 分段头
      expect(find.text('https'), findsOneWidget);
      expect(find.text('myapp'), findsOneWidget);
      // URI 主文案
      expect(find.text('https://m.example.com:8443'), findsOneWidget);
      expect(find.text('myapp://open/detail*'), findsOneWidget);
      // 来源组件 + 标签副文案（两行：标签行 + 组件行）
      expect(
        find.textContaining('activity com.example.demo.DeepActivity'),
        findsWidgets,
      );
      expect(find.textContaining('自定义 scheme · BROWSABLE · VIEW'), findsWidgets);

      // 组件全类名不得被截断：副标题 Text 必须允许多行（maxLines == null）
      final subtitleTexts = tester
          .widgetList<Text>(find.textContaining('activity com.example.demo.'))
          .toList();
      expect(subtitleTexts, isNotEmpty);
      for (final t in subtitleTexts) {
        expect(t.maxLines, isNull, reason: '深链来源组件需换行展示而非截断');
        expect(t.overflow, isNot(TextOverflow.ellipsis));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('APK 解析数据接入 UI（manifest / 签名方案 / 特征 / ELF 元数据 / static+action）', () {
    testWidgets('概览：特征 chips + 签名方案行', (tester) async {
      injectEmptyRules();
      injectDetails(
        schemes: const ApkSignatureSchemes(
          hasV2: true,
          hasV3: true,
          schemes: ['V2', 'V3'],
        ),
        features: const ApkFeatures(
          // 用不与「构建版本行」标签重名的特征，便于断言唯一性
          xposedModule: true,
          playSigning: true,
          agpVersion: '8.7.2',
        ),
      );

      await pumpPage(tester);

      // 签名方案行（概览 buildRows）
      expect(find.text('签名方案'), findsOneWidget);
      expect(find.text('V2 · V3'), findsOneWidget);
      // 特征区段（无特征时不占位，此处有 2 条）
      expect(find.text('特征'), findsOneWidget);
      expect(find.text('Xposed'), findsOneWidget);
      expect(find.text('Play 签名'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('签名 Tab：签名方案区段展示 V1–V4 胶囊', (tester) async {
      injectEmptyRules();
      injectDetails(
        schemes: const ApkSignatureSchemes(
          hasV1: true,
          hasV2: true,
          schemes: ['V1', 'V2'],
        ),
      );

      await pumpPage(tester);
      await switchTab(tester, '签名');

      expect(find.text('签名方案'), findsOneWidget);
      expect(find.text('V1'), findsOneWidget);
      expect(find.text('V2'), findsOneWidget);
      // 无证书信息但存在方案 → 不落空态
      expect(find.text('无签名信息'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('签名 Tab：无证书且无方案时仍是空态', (tester) async {
      injectEmptyRules();
      injectDetails();

      await pumpPage(tester);
      await switchTab(tester, '签名');

      expect(find.text('无签名信息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('权限 Tab：展示 maxSdkVersion 后缀', (tester) async {
      injectEmptyRules();
      injectDetails(
        permissions: const [
          'android.permission.INTERNET',
          'android.permission.READ_PHONE_STATE',
        ],
        manifest: const ApkManifestInfo(
          permissions: [
            ManifestPermission(name: 'android.permission.INTERNET'),
            ManifestPermission(
              name: 'android.permission.READ_PHONE_STATE',
              maxSdkVersion: '29',
            ),
          ],
        ),
      );

      await pumpPage(tester);
      await switchTab(tester, '权限');

      expect(find.text('android.permission.READ_PHONE_STATE · maxSdk 29'),
          findsOneWidget);
      // 无 maxSdkVersion 的权限不追加后缀
      expect(find.text('android.permission.INTERNET'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('原生库 Tab：行副标题展示 ELF 元数据（依赖/JNI/符号表/zip 对齐）',
        (tester) async {
      injectEmptyRules();
      injectDetails(
        fullLibs: const [
          NativeAbiLibs(abi: 'arm64-v8a', soFiles: [
            NativeSoFile(name: 'libnative.so', size: 4096),
          ]),
        ],
        elfScan: const ApkElfScanResult(soFiles: [
          ElfSoInfo(
            abi: 'arm64-v8a',
            soName: 'libnative.so',
            minPageSize: 16384,
            zipAlignment: 4096,
            aligned16Kb: true,
            elfType: 3,
            needed: ['libc.so', 'libm.so'],
            jniEntryPoints: ['Java_com_a_B_c'],
            stripped: true,
          ),
        ]),
      );

      await pumpPage(tester);
      await switchTab(tester, '原生库');

      expect(find.text('libnative.so'), findsOneWidget);
      expect(
        find.text('依赖 2 · JNI 1 · 已剥离 · zip 对齐 4096'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('签名 Tab：多证书全部展示（当前在前、历史在后 + 角色标签 + 张数摘要）',
        (tester) async {
      injectEmptyRules();
      injectDetails(
        detail: const InstalledAppDetail(
          signingShape: 'rotation',
          signatures: [
            // Android 侧按「原始 → 当前」返回，UI 需把历史证书排到后面
            SignatureInfo(
              subject: 'CN=Old Cert',
              sha256: 'aa:aa',
              kind: 'history',
            ),
            SignatureInfo(
              subject: 'CN=Current Cert',
              sha256: 'bb:bb',
              kind: 'current',
            ),
          ],
        ),
      );

      await pumpPage(tester);
      await switchTab(tester, '签名');

      // 两张证书都渲染，且不再落空态
      expect(find.text('无签名信息'), findsNothing);
      expect(find.text('CN=Current Cert'), findsOneWidget);
      expect(find.text('CN=Old Cert'), findsOneWidget);
      // 张数 + 形态摘要
      expect(find.text('2 张证书 · 含轮换历史'), findsOneWidget);
      // 历史证书带角色标签
      expect(find.text('历史证书'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('签名 Tab：并列签名者全部展示并标注角色', (tester) async {
      injectEmptyRules();
      injectDetails(
        detail: const InstalledAppDetail(
          signingShape: 'multiple',
          signatures: [
            SignatureInfo(subject: 'CN=Signer A', kind: 'signer'),
            SignatureInfo(subject: 'CN=Signer B', kind: 'signer'),
          ],
        ),
      );

      await pumpPage(tester);
      await switchTab(tester, '签名');

      expect(find.text('CN=Signer A'), findsOneWidget);
      expect(find.text('CN=Signer B'), findsOneWidget);
      expect(find.text('2 张证书 · 并列签名者'), findsOneWidget);
      expect(find.text('并列签名者'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('组件 Tab：新增「静态库」与「action 命中」区段', (tester) async {
      injectEmptyRules();
      injectDetails(
        staticActionHits: const [
          RuleHit(
            ruleName: 'com.google.android.trichromelibrary',
            label: 'Trichrome',
            kind: 'static',
            matched: 'com.google.android.trichromelibrary',
          ),
          RuleHit(
            ruleName: 'androidx.profileinstaller.action.INSTALL_PROFILE',
            label: 'Jetpack ProfileInstaller',
            kind: 'action',
            matched: 'androidx.profileinstaller.action.INSTALL_PROFILE',
          ),
        ],
      );

      await pumpPage(tester);
      await switchTab(tester, '组件');

      expect(find.text('未检测到组件'), findsNothing);
      expect(find.text('静态库'), findsOneWidget);
      expect(find.text('Trichrome'), findsOneWidget);
      expect(find.text('action 命中'), findsOneWidget);
      expect(find.text('Jetpack ProfileInstaller'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}