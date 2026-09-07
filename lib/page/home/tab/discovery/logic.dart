import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

import 'state.dart';
import 'widgets/tag_picker_dialog.dart';

/// 发现页控制器（Riverpod AutoDisposeNotifier）。
///
/// 数据源：ChannelManager（渠道管理器，经 ModuleManager 注册表取用），逐渠道
/// 加载应用列表；IAggregateService 提供已添加索引（入库状态/批量添加）。
/// 订阅 appsChangedStream 响应增删入库变化、dbRebuiltStream 响应数据库重建。
/// UI 提示统一走 AppDialogs（纯 Flutter），不再依赖 GetX 全局。
class DiscoveryNotifier extends AutoDisposeNotifier<DiscoveryState> {
  StreamSubscription? _appsSubscription;
  StreamSubscription? _dbRebuiltSub;
  final List<StreamSubscription> _disposables = [];

  /// 是否已释放（async 回调后写 state 前检查）
  bool _disposed = false;

  /// 聚合服务（aggregate 模块下线返回 null → 页面降级）
  IAggregateService? get _aggregator =>
      ModuleManager.instance.get<IAggregateService>();

  /// 渠道管理器（channel 模块下线时为 null，消费点软降级）
  ChannelManager? get _channelManager =>
      ModuleManager.instance.get<ChannelManager>();

  // 搜索控制器
  final searchController = TextEditingController();

  // 防抖定时器
  Timer? _debounceTimer;

  // 选中的搜索渠道
  ChannelType? _selectedSearchChannel;

  @override
  DiscoveryState build() {
    ref.onDispose(_dispose);
    // 首帧初始化（onReady 语义）：订阅变化源 + 加载数据
    Future.microtask(() {
      if (_disposed) return;
      _subscribeAndLoad();
    });
    return const DiscoveryState();
  }

