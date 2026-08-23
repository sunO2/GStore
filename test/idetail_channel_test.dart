import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/detail/state.dart';

/// 方案 A 核心契约：IChannel 默认 getDetailChannel/releaseDetailChannel。
///
/// ① 默认实现：不支持详情通道的渠道（GitHub/LocalDb/Vivo/Http/Fdroid）无需改动，
///    getDetailChannel 返回 null（详情走原路径）。
/// ② 默认实现：releaseDetailChannel 幂等（未创建过无操作，不抛）。
/// ③ 覆写渠道（如 JsChannel）：每 appId 独立实例 + 同 appId 复用 + release 释放。

/// 最小渠道实现：extends IChannel 自动继承默认 getDetailChannel/releaseDetailChannel
/// （对应方案 A "其余渠道继承默认实现、零改动"）。
class _PlainChannel extends IChannel {
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

/// 最小 IDetailChannel 实现（appId 独立 + 方法调用计数）
class _DetailChannel extends IDetailChannel {
  _DetailChannel(this.appId);

  @override
  final String appId;

  int bindCalls = 0;
  int loadCalls = 0;
  int getActionsCalls = 0;
  int startDownloadCalls = 0;
  int disposeCalls = 0;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {
    bindCalls++;
  }

  @override
  Future<void> load() async {
    loadCalls++;
  }

  @override
  List<DetailAction> getActions() {
    getActionsCalls++;
    return [];
  }

  @override
  Future<void> startDownload(DownloadInfo info) async {
    startDownloadCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

/// 覆写详情通道的渠道：模拟 JsChannel 的 appId 级工厂缓存（记录调用）
class _ChannelWithDetail extends _PlainChannel {
  final Map<String, IDetailChannel> _detailChannels = {};

  @override
  IDetailChannel? getDetailChannel(String appId) {
    return _detailChannels.putIfAbsent(appId, () => _DetailChannel(appId));
  }

  @override
  void releaseDetailChannel(String appId) {
    super.releaseDetailChannel(appId);
    _detailChannels.remove(appId)?.dispose();
  }
}

void main() {
  test('默认实现：不支持详情通道的渠道 getDetailChannel 返回 null', () {
    final ch = _PlainChannel();
    expect(ch.getDetailChannel('com.example.one'), isNull);
    expect(ch.getDetailChannel('another.app'), isNull);
  });

  test('默认实现：releaseDetailChannel 幂等（未创建过无操作，可重复调用）', () {
    final ch = _PlainChannel();
    expect(() => ch.releaseDetailChannel('never.created'), returnsNormally);
    ch.releaseDetailChannel('com.example.one');
    ch.releaseDetailChannel('com.example.one'); // 重复释放不抛
  });

  test('覆写渠道：同 appId 复用 + 不同 appId 实例隔离 + release 释放', () async {
    final ch = _ChannelWithDetail();

    final a1 = ch.getDetailChannel('app.a');
    final a2 = ch.getDetailChannel('app.a');
    final b = ch.getDetailChannel('app.b');

    expect(identical(a1, a2), isTrue, reason: '同 appId 复用同一实例');
    expect(identical(a1, b), isFalse, reason: '不同 appId 独立实例');
    expect(a1!.appId, 'app.a');
    expect(b!.appId, 'app.b');
    final aDetail = a1 as _DetailChannel;

    // 未创建的 appId 释放 → 幂等无操作
    ch.releaseDetailChannel('never.created');
    expect(aDetail.disposeCalls, 0);

    // release → 移除缓存 + dispose
    ch.releaseDetailChannel('app.a');
    expect(aDetail.disposeCalls, 1, reason: 'release 触发该实例 dispose');

    // 再取 → 新实例（非已释放旧实例）
    final a3 = ch.getDetailChannel('app.a');
    expect(identical(a3, a1), isFalse);
    expect((a3 as _DetailChannel).disposeCalls, 0);

    await ch.dispose();
  });
}