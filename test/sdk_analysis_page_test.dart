import 'dart:collection';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/generated/components.dart';
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
  /// 构建版本）并清理。
  void injectDetails({
    List<String> abis = const [],
    List<String> permissions = const [],
    List<NativeAbiLibs> fullLibs = const [],
    List<DexFile> dexFiles = const [],
    InstalledAppDetail detail = const InstalledAppDetail(),
    ApkComponents? components,
    BuildVersionInfo buildVersions = const BuildVersionInfo(),
  }) {
    ApkLibraryAnalyzer.instance.debugSetAbis(abis);
    ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(fullLibs);
    ApkLibraryAnalyzer.instance.debugSetDexFilesFull(dexFiles);
    ApkLibraryAnalyzer.instance.debugSetBuildVersions(buildVersions);
    ApkSourceService.instance.debugSetPermissions(permissions);
    ApkSourceService.instance.debugSetInstalledAppDetail(detail);
    SdkAnalysisPage.debugSetComponents(components);
    addTearDown(() {
      ApkLibraryAnalyzer.instance.debugSetAbis(null);
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(null);
      ApkLibraryAnalyzer.instance.debugSetDexFilesFull(null);
      ApkLibraryAnalyzer.instance.debugSetBuildVersions(null);
      ApkSourceService.instance.debugSetPermissions(null);
      ApkSourceService.instance.debugSetInstalledAppDetail(null);
      SdkAnalysisPage.debugSetComponents(null);
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

    // 包名/版本/安装路径
    expect(find.text('包名'), findsOneWidget);
    expect(find.text('com.example.test'), findsNWidgets(2)); // 头部 + 概览行
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('1.0.0 (1)'), findsOneWidget);
    expect(find.text('安装路径'), findsOneWidget);
    expect(find.text('/no/such/file.apk'), findsOneWidget);
    // 新增行（详情为空 → 全部「未知」）
    expect(find.text('主 Activity'), findsOneWidget);
    expect(find.text('APK 大小'), findsOneWidget);
    expect(find.text('安装时间'), findsOneWidget);
    expect(find.text('最近更新'), findsOneWidget);
    // SDK 版本解析失败 + 详情缺失 → 共 13 处「未知」降级
    // （主 Activity/APK 大小/安装时间/最近更新/minSdk/targetSdk + 新增
    // UID/共享 UID/安装来源/数据目录 + Kotlin/Gradle/Java 构建版本）
    expect(find.text('minSdk'), findsOneWidget);
    expect(find.text('targetSdk'), findsOneWidget);
    expect(find.text('未知'), findsNWidgets(13));
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
    expect(find.text('APK 大小'), findsOneWidget);
    expect(find.text('12.5 MB'), findsOneWidget);
    // 安装时间/最近更新为 0 → 未知；minSdk/targetSdk 回退详情值；
    // 新增系统行（UID/共享 UID/安装来源/数据目录）与构建版本行
    // （Kotlin/Gradle/Java）详情缺失 → 未知
    expect(find.text('未知'), findsNWidgets(9));
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
    // （其余 detail/系统行缺失 → 10 处未知）
    expect(find.text('未知'), findsNWidgets(10));
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
    // → 未知（版本/包名等行不叠加）
    expect(find.text('未知'), findsNWidgets(13));
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
}