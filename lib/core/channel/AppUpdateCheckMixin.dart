import 'package:gstore/core/agent/platform_arch.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 渠道应用更新检测的默认实现
/// 基于 getAppDetail（不强制刷新，优先使用缓存/本地索引）提取最新版本信息
///
/// 宿主渠道需实现 getAppDetail 与 info（IChannel 已声明）。
/// 各渠道可覆写 checkAppUpdate 以使用更合适的数据源。
mixin AppUpdateCheckMixin {
  /// 宿主渠道需提供（来自 IChannel）
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  });

  /// 宿主渠道需提供（来自 IChannel）
  ChannelInfo get info;

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async {
    try {
      // 不强制刷新：优先使用本地索引/缓存，避免不必要的网络请求
      final result = await getAppDetail(appId);
      if (!result.success || result.data == null) {
        return ChannelResult.failure(
          from: info.type,
          error: result.error ?? '获取应用详情失败',
        );
      }
      final detail = result.data!;

      // 按设备架构选择最佳下载包（多 APK 时匹配 arm64 等）
      final bestDownload = await PlatformArch.selectBestDownload(detail.downloads);

      return ChannelResult.success(
        data: AppUpdateCheckResult(
          appId: appId,
          packageName: detail.packageName,
          name: detail.name,
          icon: detail.icon,
          latestVersion: detail.version,
          latestDownload: bestDownload,
          detail: detail,
        ),
        from: info.type,
      );
    } catch (e) {
      appLog.error('AppUpdateCheckMixin: 检查 ${info.type.code} 更新失败 - $e');
      return ChannelResult.failure(
        from: info.type,
        error: e.toString(),
      );
    }
  }
}
