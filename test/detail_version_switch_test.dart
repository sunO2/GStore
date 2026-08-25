import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/js_detail_channel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/js/js_native_host.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/view.dart';
import 'package:gstore/page/detail/widgets.dart';

/// 详情页"切换版本"交互（Wave 3）widget/logic 级测试。
///
/// 覆盖：
/// ① 脚本渠道 → 更多动作含"切换版本"；非脚本渠道 → 无
/// ② versionOptions 返回 null → 提示不崩
/// ③ 正常：渲染选择器 → 选 env+version 确认 → 调 switchVersion → state.detailInfo 刷新
/// ④ 历史构建：onBuildHistory 被调返回 builds → 选 build → onBuildSelect（无匹配下载 → 提示）
/// ⑤ 取消 → 不调 switchVersion、detailInfo 不变
///
/// 脚本渠道用 _FakeJsChannel（extends JsChannel，覆写脚本方法，不初始化 JS 引擎）。

/// mock InstalledApps 插件方法通道：视为未安装（详情加载的安装检测不触发
/// getAppInfo；testWidgets 假异步下未 mock 的平台调用会挂起）。
void _mockInstalledApps() {
  const channel = MethodChannel('installed_apps');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'isAppInstalled':
        return false;
      default:
        return null;
    }
  });
}

/// 内存版 env store（避免 ConfigStore 依赖）
class _FakeEnvStore implements JsChannelEnvStore {
  @override
  Future<Map<String, String>> load() async => const {};

  @override
  Future<void> save(Map<String, String> env) async {}
}

/// 假脚本渠道：覆写 versionOptions/switchVersion/buildHistory/getAppInfo/getAppDetail
class _FakeJsChannel extends JsChannel {
  _FakeJsChannel({super.channelKey = 'js.version'})
      : super(
          script: '// fake',
          envStore: _FakeEnvStore(),
        );

  Map<String, dynamic>? versionOptionsResult;
  Map<String, dynamic>? switchVersionResult;
  Map<String, dynamic>? buildHistoryResult;

  int versionOptionsCalls = 0;
  int switchVersionCalls = 0;
  int buildHistoryCalls = 0;
  int getAppInfoCalls = 0;
  String? lastSwitchEnv;
  String? lastSwitchVersion;
  Map<String, dynamic>? lastSwitchBuild;
  String? lastVersionOptionsEnv;
  String? lastBuildHistoryVersion;
  String? lastBuildHistoryEnv;

  // ---- Wave B：detailMenu / setNativeHost / invokeScriptMethod ----
  List<Map<String, dynamic>>? detailMenuResult;
  int detailMenuCalls = 0;

  // ---- Wave 3：zip 包 detail.js（页面级 detailChannel）----
  bool hasDetailScript = false;
  IDetailChannel? detailChannel;
  int releaseDetailChannelCalls = 0;
  int getAppDetailCalls = 0;
  ChannelResult<IDetailInfo>? getAppDetailResult;

  @override
  IDetailChannel? getDetailChannel(String appId) {
    if (!hasDetailScript) return null;
    return detailChannel ??= _FakeJsDetailChannel(appId: 'test-app');
  }

  @override
  void releaseDetailChannel(String appId) {
    releaseDetailChannelCalls++;
    super.releaseDetailChannel(appId);
  }

  /// setNativeHost 捕获的 JSNativeHost 注册表（fake 模拟脚本内部经
  /// host.native.call('showVersionPicker'/'refreshDetail') 驱动交互）
  JSNativeHost? capturedNativeHost;

  int invokeScriptMethodCalls = 0;
  String? lastInvokedMethod;
  Map<String, dynamic>? lastInvokedParams;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Map<String, dynamic>>?> detailMenu(String appId) async {
    detailMenuCalls++;
    return detailMenuResult;
  }

  @override
  void setNativeHost(JSNativeHost host) {
    capturedNativeHost = host;
  }

