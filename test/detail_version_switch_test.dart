import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/js_detail_channel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/detail/logic.dart';

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

  // ---- Wave B：detailMenu / setUiCallbacks / invokeScriptMethod ----
  List<Map<String, dynamic>>? detailMenuResult;
  int detailMenuCalls = 0;

  // ---- Wave 3：zip 包 detail.js（页面级 detailChannel）----
  bool hasDetailScript = false;
  _FakeJsDetailChannel? detailChannel;
  int releaseDetailChannelCalls = 0;
  int getAppDetailCalls = 0;
  ChannelResult<IDetailInfo>? getAppDetailResult;

  @override
  JsDetailChannel? getDetailChannel(String appId) {
    if (!hasDetailScript) return null;
    return detailChannel ??= _FakeJsDetailChannel();
  }

  @override
  void releaseDetailChannel(String appId) {
    releaseDetailChannelCalls++;
    super.releaseDetailChannel(appId);
  }

  /// setUiCallbacks 捕获的 host.ui 实现（fake 模拟脚本内部调用）
  Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
      capturedShowVersionPicker;
  Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
      capturedShowBuildHistory;
  Future<void> Function(Map<String, dynamic> params)? capturedRefreshDetail;

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
  void setUiCallbacks({
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowVersionPicker,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowBuildHistory,
    Future<void> Function(Map<String, dynamic> params)? uiRefreshDetail,
    Future<void> Function(List<dynamic> downloads)? uiUpdateDownloadList,
  }) {
    capturedShowVersionPicker = uiShowVersionPicker;
    capturedShowBuildHistory = uiShowBuildHistory;
    capturedRefreshDetail = uiRefreshDetail;
  }

  @override
  Future<dynamic> invokeScriptMethod(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    invokeScriptMethodCalls++;
    lastInvokedMethod = method;
    lastInvokedParams = params;
    // 模拟脚本内部：jscall 经 host.ui 驱动交互（注入的 Flutter 实现被调）
    switch (method) {
      case 'jsswitchVersion':
        return capturedShowVersionPicker?.call({
          'title': '切换版本',
          'envs': ['prod', 'test'],
          'versions': [
            {'version': '1.0.0', 'envs': ['prod', 'test'], 'buildCount': 3},
            {'version': '2.0.0', 'envs': ['prod'], 'buildCount': 1},
          ],
          'currentEnv': 'prod',
          'currentVersion': '1.0.0',
        });
      case 'jsrefresh':
        await capturedRefreshDetail?.call({
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
  _FakeJsDetailChannel()
      : super(channelKey: 'js.version', detailScript: '// fake detail');

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

  /// setUiCallbacks 捕获的 host.ui 实现（模拟 detail.js 内部调用）
  Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
      capturedShowVersionPicker;
  Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
      capturedShowBuildHistory;
  Future<void> Function(Map<String, dynamic> params)? capturedRefreshDetail;

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
  void setUiCallbacks({
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowVersionPicker,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowBuildHistory,
    Future<void> Function(Map<String, dynamic> params)? uiRefreshDetail,
    Future<void> Function(List<dynamic> downloads)? uiUpdateDownloadList,
  }) {
    capturedShowVersionPicker = uiShowVersionPicker;
    capturedShowBuildHistory = uiShowBuildHistory;
    capturedRefreshDetail = uiRefreshDetail;
  }

  @override
  Future<dynamic> callMain(String method, [Map<String, dynamic>? params]) async {
    callMainCalls++;
    // 模拟 detail.js 内部：jscall 经 host.ui 驱动交互（注入的 Flutter 实现被调）
    switch (method) {
      case 'jsswitchVersion':
        return capturedShowVersionPicker?.call({
          'title': '切换版本',
          'envs': ['prod', 'test'],
          'versions': [
            {'version': '1.0.0', 'envs': ['prod', 'test'], 'buildCount': 3},
            {'version': '2.0.0', 'envs': ['prod'], 'buildCount': 1},
          ],
          'currentEnv': 'prod',
          'currentVersion': '1.0.0',
        });
      case 'jsrefresh':
        await capturedRefreshDetail?.call({
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
    required ChannelType channel,
    required String appId,
  }) async {}

  @override
  Future<bool> isAppAdded({
    required ChannelType channel,
    required String appId,
  }) async =>
      false;

  @override
  Future<List<AddedAppInfo>> getAllAddedApps() async => [];

  @override
  Future<List<AddedAppInfo>> getAppsByChannel(ChannelType channel) async => [];

  @override
  Future<int> getTotalCount() async => 0;

  @override
  Future<void> addApps({
    required ChannelType channel,
    required List<AppSummary> appInfos,
  }) async {}

  @override
  Future<bool> toggleApp({
    required ChannelType channel,
    required AppSummary appInfo,
  }) async =>
      false;

  @override
  Future<List<String>> getTags({
    required ChannelType channel,
    required String appId,
  }) async =>
      [];

  @override
  Future<void> setTags({
    required ChannelType channel,
    required String appId,
    required List<String> tags,
  }) async {}

  @override
  Future<void> clearChannel(ChannelType channel) async {}

  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async => {};

  @override
  Future<List<AggregatedAppInfo>> getAggregatedApps() async => [];
}

/// versionOptions 返回（脚本契约）
final Map<String, dynamic> _versionOptions = {
  'envs': ['prod', 'test'],
  'versions': [
    {'version': '1.0.0', 'envs': ['prod', 'test'], 'buildCount': 3},
    {'version': '2.0.0', 'envs': ['prod'], 'buildCount': 1},
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
    js.versionOptionsResult = _versionOptions;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    expect(find.text('切换版本'), findsOneWidget);
    expect(find.byIcon(Icons.swap_vert), findsOneWidget);
  });

  testWidgets('①b 非脚本渠道 → 更多动作无"切换版本"', (tester) async {
    ChannelManager.instance.registerChannel(_FakeChannel());

    final logic = buildLogic(channel: ChannelType.github);
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    expect(find.text('切换版本'), findsNothing);
    expect(find.byIcon(Icons.swap_vert), findsNothing);
  });

  testWidgets('② versionOptions 返回 null → 提示不崩', (tester) async {
    final js = _FakeJsChannel();
    js.versionOptionsResult = null;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    expect(js.versionOptionsCalls, 1);
    expect(find.text('无法获取版本选项（脚本未实现或失败）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('③ 正常：选 env+version 确认 → switchVersion → detailInfo 刷新',
      (tester) async {
    final js = _FakeJsChannel();
    js.versionOptionsResult = _versionOptions;
    js.switchVersionResult = _switchDetail;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 选择器渲染（env chips + 版本列表）
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

    // switchVersion 被调（env/version 正确）
    expect(js.switchVersionCalls, 1);
    expect(js.lastSwitchEnv, 'prod');
    expect(js.lastSwitchVersion, '2.0.0');

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
    js.versionOptionsResult = _versionOptions;
    js.buildHistoryResult = _buildHistory;
    js.switchVersionResult = null; // 无匹配下载 → 提示
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 点 1.0.0 行的历史构建
    await tester.tap(find.text('历史构建').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // onBuildHistory 被调（version/env 正确：当前选中 env = prod + 该行 version）
    expect(js.buildHistoryCalls, 1);
    expect(js.lastBuildHistoryVersion, '1.0.0');
    expect(js.lastBuildHistoryEnv, 'prod');
    expect(find.text('构建 #3'), findsOneWidget);
    expect(find.text('构建 #2'), findsOneWidget);

    // 点某项 → onBuildSelect → 无匹配下载 → 提示
    await tester.tap(find.text('构建 #3'));
    await tester.pumpAndSettle();
    expect(find.text('该构建暂不可下载'), findsOneWidget);
  });

  testWidgets('⑤ 取消 → 不调 switchVersion、detailInfo 不变', (tester) async {
    final js = _FakeJsChannel();
    js.versionOptionsResult = _versionOptions;
    js.switchVersionResult = _switchDetail;
    ChannelManager.instance.registerChannel(js);

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

    expect(js.switchVersionCalls, 0);
    expect(logic.state.detailInfo.value?.version, '1.0.0');
  });

  testWidgets('⑥ 打开切换版本 → versionOptions 带当前详情 env（按需单 env）',
      (tester) async {
    final js = _FakeJsChannel();
    js.versionOptionsResult = _versionOptions;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    // 预置当前详情（extra.env = uat）→ 初始化 versionOptions 应带该 env
    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
      'extra': {'env': 'uat'},
    });
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    expect(js.versionOptionsCalls, 1);
    expect(js.lastVersionOptionsEnv, 'uat');
  });

  testWidgets('⑦ 详情无 env → versionOptions 不带 env（脚本按凭证默认）',
      (tester) async {
    final js = _FakeJsChannel();
    js.versionOptionsResult = _versionOptions;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    expect(js.versionOptionsCalls, 1);
    expect(js.lastVersionOptionsEnv, isNull);
  });

  // ==================== Wave B：detailMenu 脚本声明详情页操作 ====================

  testWidgets('⑧ 脚本渠道：detailMenu 声明动作 → 宫格用脚本 actions（替换写死"切换版本"）',
      (tester) async {
    final js = _FakeJsChannel();
    js.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
      {'action': '清除缓存', 'jscall': 'jsclearCache'},
    ];
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    expect(js.detailMenuCalls, 1);
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
    expect(find.byIcon(Icons.extension), findsNWidgets(2));
    expect(find.byIcon(Icons.swap_vert), findsNothing,
        reason: '写死"切换版本"被脚本声明替换');
  });

  testWidgets('⑨ 脚本渠道：detailMenu 未实现（null）→ 维持写死"切换版本"',
      (tester) async {
    final js = _FakeJsChannel();
    js.detailMenuResult = null;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    expect(js.detailMenuCalls, 1);
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.byIcon(Icons.swap_vert), findsOneWidget);
    expect(find.byIcon(Icons.extension), findsNothing);
  });

  testWidgets('⑩ 点击脚本 action → 关弹框 + 调 jscall + host.ui 版本选择器生效',
      (tester) async {
    final js = _FakeJsChannel();
    js.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
    ];
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    await tester.tap(find.text('切换版本'));
    await tester.pumpAndSettle();

    // 更多弹框已关闭（动作点击先关面板再执行）
    expect(find.text('操作'), findsNothing);

    // jscall 被调（appId 正确）
    expect(js.invokeScriptMethodCalls, 1);
    expect(js.lastInvokedMethod, 'jsswitchVersion');
    expect(js.lastInvokedParams, {'appId': 'com.example.one'});

    // host.ui 注入生效：jscall 内部调 host.ui.showVersionPicker → 版本选择器弹出
    expect(find.text('环境'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);
  });

  testWidgets('⑪ 点击脚本 action → jscall 模拟 host.ui.refreshDetail → 详情刷新',
      (tester) async {
    final js = _FakeJsChannel();
    js.detailMenuResult = [
      {'action': '刷新详情', 'jscall': 'jsrefresh', 'clickIsDimiss': true},
    ];
    js.switchVersionResult = _switchDetail;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    logic.state.detailInfo.value = JsChannelDetailProxy({
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
    });
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    await tester.tap(find.text('刷新详情'));
    await tester.pumpAndSettle();

    // jscall 被调 → 脚本内部 host.ui.refreshDetail → switchVersion 刷新 detailInfo
    expect(js.invokeScriptMethodCalls, 1);
    expect(js.lastInvokedMethod, 'jsrefresh');
    expect(js.switchVersionCalls, 1);
    expect(js.lastSwitchEnv, 'prod');
    expect(js.lastSwitchVersion, '2.0.0');
    expect(logic.state.detailInfo.value?.version, '2.0.0');
  });

  testWidgets('⑫ 点"更多"：JsChannel 不调 getAppInfo（canonicalId 直接用 req.appId）',
      (tester) async {
    final js = _FakeJsChannel();
    js.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
    ];
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // 更多面板打开：detailMenu 被调，但 getAppInfo 零调用（canonical 解析跳过）
    expect(js.detailMenuCalls, 1);
    expect(js.getAppInfoCalls, 0);
    expect(find.text('切换版本'), findsOneWidget);
  });

  testWidgets('⑬ 点"更多"仅调 detailMenu：零 versionOptions/buildHistory/switchVersion 请求',
      (tester) async {
    final js = _FakeJsChannel();
    js.detailMenuResult = [
      {'action': '切换版本', 'jscall': 'jsswitchVersion', 'clickIsDimiss': true},
      {'action': '历史构建', 'jscall': 'jsBuildHistory', 'clickIsDimiss': true},
    ];
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openMoreActions(tester);

    // 点"更多"只有 detailMenu（纯菜单，零请求）；build-list 类方法均未触发
    expect(js.detailMenuCalls, 1);
    expect(js.versionOptionsCalls, 0);
    expect(js.buildHistoryCalls, 0);
    expect(js.switchVersionCalls, 0);
    expect(js.getAppInfoCalls, 0);
    // 宫格渲染脚本声明动作
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.text('历史构建'), findsOneWidget);
  });

  // ==================== Wave 3：zip 包 detail.js（页面级 detailChannel） ====================

  testWidgets('ⓐ 有 detail.js → 详情加载走 detailChannel.getAppDetail（entry 不被调）',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel();
    js.detailChannel = dc;
    dc.getAppDetailResult = {
      'appId': 'com.example.one',
      'name': 'App One',
      'version': '1.0.0',
      // 不设 packageName：避免 testWidgets 假异步下 InstalledApps 平台调用挂起
    };
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await logic.loadDetail();
    await tester.pumpAndSettle();

    // detail.js 存在 → getAppDetail 走 detailChannel（entry 原路径不被调）
    expect(dc.getAppDetailCalls, 1);
    expect(js.getAppDetailCalls, 0);
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
    await logic.loadDetail();
    await tester.pumpAndSettle();

    // 无 detail.js → getDetailChannel null → entry getAppDetail 原路径
    expect(js.getAppDetailCalls, 1);
    expect(logic.state.detailInfo.value?.version, '1.0.0');
  });

  testWidgets('ⓒ 有 detail.js → detailMenu 走 detailChannel（entry 不被调）+ host.ui 注入',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel();
    js.detailChannel = dc;
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
    // host.ui 注入到 detailChannel（创建于页面初始化，此处补注入）
    expect(dc.capturedShowVersionPicker, isNotNull);
    expect(dc.capturedRefreshDetail, isNotNull);
    // 宫格渲染 detail.js 声明动作
    expect(find.text('切换版本'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
    expect(find.byIcon(Icons.extension), findsNWidgets(2));
  });

  testWidgets('ⓓ 有 detail.js → versionOptions/switchVersion 走 detailChannel（entry 不被调）',
      (tester) async {
    final js = _FakeJsChannel();
    js.hasDetailScript = true;
    final dc = _FakeJsDetailChannel();
    js.detailChannel = dc;
    dc.detailMenuResult = null; // 无 detailMenu → 写死"切换版本"入口
    dc.versionOptionsResult = _versionOptions;
    dc.switchVersionResult = _switchDetail;
    ChannelManager.instance.registerChannel(js);

    final logic = buildLogic();
    await pumpHost(tester, logic);
    await openVersionSwitcher(tester);

    // 选择器渲染
    expect(find.text('环境'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);

    // 选 2.0.0 → 确认切换 → 全流程走 detailChannel
    await tester.tap(find.text('2.0.0'));
    await tester.pump();
    await tester.tap(find.text('确认切换'));
    await tester.pumpAndSettle();

    expect(dc.versionOptionsCalls, 1);
    expect(dc.switchVersionCalls, 1);
    expect(dc.lastSwitchEnv, 'prod');
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
    expect(js.detailChannel, isNotNull, reason: '有 detail.js → getDetailChannel 被调');

    logic.onClose();

    expect(js.releaseDetailChannelCalls, 1);
  });

  testWidgets('ⓕ 非脚本渠道（GitHub mock）：详情加载走原 getAppDetail 路径（回归）',
      (tester) async {
    final ch = _FakeChannel();
    ChannelManager.instance.registerChannel(ch);

    final logic = buildLogic(channel: ChannelType.github);
    await logic.loadDetail();
    await tester.pumpAndSettle();

    // 非脚本渠道完全不变：getAppDetail 走 channel 原路径
    expect(ch.getAppDetailCalls, 1);
    expect(logic.state.detailInfo.value?.name, 'App One');
  });
}