  void _dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    searchController.dispose();
    _appsSubscription?.cancel();
    _dbRebuiltSub?.cancel();
    for (final sub in _disposables) {
      sub.cancel();
    }
    _disposables.clear();
  }

  Future<void> _subscribeAndLoad() async {
    // 监听已添加应用变化（aggregate 模块下线时跳过订阅）
    final aggregator = _aggregator;
    if (aggregator != null) {
      _appsSubscription = aggregator.appsChangedStream.listen((_) {
        if (_disposed) return;
        _updateAddedAppsIndex();
      });
    }

    // 监听数据库重建（DB 更新下载完成后重载渠道列表）
    try {
      final dbManager = ModuleManager.instance.get<DbManager>();
      if (dbManager != null) {
        _dbRebuiltSub = dbManager.dbRebuiltStream.listen((_) {
          if (_disposed) return;
          loadData();
        });
      }
    } catch (_) {
      // DbManager 未注册：跳过数据库重建订阅
    }

    await loadData();
  }

  /// 获取渠道列表（用于UI显示）
  List<ChannelInfo> get channelList => _channelManager?.allChannelInfo ?? [];

  /// 获取已排序的渠道 code 列表（用于筛选标签）
  ///
  /// code = 枚举渠道 type.code（如 'vivo'）/ 脚本渠道 channelKey（如 'js_pingan'），
  /// 天然唯一。已加载数据的渠道 + 动态脚本渠道（未加载也占位，保证导入后切到
  /// 发现页可见）+ 其余已注册启用渠道，合并去重后按 code 排序。
  /// ChannelManager 构造私有 → 单例即 ModuleManager 绑定实例，直接取用
  List<String> get sortedChannelCodes {
    final codes = <String>{};
    // 已加载数据的渠道
    codes.addAll(state.channelApps.keys);
    // 动态脚本渠道（type=custom）并入：即使数据未加载也占位显示
    for (final channel in ChannelManager.instance.dynamicChannels) {
      codes.add(channelCode(channel));
    }
    // 其余已注册启用渠道（枚举渠道未加载也占位）
    for (final channel in ChannelManager.instance.enabledChannels) {
      codes.add(channelCode(channel));
    }
    final result = codes.toList()..sort();
    debugPrint('DiscoveryNotifier: sortedChannelCodes = $result');
    debugPrint(
        'DiscoveryNotifier: dynamicChannels = ${ChannelManager.instance.dynamicChannels.map((c) => channelCode(c)).toList()}');
    debugPrint(
        'DiscoveryNotifier: channelApps keys = ${state.channelApps.keys.toList()}');
    return result;
  }

  /// 获取当前显示的应用列表（扁平化，用于 Grid）
  /// 返回 (AppSummary, 渠道 code) 对，确保每个应用都有正确的渠道信息
  List<(AppSummary, String)> getDisplayApps() {
    List<(AppSummary, String)> result = [];

    final codes =
        state.selectedChannel == null ? sortedChannelCodes : [state.selectedChannel!];

    for (var code in codes) {
      final apps = state.channelApps[code] ?? [];
      for (var app in apps) {
        // 显示模式筛选
        final isAdded = isAppAdded(code, app.appId);
        switch (state.displayMode) {
          case DisplayMode.added:
            if (!isAdded) continue;
            break;
          case DisplayMode.notAdded:
            if (isAdded) continue;
            break;
          case DisplayMode.all:
            break;
        }

        // 搜索筛选
        if (state.searchKeyword.isNotEmpty) {
          final keyword = state.searchKeyword.toLowerCase();
          if (!app.name.toLowerCase().contains(keyword) &&
              !app.des.toLowerCase().contains(keyword)) {
            continue;
          }
        }

        result.add((app, code));
      }
    }

    return result;
  }

  /// 获取应用的渠道 code
  String? getChannelForApp(String appId) {
    for (var entry in state.channelApps.entries) {
      if (entry.value.any((app) => app.appId == appId)) {
        return entry.key;
      }
    }
    return null;
  }

  /// 获取渠道应用统计
  int getChannelAppCount(String? code) {
    if (code == null) {
      return getTotalAppCount();
    }
    return state.channelApps[code]?.length ?? 0;
  }

  /// 获取渠道已添加应用数
  int getChannelAddedCount(String? code) {
    if (code == null) {
      return getAddedAppCount();
    }
    final apps = state.channelApps[code] ?? [];
    return apps.where((app) => isAppAdded(code, app.appId)).length;
  }

  /// 计算响应式 Grid 列数
  int calculateCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width < 600) return 3; // 手机竖屏
    if (width < 900) return 5; // 手机横屏
    return 7; // 平板
  }

  /// 更新 Grid 列数
  void updateCrossAxisCount(BuildContext context) {
    state = state.copyWith(crossAxisCount: calculateCrossAxisCount(context));
  }

  /// 进入/退出多选模式
  void toggleMultiSelectMode() {
    state = state.copyWith(
      isMultiSelectMode: !state.isMultiSelectMode,
      selectedApps: !state.isMultiSelectMode ? const {} : state.selectedApps,
    );
  }

  /// 切换应用选择状态
  void toggleAppSelection(String channelCode, String appId) {
    final key = '$channelCode:$appId';
    final selected = Set<String>.of(state.selectedApps);
    if (!selected.add(key)) {
      selected.remove(key);
    }
    state = state.copyWith(selectedApps: selected);
  }

  /// 全选当前视图
  void selectAllInView() {
    final appsWithChannel = getDisplayApps();
    state = state.copyWith(
      selectedApps: {for (var (app, code) in appsWithChannel) '$code:${app.appId}'},
    );
  }

  /// 取消全选
  void deselectAll() {
    state = state.copyWith(selectedApps: const {});
  }

  /// 批量添加选中的应用
  Future<void> batchAddSelected() async {
    if (state.selectedApps.isEmpty) return;

    int successCount = 0;
    int failCount = 0;

    for (var key in state.selectedApps) {
      final parts = key.split(':');
      if (parts.length != 2) continue;

      final channelCode = parts[0];
      final appId = parts[1];

      // 查找对应的应用（渠道 code 即 channelApps 键）
      AppSummary? appInfo;
      for (var entry in state.channelApps.entries) {
        if (entry.key == channelCode) {
          for (final app in entry.value) {
            if (app.appId == appId) {
              appInfo = app;
              break;
            }
          }
          break;
        }
      }

      if (appInfo != null) {
        final channelInstance = _channelManager?.getChannelByCode(channelCode);
        if (channelInstance != null) {
          try {
            // 批量添加不逐个弹标签选择框（避免噪声），如需分类可单独添加后手动打标
            await _aggregator?.toggleApp(
              channelCode: channelCode,
              appInfo: appInfo,
            );
            successCount++;
          } catch (e) {
            failCount++;
            appLog.error('添加应用失败: $appId - $e');
          }
        }
      }
    }

    // 清空选择并退出多选
    state = state.copyWith(
      selectedApps: const {},
      isMultiSelectMode: false,
    );

    // 刷新数据
    await _updateAddedAppsIndex();

    // 显示结果
    if (failCount == 0) {
      AppDialogs.showSuccess('成功: $successCount, 失败: $failCount',
          title: '批量添加完成');
    } else {
      AppDialogs.showWarning('成功: $successCount, 失败: $failCount',
          title: '批量添加完成');
    }
  }

  /// 加载更多指定渠道的应用
  Future<void> loadMoreChannel(String code) async {
    if (state.channelLoadingMore[code] == true) return;

    state = state.copyWith(
      channelLoadingMore: {...state.channelLoadingMore, code: true},
    );

    try {
      final currentPage = state.channelPages[code] ?? 1;
      final channelInstance = _channelManager?.getChannelByCode(code);

      if (channelInstance != null) {
        // 暂时使用 forceRefresh 加载全部
        final result = await channelInstance.getAllApps(forceRefresh: true);
        if (result.success && result.data != null) {
          state = state.copyWith(
            channelApps: {...state.channelApps, code: result.data!},
            channelPages: {...state.channelPages, code: currentPage + 1},
          );
        }
      }
    } catch (e) {
      appLog.error('DiscoveryNotifier: 加载更多 $code 失败 - $e');
    } finally {
      state = state.copyWith(
        channelLoadingMore: {...state.channelLoadingMore, code: false},
      );
    }
  }

  /// 加载数据
  Future<void> loadData() async {
    state = state.copyWith(isLoading: true, errorMessage: '');

    try {
      // 并发加载所有渠道的应用和已添加索引
      await Future.wait([
        _loadAllChannelApps(),
        _updateAddedAppsIndex(),
      ]);
    } catch (e) {
      state = state.copyWith(errorMessage: '加载数据失败: $e');
      appLog.error('DiscoveryNotifier: 加载失败 - $e');
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  /// 加载所有渠道的应用
  ///
  /// 遍历 dynamicChannels（脚本渠道全量，key 索引）+ enabledChannels 去重；
  /// 每个渠道独立槽位（键 = channelCode：枚举 type.code / 脚本 channelKey），
  /// 多个脚本渠道互不合并、后注册不覆盖先注册（重启后重新注册数据不丢失）。
  Future<void> _loadAllChannelApps() async {
    final manager = _channelManager;
    if (manager == null) return;
    debugPrint(
        'DiscoveryNotifier: _loadAllChannelApps 开始 - dynamicChannels=${manager.dynamicChannels.length}, enabledChannels=${manager.enabledChannels.length}');

    final channels = <IChannel>[
      ...manager.dynamicChannels,
      ...manager.enabledChannels
          .where((c) => !manager.dynamicChannels.contains(c)),
    ];

    var updated = state.channelApps;
    for (var channel in channels) {
      final code = channelCode(channel);
      try {
        final result = await channel.getAllApps();
        debugPrint(
            'DiscoveryNotifier: 加载渠道 $code - success=${result.success}, count=${result.data?.length ?? 0}');

        if (result.success && result.data != null) {
          updated = {...updated, code: result.data!};
        }
      } catch (e) {
        appLog.error('DiscoveryNotifier: 加载 $code 失败 - $e');
        debugPrint('DiscoveryNotifier: 加载渠道 $code - 异常: $e');
        // 即使失败也添加空列表
        updated = {...updated, code: []};
      }
    }
    if (!_disposed) {
      state = state.copyWith(channelApps: updated);
    }
  }

  /// 更新已添加应用索引
  Future<void> _updateAddedAppsIndex() async {
    // aggregate 模块下线 → 注册表取不到服务，跳过索引更新
    final aggregator = _aggregator;
    if (aggregator == null) return;
    final index = await aggregator.getAddedAppsIndex();
    if (_disposed) return;
    state = state.copyWith(addedAppsIndex: index);
  }

  /// 切换渠道筛选
  void selectChannel(String? code) {
    debugPrint('DiscoveryNotifier: selectChannel called with code: $code');
    state = state.copyWith(selectedChannel: code, clearSelectedChannel: code == null);
    debugPrint(
        'DiscoveryNotifier: selectChannel done - ${state.selectedChannel ?? "null"}');
  }

  /// 切换显示模式
  void setDisplayMode(DisplayMode mode) {
    state = state.copyWith(displayMode: mode);
  }

  /// 搜索
  void setSearchKeyword(String keyword) {
    state = state.copyWith(searchKeyword: keyword);
  }

  /// 显示渠道搜索对话框
  void showChannelSearchDialog(BuildContext context) {
    final availableChannels = _channelManager?.enabledChannels ?? [];

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择搜索渠道'),
        content: availableChannels.isEmpty
            ? const Text('没有可用的渠道')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: availableChannels.map((channel) {
                  return ListTile(
                    leading: Icon(_getChannelIcon(channel.info.type)),
                    title: Text(channel.info.name),
                    subtitle: Text(channel.info.description),
                    onTap: () {
                      Navigator.of(dialogContext).pop();
                      _openChannelSearch(context, channel);
                    },
                  );
                }).toList(),
              ),
      ),
    );
  }

  /// 打开渠道搜索页面
  void _openChannelSearch(BuildContext context, dynamic channel) {
    // 获取渠道的搜索组件
    final searchWidget = channel.getAddAppWidget(
      context,
      (app) => toggleApp(context, channelCode(channel), app),
    );

    if (searchWidget != null) {
      // 渠道提供了搜索组件，直接显示
      showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: SizedBox(
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.8,
            child: searchWidget,
          ),
        ),
      );
    } else {
      // 渠道不提供搜索组件，显示提示
      AppDialogs.showInfo('${channel.info.name} 不支持搜索功能', title: '提示');
    }
  }

  /// 获取渠道图标
  IconData _getChannelIcon(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Icons.storage;
      case ChannelType.github:
        return Icons.code;
      case ChannelType.http:
        return Icons.cloud;
      case ChannelType.vivo:
        return Icons.phone_android;
      case ChannelType.fdroid:
        return Icons.android;
      case ChannelType.custom:
        return Icons.apps;
    }
  }

  /// 检查应用是否已添加
  bool isAppAdded(String code, String appId) {
    // 聚合层迁移后 channelId 存真实 channelCode（枚举 type.code / 脚本 channelKey），
    // addedAppsIndex 键与 code 直接一致，无需 'custom' 回退。
    return state.addedAppsIndex[code]?.contains(appId) ?? false;
  }

  /// 添加/移除应用（添加到聚合管理器，用于首页显示）
  Future<void> toggleApp(BuildContext context, String code, AppSummary appInfo) async {
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return;

    try {
      // 使用聚合管理器切换应用状态（aggregate 模块下线时降级为未添加）
      final added = await _aggregator?.toggleApp(
        channelCode: code,
        appInfo: appInfo,
      ) ??
          false;

      // 重新加载该渠道的应用列表
      final result = await channelInstance.getAllApps(forceRefresh: true);
      if (result.success && result.data != null) {
        state = state.copyWith(
          channelApps: {...state.channelApps, code: result.data!},
        );
      }

      // 刷新已添加应用索引（更新入库状态图标）
      await _updateAddedAppsIndex();

      if (_disposed) return;
      if (added) {
        AppDialogs.showSuccess('已添加到首页：${appInfo.name}');
      } else {
        AppDialogs.showInfo('已从首页移除：${appInfo.name}', title: '移除');
      }

      // 添加成功后才弹标签选择框（fire-and-forget，不阻塞切换流程）
      if (added && context.mounted) {
        unawaited(showTagPickerForApp(context, code, appInfo));
      }
    } catch (e) {
      if (_disposed) return;
      AppDialogs.showError('操作失败：$e');
    }
  }

  /// 本地库预置分类加载失败/为空时的内置回退列表
  static const List<String> _fallbackPresetTags = [
    '工具',
    '游戏',
    '社交',
    '影音',
    '阅读',
    '效率',
    '系统',
  ];

  /// 应用添加成功后弹出可选分类标签对话框
  ///
  /// 读取当前标签 -> 加载预置分类（本地库 AppCategory.description，失败回退内置列表）
  /// -> 展示对话框 -> 用户确认后整体保存（替换语义）。
  Future<void> showTagPickerForApp(
      BuildContext context, String code, AppSummary appInfo) async {
    // 关键：标签 key 必须与聚合库一致——addApp 落库用的是 canonicalAppId 规范化后的 appId
    // （如 GitHub 收录后为真实包名），原始 appId（如 owner/repo）作 key 会匹配不到聚合库
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return;
    final canonicalId = await channelInstance.canonicalAppId(appInfo);

    // 读取当前标签（用规范化 appId）
    final currentTags = await _aggregator
            ?.getTags(channelCode: code, appId: canonicalId) ??
        const [];

    // 加载预置分类：本地库 AppCategory 的 description 作为标签值
    var presetTags = <String>[];
    try {
      final categories = await "gstore".repoDB.db.dao.getAllCategory();
      presetTags = categories
          .map((c) => c.description.trim())
          .where((d) => d.isNotEmpty)
          .toList();
    } catch (e) {
      appLog.error('DiscoveryNotifier: 加载预置分类失败，使用内置列表 - $e');
    }
    if (presetTags.isEmpty) {
      presetTags = _fallbackPresetTags;
    }
    if (!context.mounted) return;

    // 弹出标签选择对话框
    final result = await showTagPickerDialog(
      context,
      presetTags: presetTags,
      currentTags: currentTags,
    );
    if (result == null) return; // 取消，不保存

    try {
      // 保存标签（用规范化 appId，与聚合库 key 一致）
      await _aggregator?.setTags(
        channelCode: code,
        appId: canonicalId,
        tags: result,
      );
    } catch (e) {
      appLog.error('DiscoveryNotifier: 保存标签失败 - $e');
      if (!_disposed) {
        AppDialogs.showError('保存标签失败：$e');
      }
    }
  }

  /// 保存搜索结果到渠道数据库（不直接入库首页）
  /// 用户需在渠道应用列表中选择"入库"才会加入首页
  Future<bool> saveSearchToChannel(String code, AppSummary app) async {
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return false;
    try {
      // 统一调用 IChannel.addApp（各渠道内部处理保存逻辑）
      final result = await channelInstance.addApp(app);
      if (!result.success) {
        appLog.error(
            'DiscoveryNotifier: $code 保存搜索结果失败 - ${result.error}');
        return false;
      }

      // 刷新该渠道的应用列表（让保存的应用出现在渠道视图中）
      await _refreshChannelApps(code);
      // 刷新已添加应用索引（搜索入库后更新状态）
      await _updateAddedAppsIndex();
      return true;
    } catch (e) {
      appLog.error('DiscoveryNotifier: 保存搜索结果失败 - $e');
      return false;
    }
  }

  /// 刷新指定渠道的应用列表
  Future<void> _refreshChannelApps(String code) async {
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return;
    try {
      final result = await channelInstance.getAllApps(forceRefresh: true);
      if (result.success && result.data != null) {
        state = state.copyWith(
          channelApps: {...state.channelApps, code: result.data!},
        );
      }
    } catch (e) {
      appLog.error('DiscoveryNotifier: 刷新渠道应用失败 - $e');
    }
  }

  /// 从渠道移除应用（同时从首页聚合移除）
  /// 返回是否成功；[showSnack] 为 false 时静默（批量操作场景）
  Future<bool> removeFromChannel(
    String code,
    String appId, {
    bool showSnack = true,
  }) async {
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return false;
    try {
      final result = await channelInstance.removeApp(appId);
      if (!result.success) {
        appLog.error(
            'DiscoveryNotifier: $code 移除应用失败 - ${result.error}');
        if (showSnack && !_disposed) {
          AppDialogs.showError('${result.error ?? '未知错误'}', title: '移除失败');
        }
        return false;
      }

      // 若已添加到首页，同步移除（aggregate 模块下线时跳过）
      final aggregator = _aggregator;
      if (aggregator == null) return false;
      if (await aggregator.isAppAdded(channelCode: code, appId: appId)) {
        await aggregator.removeApp(channelCode: code, appId: appId);
      }

      // 刷新渠道列表
      await _refreshChannelApps(code);
      if (showSnack && !_disposed) {
        AppDialogs.showSuccess('已从${getChannelName(code)}移除', title: '已移除');
      }
      return true;
    } catch (e) {
      appLog.error('DiscoveryNotifier: 移除渠道应用失败 - $e');
      if (showSnack && !_disposed) {
        AppDialogs.showError('$e', title: '移除失败');
      }
      return false;
    }
  }

  /// 显示应用操作菜单（长按触发）
  /// 单应用操作：添加到首页/移除首页、从渠道删除、批量管理
  void showAppActions(BuildContext context, String code, AppSummary app) {
    final isAdded = isAppAdded(code, app.appId);
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动指示器
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 应用信息头
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  AppIcon(url: app.icon, width: 40, height: 40),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          '${getChannelName(code)} · '
                          '${isAdded ? '已在首页' : '未添加到首页'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 添加到首页 / 从首页移除
            ListTile(
              leading: Icon(
                isAdded
                    ? Icons.remove_circle_outline
                    : Icons.add_circle_outline,
                color: theme.colorScheme.primary,
              ),
              title: Text(isAdded ? '从首页移除' : '添加到首页'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                toggleApp(context, code, app);
              },
            ),
            // 从渠道删除
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                '从渠道删除',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                AppDialogs.showDialog(
                  title: '移除应用',
                  content:
                      '确定从${getChannelName(code)}移除 ${app.name} 吗？',
                  confirmText: '移除',
                  cancelText: '取消',
                  isDangerous: true,
                  onConfirm: () => removeFromChannel(code, app.appId),
                );
              },
            ),
            // 批量管理
            ListTile(
              leading: Icon(
                Icons.checklist,
                color: theme.colorScheme.secondary,
              ),
              title: const Text('批量管理'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                toggleMultiSelectMode();
                toggleAppSelection(code, app.appId);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  /// 批量添加（添加渠道的所有应用）
  Future<void> addAllFromChannel(String code) async {
    final apps = state.channelApps[code] ?? [];
    if (apps.isEmpty) return;
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return;

    try {
      await _aggregator?.addApps(
        channelCode: code,
        appInfos: apps,
      );
      if (!_disposed) {
        AppDialogs.showSuccess('已添加 ${apps.length} 个应用', title: '批量添加');
      }
    } catch (e) {
      if (!_disposed) {
        AppDialogs.showError('$e', title: '操作失败');
      }
    }
  }

  /// 清空渠道的所有已添加应用
  Future<void> clearChannel(String code) async {
    final channelInstance = _channelManager?.getChannelByCode(code);
    if (channelInstance == null) return;

    try {
      await _aggregator?.clearChannel(code);
      if (!_disposed) {
        AppDialogs.showInfo('已清空 $code 渠道的所有应用', title: '已清空');
      }
    } catch (e) {
      if (!_disposed) {
        AppDialogs.showError('$e', title: '操作失败');
      }
    }
  }

  /// 获取筛选后的应用列表
  Map<String, List<AppSummary>> getFilteredApps() {
    final result = <String, List<AppSummary>>{};

    state.channelApps.forEach((code, apps) {
      // 渠道筛选
      if (state.selectedChannel != null && state.selectedChannel != code) {
        return;
      }

      // 搜索和显示模式筛选
      var filteredApps = apps.where((app) {
        // 搜索筛选
        if (state.searchKeyword.isNotEmpty) {
          final keyword = state.searchKeyword.toLowerCase();
          if (!app.name.toLowerCase().contains(keyword) &&
              !app.des.toLowerCase().contains(keyword)) {
            return false;
          }
        }

        // 显示模式筛选
        final isAdded = isAppAdded(code, app.appId);
        switch (state.displayMode) {
          case DisplayMode.added:
            return isAdded;
          case DisplayMode.notAdded:
            return !isAdded;
          case DisplayMode.all:
            return true;
        }
      }).toList();

      if (filteredApps.isNotEmpty) {
        result[code] = filteredApps;
      }
    });

    return result;
  }

  /// 获取渠道图标
  IconData getChannelIcon(String code) {
    switch (ChannelType.fromCode(code)) {
      case ChannelType.localDb:
        return Icons.storage;
      case ChannelType.github:
        return Icons.code;
      case ChannelType.http:
        return Icons.cloud;
      case ChannelType.vivo:
        return Icons.phone_android;
      case ChannelType.fdroid:
        return Icons.extension;
      case ChannelType.custom:
        return Icons.apps;
      case null:
        // 脚本渠道
        return Icons.apps;
    }
  }

  /// 获取应用总数
  int getTotalAppCount() {
    return state.channelApps.values.fold(0, (sum, apps) => sum + apps.length);
  }

  /// 获取已添加应用总数
  int getAddedAppCount() {
    return state.addedAppsIndex.values.fold(0, (sum, ids) => sum + ids.length);
  }

  /// 显示添加应用的 Bottom Sheet
  /// 直接弹出搜索框 + 渠道多选（默认 F-Droid，记忆上次选中）
  void showAddAppSheet(BuildContext context) {
    final manager = _channelManager;
    if (manager == null) return;

    // 枚举渠道 + 动态脚本渠道（channelKey 隔离），去重后过滤启用渠道。
    final allChannels = <IChannel>[
      ...manager.dynamicChannels,
      ...manager.enabledChannels
          .where((c) => !manager.dynamicChannels.contains(c)),
    ];

    // 过滤出启用的搜索渠道
    final searchableChannels = allChannels.where((c) => c.info.enabled).toList();

    if (searchableChannels.isEmpty) {
      AppDialogs.showInfo('当前没有可用的搜索渠道', title: '提示');
      return;
    }

    // 加载记忆的选中渠道（默认 F-Droid）
    _loadSelectedChannelCodes().then((saved) {
      if (!context.mounted) return;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        builder: (sheetContext) => _AddAppSearchSheet(
          channels: searchableChannels,
          initialSelectedCodes: saved,
          onSaveToChannel: saveSearchToChannel,
          onSelectionChanged: _saveSelectedChannelCodes,
        ),
      );
    });
  }

  /// 读取记忆的选中渠道（默认 F-Droid）
  Future<List<String>> _loadSelectedChannelCodes() async {
    try {
      final saved =
          await ConfigService.instance.getT<List<String>>(ConfigKeys.selectedChannels);
      if (saved != null && saved.isNotEmpty) return saved;
      return const ['fdroid'];
    } catch (e) {
      appLog.error('DiscoveryNotifier: 读取选中渠道失败 - $e');
      return const ['fdroid'];
    }
  }

  /// 保存选中渠道
  Future<void> _saveSelectedChannelCodes(List<String> codes) async {
    try {
      await ConfigService.instance.set(
        ConfigKeys.selectedChannels,
        codes,
        source: ConfigChangeSource.user,
      );
    } catch (e) {
      appLog.error('DiscoveryNotifier: 保存选中渠道失败 - $e');
    }
  }

  /// 获取渠道名称
  String getChannelName(String code) {
    switch (ChannelType.fromCode(code)) {
      case ChannelType.localDb:
        return '本地数据库';
      case ChannelType.github:
        return 'GitHub';
      case ChannelType.http:
        return 'HTTP API';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'F-Droid';
      case ChannelType.custom:
        return '自定义';
      case null:
        // 脚本渠道：取渠道名，缺失回退 code
        return _channelManager?.getChannelByCode(code)?.info.name ?? code;
    }
  }

  /// 切换显示模式（简化版本）
  void toggleDisplayMode() {
    switch (state.displayMode) {
      case DisplayMode.all:
        setDisplayMode(DisplayMode.added);
        break;
      case DisplayMode.added:
        setDisplayMode(DisplayMode.notAdded);
        break;
      case DisplayMode.notAdded:
        setDisplayMode(DisplayMode.all);
        break;
    }
  }

  /// 选择搜索渠道
  void selectSearchChannel(ChannelType? channel) {
    _selectedSearchChannel = channel;
  }

  /// 执行搜索
  Future<void> performSearch() async {
    final keyword = searchController.text.trim();
    if (keyword.isEmpty) {
      return;
    }

    // 如果有选中的搜索渠道，只在该渠道搜索
    if (_selectedSearchChannel != null) {
      await _searchInChannel(_selectedSearchChannel!.code, keyword);
    } else {
      // 搜索所有渠道：枚举渠道（enabledChannels）+ 动态脚本渠道（dynamicChannels），
      // 按 channelCode 去重——enabledChannels 中 custom 槽位存最后一个 JS 渠道，
      // dynamicChannels 含全部 JS 渠道（含 custom 槽位那个），去重避免重复搜索。
      final searched = <String>{};
      for (var channel in _channelManager?.enabledChannels ?? const <IChannel>[]) {
        final code = channelCode(channel);
        if (searched.add(code)) {
          await _searchInChannel(code, keyword);
        }
      }
      for (var channel in _channelManager?.dynamicChannels ?? const <IChannel>[]) {
        final code = channelCode(channel);
        if (searched.add(code)) {
          await _searchInChannel(code, keyword);
        }
      }
    }
  }

  /// 在指定渠道搜索
  Future<void> _searchInChannel(String code, String keyword) async {
    final channel = _channelManager?.getChannelByCode(code);
    if (channel == null) return;

    try {
      final result = await channel.searchApps(keyword, forceRefresh: true);
      if (result.success && result.data != null) {
        state = state.copyWith(
          channelApps: {...state.channelApps, code: result.data!},
        );
      }
    } catch (e) {
      appLog.error('DiscoveryNotifier: 搜索 $code 失败 - $e');
    }
  }

  /// 防抖搜索
  void debounceSearch() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      performSearch();
    });
  }

  /// 显示批量操作菜单
  void showBatchActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => Container(
        padding: AppSpacing.allLG,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.select_all),
                title: const Text('全选当前页面'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _selectAllInCurrentView();
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('批量添加已选'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _batchAddSelected();
                },
              ),
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('批量移除已选'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _batchRemoveSelected();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全选当前视图
  void _selectAllInCurrentView() {
    AppDialogs.showInfo('批量操作功能开发中', title: '提示');
  }

  /// 批量添加
  void _batchAddSelected() {
    AppDialogs.showInfo('批量操作功能开发中', title: '提示');
  }

  /// 批量移除（从渠道删除选中的应用，供 UI 调用）
  Future<void> batchRemoveSelected() => _batchRemoveSelected();

  /// 批量移除（从渠道删除选中的应用）
  Future<void> _batchRemoveSelected() async {
    if (state.selectedApps.isEmpty) return;

    final confirmed = await AppDialogs.showDialog(
      title: '移除应用',
      content: '确定从渠道移除选中的 ${state.selectedApps.length} 个应用吗？',
      confirmText: '移除',
      cancelText: '取消',
      isDangerous: true,
    );
    if (confirmed != true) return;

    int successCount = 0;
    int failCount = 0;
    final keys = List<String>.from(state.selectedApps);

    for (final key in keys) {
      final parts = key.split(':');
      if (parts.length != 2) continue;
      final channelCode = parts[0];
      final appId = parts[1];
      if (_channelManager?.getChannelByCode(channelCode) == null) continue;

      final ok = await removeFromChannel(channelCode, appId, showSnack: false);
      if (ok) {
        successCount++;
      } else {
        failCount++;
      }
    }

    // 清空选择并退出多选
    state = state.copyWith(
      selectedApps: const {},
      isMultiSelectMode: false,
    );

    if (!_disposed) {
      AppDialogs.showInfo('成功: $successCount, 失败: $failCount', title: '移除完成');
    }
  }
}

