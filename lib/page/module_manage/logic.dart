import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/module_toggle_config.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

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

/// 原生插件（Rust）展示元数据：模块名 → 标题 + 中文说明。
///
/// **成员判定与元数据解耦**：本表只决定「名字如何展示」，**不决定插件是否出现**。
/// 成员来自清单（`RustModuleLoader.loadModuleManifest()` → 生产为
/// `ModuleManifestClient`）与本地已安装目录（`RustModuleLoader.installedModuleNames()`）
/// 的并集；未收录的名字回退为「原始模块名 + 中性占位描述」，绝不臆造也绝不崩溃。
/// 保留 `llm` 等条目：当它确实出现在清单/本地时仍可正确展示与回退。
const rustPluginMetadata = <String, ({String title, String description})>{
  'qr': (title: '二维码解码', description: 'zxing-cpp 图像解码'),
  'analyzer': (title: 'APK 分析', description: 'Manifest / DEX / ELF 解析'),
  'repo': (title: 'F-Droid 仓库', description: '仓库索引下载与解析'),
  'download': (title: '下载内核', description: 'Rust 分段/多线程下载内核'),
  'llm': (title: '本地大模型', description: 'llama.cpp / GGUF 本地推理（仅 arm64）'),
};

/// 元数据表中未收录模块的中性占位描述（绝不臆造功能）。
const String rustPluginUnknownDescription = '原生插件模块';

/// 合并「清单成员」与「本地已安装模块」生成展示用插件列表。
///
/// 顺序：清单顺序优先（清单中先出现者在前），其后为「仅本地已安装」按字典序
/// 升序；按名称去重（同时命中清单与本地只出现一次）。标题/描述查
/// [rustPluginMetadata]，未收录 → 标题回退为原始模块名、描述回退
/// [rustPluginUnknownDescription]。
///
/// 该函数为纯函数：不读文件、不发网络、不抛异常。
List<RustPluginInfo> resolveRustPlugins({
  required Iterable<String> manifestNames,
  required Iterable<String> installedNames,
}) {
  final seen = <String>{};
  final out = <RustPluginInfo>[];
  void add(String name) {
    if (name.isEmpty || !seen.add(name)) return;
    final meta = rustPluginMetadata[name];
    out.add((
      name: name,
      title: meta?.title ?? name,
      description: meta?.description ?? rustPluginUnknownDescription,
    ));
  }

  for (final name in manifestNames) {
    add(name);
  }
  final installedOnly = installedNames
      .where((name) => name.isNotEmpty && !seen.contains(name))
      .toSet()
      .toList()
    ..sort();
  for (final name in installedOnly) {
    add(name);
  }
  return out;
}

/// 原生插件状态 + 下载/更新/回退控制器。
///
/// 状态经 [RustModuleLoader.probe]（隔离感知、与解析顺序语义一致）刷新；
/// 下载/更新走 `downloadAndInstall`（后台安装，不挂载），回退走
/// `rollbackToBuiltin`（**仅在内置产物真实存在时**才删除已下载产物并挂载内置；
/// slim 无内置时为非破坏性失败），清除走 `clearDownloadedModule`。UI 绝不直接
/// dlopen。
class RustPluginsController extends Notifier<RustPluginsState> {
  /// Notifier 销毁标记：异步刷新回来时不再写已废弃 state。
  bool _disposed = false;

  @override
  RustPluginsState build() {
    ref.onDispose(() => _disposed = true);
    // 首帧返回 loading，异步读取真实状态（不阻塞页面构建）。
    Future<void>.microtask(refresh);
    return const RustPluginsState(loading: true);
  }

  RustModuleLoader get _loader => RustModuleLoader.instance;

  /// 解析展示用插件列表：清单成员优先，其后为「仅本地已安装」按字典序。
  ///
  /// 清单经 [RustModuleLoader.loadModuleManifest]（生产即 `ModuleManifestClient`，
  /// 完整保留缓存/网络/随包兜底链路）；不可用或抛异常 → 降级为「仅本地已安装」，
  /// 绝不阻断页面加载。本地枚举经 [RustModuleLoader.installedModuleNames]（绝不抛）。
  Future<List<RustPluginInfo>> _resolvePluginList() async {
    final manifestNames = <String>[];
    try {
      final manifest = await _loader.loadModuleManifest();
      if (manifest != null) manifestNames.addAll(manifest.modules.keys);
    } catch (e) {
      debugPrint('RustPluginsController: 清单不可用，降级为本地已安装 - $e');
    }
    final installed = await _loader.installedModuleNames();
    return resolveRustPlugins(
      manifestNames: manifestNames,
      installedNames: installed,
    );
  }

  /// 经加载器刷新插件成员与全部插件真实状态（远端版本可解析时一并展示）。
  ///
  /// 成员每次刷新时重算（清单可能已更新/本地安装可能变化）；列表为空时
  /// `loading` 仍归 false，页面展示空状态而非卡死。
  Future<void> refresh() async {
    final plugins = await _resolvePluginList();
    if (_disposed) return;
    final out = <RustModuleStatus>[];
    String? error;
    for (final p in plugins) {
      try {
        out.add(await _loader.probe(p.name, withRemote: true));
      } catch (e) {
        error = '$e';
        out.add(RustModuleStatus(
          name: p.name,
          exists: false,
          source: 'none',
          hasBuiltin: false,
        ));
      }
    }
    if (_disposed) return;
    state = state.copyWith(
      loading: false,
      plugins: plugins,
      statuses: out,
      error: error,
      clearError: error == null,
    );
  }

