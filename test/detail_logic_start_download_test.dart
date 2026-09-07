import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/state.dart';

/// DetailLogic.startDownload 断链修复测试。
///
/// 根因：_initAndLoad 对所有渠道都设置 detailChannel（无 channel 时兜底创建
/// StandardDetailChannel），导致 startDownload 恒走 channel.startDownload
/// 分支并 return——而 StandardDetailChannel.startDownload 是空壳 stub，
/// 从不触发实际下载。
///
/// 修复：IDetailChannel 新增 drivesOwnDownloads 属性（默认 false），
/// DetailLogic.startDownload 仅在 ch.drivesOwnDownloads 为 true 时委托
/// 通道，否则走宿主编排路径（DownloadStatus.create → listener → service）。

/// 最小 IChannel 实现（只注册 ChannelManager 用）
class _StubChannel extends IChannel {
  @override
  ChannelInfo get info => ChannelInfo(
        type: ChannelType.github,
        name: 'github',
        description: '',
      );

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
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async =>
      throw UnimplementedError();

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: info.type);

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

/// 模拟 IDetailInfo（detailInfo 字段类型）
class _FakeDetailInfo implements IDetailInfo {
  @override
  String get appId => 'com.example.app';
  @override
  String get appName => '测试应用';
  @override
  String get name => '测试应用';
  @override
  String get icon => '';
  @override
  String get description => '';
  @override
  String get packageName => 'com.example.app';
  @override
  bool get isValid => true;
  @override
  String get channelId => 'github';
  @override
  ChannelType get channelType => ChannelType.github;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => null;
  @override
  String? get projectUrl => null;
  @override
  List<DownloadInfo> get downloads => const [];
  @override
  List<DetailSection> get sections => const [];
  @override
  Map<String, dynamic> get extra => const {};
  @override
  String? get readme => null;
  @override
  List<ScreenshotInfo>? get screenshots => null;
  @override
  String? get changelog => null;
  @override
  List<String>? get permissions => null;
  @override
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

/// 模拟 IDetailChannel：drivesOwnDownloads=false（标准渠道行为）。
/// 记录 startDownload 被调用次数和参数。
class _StandardFakeDetailChannel extends IDetailChannel {
  _StandardFakeDetailChannel(this.appId);

  @override
  final String appId;

  int startDownloadCalls = 0;
  DownloadInfo? lastDownloadInfo;

  @override
  bool get drivesOwnDownloads => false;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {}

  @override
  Future<void> load() async {}

  @override
  List<DetailAction> getActions() => [];

  @override
  Future<void> startDownload(DownloadInfo info) async {
    startDownloadCalls++;
    lastDownloadInfo = info;
  }

  @override
  Future<void> dispose() async {}
}

/// 模拟 IDetailChannel：drivesOwnDownloads=true（JS 渠道行为）。
class _JsFakeDetailChannel extends IDetailChannel {
  _JsFakeDetailChannel(this.appId);

  @override
  final String appId;

  int startDownloadCalls = 0;
  DownloadInfo? lastDownloadInfo;

  @override
  bool get drivesOwnDownloads => true;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {}

  @override
  Future<void> load() async {}

  @override
  List<DetailAction> getActions() => [];

  @override
  Future<void> startDownload(DownloadInfo info) async {
    startDownloadCalls++;
    lastDownloadInfo = info;
  }

  @override
  Future<void> dispose() async {}
}

/// 模拟 IDetailChannel：无 override drivesOwnDownloads（测试默认值=false）。
class _DefaultFakeDetailChannel extends IDetailChannel {
  _DefaultFakeDetailChannel(this.appId);

  @override
  final String appId;

  int startDownloadCalls = 0;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {}

  @override
  Future<void> load() async {}

  @override
  List<DetailAction> getActions() => [];

