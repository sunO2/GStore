/// 模块管理页模型与 UI 状态（Riverpod 不可变 state）。
library;

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
