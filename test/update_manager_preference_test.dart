import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:shared_preferences/shared_preferences.dart';

/// UpdateManager 检测接入用户 APK 选择偏好的全链路冒烟测试。
///
/// 走真实 `_checkOneApp`（通过公开入口 `checkApp`）：mock 渠道
/// （checkAppUpdate 返回多 APK 候选）+ InstalledApps 插件方法通道
/// （isAppInstalled / getAppInfo）+ SharedPreferences 偏好。
///
/// 选择逻辑本身的四象限（匹配/不匹配/无偏好/detail 为空）由
/// apk_matcher_test.dart 的 selectDownloadWithPreference 单测覆盖，
/// 这里验证 _checkOneApp 的接线（偏好读取 → 选择 → latestDownload 落值）。

/// 假渠道：checkAppUpdate 回放固定结果（detail.downloads 多候选，
/// latestDownload 为渠道默认首项），其余 IChannel 成员最小实现。
class _FakeChannel implements IChannel {
  _FakeChannel(this.result);

  final AppUpdateCheckResult result;

  @override
  ChannelInfo get info => ChannelInfo(
        type: ChannelType.github,
        name: 'github',
        description: 'GitHub API',
      );

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async =>
      ChannelResult.success(data: result, from: info.type);

  @override
  bool get supportsProgressiveLoading => false;

  @override
  Future<ChannelResult<List<DownloadInfo>>> fetchDownloads(
    String appId,
  ) async =>
      ChannelResult.failure(from: info.type, error: '不支持');

  @override
  Future<ChannelResult<String?>> fetchReadme(String appId) async =>
      ChannelResult.failure(from: info.type, error: '不支持');

  @override
  Future<ChannelResult<Map<String, dynamic>?>> fetchStatistics(
    String appId,
  ) async =>
      ChannelResult.failure(from: info.type, error: '不支持');

  // ==================== 其余 IChannel 成员最小实现 ====================

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
      ChannelResult.success(data: const [], from: info.type);

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: info.type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: info.type);

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: info.type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: info.type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: info.type);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: info.type);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: info.type);

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async =>
      ChannelResult.success(data: true, from: info.type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: info.type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

const _appId = 'com.example.app';
const _channelCode = 'github';

DownloadInfo _dl(String name) =>
    DownloadInfo(url: 'https://example.com/$name', name: name);

/// 最小 IDetailInfo 实现：仅承载下载候选列表
class _FakeDetail implements IDetailInfo {
  _FakeDetail({required this.downloads});

  @override
  final List<DownloadInfo> downloads;

  @override
  String get appId => _appId;

  @override
  String get appName => '示例应用';

  @override
  String get channelId => _channelCode;

  @override
  ChannelType get channelType => ChannelType.github;

  @override
  String get description => '描述';

  @override
  String? get developer => null;

  @override
  Map<String, dynamic> get extra => const {};

  @override
  String get icon => '';

  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;

  @override
  String get name => appName;

  @override
  String get packageName => _appId;

  @override
  List<String>? get permissions => null;

  @override
  String? get projectUrl => null;

  @override
  String? get readme => null;

  @override
  String? get changelog => null;

  @override
  List<ScreenshotInfo>? get screenshots => null;

  @override
  List<DetailSection> get sections => const [];

  @override
  StatisticsInfo? get statistics => null;

  @override
  String? get version => '2.0.0';

  @override
  List<StatTag> buildStatTags() => const [];
}

/// 渠道检测结果：默认选中 universal（首项），候选含 arm64 / x86_64
AppUpdateCheckResult _checkResult() {
  final universal = _dl('app-universal-v2.0.0.apk');
  final arm = _dl('app-arm64-v8a-v2.0.0.apk');
  final x86 = _dl('app-x86_64-v2.0.0.apk');
  final detail = _FakeDetail(downloads: [universal, arm, x86]);
  return AppUpdateCheckResult(
    appId: _appId,
    packageName: _appId,
    name: '示例应用',
    icon: '',
    latestVersion: '2.0.0',
    latestDownload: universal, // 渠道默认（selectBestDownload 结果）
    detail: detail,
  );
}

/// mock InstalledApps 插件方法通道：视为已安装且版本 1.0.0（低于渠道最新 2.0.0）
void _mockInstalledApps() {
  const channel = MethodChannel('installed_apps');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'isAppInstalled':
        return true;
      case 'getAppInfo':
        return <String, dynamic>{
          'name': '示例应用',
          'package_name': _appId,
          'version_name': '1.0.0',
          'version_code': 1,
          'built_with': null,
          'installed_timestamp': 0,
        };
      default:
        return null;
    }
  });
}

void _clearInstalledAppsMock() {
  const channel = MethodChannel('installed_apps');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UpdateManagerService manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _mockInstalledApps();
    ChannelManager.instance.registerChannel(_FakeChannel(_checkResult()));
    manager = UpdateManagerService();
  });

  tearDown(() async {
    _clearInstalledAppsMock();
    await ChannelManager.instance.disposeAll();
    manager.resetForTest();
  });

  test('预置偏好匹配候选之一 → 检测后 latestDownload 为匹配项（非渠道默认首项）', () async {
    // 用户曾选择 arm64 包（与渠道默认首项 universal 不同）
    await UpdateCache.savePreferredApk(_channelCode, _appId, 'app-arm64-v8a-v2.0.0.apk');

    final info = await manager.checkApp(_appId, channelCode: _channelCode);

    expect(info, isNotNull);
    expect(info!.latestDownload.name, 'app-arm64-v8a-v2.0.0.apk');
  });

  test('无偏好 → 现规则：latestDownload 为渠道默认（latestDownload 不变，回归）', () async {
    final info = await manager.checkApp(_appId, channelCode: _channelCode);

    expect(info, isNotNull);
    expect(info!.latestDownload.name, 'app-universal-v2.0.0.apk');
  });

  test('偏好无精确匹配：最近候选为渠道默认 → latestDownload 为默认（现规则不变）', () async {
    // 偏好指向旧版本 universal 包：最近候选即渠道默认首项，结果与现规则一致
    await UpdateCache.savePreferredApk(_channelCode, _appId, 'app-universal-v2.1.0.apk');

    final info = await manager.checkApp(_appId, channelCode: _channelCode);

    expect(info, isNotNull);
    expect(info!.latestDownload.name, 'app-universal-v2.0.0.apk');
  });
}
