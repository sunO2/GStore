/// Detail channel for facade-eligible channels that have no Dart `IChannel`
/// instance (e.g. `local_db`, whose Dart channel was removed at the cutover).
///
/// The core owns these channels' data, so the whole detail payload is fetched
/// through [ChannelManager.getAppDetailByCode] in one shot — the shared
/// `StandardDetailChannel` needs an `IChannel` handle this lane does not have.
library;

import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/page/detail/state.dart';
import 'package:installed_apps/installed_apps.dart';

class FacadeDetailChannel implements IDetailChannel {
  FacadeDetailChannel({
    required this.appId,
    required this.channelCode,
    required this.request,
  });

  @override
  final String appId;

  /// Channel code used for the core facade lookup (`local_db`, `github`, ...).
  final String channelCode;

  /// Route request (base info fallback + package name).
  final AppDetailRequest request;

  DetailState? _state;
  bool _loadInFlight = false;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {
    _state = state;
  }

  @override
  Future<void> load() async {
    final state = _state;
    if (state == null || _loadInFlight) return;
    _loadInFlight = true;
    state.isLoadingDetail = true;
    state.errorMessage = '';
    try {
      final result =
          await ChannelManager.instance.getAppDetailByCode(channelCode, appId);
      if (!result.success || result.data == null) {
        throw Exception(result.error ?? 'Failed to load app detail');
      }
      final detail = result.data!;
      state.detailInfo = detail;
      state.downloads = detail.downloads;
      await _checkInstalledState(state, detail.packageName.trim());
    } catch (e) {
      state.errorMessage = '加载详情失败: $e';
    } finally {
      _loadInFlight = false;
      state.isLoadingDetail = false;
      state.downloadsLoading = false;
      state.readmeLoading = false;
      state.statisticsLoading = false;
    }
  }

  Future<void> _checkInstalledState(
    DetailState state,
    String packageToCheck,
  ) async {
    if (packageToCheck.isEmpty) return;
    try {
      if (await InstalledApps.isAppInstalled(packageToCheck) == true) {
        state.installInfo = await InstalledApps.getAppInfo(packageToCheck);
      }
    } catch (e) {
      appLog.error('FacadeDetailChannel: 检测安装状态失败 - $e');
    }
  }

  @override
  List<DetailAction> getActions() => const [];

  @override
  bool get drivesOwnDownloads => false;

  @override
  Future<void> startDownload(DownloadInfo info) async {}

  @override
  Future<Map<String, dynamic>?> versionOptions(String appId, {String? env}) async =>
      null;

  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async =>
      null;

  @override
  Future<void> updateDownloads(List<DownloadInfo> downloads) async {}

  @override
  Future<void> dispose() async {}
}
