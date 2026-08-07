/// 主题配置提供者
///
/// 管理应用主题相关的配置
library;

import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';

import '../config_provider.dart';
import '../../theme/app_theme_config.dart';
import '../config_storage.dart';

/// 主题配置提供者
///
/// 负责主题配置的加载、保存和变化监听
class ThemeConfigProvider extends ConfigProvider<AppThemeConfig> {
  ThemeConfigProvider(this._storage);

  final ConfigStorage _storage;

  /// 配置键
  @override
  String get configKey => 'theme_config';

  /// 主题模式键
  static const String _modeKey = 'theme_mode';

  /// 主题模式变化控制器
  final _modeController = StreamController<AppThemeMode>.broadcast();

  /// 主题配置变化控制器
  final _configController = StreamController<AppThemeConfig>.broadcast();

  /// 当前主题模式
  final Rx<AppThemeMode> _themeMode = AppThemeMode.system.obs;

  /// 当前主题配置
  final Rx<AppThemeConfig> _themeConfig = AppThemeConfig.default_.obs;

  /// 当前主题模式
  AppThemeMode get themeMode => _themeMode.value;

  /// ThemeMode 值（用于 MaterialApp）
  ThemeMode get themeModeValue => _themeMode.value.toThemeMode();

  /// 当前主题配置
  AppThemeConfig get themeConfig => _themeConfig.value;

  /// 主题模式流
  Rx<AppThemeMode> get themeModeStream => _themeMode;

  /// 主题配置流
  Rx<AppThemeConfig> get themeConfigStream => _themeConfig;

