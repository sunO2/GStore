import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

class ChannelTestLogic extends GetxController {
  final ChannelTestState state = ChannelTestState();
  ChannelManager? _channelManager;

  @override
  void onReady() async {
    super.onReady();
    // channel 模块下线 → 注册表取不到，置 null（既有消费点已 null 降级）
    _channelManager = ModuleManager.instance.get<ChannelManager>();
    _loadInitialData();
  }

  /// 加载初始数据
  Future<void> _loadInitialData() async {
    if (_channelManager != null) {
      await executeQuery('getAllApps');
    }
  }

  /// 获取渠道列表
  List<ChannelInfo> get channelList => _channelManager?.allChannelInfo ?? [];

  /// 获取启用的渠道
  List<IChannel> get enabledChannels => _channelManager?.enabledChannels ?? [];

  /// 选择渠道
  void selectChannel(ChannelType type) {
    state.selectedChannel.value = type;
  }

  /// 执行查询
  Future<void> executeQuery(String operation) async {
    final manager = _channelManager;
    if (manager == null) {
      state.errorMessage.value = '渠道管理器未初始化';
      return;
    }

    state.operationType.value = operation;
    state.isQuerying.value = true;
    state.errorMessage.value = '';
    state.queryResult.value = null;

    try {
      ChannelResult result;

      switch (operation) {
        case 'getAllApps':
          result = await manager.getAllApps(
            from: state.selectedChannel.value,
          );
          if (result.success) {
            state.apps.value = result.data ?? [];
          }
          break;

        case 'getAppInfo':
          result = await manager.getAppInfo(
            state.appId.value,
            from: state.selectedChannel.value,
          );
          if (result.success && result.data != null) {
            state.apps.value = [result.data!];
          } else {
            state.apps.value = [];
          }
          break;

        case 'searchApps':
          if (state.searchKeyword.value.isEmpty) {
            state.errorMessage.value = '请输入搜索关键词';
            state.isQuerying.value = false;
            return;
          }
          result = await manager.searchApps(
            state.searchKeyword.value,
            from: state.selectedChannel.value,
          );
          if (result.success) {
            state.apps.value = result.data ?? [];
          }
          break;

        case 'searchByCategory':
          result = await manager.searchByCategory(
            state.categoryId.value,
            from: state.selectedChannel.value,
          );
          if (result.success) {
            state.apps.value = result.data ?? [];
          }
          break;

        case 'getAllCategories':
          result = await manager.getAllCategories(
            from: state.selectedChannel.value,
          );
          if (result.success) {
            // 分类数据不显示在应用列表中
            state.apps.value = [];
          }
          break;

        case 'checkUpdate':
          result = await manager.checkUpdate(
            from: state.selectedChannel.value,
          );
          state.apps.value = [];
          break;

        case 'checkAllUpdates':
          var results = await manager.checkAllUpdates();
          var sb = StringBuffer();
          results.forEach((type, result) {
            sb.writeln('$type: ${result.success ? (result.data ?? false) : "失败"}');
          });
          state.queryResult.value = ChannelResult(
            from: state.selectedChannel.value,
            success: true,
            metadata: {'summary': sb.toString()},
          );
          state.isQuerying.value = false;
          return;

        default:
          state.errorMessage.value = '未知操作: $operation';
          state.isQuerying.value = false;
          return;
      }

      state.queryResult.value = result;

      if (!result.success) {
        state.errorMessage.value = result.error ?? '查询失败';
      }
    } catch (e) {
      state.errorMessage.value = '查询异常: $e';
      state.queryResult.value = ChannelResult.failure(
        from: state.selectedChannel.value,
        error: e.toString(),
      );
    } finally {
      state.isQuerying.value = false;
    }
  }

  /// 清除缓存
  Future<void> clearCache() async {
    final manager = _channelManager;
    if (manager == null) return;

    await manager.clearCache(
      from: state.selectedChannel.value,
    );
    Get.snackbar(
      '清除缓存',
      '已清除 ${state.selectedChannel.value.code} 渠道的缓存',
      icon: const Icon(Icons.check_circle, color: Colors.green),
    );
  }

  /// 刷新数据
  Future<void> refresh() async {
    await executeQuery(state.operationType.value);
  }

  /// 切换渠道并刷新
  Future<void> switchChannel(ChannelType type) async {
    selectChannel(type);
    await refresh();
  }

  /// 获取渠道图标
  IconData getChannelIcon(ChannelType type) {
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
        return Icons.extension;
      default:
        return Icons.apps;
    }
  }

  @override
  void onClose() {
    super.onClose();
  }

  /// 显示日志
  void showLogs() {
    Get.toNamed(AppRoute.logViewer);
  }

  /// 切换开发者模式
  void toggleDeveloperMode() {
    state.developerMode.value = !state.developerMode.value;
    Get.snackbar(
      '开发者模式',
      state.developerMode.value ? '已开启' : '已关闭',
      icon: Icon(
        state.developerMode.value ? Icons.bug_report : Icons.bug_report_outlined,
        color: state.developerMode.value ? Colors.orange : Colors.grey,
      ),
      duration: const Duration(seconds: 1),
    );
  }

  /// 选择操作（用于开发者模式）
  void selectOperation(String operation) {
    state.currentOperation.value = operation;
    executeQuery(operation);
  }

  /// 获取渠道名称
  String getChannelName(ChannelType type) {
    switch (type) {
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
      default:
        return type.code;
    }
  }
}
