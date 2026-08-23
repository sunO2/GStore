import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/state.dart';
import 'package:installed_apps/installed_apps.dart';

/// 标准渠道详情通道：包装 [IChannel] 为 GitHub / LocalDb / Vivo / Http / Fdroid
/// 等标准渠道提供详情数据加载能力。
///
/// 由各渠道 [IChannel.getDetailChannel] 工厂创建；页面打开后调用方（DetailLogic）
/// 经 [bind] 注入状态容器 + UI 回调接口，后续 [load] 及交互把数据写入 [state]。
///
/// ## 加载路径
/// - [load] 按 `channel.supportsProgressiveLoading` 分流：
///   - true（GitHub / LocalDb）：基础信息立即注入 → 三路并行
///     （统计 / 下载 / README）独立渐进渲染，单区块失败只降级自身；
///   - false（Vivo / Fdroid / Http 等）：回退旧流程 `getAppDetail` 一次性完整注入
///     （截图/下载/更新日志/权限/评分等区块仅此流程提供）。
/// - 渐进路径经 [_ProgressiveDetailInfo] 包装 [AppDetailInfo]，保证
///   DownloadStrategyManager.createContext 等以 [IDetailInfo] 消费的路径兼容。
class StandardDetailChannel implements IDetailChannel {
  @override
  final String appId;

  /// 被包装的渠道实例（getAppInfo/getAppDetail/fetch* 消费入口）
  final IChannel channel;

  /// 请求参数（基础信息兜底 + 包名回退）
  final AppDetailRequest request;

  /// 渠道唯一标识（枚举渠道 = type.code；脚本渠道 = channelKey）
  final String channelCode;

  /// bind 注入的详情状态容器（[load] 及后续交互写入数据；未 bind → null）
  DetailState? _state;

  /// bind 注入的 UI 回调接口（交互经其触达页面层；未 bind → null）
  DetailCallbacks? _callbacks;

  /// 加载进行中（重入锁：防 Rx/重建/重复调用触发叠加请求）
  bool _loadInFlight = false;

  StandardDetailChannel({
    required this.appId,
    required this.channel,
    required this.request,
    required this.channelCode,
  });

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {
    _state = state;
    _callbacks = callbacks;
  }

  /// 加载应用详情（分块渐进组装 / 旧流程回退）。
  ///
  /// 分块路径：① `getAppInfo` → 基础 detailInfo 立即注入（头部/应用信息卡立即可渲染）
  /// ② 三路并行（统计/下载/README），各自独立 try/catch 互不阻塞，
  ///    任一区块失败只降级自身（区块保持 null + loading 复位）。
  /// 旧流程路径：`getAppInfo`（缓存基础信息，失败仅日志）→ `getAppDetail`
  /// 一次性完整注入（截图/下载/更新日志/权限/评分等区块）。
  @override
  Future<void> load() async {
    final state = _state;
    if (state == null) {
      appLog.warning('StandardDetailChannel: load 未 bind（state 未注入），跳过');
      return;
    }
    if (_loadInFlight) {
      appLog.warning('StandardDetailChannel: load 已在进行中，忽略重复调用（防请求叠加）');
      return;
    }
    _loadInFlight = true;
    state.isLoadingDetail.value = true;
    state.errorMessage.value = '';

    try {
      // 非分块渠道（Vivo/Fdroid/Http 等）：回退旧流程 getAppDetail 一次性完整注入。
      // 截图/下载/更新日志/权限/评分等区块仅旧流程提供，分块改造不得使其丢失。
      if (!channel.supportsProgressiveLoading) {
        await _loadDetailLegacy(state);
        return;
      }

      // ① 基础信息（失败仅日志不阻塞，回退 request 参数）
      AppSummary? basic;
      try {
        final basicInfoResult = await channel.getAppInfo(
          request.appId,
          forceRefresh: false,
        );
        basic = basicInfoResult.success ? basicInfoResult.data : null;
      } catch (e) {
        appLog.error('StandardDetailChannel: 获取基础信息失败（不阻塞分块加载） - $e');
      }

      // 基础 detailInfo 就绪即注入（头部/应用信息卡立即可渲染）
      final baseDetail = _buildBaseDetailInfo(basic);
      // 包名回退：getAppInfo（keepExistingPackageName: false）无 metadata 时
      // packageName 为 null（离线 LocalDb 应用检测丢失）——回退请求参数包名，
      // 使 packageName 语义与旧 getAppDetail（keepExistingPackageName: true）对齐。
      final effectivePackageName = (baseDetail.packageName?.isNotEmpty ?? false)
          ? baseDetail.packageName!
          : request.packageName;
      final effectiveBase = (effectivePackageName != null &&
              effectivePackageName.isNotEmpty)
          ? baseDetail.copyWith(packageName: effectivePackageName)
          : baseDetail;
      state.detailInfo.value = _ProgressiveDetailInfo(effectiveBase);

      // packageName 就绪即执行安装检测（插件调用失败已容忍，不影响加载流程）
      await _checkInstalledState(state, effectivePackageName?.trim());

      // ② 三路并行分块加载（统计/下载/README），各自独立降级互不阻塞
      await Future.wait([
        _loadStatistics(state),
        _loadDownloads(state),
        _loadReadme(state),
      ]);
    } catch (e) {
      state.errorMessage.value = '加载详情失败: $e';
    } finally {
      _loadInFlight = false;
      state.isLoadingDetail.value = false;
    }
  }