  @override
  Future<dynamic> invokeScriptMethod(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    invokeScriptMethodCalls++;
    lastInvokedMethod = method;
    lastInvokedParams = params;
    // 模拟脚本内部：jscall 经 host.native.call('showVersionPicker') 驱动交互
    // （注入的 Flutter 实现被调）
    switch (method) {
      case 'jsswitchVersion':
        return capturedNativeHost?['ui.showVersionPicker']?.call({
          'title': '切换版本',
          'envs': ['prod', 'test'],
          'versions': [
            {
              'version': '1.0.0',
              'envs': ['prod', 'test'],
              'buildCount': 3
            },
            {
              'version': '2.0.0',
              'envs': ['prod'],
              'buildCount': 1
            },
          ],
          'currentEnv': 'prod',
          'currentVersion': '1.0.0',
        });
      case 'jsrefresh':
        await capturedNativeHost?['ui.refreshDetail']?.call({
          'appId': 'com.example.one',
          'env': 'prod',
          'version': '2.0.0',
        });
        return {'ok': true};
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> versionOptions(
    String appId, {
    String? env,
  }) async {
    versionOptionsCalls++;
    lastVersionOptionsEnv = env;
    return versionOptionsResult;
  }

  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async {
    switchVersionCalls++;
    lastSwitchEnv = env;
    lastSwitchVersion = version;
    lastSwitchBuild = build;
    return switchVersionResult;
  }

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    buildHistoryCalls++;
    lastBuildHistoryVersion = version;
    lastBuildHistoryEnv = env;
    return buildHistoryResult;
  }

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
    String? version,
  }) async {
    getAppInfoCalls++;
    return ChannelResult.success(data: null, from: ChannelType.custom);
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
    String? version,
  }) async {
    getAppDetailCalls++;
    return getAppDetailResult ??
        ChannelResult.success(
          data: JsChannelDetailProxy(const {}),
          from: ChannelType.custom,
        );
  }
}

/// 假 detail 通道（zip 包 detail.js 页面级 runtime）：覆写脚本方法，
/// 不初始化 JS 引擎；断言详情页消费走 detailChannel 而非 entry。
class _FakeJsDetailChannel extends JsDetailChannel {
  _FakeJsDetailChannel({required super.appId})
      : super(
          channelKey: 'js.version',
          detailScript: '// fake detail',
        );

  Map<String, dynamic>? getAppDetailResult;
  Map<String, dynamic>? versionOptionsResult;
  Map<String, dynamic>? switchVersionResult;
  Map<String, dynamic>? buildHistoryResult;
  List<Map<String, dynamic>>? detailMenuResult;

  int getAppDetailCalls = 0;
  int versionOptionsCalls = 0;
  int switchVersionCalls = 0;
  int buildHistoryCalls = 0;
  int detailMenuCalls = 0;
  int callMainCalls = 0;
  String? lastSwitchEnv;
  String? lastSwitchVersion;
  Map<String, dynamic>? lastSwitchBuild;
  String? lastVersionOptionsEnv;
  String? lastBuildHistoryVersion;
  String? lastBuildHistoryEnv;

  /// setNativeHost 捕获的 JSNativeHost 注册表（模拟 detail.js 内部经
  /// host.native.call('showVersionPicker'/'refreshDetail'/'updateDownloadList') 驱动交互）
  JSNativeHost? capturedNativeHost;

  @override
  Future<Map<String, dynamic>?> getAppDetail(
    String appId, {
    String? version,
  }) async {
    getAppDetailCalls++;
    return getAppDetailResult;
  }

  @override
  Future<Map<String, dynamic>?> versionOptions(
    String appId, {
    String? env,
  }) async {
    versionOptionsCalls++;
    lastVersionOptionsEnv = env;
    return versionOptionsResult;
  }

  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async {
    switchVersionCalls++;
    lastSwitchEnv = env;
    lastSwitchVersion = version;
    lastSwitchBuild = build;
    return switchVersionResult;
  }

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    buildHistoryCalls++;
    lastBuildHistoryVersion = version;
    lastBuildHistoryEnv = env;
    return buildHistoryResult;
  }

  @override
  Future<List<Map<String, dynamic>>?> detailMenu(String appId) async {
    detailMenuCalls++;
    return detailMenuResult;
  }

  @override
  void setNativeHost(JSNativeHost host) {
    capturedNativeHost = host;
  }

  @override
  Future<dynamic> callMain(String method,
      [Map<String, dynamic>? params]) async {
    callMainCalls++;
    // 模拟 detail.js 内部：jscall 经 host.native.call('showVersionPicker') 驱动交互
    // （注入的 Flutter 实现被调）
    switch (method) {
      case 'jsswitchVersion':
        return capturedNativeHost?['ui.showVersionPicker']?.call({
          'title': '切换版本',
          'envs': ['prod', 'test'],
          'versions': [
            {
              'version': '1.0.0',
              'envs': ['prod', 'test'],
              'buildCount': 3
            },
            {
              'version': '2.0.0',
              'envs': ['prod'],
              'buildCount': 1
            },
          ],
          'currentEnv': 'prod',
          'currentVersion': '1.0.0',
        });
      case 'jsrefresh':
        await capturedNativeHost?['ui.refreshDetail']?.call({
          'appId': 'com.example.one',
          'env': 'prod',
          'version': '2.0.0',
        });
        return {'ok': true};
    }
    return null;
  }
}