/// 发现页 provider（页面级 autoDispose：切走销毁，回来重建加载）。
final discoveryProvider = NotifierProvider.autoDispose<DiscoveryNotifier, DiscoveryState>(
  DiscoveryNotifier.new,
);

/// 添加应用搜索 Bottom Sheet
/// 直接搜索，下方渠道多选（默认 F-Droid，记忆选中）
class _AddAppSearchSheet extends StatefulWidget {
  /// 可选搜索渠道
  final List<IChannel> channels;

  /// 初始选中的渠道 codes
  final List<String> initialSelectedCodes;

  /// 保存到渠道回调（返回是否成功）
  final Future<bool> Function(String code, AppSummary appInfo)
      onSaveToChannel;

  /// 选中渠道变化回调（持久化）
  final Future<void> Function(List<String> codes) onSelectionChanged;

  const _AddAppSearchSheet({
    required this.channels,
    required this.initialSelectedCodes,
    required this.onSaveToChannel,
    required this.onSelectionChanged,
  });

  @override
  State<_AddAppSearchSheet> createState() => _AddAppSearchSheetState();
}

class _AddAppSearchSheetState extends State<_AddAppSearchSheet> {
  late final Set<String> _selectedCodes;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 搜索结果：应用 + 来源渠道 code
  final List<(AppSummary, String)> _results = [];