  /// 旧流程加载详情（非分块渠道回退路径）：还原分块改造前的 loadDetail 主体。
  ///
  /// `getAppInfo`（缓存基础信息，失败仅日志不阻塞）→ `getAppDetail` 一次性完整注入
  /// （截图/下载/更新日志/权限/评分等全部区块）→ 基于详情 packageName 检测安装状态。
  /// isLoadingDetail 的复位由外层 [load] 的 finally 统一负责。
  Future<void> _loadDetailLegacy(DetailState state) async {
    // 先获取基本信息（缓存数据；失败不阻塞，请求参数/详情兜底显示）
    try {
      await channel.getAppInfo(
        request.appId,
        forceRefresh: false,
      );
    } catch (e) {
      appLog.error('StandardDetailChannel: 获取基础信息失败（不阻塞详情加载） - $e');
    }

    // 再获取详情信息（一次性完整注入）
    final result = await channel.getAppDetail(
      request.appId,
      forceRefresh: false,
    );
    if (!result.success || result.data == null) {
      throw Exception(result.error ?? 'Failed to load app detail');
    }

    state.detailInfo.value = result.data;

    // 详情加载后，使用详情中的 packageName 检测安装状态
    await _checkInstalledState(state, result.data?.packageName.trim());
  }

  /// 基于基础信息（AppSummary）+ 请求参数构造渐进组装的基础详情。
  ///
  /// 字段与旧 getAppDetail 结果对齐：appId/name/icon/description/channel/
  /// packageName/version/developer/projectUrl + extra 基础键
  /// （developer/repositoryName/projectUrl/proxy——供 _githubRepo / 下载策略读取）。
  AppDetailInfo _buildBaseDetailInfo(AppSummary? basic) {
    final name = (basic?.name.isNotEmpty ?? false) ? basic!.name : request.name;
    final icon =
        (basic?.icon.isNotEmpty ?? false) ? basic!.icon : (request.icon ?? '');
    final des = (basic?.des.isNotEmpty ?? false)
        ? basic!.des
        : (request.description ?? '');
    final developer = (basic?.user.isNotEmpty ?? false) ? basic!.user : null;
    final projectUrl = _buildProjectUrl(basic);

    return AppDetailInfo(
      appId: (basic?.appId.isNotEmpty ?? false) ? basic!.appId : request.appId,
      name: name,
      icon: icon,
      description: des,
      channel: request.channel,
      sections: const [],
      packageName: basic?.packageName,
      developer: developer,
      projectUrl: projectUrl,
      extra: {
        if (developer != null) 'developer': developer,
        if (basic?.repositories.isNotEmpty ?? false)
          'repositoryName': basic!.repositories,
        if (projectUrl != null) 'projectUrl': projectUrl,
        'proxy': getProxy(),
      },
    );
  }