/// 非脚本渠道（用于 ①b：确认非脚本渠道不注入"切换版本"）
class _FakeChannel extends IChannel {
  @override
  ChannelInfo get info => ChannelInfo(
        type: ChannelType.github,
        name: 'github',
        description: '',
        priority: 1,
        enabled: true,
      );

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async {
    return ChannelResult.success(data: null, from: ChannelType.github);
  }

  @override
  Future<void> initialize() async {}

  @override
  bool get isInitialized => true;

  @override
  Future<bool> checkAvailable() async => true;

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: ChannelType.github);

  int getAppDetailCalls = 0;

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    getAppDetailCalls++;
    return ChannelResult.success(
      data: JsChannelDetailProxy({'appId': appId, 'name': 'App One'}),
      from: ChannelType.github,
    );
  }

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: ChannelType.github);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: ChannelType.github);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: ChannelType.github);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: ChannelType.github);

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async =>
      ChannelResult.success(data: true, from: ChannelType.github);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

/// 假聚合服务（showMoreActions 需要 _aggregator 非空）
class _FakeAggregateService implements IAggregateService {
  @override
  Stream<List<AddedAppInfo>> get appsChangedStream => const Stream.empty();

  @override
  Future<void> removeApp({
    required String channelCode,
    required String appId,
  }) async {}

  @override
  Future<bool> isAppAdded({
    required String channelCode,
    required String appId,
  }) async =>
      false;

  @override
  Future<List<AddedAppInfo>> getAllAddedApps() async => [];

  @override
  Future<List<AddedAppInfo>> getAppsByChannel(String channelCode) async => [];

  @override
  Future<int> getTotalCount() async => 0;

  @override
  Future<void> addApps({
    required String channelCode,
    required List<AppSummary> appInfos,
  }) async {}

  @override
  Future<bool> toggleApp({
    required String channelCode,
    required AppSummary appInfo,
  }) async =>
      false;

  @override
  Future<List<String>> getTags({
    required String channelCode,
    required String appId,
  }) async =>
      [];

  @override
  Future<void> setTags({
    required String channelCode,
    required String appId,
    required List<String> tags,
  }) async {}

  @override
  Future<void> clearChannel(String channelCode) async {}

  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async => {};

  @override
  Future<List<AggregatedAppInfo>> getAggregatedApps() async => [];
}

/// versionOptions 返回（脚本契约）
final Map<String, dynamic> _versionOptions = {
  'envs': ['prod', 'test'],
  'versions': [
    {
      'version': '1.0.0',
      'envs': ['prod', 'test'],
      'buildCount': 3
    },
    {
      'version': '2.0.0',
      'envs': ['prod'],
      'buildCount': 1
    },
  ],
  'currentEnv': 'prod',
  'currentVersion': '1.0.0',
};

/// switchVersion 返回（同 getAppDetail 结构）
final Map<String, dynamic> _switchDetail = {
  'appId': 'com.example.one',
  'name': 'App One',
  'version': '2.0.0',
  'packageName': 'com.example.one',
  'developer': 'dev',
  'downloads': [
    {
      'url': 'https://example.com/one-2.0.0.apk',
      'name': 'one-2.0.0.apk',
      'version': '2.0.0',
    },
  ],
};

/// buildHistory 返回
final Map<String, dynamic> _buildHistory = {
  'builds': [
    {
      'num': 3,
      'publishedAt': '2024-01-03',
      'size': 1024,
      'changelog': '修复',
      'installTimes': 10,
      'builtBy': 'ci',
      'ipaName': 'one-1.0.0-3.ipa',
    },
    {
      'num': 2,
      'publishedAt': '2024-01-02',
      'size': 1024,
      'changelog': '新增',
      'installTimes': 8,
      'builtBy': 'ci',
      'ipaName': 'one-1.0.0-2.ipa',
    },
  ],
};