  bool _searching = false;
  bool _searched = false;
  Timer? _debounce;

  /// 已保存到渠道的应用 key（code:appId）
  final Set<String> _savedKeys = {};

  /// 正在保存的 key
  String? _savingKey;

  @override
  void initState() {
    super.initState();
    // 初始选中 = 记忆的选中（过滤无效渠道），空则默认 fdroid
    final validCodes = widget.channels.map(channelCode).toSet();
    final initial = widget.initialSelectedCodes.where(validCodes.contains).toSet();
    _selectedCodes = initial.isNotEmpty ? initial : {'fdroid'};
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 切换渠道选中
  void _toggleChannel(String code) {
    setState(() {
      if (!_selectedCodes.remove(code)) {
        _selectedCodes.add(code);
      }
    });
    // 持久化选中
    widget.onSelectionChanged(_selectedCodes.toList());
    // 有搜索词则重新搜索
    if (_searchController.text.trim().isNotEmpty) {
      _doSearch(_searchController.text.trim());
    }
  }

  /// 防抖搜索
  void _onKeywordChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final keyword = value.trim();
      if (keyword.isEmpty) {
        setState(() {
          _results.clear();
          _searched = false;
        });
        return;
      }
      _doSearch(keyword);
    });
  }

  /// 搜索所有选中渠道，聚合结果
  Future<void> _doSearch(String keyword) async {
    final channels = widget.channels
        .where((c) => _selectedCodes.contains(channelCode(c)))
        .toList();
    if (channels.isEmpty) {
      setState(() {
        _results.clear();
        _searched = true;
      });
      return;
    }

    setState(() {
      _searching = true;
      _searched = true;
    });

    final newResults = <(AppSummary, String)>[];
    for (final channel in channels) {
      final code = channelCode(channel);
      try {
        final result = await channel.searchApps(keyword, forceRefresh: true);
        if (result.success && result.data != null) {
          for (final app in result.data!) {
            newResults.add((app, code));
          }
        }
      } catch (e) {
        appLog.error('_AddAppSearchSheet: 搜索 $code 失败 - $e');
      }
    }

    // 按搜索词相似度排序（名称/包名完全匹配 > 前缀 > 包含 > 描述包含）
    final kw = keyword.toLowerCase();
    newResults.sort((a, b) => _scoreResult(b.$1, kw) - _scoreResult(a.$1, kw));

    if (!mounted) return;
    setState(() {
      _results
        ..clear()
        ..addAll(newResults);
      _searching = false;
    });
  }

  /// 计算应用与搜索词的匹配分数
  int _scoreResult(AppSummary app, String kw) {
    final name = app.name.toLowerCase();
    final pkg = app.appId.toLowerCase();
    final des = app.des.toLowerCase();
    int score = 0;
    if (name == kw) {
      score += 100;
    } else if (name.startsWith(kw)) {
      score += 80;
    } else if (name.contains(kw)) {
      score += 60;
    }
    if (pkg == kw) {
      score += 50;
    } else if (pkg.contains(kw)) {
      score += 40;
    }
    if (des.contains(kw)) {
      score += 20;
    }
    return score;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动指示器
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '搜索应用',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // 渠道多选
            SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: widget.channels.map((channel) {
                    final code = channelCode(channel);
                    final selected = _selectedCodes.contains(code);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: Icon(
                          _channelIcon(code),
                          size: 16,
                          color: selected ? scheme.onSecondaryContainer : null,
                        ),
                        label: Text(channel.info.name),
                        selected: selected,
                        onSelected: (_) => _toggleChannel(code),
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const Divider(height: 1),

            // 搜索输入框
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: TextField(
                controller: _searchController,
                focusNode: _focusNode,
                onChanged: _onKeywordChanged,
                onSubmitted: (value) {
                  final keyword = value.trim();
                  if (keyword.isNotEmpty) _doSearch(keyword);
                },
                decoration: InputDecoration(
                  hintText: '输入应用名称或包名搜索',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),

            // 搜索结果
            Flexible(
              child: _buildResultArea(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 结果区域
  Widget _buildResultArea(BuildContext context) {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: AppLoading(size: AppLoadingSize.medium),
      );
    }

    if (!_searched) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text('输入关键词，搜索所选渠道的应用'),
        ),
      );
    }

    if (_results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('未找到相关应用')),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final (app, code) = _results[index];
        final scheme = Theme.of(context).colorScheme;
        return ListTile(
            leading: app.icon.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: app.icon,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          _defaultAppIcon(context),
                    ),
                  )
                : _defaultAppIcon(context),
            // 标题行：应用名 + 渠道标签（渠道名始终可见，不被截断）
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _channelName(code),
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: app.des.isNotEmpty
                ? Text(
                    app.des,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            trailing: _buildSaveButton(code, app),
          );
        },
    );
  }

  /// 保存按钮：保存到渠道数据库（不直接入库首页）
  Widget _buildSaveButton(String code, AppSummary app) {
    final key = '$code:${app.appId}';
    final saved = _savedKeys.contains(key);
    final saving = _savingKey == key;

    if (saved) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 16, color: Colors.green),
            SizedBox(width: 4),
            Text('已添加', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
      ),
      onPressed: saving ? null : () => _saveToChannel(code, app),
      child: saving
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('添加'),
    );
  }

  /// 保存到渠道（保存搜索结果，供后续入库）
  Future<void> _saveToChannel(String code, AppSummary app) async {
    final key = '$code:${app.appId}';
    setState(() => _savingKey = key);
    final success = await widget.onSaveToChannel(code, app);
    if (!mounted) return;
    setState(() {
      _savingKey = null;
      if (success) {
        _savedKeys.add(key);
        AppDialogs.showSuccess(
          '${app.name} 已保存，可到渠道列表中选择入库',
          title: '已添加到${_channelName(code)}',
        );
      } else {
        AppDialogs.showError(
          '${app.name} 保存到${_channelName(code)}失败',
          title: '添加失败',
        );
      }
    });
  }

  /// 默认应用图标
  Widget _defaultAppIcon(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.android, color: Colors.grey),
    );
  }

  /// 渠道名称
  String _channelName(String code) {
    switch (ChannelType.fromCode(code)) {
      case ChannelType.localDb:
        return '本地数据库';
      case ChannelType.github:
        return 'GitHub';
      case ChannelType.http:
        return 'HTTP API';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'F-Droid';
      case ChannelType.custom:
        return '自定义';
      case null:
        // 脚本渠道：取渠道名，缺失回退 code
        return ChannelManager.instance.getChannelByKey(code)?.info.name ?? code;
    }
  }

  /// 渠道图标
  IconData _channelIcon(String code) {
    switch (ChannelType.fromCode(code)) {
      case ChannelType.localDb:
        return Icons.storage;
      case ChannelType.github:
        return Icons.code;
      case ChannelType.http:
        return Icons.cloud;
      case ChannelType.vivo:
        return Icons.phone_android;
      case ChannelType.fdroid:
        return Icons.android;
      case ChannelType.custom:
        return Icons.apps;
      case null:
        // 脚本渠道
        return Icons.apps;
    }
  }
}
