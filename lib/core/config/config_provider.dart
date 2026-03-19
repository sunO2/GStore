/// 配置提供者接口
///
/// 定义配置项的加载、保存、清除等操作
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

/// 配置提供者接口
///
/// 每种配置类型都需要实现此接口，提供统一的配置管理方式
/// [T] 是具体的配置类型（如 AppThemeConfig、WebDavConfig 等）
/// 不强制要求 T 继承 ConfigItem，以保持向后兼容性
abstract class ConfigProvider<T> {
  /// 配置键（唯一标识）
  String get configKey;

  /// 加载配置
  ///
  /// 如果配置不存在，返回 null
  /// 如果加载失败，应该捕获异常并返回 null 或默认值
  Future<T?> load();

  /// 保存配置
  ///
  /// 返回是否保存成功
  /// 保存失败时应该捕获异常并返回 false
  Future<bool> save(T config);

  /// 从 JSON Map 导入配置
  ///
  /// 默认实现不支持从 JSON 导入
  /// 子类应该覆盖此方法以支持配置导入
  Future<bool> importFromJson(Map<String, dynamic> json) async {
    debugPrint('ConfigProvider[$configKey]: importFromJson 未实现，无法导入配置');
    return false;
  }

  /// 清除配置
  ///
  /// 返回是否清除成功
  Future<bool> clear();

  /// 监听配置变化
  ///
  /// 返回一个 Stream，当配置发生变化时发出新值
  /// 如果配置不存在，发出 null
  Stream<T?> watch();

  /// 检查配置是否存在
  Future<bool> exists() async {
    final config = await load();
    return config != null;
  }

  /// 获取配置或默认值
  ///
  /// 子类应该实现此方法以提供默认值
  Future<T> getOrDefault() async {
    final config = await load();
    if (config != null) return config;
    throw UnimplementedError('Subclass must implement defaultConfig');
  }
}
