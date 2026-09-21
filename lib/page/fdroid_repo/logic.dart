/// F-Droid 仓库管理页面业务逻辑
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/page/fdroid_repo/add_source_dialog.dart';
import 'package:gstore/page/fdroid_repo/mirror_dialog.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/fdroid_repo/state.dart';

/// F-Droid 仓库管理业务逻辑（Riverpod 版）。
class FdroidRepoNotifier extends Notifier<FdroidRepoState> {
  final TextEditingController searchController = TextEditingController();

  /// F-Droid 仓库服务（注册表注入：fdroid 模块下线时为 null → 软降级）
  IFdroidRepoService? get _service =>
      ModuleManager.instance.get<IFdroidRepoService>();

  /// 具体管理器（绑定实现为 FdroidRepoManager 时可用，承载响应式源/进度状态）
  FdroidRepoManager? get _manager =>
      _service is FdroidRepoManager ? _service as FdroidRepoManager : null;

  /// 是否已执行过 [start]（防止重复初始化）
  bool _started = false;

  @override
  FdroidRepoState build() {
    final manager = _manager;
    if (manager == null) {
      // fdroid 模块未启用 → 页面降级为空状态提示
      return const FdroidRepoState(errorMessage: 'F-Droid 模块未启用');
    }
    // 订阅管理器响应式字段（源列表/加载进度/错误信息等）同步到页面状态
    manager.addListener(_syncFromManager);
    ref.onDispose(() {
      manager.removeListener(_syncFromManager);
      searchController.dispose();
    });
    return FdroidRepoState(
      sources: List.of(manager.sources),
      currentSource: manager.currentSource,
      isLoading: manager.isLoading,
      loadingProgress: manager.loadingProgress * 100,
      errorMessage: manager.errorMessage?.isNotEmpty == true
          ? manager.errorMessage
          : null,
    );
  }

