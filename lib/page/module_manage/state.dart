import 'package:get/get.dart';

/// 模块条目（模块管理页展示元数据 + 实时状态）
class ModuleEntry {
  ModuleEntry({
    required this.name,
    required this.title,
    required this.description,
    this.dependencies = const [],
    required this.togglable,
    this.note,
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
  final RxBool enabled = true.obs;
}

/// 模块管理页状态
class ModuleManageState {
  /// 模块条目列表
  final RxList<ModuleEntry> entries = <ModuleEntry>[].obs;

  /// 初始化中
  final RxBool loading = true.obs;

  /// 切换中的模块名（期间 Switch 置灰防连击）
  final RxSet<String> toggling = <String>{}.obs;
}