  /// 构造项目主页：GitHub 仓库型应用（user/repositories 齐备）→ github.com 地址。
  String? _buildProjectUrl(AppSummary? basic) {
    final user = basic?.user ?? '';
    final repo = basic?.repositories ?? '';
    if (user.isNotEmpty && repo.isNotEmpty) {
      return 'https://github.com/$user/$repo';
    }
    return null;
  }

  /// 检测安装状态（packageName 就绪后调用；插件失败已容忍，不影响加载流程）。
  Future<void> _checkInstalledState(DetailState state, String? packageToCheck) async {
    if (packageToCheck == null || packageToCheck.isEmpty) {
      appLog.error('StandardDetailChannel: 无法检测安装状态 - 没有可用的包名');
      return;
    }
    try {
      final isInstalled = await InstalledApps.isAppInstalled(packageToCheck);
      if (isInstalled == true) {
        state.installInfo.value = await InstalledApps.getAppInfo(packageToCheck);
        appLog.info('StandardDetailChannel: ✓ 应用已安装 - ${state.installInfo.value?.packageName}');
      } else {
        appLog.info('StandardDetailChannel: ✗ 应用未安装 - "$packageToCheck"');
      }
    } catch (e) {
      appLog.error('StandardDetailChannel: 检测安装状态时出错: $e');
    }
  }

  /// 区块数据到达后对当前 detailInfo 做 copyWith 增补（渐进组装，每次注入即渲染对应区块）
  void _updateDetailInfo(AppDetailInfo Function(AppDetailInfo) transform) {
    final current = _state?.detailInfo.value;
    if (current is _ProgressiveDetailInfo) {
      // 新包装实例触发 Rx 通知
      _state!.detailInfo.value = _ProgressiveDetailInfo(transform(current.inner));
    }
  }

  /// 分块加载：统计（apiList → extra.apiData，供 buildStatTags / createContext 解析）
  Future<void> _loadStatistics(DetailState state) async {
    state.statisticsLoading.value = true;
    try {
      final result = await channel.fetchStatistics(request.appId);
      if (result.success && result.data != null) {
        final apiData = result.data!;
        _updateDetailInfo((inner) {
          final extra = Map<String, dynamic>.from(inner.extra);
          extra['apiData'] = apiData;
          // metadata 全量并入 extra（versionCode 等供更新检测消费）
          final meta = apiData['metadata'];
          if (meta is Map) {
            extra['metadata'] = Map<String, dynamic>.from(meta);
          }
          final metaVersion = apiData['versionName']?.toString();
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：有 stars/forks 才声明统计区块
          if ((apiData['stargazers_count'] != null ||
                  apiData['forks_count'] != null) &&
              !sections.contains(DetailSection.statistics)) {
            sections.add(DetailSection.statistics);
          }
          return inner.copyWith(
            extra: extra,
            // metadata versionName 优先（APK 提取，更准确）；否则 releases 首项
            // （_loadDownloads 兜底 inner.version ?? downloads.first.version）
            version: metaVersion?.isNotEmpty == true ? metaVersion : inner.version,
            sections: sections,
          );
        });
      }
    } catch (e) {
      appLog.error('StandardDetailChannel: 加载统计失败（独立降级，不阻塞其他区块） - $e');
    } finally {
      state.statisticsLoading.value = false;
    }
  }

  /// 分块加载：下载列表（state.downloads + detailInfo.downloads/version + sections）
  Future<void> _loadDownloads(DetailState state) async {
    state.downloadsLoading.value = true;
    try {
      final result = await channel.fetchDownloads(request.appId);
      if (result.success) {
        final downloads = result.data ?? const <DownloadInfo>[];
        state.downloads.value = downloads;
        _updateDetailInfo((inner) {
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：有下载项才声明下载区块
          if (downloads.isNotEmpty &&
              !sections.contains(DetailSection.downloads)) {
            sections.add(DetailSection.downloads);
          }
          return inner.copyWith(
            downloads: downloads,
            // 最新版本：下载列表首项（releases 按时间倒序，与旧 latestVersion 语义对齐）
            version: inner.version ??
                (downloads.isNotEmpty ? downloads.first.version : null),
            sections: sections,
          );
        });
      }
    } catch (e) {
      appLog.error('StandardDetailChannel: 加载下载列表失败（独立降级，不阻塞其他区块） - $e');
    } finally {
      state.downloadsLoading.value = false;
    }
  }