  /// 页面挂载后初始化（view initState 调用，等价原 GetX onInit）。
  /// 幂等：重复调用自动跳过（模块重新启用后可再次触发初始化）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _initData();
  }

  /// 将管理器的响应式字段同步到页面状态。
  void _syncFromManager() {
    final manager = _manager;
    if (manager == null) return;
    final error = manager.errorMessage;
    state = state.copyWith(
      sources: List.of(manager.sources),
      currentSource: manager.currentSource,
      isLoading: manager.isLoading,
      loadingProgress: manager.loadingProgress * 100,
      errorMessage: error?.isNotEmpty == true ? error : null,
    );
  }

  /// 初始化数据
  Future<void> _initData() async {
    final manager = _manager;
    if (manager == null) {
      state = state.copyWith(errorMessage: 'F-Droid 模块未启用');
      return;
    }
    // 首帧后管理器字段已就绪，先同步一次
    _syncFromManager();
    try {
      // 加载统计信息
      await _loadStatistics();

      // 冷启动：把各源实际生效的资源基址备好（只读各自的本地库，不触网）
      await _prefetchAllBases();
    } catch (e) {
      state = state.copyWith(errorMessage: '初始化失败: $e');
    }
  }

  /// 加载统计信息
  Future<void> _loadStatistics() async {
    final manager = _manager;
    if (manager == null) return;
    try {
      state = state.copyWith(statistics: await manager.getStatistics());
    } catch (e) {
      appLog.error('加载统计信息失败: $e');
    }
  }

  /// 加载仓库数据
  Future<void> loadRepository() async {
    final service = _service;
    final manager = _manager;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    debugPrint('FdroidRepoNotifier: loadRepository 被调用');
    debugPrint('FdroidRepoNotifier: state.currentSource = ${state.currentSource}');
    debugPrint('FdroidRepoNotifier: _manager.currentSource = ${manager?.currentSource}');

    if (state.currentSource == null) {
      debugPrint('FdroidRepoNotifier: currentSource 为 null，尝试从 manager 同步');
      state = state.copyWith(currentSource: manager?.currentSource);
    }

    if (state.currentSource == null) {
      AppDialogs.showError('请先选择一个源');
      return;
    }

    try {
      appLog.info('FdroidRepoNotifier: 开始加载仓库: ${state.currentSource?.repoUrl}');
      await service.loadRepository();

      await _loadStatistics();
      await _prefetchAllBases();
      AppDialogs.showSuccess('仓库数据同步完成（${_syncSummaryLabel()}）');
    } catch (e) {
      appLog.error('FdroidRepoNotifier: 加载失败 - $e');
      AppDialogs.showError('加载失败: $e');
    }
  }

  /// 同步仓库数据（**真实增量**：模块在 download_repo 内部自动走
  /// entry.json + diff，必要时才回退全量——宿主侧无需"先检查再应用"两步）。
  Future<void> checkAndUpdate() async {
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    if (state.enabledSourcesCount == 0) {
      AppDialogs.showError('请先启用至少一个源');
      return;
    }
    try {
      final total = await service.loadAllEnabled();
      await _loadStatistics();
      // 各源实际生效的地址（resolved_url）与同步结果刚被回填 → 逐源展示
      await _prefetchAllBases();
      AppDialogs.showSuccess('同步完成：$total 个应用（${_syncSummaryLabel()}）');
    } catch (e) {
      appLog.error('FdroidRepoNotifier: 同步仓库失败 - $e');
      AppDialogs.showError('同步失败: $e');
    }
  }

  /// 本次同步的可读概括（**按源**统计，不再假装有一个"整体上次同步"）
  String _syncSummaryLabel() {
    final synced = state.syncedThisSessionCount;
    if (synced == 0) return '无源完成同步';
    final incremental = state.incrementalSourcesCount;
    return incremental > 0 ? '$synced 个源已同步，其中 $incremental 个走增量' : '$synced 个源已同步（全量）';
  }

  /// 添加自定义源（支持 fdroidrepos:// 深链 + 指纹确认）
  Future<void> addSource(BuildContext context) async {
    final result = await AddSourceDialog.show(context);
    if (result == null) return;

    final name = result.name;
    final url = result.url;

    try {
      // 验证 URL 格式
      final uri = Uri.parse(url);
      if (!uri.hasScheme || (!uri.scheme.startsWith('http'))) {
        AppDialogs.showError('请输入有效的 URL（以 http:// 或 https:// 开头）');
        return;
      }

      final service = _service;
      if (service == null) {
        AppDialogs.showError('F-Droid 模块未启用');
        return;
      }

      // 去重（F-Droid 的仓库身份 = 签名密钥指纹）：
      // 1) 指纹相同 → 同一个源，无论 URL/镜像怎么变
      // 2) 无指纹时退化为规范化地址比较
      final newKey = FdroidRustRepoManager.sourceIdentity(
          fingerprint: result.fingerprint, repoUrl: url);
      for (final s in state.sources) {
        final k = FdroidRustRepoManager.sourceIdentity(
            fingerprint: s.fingerprint, repoUrl: s.repoUrl);
        if (k == newKey) {
          AppDialogs.showError('该源已存在（${s.name}）：仓库身份相同，无需重复添加');
          return;
        }
      }
      // 3) 地址命中已有源的镜像 → 说明"这其实是某个源的镜像"，挂过去而不是新增一个"镜像源"
      FdroidSource? mirrorOwner;
      for (final s in state.sources) {
        if (s.mirrors.any((m) => FdroidRustRepoManager.normalizeRepoUrl(m.url) ==
            FdroidRustRepoManager.normalizeRepoUrl(url))) {
          mirrorOwner = s;
          break;
        }
      }
      if (mirrorOwner != null) {
        final ok = await AppDialogs.showConfirmDialog(
          title: '这是镜像地址',
          message: '该地址是「${mirrorOwner.name}」已配置的镜像。\n'
              '按 F-Droid 的层级，镜像应挂在源下面而不是新增一个源。\n'
              '是否把它作为该源的镜像启用？',
        );
        if (ok != true) return;
        final exists = mirrorOwner.mirrors
            .any((m) => FdroidRustRepoManager.normalizeRepoUrl(m.url) ==
                FdroidRustRepoManager.normalizeRepoUrl(url));
        if (!exists) {
          await service.updateSource(mirrorOwner.copyWith(
            mirrors: [...mirrorOwner.mirrors, FdroidMirror(url: url)],
            useMirrors: true,
          ));
        }
        AppDialogs.showSuccess('已挂到「${mirrorOwner.name}」的镜像列表');
        return;
      }

      // 创建新源
      final newSource = FdroidSource(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        repoUrl: url,
        enabled: true,
        priority: state.sources.length + 1,
        // 深链里给出的指纹随源保存，供后续验签/指纹比对使用
        fingerprint: result.fingerprint,
      );

      // 通过 F-Droid 服务添加源
      await service.addSource(newSource);

      AppDialogs.showSuccess('已添加源：$name');
    } catch (e) {
      AppDialogs.showError('添加源失败: $e');
    }
  }

  /// 编辑源（改名/改地址/改指纹）。
  /// 注意：**仓库身份变化（地址或指纹变了）会落到新的数据槽**，旧库数据不再复用。
  Future<void> editSource(BuildContext context, FdroidSource source) async {
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    final result = await AddSourceDialog.show(
      context,
      initial: AddSourceResult(
        name: source.name,
        url: source.repoUrl,
        fingerprint: source.fingerprint,
      ),
    );
    if (result == null) return;
    try {
      final updated = source.copyWith(
        name: result.name,
        repoUrl: result.url,
        fingerprint: result.fingerprint,
      );
      await service.updateSource(updated);
      final identityChanged = FdroidRustRepoManager.sourceIdentity(
            fingerprint: source.fingerprint,
            repoUrl: source.repoUrl,
          ) !=
          FdroidRustRepoManager.sourceIdentity(
            fingerprint: result.fingerprint,
            repoUrl: result.url,
          );
      AppDialogs.showSuccess(identityChanged
          ? '已更新；仓库身份已变化，下次加载将写入新的数据槽'
          : '已更新');
      state = state.copyWith(sources: _managerOrEmptySources());
    } catch (e) {
      AppDialogs.showError('更新失败: $e');
    }
  }

  /// 启用/禁用某个源（多源可同时启用）
  Future<void> setSourceEnabled(FdroidSource source, bool enabled) async {
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    try {
      await service.setSourceEnabled(source.id, enabled);
      state = state.copyWith(sources: _managerOrEmptySources());
    } catch (e) {
      AppDialogs.showError('操作失败: $e');
    }
  }

  /// 加载**全部已启用**的源（多源并存；单个源失败不影响其它源）
  Future<void> loadAllSources() async {
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    if (state.enabledSourcesCount == 0) {
      AppDialogs.showError('请先启用至少一个源');
      return;
    }
    try {
      final total = await service.loadAllEnabled();
      await _loadStatistics();
      await _prefetchAllBases();
      AppDialogs.showSuccess('已加载 ${state.enabledSourcesCount} 个源，共 $total 个应用（${_syncSummaryLabel()}）');
    } catch (e) {
      appLog.error('FdroidRepoNotifier: 多源加载失败 - $e');
      AppDialogs.showError('加载失败: $e');
    }
  }

  /// 配置源的镜像（从属配置：启用/禁用、增删、从索引导入）
  Future<void> configureMirrors(BuildContext context, FdroidSource source) async {
    final result = await MirrorConfigDialog.show(context, source);
    if (result == null) return;
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    try {
      await service.updateSource(source.copyWith(
        mirrors: result.mirrors,
        useMirrors: result.useMirrors,
      ));
      AppDialogs.showSuccess('镜像配置已保存');
    } catch (e) {
      AppDialogs.showError('保存失败: $e');
    }
  }

  /// 删除源（配置层面；已下载的索引数据留在该源自己的库里）
  Future<void> deleteSource(BuildContext context, FdroidSource source) async {
    final ok = await AppDialogs.showConfirmDialog(
      title: '删除源',
      message: '确定删除「${source.name}」？该源已下载的索引数据将不再显示。',
      isDangerous: true,
    );
    if (ok != true) return;
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    try {
      await service.removeSource(source.id);
      AppDialogs.showSuccess('已删除源：${source.name}');
    } catch (e) {
      AppDialogs.showError('删除失败: $e');
    }
  }

  /// 服务层当前的源列表（启用状态变更后同步到 UI 状态）
  List<FdroidSource> _managerOrEmptySources() => _service?.sources ?? state.sources;

  /// 搜索应用
  Future<void> searchApps(String keyword) async {
    if (keyword.trim().isEmpty) {
      _allResults = const [];
      state = state.copyWith(searchResults: const []);
      return;
    }

    final service = _service;
    if (service == null) {
      _allResults = const [];
      state = state.copyWith(searchResults: const []);
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }

    try {
      state = state.copyWith(isSearching: true);

      final results = await service.searchApps(keyword, limit: 50);
      // 将 Map 转换为 FdroidApp 对象
      final fdroidApps = results.map((map) => FdroidApp(
        packageName: map['packageName'] ?? '',
        name: map['name'] ?? '',
        summary: map['summary'] ?? '',
        icon: map['icon'] ?? '',
        license: map['license'],
        authorName: map['authorName'],
        sourceCode: map['sourceCode'],
        webSite: map['webSite'],
        categories: map['categories']?.join(',') ?? '',
        added: map['added'],
        lastUpdated: map['lastUpdated'],
        sourceId: map['sourceId'] as String?,
        versions: FdroidAppVersion.parseAll(map['versions'] as String?),
        suggestedVersionCode: _suggestedVersionCode(map['metadata'] as String?),
        appMeta: FdroidAppMeta.parse(map['metadata'] as String?),
      )).toList();
      _allResults = fdroidApps;
      await _loadDeviceSdk(); // minSdk 兼容判断需要设备 API level
      // 结果图标要按"各自所属源"的实际地址拼，先把基址备好
      await _prefetchBases(fdroidApps.map((a) => a.sourceId));
      _applyFilters(); // 由筛选统一写 state.searchResults
    } catch (e) {
      AppDialogs.showError('搜索失败: $e');
    } finally {
      state = state.copyWith(isSearching: false);
    }
  }

  /// 版本区段（沿用同一个底部弹层，不新开页面）
  ///
  /// 版本级元数据来自索引的 `versions`，包含：APK 文件名/大小/SHA-256、
  /// ABI(nativecode)、min/targetSdk、抗特性、发布通道。
  List<Widget> _versionRows(FdroidApp app) {
    final versions = app.versions;
    if (versions.isEmpty) return const [];
    final deviceAbi = _deviceAbi();
    final rows = <Widget>[
      ListTile(
        dense: true,
        leading: const Icon(Icons.history),
        title: Text('版本（${versions.length}）'),
        subtitle: Text(app.suggestedVersionCode == null
            ? '按版本号从新到旧'
            : '建议版本 ${app.suggestedVersionCode}（更高版本为测试/预览，不自动更新）'),
      ),
    ];
    for (final v in versions.take(20)) {
      final compatible = v.isCompatible(deviceAbi: deviceAbi, deviceSdk: _deviceSdkCache);
      final isSuggested = app.suggestedVersionCode != null &&
          v.versionCode == app.suggestedVersionCode;
      final parts = <String>[
        if (v.size > 0) '${(v.size / 1024 / 1024).toStringAsFixed(2)} MB',
        if (v.nativecode.isNotEmpty) v.nativecode.join('/'),
        if (v.minSdk > 0) 'minSdk ${v.minSdk}',
        if (v.releaseChannels.isNotEmpty) v.releaseChannels.join('/'),
        if (v.antiFeatures.isNotEmpty) '抗特性 ${v.antiFeatures.length}',
      ];
      rows.add(ListTile(
        dense: true,
        leading: Icon(
          compatible ? Icons.check_circle_outline : Icons.block,
          size: 18,
        ),
        title: Text('${v.versionName}（${v.versionCode}）'),
        subtitle: Text(parts.isEmpty ? v.apkName : parts.join(' · ')),
        trailing: isSuggested ? const Chip(label: Text('建议')) : null,
      ));
    }
    if (versions.length > 20) {
      rows.add(ListTile(dense: true, title: Text('…还有 ${versions.length - 20} 个版本')));
    }
    return rows;
  }

  /// 扩展区段：抗特性 + 图片（特色图/截图）——同样沿用既有弹层架构
  List<Widget> _extrasRows(FdroidApp app) {
    // 图片地址规则：**用应用所属源的 repoUrl**（镜像只服务索引/diff 下载，不参与图片）。
    // 记一条日志便于真机核对地址（图片加载失败时可直接比对）。
    final icon = _assetUrl(app, app.icon);
    appLog.info('Fdroid 详情: 图片基地址=${_assetBaseFor(app)}'
        '（源=${_sourceNameOf(app)}）icon=${icon ?? '(无)'}');
    final meta = app.appMeta;
    final rows = <Widget>[];

    // 图标（真实渲染，失败降级占位）
    if (icon != null) rows.add(_imageBlock('图标', icon, height: 96, fit: BoxFit.contain));

    final feature = _assetUrl(app, meta.featureGraphic);
    if (feature != null) rows.add(_imageBlock('特色图', feature));

    final promo = _assetUrl(app, meta.promoGraphic);
    if (promo != null) rows.add(_imageBlock('宣传图', promo));

    final shots = meta.screenshots
        .map((p) => _assetUrl(app, p))
        .whereType<String>()
        .toList();
    for (var i = 0; i < shots.length; i++) {
      rows.add(_imageBlock('截图 ${i + 1}/${shots.length}', shots[i], height: 220, fit: BoxFit.contain));
    }

    if (meta.antiFeatures.isNotEmpty) {
      rows.add(ListTile(
        dense: true,
        leading: const Icon(Icons.warning_amber_outlined),
        title: const Text('抗特性'),
        subtitle: Text(meta.antiFeatures.join(' / ')),
      ));
    }
    return rows;
  }

  /// 图片块：**真正渲染图片**（之前只显示 URL 文本 → 这就是"图片加载不出来"）
  /// 加载中/失败都有明确反馈；长按复制图片地址便于排查。
  Widget _imageBlock(String label, String url,
      {double height = 140, BoxFit fit = BoxFit.cover}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 6),
            child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          GestureDetector(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: url));
              AppDialogs.showSuccess('已复制图片地址');
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Image.network(
                url,
                height: height,
                width: double.infinity,
                fit: fit,
                loadingBuilder: (c, child, progress) => progress == null
                    ? child
                    : SizedBox(
                        height: height,
                        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                errorBuilder: (c, e, st) => Container(
                  height: height,
                  alignment: Alignment.center,
                  color: Theme.of(c).colorScheme.surfaceContainerHighest,
                  child: const Text('图片加载失败（长按可复制地址）', style: TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }


  /// 清空数据
  Future<void> clearData() async {
    final confirmed = await AppDialogs.showConfirmDialog(
      title: '确认清空',
      message: '确定要清空所有数据吗？此操作不可恢复。',
      confirmText: '确定',
      cancelText: '取消',
    );

    if (confirmed != true) return;

    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }

    try {
      await service.clearData();
      await _loadStatistics();
      AppDialogs.showSuccess('数据已清空');
    } catch (e) {
      AppDialogs.showError('清空失败: $e');
    }
  }

  /// 打开应用详情
  // ══ 筛选（本地、作用于已加载的搜索结果）══
  List<FdroidApp> _allResults = const [];
  String? _categoryFilter;
  bool _hideAntiFeature = false;
  bool _onlyCompatible = false;

  /// 结果里出现过的分类（用于筛选条）
  List<String> get availableCategories {
    final set = <String>{};
    for (final a in _allResults) {
      set.addAll(a.categories ?? const []);
    }
    final list = set.toList()..sort();
    return list;
  }

  String? get categoryFilter => _categoryFilter;
  bool get hideAntiFeature => _hideAntiFeature;
  bool get onlyCompatible => _onlyCompatible;

  void setCategoryFilter(String? category) {
    _categoryFilter = category;
    _applyFilters();
  }

  void setHideAntiFeature(bool hide) {
    _hideAntiFeature = hide;
    _applyFilters();
  }

  void setOnlyCompatible(bool only) {
    _onlyCompatible = only;
    _applyFilters();
  }

  /// 应用筛选（不重新请求索引）
  void _applyFilters() {
    final abi = _deviceAbi();
    final sdk = _deviceSdkCache;
    final filtered = _allResults.where((a) {
      if (_categoryFilter != null &&
          !(a.categories ?? const []).contains(_categoryFilter)) {
        return false;
      }
      if (_hideAntiFeature && a.appMeta.antiFeatures.isNotEmpty) return false;
      if (_onlyCompatible) {
        final vs = a.versions;
        // 没有版本信息时不误杀（保守放行）
        if (vs.isNotEmpty &&
            !vs.any((v) => v.isCompatible(deviceAbi: abi, deviceSdk: sdk))) {
          return false;
        }
      }
      return true;
    }).toList();
    state = state.copyWith(searchResults: filtered);
  }

  /// 应用所属的源（记录里的标识可能是 id / 指纹 / 旧逻辑身份键，三者都认）
  FdroidSource? _sourceOf(FdroidApp app) {
    final id = app.sourceId;
    if (id != null && id.isNotEmpty) {
      for (final s in state.sources) {
        if (FdroidRustRepoManager.identityMatches(s, id)) {
          return s;
        }
      }
    }
    return state.currentSource;
  }

  /// 资源基地址：**按应用所属源**取，源开启镜像回退时**镜像优先**
  ///
  /// 真机：国内直连 f-droid.org 会连接超时，图片/截图同样必须走镜像——
  /// "镜像只服务索引/diff、不参与图片"是不成立的，那样详情页图片一直加载不出来。
  ///
  /// 首选源**实际生效的地址**（模块 resolved_url，镜像回退后真正可用的那个）；
  /// 未知时才按镜像配置兜底（两套规则并存会让同一应用在不同界面拿到不同地址）。
  String _assetBaseFor(FdroidApp app) {
    final src = _sourceOf(app);
    if (src == null) return '(无)';
    final resolved = _service?.cachedBaseFor(src);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    if (src.useMirrors) {
      for (final m in src.mirrors) {
        if (m.enabled && m.url.isNotEmpty) return m.url;
      }
    }
    return src.repoUrl;
  }

  /// 预取这些源标识对应源的"实际生效基址"（冷启动首次为本地库读取，不触网）
  Future<void> _prefetchBases(Iterable<String?> sourceIds) async {
    final service = _service;
    if (service == null) return;
    for (final id in sourceIds.whereType<String>().where((e) => e.isNotEmpty).toSet()) {
      for (final s in state.sources) {
        if (FdroidRustRepoManager.identityMatches(s, id)) {
          await service.ensureBaseFor(s);
          break;
        }
      }
    }
  }

  /// 预取全部已配置源的基址（同步/搜索后调用一次即可覆盖所有展示面）
  Future<void> _prefetchAllBases() =>
      _prefetchBases(state.sources.map((s) => s.id));

  /// 图片相对路径 → 绝对地址（已是绝对地址则幂等透传）
  String? _assetUrl(FdroidApp app, String path) {
    if (path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = _assetBaseFor(app);
    if (base.isEmpty || base == '(无)') return null;
    // 索引里的路径通常以 `/` 开头（如 /com.x8bit.bitwarden/en-US/icon_x.png）
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }


  /// 建议版本号（索引在应用级 metadata 里声明；用于 beta 语义：稳定版 vs 更新的测试版）
  static int? _suggestedVersionCode(String? metadataJson) {
    if (metadataJson == null || metadataJson.isEmpty) return null;
    try {
      final m = jsonDecode(metadataJson);
      if (m is Map) {
        final v = m['suggestedVersionCode'] ?? m['currentVersionCode'];
        if (v is int) return v;
        if (v is String) return int.tryParse(v);
      }
    } catch (_) {}
    return null;
  }

  /// 设备 API level（缓存；用于 minSdk 兼容性判断）
  int? _deviceSdkCache;

  Future<int?> _loadDeviceSdk() async {
    if (_deviceSdkCache != null) return _deviceSdkCache;
    if (!Platform.isAndroid) return null;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _deviceSdkCache = info.version.sdkInt;
    } catch (_) {
      _deviceSdkCache = null;
    }
    return _deviceSdkCache;
  }

  /// 当前设备 ABI（用于版本兼容性判断）
  static String? _deviceAbi() {
    switch (Abi.current()) {
      case Abi.androidArm64:
        return 'arm64-v8a';
      case Abi.androidArm:
        return 'armeabi-v7a';
      case Abi.androidX64:
        return 'x86_64';
      case Abi.androidIA32:
        return 'x86';
      default:
        return null;
    }
  }

  /// 应用详情：底部弹层展示，并**标明来源源**（多源下必须知道数据来自哪个库）
  Future<void> openAppDetail(FdroidApp app) async {
    // 多源路由：按 sourceId 找到来源源，决定后续查询/安装走哪个库
    final origin = _sourceOf(app);
    appLog.info('FdroidRepoNotifier: 打开详情 ${app.packageName}（来源源=${origin?.name ?? "未知"}）');

    final rows = <Widget>[
      if (origin != null)
        ListTile(
          dense: true,
          leading: const Icon(Icons.source_outlined),
          title: const Text('来源源'),
          subtitle: Text('${origin.name} · ${origin.repoUrl}'),
        ),
      ListTile(dense: true, leading: const Icon(Icons.tag), title: const Text('包名'), subtitle: Text(app.packageName)),
      if ((app.summary).isNotEmpty)
        ListTile(dense: true, leading: const Icon(Icons.notes), title: const Text('摘要'), subtitle: Text(app.summary)),
      if ((app.license ?? '').isNotEmpty)
        ListTile(dense: true, leading: const Icon(Icons.gavel), title: const Text('许可证'), subtitle: Text(app.license!)),
      if ((app.authorName ?? '').isNotEmpty)
        ListTile(dense: true, leading: const Icon(Icons.person_outline), title: const Text('作者'), subtitle: Text(app.authorName!)),
      if ((app.sourceCode ?? '').isNotEmpty)
        ListTile(dense: true, leading: const Icon(Icons.code), title: const Text('源码'), subtitle: Text(app.sourceCode!)),
      if ((app.webSite ?? '').isNotEmpty)
        ListTile(dense: true, leading: const Icon(Icons.public), title: const Text('网站'), subtitle: Text(app.webSite!)),
      if ((app.categories ?? const []).isNotEmpty)
        ListTile(dense: true, leading: const Icon(Icons.category_outlined), title: const Text('分类'), subtitle: Text(app.categories!.join(' / '))),
      ..._versionRows(app),
      ..._extrasRows(app),
    ];

    await AppDialogs.showBottomSheet<void>(title: app.name, children: rows);
  }


  /// 应用所属源名称（多源下用于核对图片走的是哪个源）
  String _sourceNameOf(FdroidApp app) =>
      _sourceOf(app)?.name ?? state.currentSource?.name ?? '(当前源)';
}

/// F-Droid 仓库管理页 provider。
final fdroidRepoProvider =
    NotifierProvider<FdroidRepoNotifier, FdroidRepoState>(
  FdroidRepoNotifier.new,
);