  /// 下载/更新：触发远端更新路径（后台安装，绝不挂载；下次启动生效）。
  ///
  /// 内部下载进度经 [RustModuleLoader.downloadAndInstall] 的 `onProgress`
  /// 实时回填到 [RustPluginsState.progress]；成功/失败经统一 [AppDialogs]
  /// Snackbar 提示，失败同时写入 [RustPluginsState.errors]（页面可见）。
  /// **绝不**进入用户下载管线（无下载任务、无系统通知、无安装）。
  Future<bool> download(String name) async {
    if (state.isBusy(name)) return false;
    _setBusy(name, true);
    _clearError(name);
    _setProgress(name, 0);
    var ok = false;
    String? failure;
    try {
      ok = await _loader.downloadAndInstall(
        name,
        allowBootstrap: name == RustModuleLoader.downloadModuleName,
        onProgress: (fraction, {sizeBytes}) => _setProgress(name, fraction),
      );
    } catch (e) {
      failure = '$e';
      ok = false;
    } finally {
      // 先清除进度：避免下载结束后残留进度条（stale state）。
      _clearProgress(name);
      if (ok) {
        AppDialogs.showSuccess('模块 $name 下载完成，重启应用后生效');
      } else {
        final message = failure ?? '模块 $name 下载未完成（无可更新版本或校验失败）';
        _setError(name, message);
        AppDialogs.showError(message);
      }
      await refresh();
      _setBusy(name, false);
    }
    return ok;
  }

  /// 回退到内置：删除下载产物并尝试挂载内置模块。
  ///
  /// 加载器在**无内置真实产物**（精简包 slim）时按非破坏性语义返回 `false`
  /// 且**不删除**任何文件。此处的失败**绝不静默吞掉**——经统一 [AppDialogs]
  /// 错误 Snackbar 明确告知用户，并写入页面可见错误行。
  ///
  /// **仅在回退成功时**作废自举门的缓存：回退删除了下载产物并挂载内置，回退前
  /// 缓存的实例/状态已属于旧世界，必须由 [ModuleBootstrap.invalidate] 淘汰，
  /// 否则后续 `acquire` 会命中陈旧实例、掩盖回退直到重启。加载器侧同时经
  /// [RustModuleLoader.invalidateModule] 打「代号墓碑」，让回退时仍在途的孤儿
  /// 安装于下一个写盘检查点自行中止（不强杀在途 future）。返回 `false` 时**绝不**
  /// 作废：非破坏性失败必须保持模块原样可用。
  Future<bool> rollback(String name) async {
    if (state.isBusy(name)) return false;
    _setBusy(name, true);
    _clearError(name);
    var ok = false;
    try {
      ok = await _loader.rollbackToBuiltin(name);
      if (ok) {
        _loader.invalidateModule(name);
        ModuleBootstrap.instance.invalidate(name);
      }
    } catch (e) {
      debugPrint('RustPluginsController: 模块 $name 回退失败 - $e');
      ok = false;
    } finally {
      await refresh();
      _setBusy(name, false);
    }
    if (!ok) {
      const message = '无法回退到内置版本（精简包无内置版本或内置挂载失败）';
      _setError(name, message);
      AppDialogs.showError(message);
    }
    return ok;
  }

  /// 清除已下载产物（仅 slim：无内置可回退时的显式破坏性恢复路径）。
  ///
  /// **绝不**由普通点击触发：UI 必须先经统一危险确认弹层
  /// （[AppDialogs.showConfirmSheet] `isDangerous: true`）后才调用本方法。
  /// 结果经统一 [AppDialogs] Snackbar 反馈，并刷新状态。
  Future<bool> clearDownloaded(String name) async {
    if (state.isBusy(name)) return false;
    _setBusy(name, true);
    _clearError(name);
    var ok = false;
    try {
      await _loader.clearDownloadedModule(name);
      ok = true;
    } catch (e) {
      debugPrint('RustPluginsController: 清除模块 $name 已下载产物失败 - $e');
      ok = false;
    } finally {
      await refresh();
      _setBusy(name, false);
    }
    if (ok) {
      AppDialogs.showSuccess('已清除模块 $name 的已下载文件');
    } else {
      AppDialogs.showError('清除模块 $name 的已下载文件失败');
    }
    return ok;
  }

  void _setBusy(String name, bool busy) {
    if (_disposed) return;
    final next = {...state.busy};
    if (busy) {
      next.add(name);
    } else {
      next.remove(name);
    }
    state = state.copyWith(busy: next);
  }

  /// 记录模块内部下载进度（Notifier 已销毁时忽略）。
  void _setProgress(String name, double fraction) {
    if (_disposed) return;
    state = state.copyWith(
      progress: {...state.progress, name: ModuleDownloadProgress(fraction)},
    );
  }

  /// 清除模块内部下载进度。
  void _clearProgress(String name) {
    if (_disposed) return;
    if (!state.progress.containsKey(name)) return;
    final next = {...state.progress}..remove(name);
    state = state.copyWith(progress: next);
  }

  /// 记录模块内部下载/更新错误（页面可见；绝不进系统通知）。
  void _setError(String name, String message) {
    if (_disposed) return;
    state = state.copyWith(errors: {...state.errors, name: message});
  }

  /// 清除模块内部下载/更新错误（重新操作前）。
  void _clearError(String name) {
    if (_disposed) return;
    if (!state.errors.containsKey(name)) return;
    final next = {...state.errors}..remove(name);
    state = state.copyWith(errors: next);
  }
}

/// 原生插件区域 Provider。
final rustPluginsProvider =
    NotifierProvider<RustPluginsController, RustPluginsState>(
  RustPluginsController.new,
);