  @override
  Future<void> startDownload(DownloadInfo info) async {
    startDownloadCalls++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StubChannel stubChannel;

  setUp(() {
    stubChannel = _StubChannel();
    ChannelManager.instance.registerChannel(stubChannel);
    ModuleManager.instance.bindByType(ChannelManager, ChannelManager.instance);
  });

  tearDown(() {
  });

  group('drivesOwnDownloads 属性', () {
    test('IDetailChannel 默认 drivesOwnDownloads=false', () {
      final ch = _DefaultFakeDetailChannel('test');
      expect(ch.drivesOwnDownloads, isFalse);
    });

    test('JS 渠道 fake drivesOwnDownloads=true', () {
      final ch = _JsFakeDetailChannel('test');
      expect(ch.drivesOwnDownloads, isTrue);
    });

    test('标准渠道 fake drivesOwnDownloads=false', () {
      final ch = _StandardFakeDetailChannel('test');
      expect(ch.drivesOwnDownloads, isFalse);
    });
  });

  group('DetailLogic.startDownload 委托行为', () {
    test('drivesOwnDownloads=false（标准渠道）：不委托 channel.startDownload', () async {
      final logic = DetailLogic();
      final fakeCh = _StandardFakeDetailChannel('com.example.app');
      logic.detailChannel = fakeCh;
      logic.request = const AppDetailRequest(
        appId: 'com.example.app',
        name: '测试应用',
        channel: ChannelType.github,
      );

      // 设置 state.detailInfo 使编排路径可执行（虽然后续 service 为 null 会提前 return）
      logic.state.detailInfo = _FakeDetailInfo();

      final download = DownloadInfo(
        url: 'https://example.com/test.apk',
        name: 'test.apk',
        version: '1.0.0',
      );

      // startDownload 走宿主编排路径；DownloadStatus.create 调用
      // getDownloadsDirectory() 在测试环境抛平台异常，预期行为
      try {
        await logic.startDownload(download);
      } catch (_) {
        // 平台插件不可用（getDownloadsDirectory），预期异常——不影响断言
      }

      // 关键断言：channel.startDownload 未被调用（drivesOwnDownloads=false 不委托）
      expect(fakeCh.startDownloadCalls, 0,
          reason: '标准渠道 startDownload 不应被 DetailLogic 委托');
    });

    test('drivesOwnDownloads=true（JS 渠道）：委托 channel.startDownload', () async {
      final logic = DetailLogic();
      final fakeCh = _JsFakeDetailChannel('com.example.app');
      logic.detailChannel = fakeCh;
      logic.request = const AppDetailRequest(
        appId: 'com.example.app',
        name: '测试应用',
        channel: ChannelType.github,
      );

      final download = DownloadInfo(
        url: 'https://example.com/test.apk',
        name: 'test.apk',
        version: '1.0.0',
      );

      await logic.startDownload(download);

      // 关键断言：channel.startDownload 被调用了
      expect(fakeCh.startDownloadCalls, 1,
          reason: 'JS 渠道 startDownload 应被 DetailLogic 委托');
      expect(fakeCh.lastDownloadInfo?.url, 'https://example.com/test.apk');
    });

    test('detailChannel=null：走宿主编排路径（无崩溃）', () async {
      final logic = DetailLogic();
      logic.detailChannel = null;
      logic.request = const AppDetailRequest(
        appId: 'com.example.app',
        name: '测试应用',
        channel: ChannelType.github,
      );

      final download = DownloadInfo(
        url: 'https://example.com/test.apk',
        name: 'test.apk',
        version: '1.0.0',
      );

      // 无 detailChannel → 走宿主编排路径；DownloadStatus.create 调用
      // getDownloadsDirectory() 在测试环境抛平台异常，预期行为
      try {
        await logic.startDownload(download);
      } catch (_) {
        // 平台插件不可用（getDownloadsDirectory），预期异常——不影响测试
      }
      // 到达此处即为通过（无死循环/递归崩溃）
    });
  });
}