  @override
  Future<AppThemeConfig?> load() async {
    try {
      debugPrint('ThemeConfigProvider: 开始加载配置');
      final jsonString = await _storage.getString(configKey);
      if (jsonString != null) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        debugPrint('ThemeConfigProvider: 已找到保存的配置');
        debugPrint('ThemeConfigProvider: useCustomColors = ${json['useCustomColors']}');

        final config = AppThemeConfig.fromJson(json);
        _themeConfig.value = config;

        appLog.info('ThemeConfigProvider: 配置加载成功 - useCustomColors = ${config.useCustomColors}');
        return config;
      }
      debugPrint('ThemeConfigProvider: 未找到保存的配置，使用默认值');
      return AppThemeConfig.default_;
    } catch (e) {
      appLog.error('ThemeConfigProvider: 加载配置失败 - $e');
      return AppThemeConfig.default_;
    }
  }

  @override
  Future<bool> save(AppThemeConfig config) async {
    try {
      debugPrint('ThemeConfigProvider: 准备保存配置');
      debugPrint('ThemeConfigProvider: useCustomColors = ${config.useCustomColors}');

      final jsonString = jsonEncode(config.toJson());
      debugPrint('ThemeConfigProvider: JSON = $jsonString');

      final success = await _storage.setString(configKey, jsonString);
      if (success) {
        _themeConfig.value = config;
        _configController.add(config);
        appLog.info('ThemeConfigProvider: 配置已保存并发出变化事件');
      } else {
        appLog.error('ThemeConfigProvider: 保存失败 - setString 返回 false');
      }
      return success;
    } catch (e) {
      appLog.error('ThemeConfigProvider: 保存异常 - $e');
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    final success = await _storage.remove(configKey);
    if (success) {
      _themeConfig.value = AppThemeConfig.default_;
      _configController.add(AppThemeConfig.default_);
      appLog.info('ThemeConfigProvider: 配置已清除并发出变化事件');
    }
    return success;
  }

  @override
  Stream<AppThemeConfig?> watch() {
    return _configController.stream.map((_) => _themeConfig.value);
  }

  /// 加载主题模式
  Future<AppThemeMode?> loadMode() async {
    try {
      final modeIndex = await _storage.getInt(_modeKey);
      if (modeIndex != null) {
        final mode = AppThemeMode.values[modeIndex];
        _themeMode.value = mode;
        return mode;
      }
      return AppThemeMode.system;
    } catch (e) {
      return AppThemeMode.system;
    }
  }

  /// 保存主题模式
  Future<bool> saveMode(AppThemeMode mode) async {
    try {
      final success = await _storage.setInt(_modeKey, mode.index);
      if (success) {
        _themeMode.value = mode;
        _modeController.add(mode);
        appLog.info('ThemeConfigProvider: 主题模式已保存并发出变化事件 - $mode');
      }
      return success;
    } catch (e) {
      return false;
    }
  }

  /// 监听主题模式变化
  Stream<AppThemeMode> watchMode() {
    return _modeController.stream;
  }

  /// 切换主题（浅色/深色）
  Future<void> toggleTheme() async {
    final newMode = switch (_themeMode.value) {
      AppThemeMode.system => AppThemeMode.light,
      AppThemeMode.light => AppThemeMode.dark,
      AppThemeMode.dark => AppThemeMode.light,
    };
    await saveMode(newMode);
  }

  /// 重置主题配置为默认
  Future<void> resetToDefault() async {
    await save(AppThemeConfig.default_);
  }

  /// 设置自定义颜色主题
  Future<void> setCustomColorTheme({
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  }) async {
    final config = AppThemeConfig(
      useCustomColors: true,
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      tertiaryColor: tertiaryColor,
      fontStyle: _themeConfig.value.fontStyle,
      radiusStyle: _themeConfig.value.radiusStyle,
      borderStyle: _themeConfig.value.borderStyle,
    );
    await save(config);
  }

  /// 设置字体风格
  Future<void> setFontStyle(AppFontStyle fontStyle) async {
    final config = _themeConfig.value.copyWith(fontStyle: fontStyle);
    await save(config);
  }

  /// 设置圆角风格
  Future<void> setRadiusStyle(AppRadiusStyle radiusStyle) async {
    final config = _themeConfig.value.copyWith(radiusStyle: radiusStyle);
    await save(config);
  }

  /// 设置边框风格
  Future<void> setBorderStyle(AppBorderStyle borderStyle) async {
    final config = _themeConfig.value.copyWith(borderStyle: borderStyle);
    await save(config);
  }

  /// 切换是否使用自定义颜色
  Future<void> toggleCustomColors() async {
    final oldValue = _themeConfig.value.useCustomColors;
    final newValue = !oldValue;

    debugPrint('ThemeConfigProvider: toggleCustomColors 被调用');
    debugPrint('ThemeConfigProvider: 旧值 = $oldValue, 新值 = $newValue');

    final config = _themeConfig.value.copyWith(
      useCustomColors: newValue,
    );

    debugPrint('ThemeConfigProvider: 准备保存配置 - useCustomColors = ${config.useCustomColors}');

    await save(config);

    debugPrint('ThemeConfigProvider: 保存完成，当前值 = ${_themeConfig.value.useCustomColors}');
  }

  /// 释放资源
  void dispose() {
    _modeController.close();
    _configController.close();
  }

  @override
  Future<bool> importFromJson(Map<String, dynamic> json) async {
    try {
      debugPrint('ThemeConfigProvider: 开始从 JSON 导入配置');
      debugPrint('ThemeConfigProvider: JSON keys: ${json.keys.toList()}');
      debugPrint('ThemeConfigProvider: fontStyle = ${json['fontStyle']}, radiusStyle = ${json['radiusStyle']}, borderStyle = ${json['borderStyle']}');

      final config = AppThemeConfig.fromJson(json);
      debugPrint('ThemeConfigProvider: 配置对象创建成功');

      final success = await save(config);
      debugPrint('ThemeConfigProvider: 保存结果 - $success');
      return success;
    } catch (e, stackTrace) {
      appLog.error('ThemeConfigProvider: 导入配置失败 - $e');
      debugPrint('ThemeConfigProvider: 堆栈跟踪: $stackTrace');
      return false;
    }
  }
}
