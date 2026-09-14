import 'dart:async';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/module_manager.dart';

/// 把现有各事件源适配进 [AppEventBus]（幂等）。
///
/// 采用"适配而非替换"：DatabaseEventBus / ModuleManager.onChange /
/// ConfigService.onChange 的公开 API 与全部调用点保持不变，本类只做单向汇聚。
/// 配置变化额外标记 `downlink: true`，经 AppEventBus 下发到 Rust 模块
/// （模块用新的 `on_event` 订阅；见 Rust 侧 on_event 槽）。
class AppEventBusBootstrap {
  AppEventBusBootstrap._();

  static bool _initialized = false;
  static final List<StreamSubscription<dynamic>> _subs = [];

  /// 幂等初始化（在 registerService 中调用一次）
  static void initialize() {
    if (_initialized) return;
    _initialized = true;

    final bus = AppEventBus.instance;

    // 数据库变化 → 统一总线
    _subs.add(DatabaseEventBus.instance.eventStream.listen((e) {
      bus.publish(AppEvent(
        type: AppEventTypes.dbChanged,
        source: AppEventSource.database,
        data: {'type': e.type.name, 'data': e.data},
      ));
    }));

    // 模块上下线 → 统一总线
    _subs.add(ModuleManager.instance.onChange.listen((e) {
      bus.publish(AppEvent(
        type: AppEventTypes.moduleLifecycle,
        source: AppEventSource.module,
        data: {'module': e.moduleName, 'lifecycle': e.lifecycle.name},
      ));
    }));

    // 配置变化 → 统一总线（并下发 Rust 模块：模块按 key 过滤）
    _subs.add(ConfigService.instance.onChange.listen((e) {
      bus.publish(AppEvent(
        type: AppEventTypes.configChanged,
        source: AppEventSource.config,
        data: {'key': e.key, 'value': e.newValue},
        downlink: true,
      ));

      // 主题变化单独成事件（主题模式/主题配置），供模块订阅主题切换
      if (e.key == ConfigKeys.themeMode || e.key == ConfigKeys.themeConfig) {
        bus.publish(AppEvent(
          type: AppEventTypes.themeChanged,
          source: AppEventSource.config,
          data: {'key': e.key, 'value': e.newValue},
          downlink: true,
        ));
      }
    }));

    appLog.info('AppEventBusBootstrap: 已接入 DB / 模块 / 配置 事件源');
  }

  /// 释放适配订阅（测试/重置用）
  static Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _initialized = false;
  }
}
