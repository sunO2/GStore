import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/js_script_utils.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/js/js_native_host.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/page/detail/state.dart';

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
class JsDetailChannel implements IDetailChannel {
  /// appId 级详情通道归属应用（与工厂 appId 缓存键一致）
  @override
  final String appId;

  /// 所属渠道唯一标识（与 JsChannel 同 key，数据隔离一致）
  final String channelKey;

  /// detail.js 脚本源码
  final String detailScript;

  final JsChannelRuntime _runtime;

  /// runtime 懒初始化：首次 [callMain] 时加载脚本；失败降级为 null（不崩）。
  /// 构造不建引擎，页面未实际使用时零成本。
  JsDetailChannel({
    required this.appId,
    required this.channelKey,
    required this.detailScript,
    Dio? dio,
    ChannelAddedAppDao? appDao,
    Future<Object?> Function(String key)? configGetter,
    Map<String, String> Function()? envReader,
    void Function(String message)? logInfo,
    void Function(String message)? logError,
    JSNativeHost? nativeHost,
    Future<Map<String, dynamic>> Function(String packageName)?
        installedInfoReader,
  }) : _runtime = JsChannelRuntime(
          channelKey: channelKey,
          script: detailScript,
          dio: dio,
          appDao: appDao,
          configGetter: configGetter,
          envReader: envReader,
          logInfo: logInfo,
          logError: logError,
          nativeHost: nativeHost,
          installedInfoReader: installedInfoReader,
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

  /// host.native 注入（与 entry 相同语义）：详情页使用时覆盖构造时透传的实现。
  ///
  /// detail 通道由 [JsChannel.getDetailChannel] 在页面初始化时创建（早于详情页
  /// showMoreActions 的 host.native 注入），此处允许注入晚于创建——脚本下次调用
  /// `host.native.call('ui.showVersionPicker', ...)` 等即生效。
  void setNativeHost(JSNativeHost host) => _runtime.setNativeHost(host);

  /// bind 后安装的 native host（含 ui.* 六个 handler）。
  /// 仅供单测直接触发 handler（无需 JS 引擎），生产代码勿用。
  @visibleForTesting
  JSNativeHost get nativeHostForTest => _runtime.nativeHost;

  // ==================== bind 模式（构造后注入 state + callbacks） ====================

  /// bind 注入的详情状态容器（[load] 及后续交互写入数据；未 bind → null）
  DetailState? _boundState;

  /// bind 注入的 UI 回调接口（[load]/脚本交互经其刷新 UI；未 bind → null）
  DetailCallbacks? _boundCallbacks;

  /// [getActions] 返回的操作项缓存（[load] 时从脚本 detailMenu 刷新）
  List<DetailAction> _actions = const [];

  /// 本次 [load] 期间脚本是否已推送过阶段数据（ui.updateDetail）。
  ///
  /// load 进入即复位；失败判别用：已推送 → 保内容 + 提示（不设错误页）；
  /// 未推送（纯 prefill）→ 错误页可重试。
  bool _receivedUpdateDetail = false;

  /// bind 模式：构造后注入状态容器 + UI 回调接口。
  ///
  /// 工厂 [JsChannel.getDetailChannel] 只负责按 appId 创建实例（不改签名），
  /// 页面打开后调用方（DetailLogic）经此方法注入 state + callbacks，
  /// 后续 [load] 及脚本交互把数据写入 [state]。
  /// 同时安装 native host 回调（脚本 jscall 时可立即调起 UI 交互）。
  @override
  void bind(DetailState state, DetailCallbacks callbacks) {
    _boundState = state;
    _boundCallbacks = callbacks;
    _installNativeHost(callbacks);
  }

  /// 安装 native host 回调：注册 'ui' 命名空间的七个 handler，
  /// 脚本内部经 `host.native.call('ui.showVersionPicker', ...)` 等驱动 UI 交互。
  void _installNativeHost(DetailCallbacks cb) {
    final host = JSNativeHost()
      ..register('ui', 'showVersionPicker', (p) async {
        await cb.showVersionPicker(
          options: Map<String, dynamic>.from(p),
          appId: appId,
        );
        return null;
      })
      ..register('ui', 'showBuildHistory', (p) async {
        final builds = ((p['builds'] as List?) ?? [])
            .map((b) => Map<String, dynamic>.from(b as Map))
            .toList();
        await cb.showBuildHistory(
          builds: builds,
          appId: appId,
          version: p['version']?.toString() ?? '',
          env: p['env']?.toString() ?? '',
        );
        return null;
      })
      ..register('ui', 'refreshDetail', (p) async {
        await cb.refreshDetail(detailData: Map<String, dynamic>.from(p));
        return null;
      })
      ..register('ui', 'updateDownloadList', (p) async {
        final downloads = (p['downloads'] as List?) ?? [];
        final parsed = JsChannelDetailProxy({'downloads': downloads}).downloads;
        await cb.updateDownloadList(downloads: parsed);
        return null;
      })
      ..register('ui', 'showUAPicker', (p) async {
        final uas = ((p['options'] as List?) ?? [])
            .map((e) => (e as Map)['ua']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
        final current = (p['current'] as String?)?.isNotEmpty == true
            ? p['current'] as String
            : null;
        return await cb.showUAPicker(
            uaOptions: uas, appId: appId, current: current);
      })
      ..register('ui', 'updateDetail', (p) async {
        // 粒度推送原语：脚本分阶段上屏数据（任意键子集，展开合并语义见
        // DetailCallbacks.updateDetail）。置位标志供 load 失败判别。
        _receivedUpdateDetail = true;
        await cb.updateDetail(partial: Map<String, dynamic>.from(p));
        return null;
      })
      ..register('ui', 'setBusy', (p) async {
        await cb.setActionBusy(
            visible: p['visible'] == true,
            label: p['label']?.toString() ?? '');
        return null;
      });
    setNativeHost(host);
  }

  /// 加载详情数据并写入 bound 的 [DetailState]（六步纪律）：
  ///
  /// ① 进入即复位推送标志 + 打开基础 loading（`isLoadingDetail`，骨架 spinner）；
  /// ② 从 request 构建保底 prefill（仅非空字段 + downloads 空数组 +
  ///    sections:['downloads']）经 [DetailCallbacks.refreshDetail] 注入——
  ///    基础信息即时上屏，网络前不再整页空白（AppDetailRequest 无 version 字段，
  ///    prefill 不含 version）；
  /// ③ 下载/README/统计三区块 loading 骨架置 true；
  /// ④ 经脚本 main('getAppDetail') 拉取全量详情；
  /// ⑤ 成功 → refreshDetail 全量替换 + 三标志复位 + 刷新操作项缓存；
  ///    失败(null) → 显式 [_receivedUpdateDetail] 判别：脚本已推送过阶段数据
  ///    则 showError 提示并保留已上屏内容；纯 prefill 则设 errorMessage
  ///    （错误页可重试），失败不再静默白屏；
  /// ⑥ finally 复位 isLoadingDetail。
  ///
  /// 未 bind → 仅日志（脚本直调/单测场景），不崩溃。
  @override
  Future<void> load() async {
    final state = _boundState;
    final callbacks = _boundCallbacks;
    if (state == null || callbacks == null) {
      _logError('load 未 bind（state/callbacks 未注入），跳过');
      return;
    }
    // ① 进入即复位推送标志 + 打开基础 loading
    _receivedUpdateDetail = false;
    state.isLoadingDetail.value = true;
    try {
      // ② 保底 prefill：request 基础信息即时上屏 + 下载区骨架声明
      await callbacks.refreshDetail(detailData: _buildPrefill(state));
      // ③ 三区块 loading 骨架
      state.downloadsLoading.value = true;
      state.readmeLoading.value = true;
      state.statisticsLoading.value = true;
      // ④ 拉取全量详情
      final raw = await getAppDetail(appId);
      if (raw != null) {
        // ⑤a 成功：全量替换 + 三标志复位 + 操作项缓存刷新
        await callbacks.refreshDetail(detailData: raw);
        state.downloadsLoading.value = false;
        state.readmeLoading.value = false;
        state.statisticsLoading.value = false;
        await _refreshActions();
      } else {
        // ⑤b 失败判别：已推送过阶段数据 → 保内容提示；纯 prefill → 错误页可重试
        _logError('load: getAppDetail 返回 null，调用方兜底');
        if (_receivedUpdateDetail) {
          callbacks.showError('详情加载失败，当前显示为已加载内容');
        } else {
          state.errorMessage.value = '详情加载失败';
        }
      }
    } finally {
      // ⑥ 基础 loading 复位
      state.isLoadingDetail.value = false;
    }
  }

  /// 从 bound state 的 request 构建保底 prefill Map：
  /// appId/name/icon/description/packageName 仅含非空字段（缺失跳过该键）；
  /// 固定附 `downloads` 空数组与 `sections: ['downloads']`（下载区骨架声明）；
  /// packageName 非空时附 `extra: {packageName}`。不含 version
  /// （AppDetailRequest 无该字段）。request 为 null 时仅含固定键。
  Map<String, dynamic> _buildPrefill(DetailState state) {
    final req = state.request;
    final prefill = <String, dynamic>{
      'downloads': const <DownloadInfo>[],
      'sections': const ['downloads'],
    };
    if (req == null) return prefill;
    if (req.appId.isNotEmpty) prefill['appId'] = req.appId;
    if (req.name.isNotEmpty) prefill['name'] = req.name;
    final icon = req.icon;
    if (icon != null && icon.isNotEmpty) prefill['icon'] = icon;
    final description = req.description;
    if (description != null && description.isNotEmpty) {
      prefill['description'] = description;
    }
    final packageName = req.packageName;
    if (packageName != null && packageName.isNotEmpty) {
      prefill['packageName'] = packageName;
      prefill['extra'] = {'packageName': packageName};
    }
    return prefill;
  }

  /// 脚本 detailMenu → [DetailAction] 列表缓存（[getActions] 消费）。
  ///
  /// onTap 语义与 DetailLogic._handleJsAction 一致：调脚本方法（交互由 host.ui 驱动）；
  /// 脚本未实现 / 返回非列表 → 空列表（调用方维持现状兜底）。
  Future<void> _refreshActions() async {
    final menu = await detailMenu(appId);
    if (menu == null) {
      _actions = const [];
      return;
    }
    _actions = menu.map((e) {
      final label = e['action']?.toString() ?? '';
      final jscall = e['jscall']?.toString() ?? '';
      return DetailAction(
        label: label.isEmpty ? (jscall.isEmpty ? '未知动作' : jscall) : label,
        onTap: () async {
          if (jscall.isEmpty) return;
          await callMain(jscall, {'appId': appId});
        },
      );
    }).toList();
  }

  /// 返回脚本 detailMenu 声明的操作项（"更多"面板展示）。
  /// 未 [load]/未 bind/脚本未实现 → 空列表（调用方兜底）。
  @override
  List<DetailAction> getActions() => _actions;

  /// 发起下载：透传脚本 main('download')（语义同 [callMain]，脚本未实现 →
  /// null + 日志，调用方维持现状兜底；下载结果由 host.ui 回调驱动注入 UI）。
  @override
  Future<void> startDownload(DownloadInfo info) async {
    await callMain('download', {
      'appId': appId,
      'url': info.url,
      'name': info.name,
      if (info.version != null) 'version': info.version,
      if (info.size != null) 'size': info.size,
    });
  }

  /// 更新下载区：替换 bound state 的 detailInfo 中 downloads 字段（局部更新，不重载）。
  /// 脚本调用 `host.native.call('updateDownloadList', {downloads})` 时触发。
  @override
  Future<void> updateDownloads(List<DownloadInfo> downloads) async {
    final state = _boundState;
    final current = state?.detailInfo.value;
    if (current is JsChannelDetailProxy) {
      final data = Map<String, dynamic>.from(current.data);
      data['downloads'] = downloads;
      state!.detailInfo.value = JsChannelDetailProxy(data);
    }
  }

  /// 释放 runtime（页面退出调用；数据/缓存随实例释放，免缓存管理）
  @override
  Future<void> dispose() => _runtime.dispose();

  void _logError(String message) =>
      appLog.error('[js-detail:$channelKey] $message');
}