/// detail.js getAppDetail 基础返回。
///
/// JsDetailChannel.load：`getAppDetail` 返回 null → 提前 return（detailMenu 的
/// _refreshActions 不执行，操作宫格为空）。故脚本渠道测试需给非 null 的
/// getAppDetailResult，使 load 完整走 refreshDetail + detailMenu 动作加载。
final Map<String, dynamic> _detailJsBasics = {
  'appId': 'com.example.one',
  'name': 'App One',
  'version': '1.0.0',
};

/// 脚本渠道（detail.js 页面级）通用设置：hasDetailScript → getDetailChannel
/// 返回缓存的 _FakeJsDetailChannel；detailMenuResult 声明宫格动作。
void _setupDetailJs(_FakeJsChannel js, _FakeJsDetailChannel dc) {
  js.hasDetailScript = true;
  js.detailChannel = dc;
  ChannelManager.instance.registerChannel(js);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.reset();
    ModuleManager.instance.bindByType(ChannelManager, ChannelManager.instance);
    ModuleManager.instance
        .bindByType(IAggregateService, _FakeAggregateService());
    _mockInstalledApps();
  });

  DetailLogic buildLogic({ChannelType channel = ChannelType.custom}) {
    final logic = DetailLogic();
    logic.request = AppDetailRequest(
      appId: 'com.example.one',
      name: 'App One',
      packageName: 'com.example.one',
      channel: channel,
    );
    logic.onReady();
    return logic;
  }

  Future<void> pumpHost(WidgetTester tester, DetailLogic logic) async {
    await tester.pumpWidget(
      GetMaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => logic.showMoreActions(context),
                child: const Text('更多'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openMoreActions(WidgetTester tester) async {
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
  }

  Future<void> openVersionSwitcher(WidgetTester tester) async {
    await openMoreActions(tester);
    await tester.tap(find.text('切换版本'));
    await tester.pumpAndSettle();
  }

  testWidgets('① 脚本渠道 → 更多动作含"切换版本"', (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    expect(find.text('切换版本'), findsOneWidget);
    // 脚本声明动作（无图标 → 宫格默认 extension 图标）
    expect(find.byIcon(Icons.extension), findsOneWidget);
  });

  testWidgets('①b 非脚本渠道 → 更多动作无"切换版本"', (tester) async {
    ChannelManager.instance.registerChannel(_FakeChannel());

    final logic = buildLogic(channel: ChannelType.github);
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    expect(find.text('切换版本'), findsNothing);
    expect(find.byIcon(Icons.swap_vert), findsNothing);
  });

  testWidgets('② versionOptions 返回 null → 选择器空列表提示（不崩）', (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    dc.versionOptionsResult = null; // 空数据路径
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 点 env chip → 按需调 detailChannel.versionOptions → null → 空列表提示（不崩）
    await tester.tap(find.text('test'));
    await tester.pumpAndSettle();

    expect(dc.versionOptionsCalls, 1);
    expect(dc.lastVersionOptionsEnv, 'test');
    expect(find.text('该环境暂无版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('③ 正常：选 env+version 确认 → switchVersion → detailInfo 刷新',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    dc.switchVersionResult = _switchDetail;
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 选择器渲染（env chips + 版本列表，数据来自脚本 showVersionPicker options）
    expect(find.text('环境'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
    expect(find.text('test'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);

    // 选 2.0.0 → 确认切换
    await tester.tap(find.text('2.0.0'));
    await tester.pump();
    await tester.tap(find.text('确认切换'));
    await tester.pumpAndSettle();

    // switchVersion 被调（env/version 正确，走 detailChannel）
    expect(dc.switchVersionCalls, 1);
    expect(dc.lastSwitchEnv, 'prod');
    expect(dc.lastSwitchVersion, '2.0.0');

    // detailInfo 整体刷新（新 env+version 详情）
    final detail = logic.state.detailInfo.value;
    expect(detail, isNotNull);
    expect(detail!.version, '2.0.0');
    expect(detail.name, 'App One');
    expect(detail.downloads, hasLength(1));
    expect(detail.downloads.first.url, 'https://example.com/one-2.0.0.apk');
  });

  testWidgets('④ 历史构建：onBuildHistory 返回 builds → 选 build → 无匹配下载提示',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    dc.buildHistoryResult = _buildHistory;
    dc.switchVersionResult = null; // 无匹配下载 → 提示
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 点 1.0.0 行的历史构建
    await tester.tap(find.text('历史构建').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // onBuildHistory 被调（version/env 正确：当前选中 env = prod + 该行 version）
    expect(dc.buildHistoryCalls, 1);
    expect(dc.lastBuildHistoryVersion, '1.0.0');
    expect(dc.lastBuildHistoryEnv, 'prod');
    expect(find.text('构建 #3'), findsOneWidget);
    expect(find.text('构建 #2'), findsOneWidget);

    // 点某项 → onBuildSelect → 无匹配下载 → 提示
    await tester.tap(find.text('构建 #3'));
    await tester.pumpAndSettle();
    expect(find.text('该构建暂不可下载'), findsOneWidget);
  });

  testWidgets('⑤ 取消 → 不调 switchVersion、detailInfo 不变', (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    dc.switchVersionResult = _switchDetail;
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    // 预置初始 detailInfo（切换前版本）
    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
    });
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(dc.switchVersionCalls, 0);
    expect(logic.state.detailInfo.value?.version, '1.0.0');
  });

  testWidgets('⑥ 打开切换版本 → env 切换按需单 env 拉取 versionOptions（初始不预拉取）',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    dc.versionOptionsResult = _versionOptions;
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 初始：脚本 showVersionPicker options 自带版本列表，不预拉取 versionOptions
    expect(dc.versionOptionsCalls, 0);
    expect(find.text('2.0.0'), findsOneWidget);

    // 点 test env chip → 按需单 env 调 detailChannel.versionOptions（env 透传）
    await tester.tap(find.text('test'));
    await tester.pumpAndSettle();

    expect(dc.versionOptionsCalls, 1);
    expect(dc.lastVersionOptionsEnv, 'test');
  });

  testWidgets('⑦ 无 env 交互 → versionOptions 零调用（脚本 options 自带版本列表）',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 详情无 env 预置：打开选择器不预拉取，版本直接来自脚本 options
    expect(dc.versionOptionsCalls, 0);
    expect(find.text('2.0.0'), findsOneWidget);
  });

  // ==================== Wave B：detailMenu 脚本声明详情页操作 ====================

  testWidgets('⑧ 脚本渠道：detailMenu 声明动作 → 宫格用脚本 actions（替换写死"切换版本"）',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
      {'action': '清除缓存', 'jscall': 'jsclearCache'},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // detailMenu 走 detailChannel（load 时刷新动作宫格）
    expect(dc.detailMenuCalls, 1);
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
    expect(find.byIcon(Icons.extension), findsNWidgets(2));
    expect(find.byIcon(Icons.swap_vert), findsNothing,
        reason: '写死"切换版本"被脚本声明替换');
  });

  testWidgets('⑨ 脚本渠道：detailMenu 未实现（null）→ 维持现状：宫格无脚本动作（不崩）',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = null; // 脚本未实现 detailMenu
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // detailMenu 被调但返回 null → 无脚本动作注入（旧写死"切换版本"已移除）
    expect(dc.detailMenuCalls, 1);
    expect(find.text('切换版本'), findsNothing);
    expect(find.byIcon(Icons.extension), findsNothing);
    expect(find.text('操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑩ 点击脚本 action → 关弹框 + 调 jscall + host.native 版本选择器生效',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    await tester.tap(find.text('切换版本'));
    await tester.pumpAndSettle();

    // 更多弹框已关闭（动作点击先关面板再执行）
    expect(find.text('操作'), findsNothing);

    // jscall 走 detailChannel.callMain
    expect(dc.callMainCalls, 1);

    // host.native 注入生效：jscall 内部调 host.native.call('showVersionPicker') → 版本选择器弹出
    expect(dc.capturedNativeHost, isNotNull);
    expect(dc.capturedNativeHost!['ui.showVersionPicker'], isNotNull);
    expect(find.text('环境'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);
  });

  testWidgets('⑪ 点击脚本 action → jscall 模拟 host.native.refreshDetail → 详情刷新',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '刷新详情', 'jscall': 'jsrefresh', 'clickIsDimiss': true},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    await tester.tap(find.text('刷新详情'));
    await tester.pumpAndSettle();

    // jscall 走 detailChannel → 脚本内部 host.native.call('refreshDetail') 刷新 detailInfo
    expect(dc.callMainCalls, 1);
    expect(dc.capturedNativeHost!['ui.refreshDetail'], isNotNull);
    expect(logic.state.detailInfo.value?.version, '2.0.0');
  });

  testWidgets('⑫ 点"更多"：canonical 解析 getAppInfo 仅一次 + detailMenu 走 detailChannel',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // 更多面板打开：detailMenu 走 detailChannel；getAppInfo 仅 canonical 解析一次
    expect(dc.detailMenuCalls, 1);
    expect(js.getAppInfoCalls, 1);
    expect(find.text('切换版本'), findsOneWidget);
  });

  testWidgets(
      '⑬ 点"更多"仅调 detailMenu：零 versionOptions/buildHistory/switchVersion 请求',
      (tester) async {
    final js = _FakeJsChannel();
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    dc.getAppDetailResult = _detailJsBasics;
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
      {'action': '历史构建', 'jscall': 'jsBuildHistory', 'clickIsDimiss': true},
    ];
    _setupDetailJs(js, dc);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // 点"更多"只有 detailMenu（纯菜单，零请求）；build-list 类方法均未触发
    expect(dc.detailMenuCalls, 1);
    expect(dc.versionOptionsCalls, 0);
    expect(dc.buildHistoryCalls, 0);
    expect(dc.switchVersionCalls, 0);
    expect(js.getAppInfoCalls, 1); // 仅 canonical 解析一次
    // 宫格渲染脚本声明动作
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.text('历史构建'), findsOneWidget);
  });

  // ==================== Wave 3：zip 包 detail.js（页面级 detailChannel） ====================

  testWidgets('ⓐ 有 detail.js → 详情加载走 detailChannel.getAppDetail（entry 不被调）',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    js.detailChannel = dc;
    dc.getAppDetailResult = {
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
      // 不设 packageName：避免 testWidgets 假异步下 InstalledApps 平台调用挂起
    };
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await tester.pumpAndSettle();

    // detail.js 存在 → getAppDetail 走 detailChannel（entry 原路径不被调）
    // （buildLogic 的 onReady → _initAndLoad 已触发 load，不再重复 loadDetail）
    expect(dc.getAppDetailCalls, 1);
    expect(js.getAppDetailCalls, 0);
    // 有 detail.js → 跳过 entry getAppInfo 预取（避免重复 build-list + login/check）
    expect(js.getAppInfoCalls, 0);
    expect(logic.state.detailInfo.value?.version, '1.0.0');
    expect(logic.state.detailInfo.value?.name, 'App One');
  });

  testWidgets('ⓑ 无 detail.js（getDetailChannel null）→ 详情加载走 entry 原路径（兼容）',
      (tester) async {
    final js = _FakeJsChannel(); // hasDetailScript = false
    js.getAppDetailResult = ChannelResult.success(
      data: JsChannelDetailProxy({
        'appId': 'com.example.one',
        'name': 'App One',
        'version': '1.0.0',
        // 不设 packageName：避免 testWidgets 假异步下 InstalledApps 平台调用挂起
      }),
      from: ChannelType.custom,
    );
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await tester.pumpAndSettle();

    // 无 detail.js → getDetailChannel null → entry getAppDetail 原路径
    // （buildLogic 的 onReady 已触发 load，不再重复 loadDetail）
    expect(js.getAppDetailCalls, 1);
    expect(logic.state.detailInfo.value?.version, '1.0.0');
  });

  testWidgets(
      'ⓒ 有 detail.js → detailMenu 走 detailChannel（entry 不被调）+ host.native 注入',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    js.detailChannel = dc;
    dc.getAppDetailResult = _detailJsBasics; // load 前置：raw 非 null 才会刷 detailMenu 动作
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
      {'action': '清除缓存', 'jscall': 'jsclearCache'},
    ];
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // detailMenu 走 detailChannel（entry 不被调）
    expect(dc.detailMenuCalls, 1);
    expect(js.detailMenuCalls, 0);
    // host.native 注入到 detailChannel（创建于页面初始化，此处补注入）
    expect(dc.capturedNativeHost, isNotNull);
    expect(dc.capturedNativeHost!['ui.showVersionPicker'], isNotNull);
    expect(dc.capturedNativeHost!['ui.refreshDetail'], isNotNull);
    // 宫格渲染 detail.js 声明动作
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
    expect(find.byIcon(Icons.extension), findsNWidgets(2));
  });

  testWidgets(
      'ⓓ 有 detail.js → versionOptions/switchVersion 走 detailChannel（entry 不被调）',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    js.detailChannel = dc;
    dc.getAppDetailResult = _detailJsBasics; // load 前置：非 null 才加载 detailMenu 动作
    // 脚本声明"切换版本"入口（detail.js 无内置写死入口）
    dc.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion'},
    ];
    dc.versionOptionsResult = _versionOptions;
    dc.switchVersionResult = _switchDetail;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 选择器渲染（数据来自脚本 showVersionPicker options）
    expect(find.text('环境'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);

    // 切到 test env → 按需单 env 调 detailChannel.versionOptions（entry 不被调）
    await tester.tap(find.text('test'));
    await tester.pumpAndSettle();
    expect(dc.versionOptionsCalls, 1);
    expect(dc.lastVersionOptionsEnv, 'test');

    // 选 2.0.0 → 确认切换 → switchVersion 全流程走 detailChannel
    await tester.tap(find.text('2.0.0'));
    await tester.pump();
    await tester.tap(find.text('确认切换'));
    await tester.pumpAndSettle();

    expect(dc.switchVersionCalls, 1);
    expect(dc.lastSwitchEnv, 'test');
    expect(dc.lastSwitchVersion, '2.0.0');
    expect(js.versionOptionsCalls, 0);
    expect(js.switchVersionCalls, 0);
    expect(logic.state.detailInfo.value?.version, '2.0.0');
  });

  testWidgets('ⓔ 页面退出（onClose）→ JsChannel.releaseDetailChannel 被调（工厂缓存清理）',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    expect(js.detailChannel, isNotNull,
        reason: '有 detail.js → getDetailChannel 被调');

    logic.onClose();

    expect(js.releaseDetailChannelCalls, 1);
  });

  testWidgets('ⓕ 非脚本渠道（GitHub mock）：详情加载走原 getAppDetail 路径（回归）',
      (tester) async {
    final ch = _FakeChannel();
    ChannelManager.instance.registerChannel(ch);

    final logic = buildLogic(channel: ChannelType.github);
    await tester.pumpAndSettle();

    // 非脚本渠道完全不变：getAppDetail 走 channel 原路径
    // （buildLogic 的 onReady 已触发 load，不再重复 loadDetail）
    expect(ch.getAppDetailCalls, 1);
    expect(logic.state.detailInfo.value?.name, 'App One');
  });

  // ==================== Wave 2：host.native updateDownloadList（切构建历史局部更新下载区） ====================

  /// 预置脚本渠道 + detail.js（先注册渠道再 buildLogic，保证 _initDetailChannel
  /// 拿到 detailChannel）+ 注入 host.native 能力（openMoreActions 触发 setNativeHost）。
  Future<(DetailLogic, _FakeJsDetailChannel)> setupDetailChannel(
    WidgetTester tester,
  ) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    js.detailChannel = dc;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(
        tester); // 触发 setNativeHost 注入（含 updateDownloadList 注册）
    return (logic, dc);
  }

  testWidgets(
      'ⓖ 注入 updateDownloadList → 传 downloads → detailInfo.downloads 局部更新（不重载）',
      (tester) async {
    final (logic, dc) = await setupDetailChannel(tester);
    // 预置当前详情（旧下载区）
    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
      'downloads': [
        {'url': 'https://example.com/old.apk', 'name': 'old.apk'},
      ],
    });

    // 模拟 JS 调 host.native.call('updateDownloadList', {downloads})（切构建历史 → 缓存下载区）
    await dc.capturedNativeHost!['ui.updateDownloadList']!({
      'downloads': [
        {
          'url': 'https://example.com/new.apk',
          'name': 'new.apk',
          'version': '1.0.0',
        },
      ],
    });

    // detailInfo.downloads 局部更新（新下载项），其余字段保持
    final detail = logic.state.detailInfo.value;
    expect(detail, isNotNull);
    expect(detail!.downloads, hasLength(1));
    expect(detail.downloads.first.name, 'new.apk');
    expect(detail.downloads.first.url, 'https://example.com/new.apk');
    expect(detail.version, '1.0.0');
    expect(detail.name, 'App One');
  });

  testWidgets('ⓗ updateDownloadList 不触发重新请求（switchVersion/getAppDetail 零调用）',
      (tester) async {
    final (logic, dc) = await setupDetailChannel(tester);
    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
    });

    await dc.capturedNativeHost!['ui.updateDownloadList']!({
      'downloads': [
        {'url': 'https://example.com/new.apk', 'name': 'new.apk'},
      ],
    });

    // 纯本地更新：不调脚本/不重新请求详情（getAppDetail 仅 setup 初始化 load 一次）
    expect(dc.switchVersionCalls, 0);
    expect(dc.getAppDetailCalls, 1);
    expect(dc.callMainCalls, 0);
  });

  testWidgets('ⓘ detailInfo 为 null → updateDownloadList 不崩', (tester) async {
    final (logic, dc) = await setupDetailChannel(tester);
    // prefill 纪元：setup 的 bind+load 会无条件注入 prefill proxy，
    // 手动置 null 构造真实 null 场景（绕过 load 的 prefill）。
    logic.state.detailInfo.value = null;

    await dc.capturedNativeHost!['ui.updateDownloadList']!({
      'downloads': [
        {'url': 'https://example.com/new.apk', 'name': 'new.apk'},
      ],
    });

    expect(logic.state.detailInfo.value, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ⓙ 下载项 downloadable/note 字段正确透传', (tester) async {
    final (logic, dc) = await setupDetailChannel(tester);
    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
    });

    await dc.capturedNativeHost!['ui.updateDownloadList']!({
      'downloads': [
        {
          'url': '',
          'name': 'locked.apk',
          'downloadable': false,
          'note': '需配置凭证后下载',
        },
      ],
    });

    final detail = logic.state.detailInfo.value;
    final item = detail!.downloads.first;
    expect(item.downloadable, isFalse);
    expect(item.note, '需配置凭证后下载');
  });

  testWidgets('ⓚ 真实下载区消费：pump 详情页 → 注入回调 → 下载区显示新下载项', (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel(appId: 'test-app');
    js.detailChannel = dc;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    Get.put(logic);
    await tester.pumpWidget(const GetMaterialApp(home: DetailPage()));
    // 两次 bind+load 落定：buildLogic 手动 onReady + DisposableInterface
    // post-frame onReady 各触发一次（getAppDetail 均 null）。
    await tester.pump();
    await tester.pump();
    logic.state.errorMessage.value = '';

    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
      // 对齐 view.dart/_buildPrefill：sections 声明下载区
      'sections': ['downloads'],
      'downloads': [
        {'url': 'https://example.com/old.apk', 'name': 'old.apk'},
      ],
    });
    await tester.pump();

    // 初始下载区显示旧下载项
    expect(find.byType(DownloadsSection), findsOneWidget);
    expect(find.text('old.apk'), findsOneWidget);

    // 点"更多"触发 setNativeHost 注入（含 updateDownloadList 注册）
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(dc.capturedNativeHost!['ui.updateDownloadList'], isNotNull);

    // 基线：updateDownloadList 之前的 getAppDetail 次数（buildLogic + 详情页各 load 一次）
    final baselineDetailCalls = dc.getAppDetailCalls;

    // 模拟 JS 调 host.native.call('updateDownloadList', {downloads})（切构建历史 → 缓存下载区）
    await dc.capturedNativeHost!['ui.updateDownloadList']!({
      'downloads': [
        {
          'url': 'https://example.com/new.apk',
          'name': 'new.apk',
          'version': '1.0.0',
        },
      ],
    });
    await tester.pump();

    // 下载区局部刷新：显示新下载项（旧项消失），不重载详情
    expect(find.text('new.apk'), findsOneWidget);
    expect(find.text('old.apk'), findsNothing);
    expect(dc.switchVersionCalls, 0);
    // 纯本地更新：updateDownloadList 不触发重新请求详情
    expect(dc.getAppDetailCalls, baselineDetailCalls);
    expect(tester.takeException(), isNull);
  });
}
