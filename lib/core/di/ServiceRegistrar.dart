/// 服务注册配置
/// 集中管理所有服务的注册
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/config/AppConfig.dart';
import 'package:gstore/core/di/ServiceContainer.dart';
import 'package:gstore/core/error/ErrorHandler.dart';
import 'package:gstore/core/security/UrlValidator.dart';

/// 服务注册器
/// 集中管理所有服务的注册逻辑
class ServiceRegistrar {
  ServiceRegistrar._internal();

  static final ServiceRegistrar _instance = ServiceRegistrar._internal();

  factory ServiceRegistrar() => _instance;

  /// 已注册的渠道工厂
  final Map<String, IChannel Function()> _channelFactories = {};

  /// 注册渠道工厂
  void registerChannelFactory(
    String channelType,
    IChannel Function() factory,
  ) {
    _channelFactories[channelType] = factory;
  }

  /// 注册所有核心服务
  void registerCoreServices(ServiceContainer container) {
    debugPrint('ServiceRegistrar: 开始注册核心服务...');

    // 1. 应用配置（单例）
    container.registerSingleton<AppConfig>(
      factory: (_) => AppConfig(),
    );

    // 2. URL 验证器（单例）
    container.registerSingleton<UrlValidator>(
      factory: (c) => UrlValidator(),
    );

    // 3. 错误处理器（单例）
    container.registerSingleton<ErrorHandler>(
      factory: (c) => ErrorHandler(),
    );

    // 4. Dio 客户端（单例）
    container.registerSingleton<Dio>(
      factory: (c) {
        final config = c.getService<AppConfig>();
        return Dio(
          BaseOptions(
            connectTimeout: Duration(milliseconds: config.networkTimeoutMs),
            receiveTimeout: Duration(milliseconds: config.networkTimeoutMs),
            sendTimeout: Duration(milliseconds: config.networkTimeoutMs),
          ),
        );
      },
    );

    // 5. ChannelManager（单例）
    container.registerInstance<ChannelManager>(ChannelManager.instance);

    debugPrint('ServiceRegistrar: 核心服务注册完成');
  }

  /// 注册渠道服务
  void registerChannels(
    ServiceContainer container,
    List<IChannel> channels,
  ) {
    debugPrint('ServiceRegistrar: 开始注册渠道服务...');

    final channelManager = container.getService<ChannelManager>();

    // 批量注册渠道
    channelManager.registerChannels(channels);

    debugPrint('ServiceRegistrar: 已注册 ${channels.length} 个渠道');
  }

  /// 初始化所有服务
  Future<void> initializeServices(ServiceContainer container) async {
    debugPrint('ServiceRegistrar: 开始初始化服务...');

    try {
      // 1. 初始化配置
      final config = container.getService<AppConfig>();
      await config.initialize();

      // 2. 初始化错误处理器
      final errorHandler = container.getService<ErrorHandler>();
      errorHandler.initialize();

      // 3. 初始化渠道管理器
      final channelManager = container.getService<ChannelManager>();
      await channelManager.initializeAll();

      debugPrint('ServiceRegistrar: 服务初始化完成');
    } catch (e, stackTrace) {
      debugPrint('ServiceRegistrar: 服务初始化失败 - $e');
      final errorHandler = container.tryGetService<ErrorHandler>();
      errorHandler?.handle(e, stackTrace);
      rethrow;
    }
  }

  /// 创建服务定位器并注册所有服务
  static Future<void> setup({
    required List<IChannel> channels,
    Map<String, dynamic>? customConfig,
  }) async {
    final locator = ServiceLocator();
    final registrar = ServiceRegistrar();

    // 初始化服务定位器
    locator.initialize(
      registerServices: (container) {
        // 注册核心服务
        registrar.registerCoreServices(container);

        // 注册渠道
        registrar.registerChannels(container, channels);

        // 应用自定义配置
        if (customConfig != null) {
          final config = container.getService<AppConfig>();
          config.initialize(customConfig: customConfig);
        }
      },
    );

    // 初始化所有服务
    await registrar.initializeServices(locator.currentContainer);
  }

  /// 获取已注册的渠道工厂
  IChannel Function()? getChannelFactory(String channelType) {
    return _channelFactories[channelType];
  }

  /// 清除所有注册
  void clearRegistrations() {
    _channelFactories.clear();
  }
}
