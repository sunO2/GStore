import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
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
  String? lastSwitchEnv;
  String? lastSwitchVersion;
  String? lastVersionOptionsEnv;

  @override
  Future<void> initialize() async {}

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
  }) async {
    switchVersionCalls++;
    lastSwitchEnv = env;
    lastSwitchVersion = version;
    return switchVersionResult;
  }

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    buildHistoryCalls++;
    return buildHistoryResult;
  }

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
    String? version,
  }) async {
    return ChannelResult.success(data: null, from: ChannelType.custom);
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
    String? version,
  }) async {
    return ChannelResult.success(
      data: JsChannelDetailProxy(const {}),
      from: ChannelType.custom,
    );
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

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    throw UnimplementedError();
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

    // onBuildHistory 被调（version/env 正确）
    expect(js.buildHistoryCalls, 1);
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
}
