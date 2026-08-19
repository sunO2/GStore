import 'package:dio/dio.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/js_script_utils.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/logger/LogManager.dart';

/// 页面级详情通道：独立 runtime 加载 detail.js（状态隔离，页面退出释放）。
/// 由 [JsChannel.getDetailChannel] 工厂创建；dispose 释放（数据免缓存管理）。
///
/// ## 与 entry runtime 的关系
/// - 独立 [JsChannelRuntime] 实例（独立 QuickJS context）：详情页脚本状态
///   与发现页脚本互不干扰，多个 appId 的详情实例也互相隔离。
/// - channelKey 复用所属 JsChannel 的 key：host.database / host.env 数据隔离
///   与 entry 一致（同一渠道读写同一份库记录）。
/// - 依赖（dio/appDao/configGetter/env/log/ui 回调）由工厂透传 entry 的注入值，
///   测试/生产行为一致。
///
/// ## 生命周期
/// 工厂懒创建（appId 级缓存）；页面退出调用 releaseDetailChannel → dispose，
/// 数据/缓存随 runtime 实例释放，无需单独缓存管理。
class JsDetailChannel {
  /// 所属渠道唯一标识（与 JsChannel 同 key，数据隔离一致）
  final String channelKey;

  /// detail.js 脚本源码
  final String detailScript;

  final JsChannelRuntime _runtime;

  /// runtime 懒初始化：首次 [callMain] 时加载脚本；失败降级为 null（不崩）。
  /// 构造不建引擎，页面未实际使用时零成本。
  JsDetailChannel({
    required this.channelKey,
    required this.detailScript,
    Dio? dio,
    ChannelAddedAppDao? appDao,
    Future<Object?> Function(String key)? configGetter,
    Map<String, String> Function()? envReader,
    void Function(String message)? logInfo,
    void Function(String message)? logError,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowVersionPicker,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowBuildHistory,
    Future<void> Function(Map<String, dynamic> params)? uiRefreshDetail,
    Future<void> Function(List<dynamic> downloads)? uiUpdateDownloadList,
  }) : _runtime = JsChannelRuntime(
          channelKey: channelKey,
          script: detailScript,
          dio: dio,
          appDao: appDao,
          configGetter: configGetter,
          envReader: envReader,
          logInfo: logInfo,
          logError: logError,
          uiShowVersionPicker: uiShowVersionPicker,
          uiShowBuildHistory: uiShowBuildHistory,
          uiRefreshDetail: uiRefreshDetail,
          uiUpdateDownloadList: uiUpdateDownloadList,
        );

  /// 已释放（dispose 后 true；释放后调用方法 → 降级 null）
  bool get isDisposed => _runtime.isDisposed;

  /// 脚本分发（同 JsChannel._callMain：调 `main(method, params)` 拆 `{ok, data}`）：
  /// - 返回 `{ok: true, data}` → data
  /// - 返回 `{ok: false}` / JS 抛错 / 脚本加载失败 → null（调用方降级，不崩）
  /// - 返回其他值 → 原值（null = 未实现）
  Future<dynamic> callMain(String method, [Map<String, dynamic>? params]) async {
    try {
      if (!_runtime.isInitialized) {
        await _runtime.initialize();
      }
      // 每次调用前从 envReader 刷新 env 快照：detail 通道按 appId 缓存复用，
      // 可能创建于 setEnv 之前（快照了旧空 env）；刷新保证 host.env 始终读到
      // 渠道最新 env（配置 PINGAN_USER/PINGAN_PASS 后详情页立即可下载）。
      _runtime.refreshEnv();
      final raw = await _runtime.call(
        'main',
        [method, params ?? const <String, dynamic>{}],
      );
      if (raw is Map && raw['ok'] is bool) {
        final ok = raw['ok'] as bool;
        if (ok) return raw['data'];
        _logError('detail 脚本 $method 返回 ok: false');
        return null;
      }
      return raw;
    } catch (e) {
      _logError('detail 脚本 $method 调用失败: $e');
      return null;
    }
  }

  /// 详情页消费方法（对齐 JsChannel 同名方法契约，走 detail.js）：

  /// 应用详情（脚本 main('getAppDetail')）→ 原始详情 Map（同 JsChannelDetailProxy 结构）；
  /// 脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> getAppDetail(
    String appId, {
    String? version,
  }) async {
    final data = await callMain('getAppDetail', {
      'appId': appId,
      if (version != null) 'version': version,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 应用信息（脚本 main('getAppInfo')）→ AppInfo JSON Map；
  /// 脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> getAppInfo(
    String appId, {
    String? version,
  }) async {
    final data = await callMain('getAppInfo', {
      'appId': appId,
      if (version != null) 'version': version,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 版本/环境切换选项（脚本 main('versionOptions')）→
  /// `{ envs, versions: [{version, envs, buildCount}], currentEnv, currentVersion }`；
  /// 脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> versionOptions(
    String appId, {
    String? env,
  }) async {
    final data = await callMain('versionOptions', {
      'appId': appId,
      if (env != null) 'env': env,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 切换版本/环境（脚本 main('switchVersion')）→ 该 env+version 的详情 Map；
  /// [build] 可选：历史构建选中项 `{num, ipaName}` → 脚本切换到该构建；
  /// 脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async {
    final data = await callMain('switchVersion', {
      'appId': appId,
      'env': env,
      'version': version,
      if (build != null) 'build': build,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 指定版本历史构建（脚本 main('buildHistory')）→
  /// `{ builds: [{num, publishedAt, size, changelog, installTimes, builtBy, ipaName}] }`；
  /// 脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    final data = await callMain('buildHistory', {
      'appId': appId,
      'version': version,
      'env': env,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 详情页操作菜单（脚本 main('detailMenu')）→
  /// `[{action, jscall, icon?, clickIsDimiss?}]`；脚本未实现/非列表 → null
  Future<List<Map<String, dynamic>>?> detailMenu(String appId) async {
    final data = await callMain('detailMenu', {'appId': appId});
    if (data is! List) return null;
    return data.map((e) => stringKeyedMap(e)).toList();
  }

  /// host.ui 注入（与 entry 相同语义）：详情页使用时覆盖构造时透传的实现。
  ///
  /// detail 通道由 [JsChannel.getDetailChannel] 在页面初始化时创建（早于详情页
  /// showMoreActions 的 host.ui 注入），此处允许注入晚于创建——脚本下次调用
  /// `host.ui.showVersionPicker` / `host.ui.showBuildHistory` / `host.ui.refreshDetail` /
  /// `host.ui.updateDownloadList` 即生效（回调调用时读取）。
  void setUiCallbacks({
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowVersionPicker,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowBuildHistory,
    Future<void> Function(Map<String, dynamic> params)? uiRefreshDetail,
    Future<void> Function(List<dynamic> downloads)? uiUpdateDownloadList,
  }) {
    _runtime.setUiCallbacks(
      uiShowVersionPicker: uiShowVersionPicker,
      uiShowBuildHistory: uiShowBuildHistory,
      uiRefreshDetail: uiRefreshDetail,
      uiUpdateDownloadList: uiUpdateDownloadList,
    );
  }

  /// 释放 runtime（页面退出调用；数据/缓存随实例释放，免缓存管理）
  Future<void> dispose() => _runtime.dispose();

  void _logError(String message) =>
      appLog.error('[js-detail:$channelKey] $message');
}
