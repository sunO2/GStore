/// 模块管理页模型与 UI 状态（Riverpod 不可变 state）。
library;

import 'package:gstore/core/rust/ModuleLoader.dart';

/// 模块条目（模块管理页展示元数据 + 实时状态）
class ModuleEntry {
  const ModuleEntry({
    required this.name,
    required this.title,
    required this.description,
    this.dependencies = const [],
    required this.togglable,
    this.note,
    this.enabled = true,
  });

  /// 模块名（对应 AppModule.moduleName / ModuleToggleConfig.keyOf）
  final String name;

  /// 中文名
  final String title;

  /// 描述
  final String description;

  /// 依赖模块名列表（展示用）
  final List<String> dependencies;

  /// 是否可开关（业务模块 true；系统模块 false 置灰）
  final bool togglable;

  /// 置灰说明（'系统模块' / '待接口就绪'）
  final String? note;

  /// 当前启用状态（订阅 onChange 实时刷新）
  final bool enabled;

  ModuleEntry copyWith({bool? enabled}) {
    return ModuleEntry(
      name: name,
      title: title,
      description: description,
      dependencies: dependencies,
      togglable: togglable,
      note: note,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// 模块管理页 UI 状态。
class ModuleManageState {
  final List<ModuleEntry> entries;
  final bool loading;
  final Set<String> toggling;

  const ModuleManageState({
    this.entries = const [],
    this.loading = true,
    this.toggling = const {},
  });

  ModuleManageState copyWith({
    List<ModuleEntry>? entries,
    bool? loading,
    Set<String>? toggling,
  }) {
    return ModuleManageState(
      entries: entries ?? this.entries,
      loading: loading ?? this.loading,
      toggling: toggling ?? this.toggling,
    );
  }
}

/// 单个原生插件的**内部下载进度**（不进入用户下载管线）。
///
/// [fraction] 为 `[0,1]` 的完成比例；[percent] 为其百分比取整。
class ModuleDownloadProgress {
  final double fraction;

  const ModuleDownloadProgress(this.fraction);

  /// 百分比（0~100）。
  int get percent => (fraction.clamp(0.0, 1.0) * 100).round();
}

/// 原生插件（Rust）区域 UI 状态。
///
/// - [loading]：首次/刷新读取中（页面显示静态占位，避免测试 pumpAndSettle 卡死）
/// - [statuses]：各插件 `probe` 结果（隔离感知、与解析顺序一致）
/// - [busy]：正在执行下载/更新/回退的模块名（按钮置灰防连击）
/// - [progress]：内部下载/更新进度（按模块名；下载结束即清除，不进入用户管线）
/// - [errors]：内部下载/更新的最近一次错误（按模块名；页面可见，绝不进系统通知）
/// - [error]：最近一次整体读取的错误（单个插件失败已降级为 none）
class RustPluginsState {
  final bool loading;
  final List<RustModuleStatus> statuses;
  final Set<String> busy;
  final Map<String, ModuleDownloadProgress> progress;
  final Map<String, String> errors;
  final String? error;

  const RustPluginsState({
    this.loading = true,
    this.statuses = const [],
    this.busy = const {},
    this.progress = const {},
    this.errors = const {},
    this.error,
  });

  /// 按模块名取状态（未收录 → null）。
  RustModuleStatus? statusOf(String name) {
    for (final status in statuses) {
      if (status.name == name) return status;
    }
    return null;
  }

  /// 指定模块是否正在执行操作。
  bool isBusy(String name) => busy.contains(name);

  /// 指定模块的内部下载进度（无 → null）。
  ModuleDownloadProgress? progressOf(String name) => progress[name];

  /// 指定模块的内部下载/更新错误（无 → null）。
  String? errorOf(String name) => errors[name];

  RustPluginsState copyWith({
    bool? loading,
    List<RustModuleStatus>? statuses,
    Set<String>? busy,
    Map<String, ModuleDownloadProgress>? progress,
    Map<String, String>? errors,
    String? error,
    bool clearError = false,
  }) {
    return RustPluginsState(
      loading: loading ?? this.loading,
      statuses: statuses ?? this.statuses,
      busy: busy ?? this.busy,
      progress: progress ?? this.progress,
      errors: errors ?? this.errors,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