  /// 分块加载：README（state.readme + detailInfo.extra.readme + sections）
  Future<void> _loadReadme(DetailState state) async {
    state.readmeLoading.value = true;
    try {
      final result = await channel.fetchReadme(request.appId);
      if (result.success && result.data != null) {
        final readme = result.data!;
        state.readme.value = readme;
        _updateDetailInfo((inner) {
          final extra = Map<String, dynamic>.from(inner.extra);
          extra['readme'] = readme;
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：README 非空才声明区块
          if (readme.isNotEmpty && !sections.contains(DetailSection.readme)) {
            sections.add(DetailSection.readme);
          }
          return inner.copyWith(extra: extra, sections: sections);
        });
      }
    } catch (e) {
      appLog.error('StandardDetailChannel: 加载 README 失败（独立降级，不阻塞其他区块） - $e');
    } finally {
      state.readmeLoading.value = false;
    }
  }

  /// 是否可提交应用元数据（GitHub 渠道，或 LocalDb 中的 GitHub 仓库类型应用）
  bool get canSubmitAppMetadata => _githubRepo() != null;

  /// 从请求/详情中解析 GitHub owner/repo
  /// - GitHub 渠道：apiData.full_name 或 appId（owner/repo）
  /// - LocalDb 渠道：extra 中的 repositoryName + developer（GitHub 仓库类型应用）
  ({String owner, String repo})? _githubRepo() {
    final detail = _state?.detailInfo.value;

    if (request.channel == ChannelType.github) {
      // 优先从 apiData.full_name 解析
      final apiData = detail?.extra['apiData'];
      if (apiData is Map && apiData['full_name'] is String) {
        final full = apiData['full_name'] as String;
        final parts = full.split('/');
        if (parts.length == 2) return (owner: parts[0], repo: parts[1]);
      }

      // 回退：appId 格式为 owner/repo
      final parts = request.appId.split('/');
      if (parts.length == 2) return (owner: parts[0], repo: parts[1]);
    } else if (request.channel == ChannelType.localDb && detail != null) {
      // LocalDb 中的 GitHub 仓库类型应用：repositoryName + developer
      final repositoryName = detail.extra['repositoryName']?.toString();
      final developer = detail.extra['developer']?.toString();
      if ((repositoryName?.isNotEmpty ?? false) &&
          (developer?.isNotEmpty ?? false)) {
        return (owner: developer!, repo: repositoryName!);
      }
    }

    return null;
  }

  /// 返回操作项列表（"更多"按钮面板展示）。
  ///
  /// 标准渠道无脚本 detailMenu：返回通用操作——GitHub 仓库型应用
  /// 可"完善应用信息"，有项目主页时提供"项目主页"跳转。
  @override
  List<DetailAction> getActions() {
    final callbacks = _callbacks;
    if (callbacks == null) return const [];

    return <DetailAction>[
      // 完善应用信息（GitHub 渠道 / LocalDb 的 GitHub 仓库类型应用）
      if (canSubmitAppMetadata)
        DetailAction(
          label: '完善应用信息',
          icon: Icons.manage_search,
          onTap: callbacks.submitAppMetadata,
        ),
      // 项目主页（打开项目的 GitHub 地址 / 项目详情地址）
      if (_state?.detailInfo.value?.projectUrl != null)
        DetailAction(
          label: '项目主页',
          icon: Icons.language,
          onTap: () async => callbacks.openProjectBrowser(),
        ),
    ];
  }

  /// 发起下载：经 UI 回调触发（空 URL 守卫提示；下载编排由页面层负责）。
  @override
  Future<void> startDownload(DownloadInfo info) async {
    final callbacks = _callbacks;
    if (callbacks == null) {
      appLog.warning('StandardDetailChannel: startDownload 未 bind（callbacks 未注入），跳过');
      return;
    }

    final downloadUrl = info.url.trim();
    if (downloadUrl.isEmpty) {
      // 空 URL 守卫（与页面层语义一致）：脚本未生成下载地址（如未配置渠道凭证/
      // 认证失败）→ 提示凭证，不发起空 URL 下载
      await callbacks.showWarningDialog(
        title: '无法下载',
        content: info.note?.isNotEmpty == true
            ? info.note!
            : '下载地址不可用\n请先在渠道环境变量配置所需凭证后重试',
      );
      return;
    }

    appLog.info('StandardDetailChannel: startDownload - name=${info.name} url=$downloadUrl');
  }

