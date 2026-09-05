import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/module_toggle_config.dart';

import 'state.dart';

/// 模块管理逻辑（Riverpod Notifier）
///
/// - build 构建模块清单（9 可开关业务模块 + 8 系统置灰模块）并订阅
///   [ModuleManager.onChange] 实时刷新各模块启用状态
/// - [toggle]：经 [ModuleToggleConfig.setEnabled] 持久化 + 运行时上下线；
///   切换中置灰防连击；因活跃依赖者被拒时 AppDialogs 提示"关闭 X 将影响 Y/Z 模块"
class ModuleManageNotifier extends Notifier<ModuleManageState> {
  /// onChange 订阅（Notifier 销毁时经 ref.onDispose 取消）
  StreamSubscription<ModuleEvent>? _changeSubscription;

  @override
  ModuleManageState build() {
    // 构建清单 + 初始化状态
    final entries = _buildEntries();
    final refreshed = _withEnabled(entries);
    final state = ModuleManageState(
      entries: refreshed,
      loading: false,
    );
    // 订阅模块上下线事件实时刷新
    _changeSubscription = ModuleManager.instance.onChange.listen((_) {
      _refreshEnabled();
    });
    ref.onDispose(() => _changeSubscription?.cancel());
    return state;
  }

  /// 切换模块开关
  ///
  /// [enabled] 目标状态；切换期间 [state.toggling] 防连击（UI 同时置灰）。
  /// 关闭被活跃依赖者拒绝时 AppDialogs 提示。
  Future<void> toggle(String name, bool enabled) async {
    final toggling = state.toggling;
    if (toggling.contains(name)) return; // 防连击
    state = state.copyWith(
      toggling: {...toggling, name},
    );
    try {
      final ok = await ModuleToggleConfig.instance.setEnabled(name, enabled);
      if (!ok && !enabled) {
        _showRejectedWarning(name);
      }
    } finally {
      final next = {...state.toggling}..remove(name);
      state = state.copyWith(toggling: next);
      _refreshEnabled();
    }
  }

  /// 构建模块清单：9 可开关业务模块 + 8 系统置灰模块
  List<ModuleEntry> _buildEntries() {
    return const [
      // ---- 可开关业务模块（9）----
      ModuleEntry(
        name: 'channel',
        title: '渠道',
        description: '多来源应用聚合（GitHub / F-Droid / vivo / 本地库）',
        dependencies: ['db'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'download',
        title: '下载',
        description: '应用下载与断点续传',
        dependencies: ['channel', 'config'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'backup',
        title: '备份',
        description: '本地与 WebDAV 数据备份恢复',
        dependencies: ['db', 'config', 'channel'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'webdav',
        title: 'WebDAV',
        description: 'WebDAV 云端备份同步',
        dependencies: ['backup', 'config'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'fdroid',
        title: 'F-Droid',
        description: 'F-Droid 仓库解析与源管理',
        dependencies: ['config', 'db'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'theme',
        title: '主题',
        description: '主题模式与动态配色',
        dependencies: ['config'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'install',
        title: '安装',
        description: '应用安装（Shizuku 静默安装）',
        togglable: true,
      ),
      ModuleEntry(
        name: 'aggregate',
        title: '我的应用',
        description: '已添加应用聚合管理',
        dependencies: ['db'],
        togglable: true,
      ),
      ModuleEntry(
        name: 'agent_tools',
        title: 'Agent 助手',
        description: 'AI 对话与内置工具',
        dependencies: ['config', 'channel'],
        togglable: true,
      ),
      // ---- 系统置灰模块（8）----
      ModuleEntry(
        name: 'log',
        title: '日志',
        description: '应用日志记录与查看',
        togglable: false,
        note: '系统模块',
      ),
      ModuleEntry(
        name: 'config',
        title: '配置',
        description: '应用配置存储',
        togglable: false,
        note: '系统模块',
      ),
      ModuleEntry(
        name: 'notification',
        title: '通知',
        description: '下载完成等系统通知',
        togglable: false,
        note: '系统模块',
      ),
      ModuleEntry(
        name: 'rhttp',
        title: '网络',
        description: '网络请求引擎',
        togglable: false,
        note: '系统模块',
      ),
      ModuleEntry(
        name: 'db',
        title: '数据库',
        description: '本地数据库（基础依赖）',
        togglable: false,
        note: '系统模块',
      ),
      ModuleEntry(
        name: 'user',
        title: '用户',
        description: '用户与凭据管理',
        togglable: false,
        note: '系统模块',
      ),
      ModuleEntry(
        name: 'update',
        title: '更新',
        description: '更新检测与管理',
        togglable: false,
        note: '待接口就绪',
      ),
      ModuleEntry(
        name: 'badge',
        title: '红点',
        description: '角标提示',
        togglable: false,
        note: '待接口就绪',
      ),
    ];
  }

  /// 从 ModuleManager 重读各模块启用状态（同步；系统模块恒启用）
  void _refreshEnabled() {
    state = state.copyWith(
      entries: _withEnabled(state.entries),
    );
  }

  /// 返回 enabled 按 ModuleManager 实时状态填充的新列表。
  List<ModuleEntry> _withEnabled(List<ModuleEntry> entries) {
    final manager = ModuleManager.instance;
    return entries
        .map((e) => e.copyWith(enabled: manager.isModuleEnabled(e.name)))
        .toList();
  }

  /// 活跃依赖者拒绝提示：关闭 [name] 将影响 Y/Z 模块
  void _showRejectedWarning(String name) {
    final dependents = _activeDependentsOf(name);
    if (dependents.isEmpty) return;
    final target = _titleOf(name);
    final affected = dependents.map(_titleOf).join('/');
    AppDialogs.showWarning('关闭 $target 将影响 $affected 模块');
  }

  /// 活跃依赖者：已初始化且声明依赖 [name] 的模块名列表
  List<String> _activeDependentsOf(String name) {
    final manager = ModuleManager.instance;
    return manager.moduleNames.where((moduleName) {
      final module = manager.getModule(moduleName);
      return module != null &&
          module.dependencies.contains(name) &&
          manager.isInitialized(moduleName);
    }).toList();
  }

  /// 模块名 → 中文名（未收录时原样返回）
  String _titleOf(String name) {
    for (final entry in state.entries) {
      if (entry.name == name) return entry.title;
    }
    return name;
  }
}

/// 模块管理页 Provider。
final moduleManageProvider =
    NotifierProvider<ModuleManageNotifier, ModuleManageState>(
  ModuleManageNotifier.new,
);