  /// 版本/环境切换选项（标准渠道不支持，默认 null）
  @override
  Future<Map<String, dynamic>?> versionOptions(String appId, {String? env}) async => null;

  /// 切换版本/环境（标准渠道不支持，默认 null）
  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async => null;

  /// 指定版本历史构建（标准渠道不支持，默认 null）
  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async => null;

  /// 更新下载区（标准渠道无代理数据，默认 no-op）
  @override
  Future<void> updateDownloads(List<DownloadInfo> downloads) async {}

  /// 释放资源：标准渠道无独立 runtime/缓存，无操作（幂等）。
  @override
  Future<void> dispose() async {}
}

/// 渐进组装中的详情信息：包装 [AppDetailInfo]，暴露 [IDetailInfo] 接口。
///
/// AppDetailInfo 本身不实现 IDetailInfo（渠道详情走各自的 ChannelDetailProxy），
/// 这里在通道内做最小适配，保证 state.detailInfo / DownloadStrategyManager.createContext
/// 等以 IDetailInfo 消费的路径兼容；字段与旧 getAppDetail 结果对齐
/// （downloads/readme/statistics/version/developer/projectUrl/extra 各键）。
class _ProgressiveDetailInfo implements IDetailInfo {
  _ProgressiveDetailInfo(this.inner);

  /// 内部承载对象（三路数据到达时通过 copyWith 增补）
  final AppDetailInfo inner;

  @override
  String get packageName => inner.packageName ?? '';

  @override
  String get appName => inner.name;

  @override
  String get name => inner.name;

  @override
  String get icon => inner.icon;

  @override
  String get description => inner.description;

  @override
  String get appId => inner.appId;

  @override
  String get channelId => inner.channel.code;

  @override
  ChannelType get channelType => inner.channel;

  @override
  String? get version => inner.version;

  @override
  String? get developer => inner.developer;

  @override
  String? get projectUrl => inner.projectUrl;

  @override
  List<DownloadInfo> get downloads => inner.downloads;

  @override
  List<DetailSection> get sections => inner.sections;

  @override
  Map<String, dynamic> get extra => inner.extra;

  @override
  String? get readme => inner.readme;

  @override
  List<ScreenshotInfo>? get screenshots => inner.screenshots;

  @override
  String? get changelog => inner.changelog;

  @override
  List<String>? get permissions => inner.permissions;

  @override
  StatisticsInfo? get statistics {
    final s = inner.statistics;
    if (s != null) return s;
    // 与渠道代理一致：从 extra.apiData 解析 GitHub 统计
    final apiData = inner.extra['apiData'];
    if (apiData is Map) {
      final stars = apiData['stargazers_count'];
      final watchers = apiData['watchers_count'];
      final forks = apiData['forks_count'];
      if (stars is int || watchers is int || forks is int) {
        return StatisticsInfo(
          stars: stars is int ? stars : null,
          watchers: watchers is int ? watchers : null,
          forks: forks is int ? forks : null,
        );
      }
    }
    return null;
  }

  @override
  List<StatTag> buildStatTags() {
    // 与 GitHub/LocalDb 渠道代理一致：从 extra.apiData 构建统计标签
    final tags = <StatTag>[];
    final apiData = inner.extra['apiData'];
    if (apiData is Map) {
      final stars = apiData['stargazers_count'];
      final watchers = apiData['watchers_count'];
      final forks = apiData['forks_count'];
      if (stars is int && stars > 0) tags.add(StatTag.stars(stars));
      if (watchers is int && watchers > 0) tags.add(StatTag.watchers(watchers));
      if (forks is int && forks > 0) tags.add(StatTag.forks(forks));
    }
    return tags;
  }

  @override
  bool get isValid => inner.isValid;
}