import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/RustTask.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/models.dart' show AppInfo;

/// F-Droid 仓库管理器（模块化实现）
///
/// repo 域已拆为独立模块 gstore_mod_repo.so：本门面经模块路由调用
/// （ModuleLoader 内置提取 → dlopen → 信封路由），不再走宿主强类型。
class FdroidRustRepoManager {
  FdroidRustRepoManager._();

  /// 当前活动源的稳定身份键（决定数据落在哪个库）
  static String? _activeSourceKey;

  /// 当前活动源对象：[_ensureInstance] 由它**实时**解析身份。
  ///
  /// WHY：此前用 `_activeSourceKey ?? 'url:default'` 兜底，而任何真实源的
  /// 身份键都不可能是 `url:default`（源地址/指纹都归一化过）→ 未设置活动源时
  /// 会读写一个搜索永远读不到的幽灵库（"插件加载成功却搜不到"的根因）。
  /// 用源对象解析身份后，读取与下载必然落在同一个数据槽。
  static FdroidSource? _activeSource;

  /// 测试专用：替换实例工厂以绕过 FFI/平台通道（生产为 `null`）。
  ///
  /// 实例缓存与单飞全部由 [ModuleBootstrap] 门按
  /// `repo#<身份键>` 维度持有，本类不再自建缓存。
  @visibleForTesting
  static ModuleInstanceFactory? debugInstanceFactory;

  /// 测试专用：替换长任务启动器，绕过 FFI 的 [RustTasks.start]（生产为 `null`）。
  ///
  /// WHY：`RustTasks` 只有 `debugResetBridge`（仅置 `_bridge = null`，随后仍经
  /// FFI `TaskBridge.newInstance()` 重建），没有任何可注入的工厂。测试需要断言
  /// "空库触发一次下载 / 空库不重复下载" 时，必须在**任务启动**这一层拦截。
  /// 默认 `null` → 生产路径逐字节不变。
  @visibleForTesting
  static Future<RustTask> Function(FdroidSource source)? debugTaskStarter;

  /// 源的**逻辑**身份键：优先指纹（仓库身份就是签名密钥），否则用归一化地址。
  ///
  /// ⚠️ 仅用于「同源判定 / 跨地址去重」等**语义**场景（例如 `addSource`/`editSource`
  /// 判断新源是否与已有源是同一个仓库）。**绝不能**把它当作存储槽位键：
  /// 指纹在**首次下载过程中**才会学到（见 `_syncSignerFingerprint`），若用指纹
  /// 决定库文件，首次加载会在中途从 `url:…` 翻到 `fp:…`，导致「首次跑两遍下载、
  /// 列表空到下拉刷新」的线上事故。存储槽位请用 [storageIdentity]。
  @visibleForTesting
  static String sourceIdentity({String? fingerprint, required String repoUrl}) {
    final fp = (fingerprint ?? '').replaceAll(':', '').trim().toUpperCase();
    if (fp.isNotEmpty) return 'fp:$fp';
    return 'url:${normalizeRepoUrl(repoUrl)}';
  }

  /// 决定**实例键与库槽位**的稳定身份：源一生恒定。
  ///
  /// 绝不使用下载后才知道的指纹（否则槽位会在首次加载中途翻转）。`FdroidSource.id`
  /// 非空（如 `official` / `custom_<ms>`），不会与默认实例键 `''` 冲突。
  static String storageIdentity(FdroidSource source) => source.id;

  /// 归一化地址：去尾斜杠 + scheme/host 小写（仅用于身份比较）
  @visibleForTesting
  static String normalizeRepoUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    final m = RegExp(r'^([a-zA-Z]+)://([^/]+)').firstMatch(u);
    if (m != null) {
      u = '${m.group(1)!.toLowerCase()}://${m.group(2)!.toLowerCase()}${u.substring(m.end)}';
    }
    return u;
  }

  /// [stored] 这个已持久化的源标识是否指向 [source]（读取侧向后兼容匹配）。
  ///
  /// 迁移目的：历史版本把 [sourceIdentity]（逻辑身份，指纹优先）写进了
  /// `ChannelAddedApp.sourceId`。现在存储身份改为 [storageIdentity]（源 id），
  /// 读取时必须同时认得两者，否则老记录会匹配不到任何源。
  ///
  /// 接受（标识符内冒号不敏感、指纹大小写不敏感）：
  /// - 原始 `source.id`；
  /// - 原始指纹（`AB:CD` 或 `ABCD`）；
  /// - 旧逻辑身份的 `fp:<HEX>` 形式；
  /// - 旧逻辑身份的 `url:<归一化地址>` 形式，以及裸的归一化地址。
  ///
  /// [stored] 为 null / 空白 / 无关值一律返回 false。
  @visibleForTesting
  static bool identityMatches(FdroidSource source, String? stored) {
    if (stored == null) return false;
    final s = stored.trim();
    if (s.isEmpty) return false;

    // 1) 现用存储身份：源 id
    if (s == source.id) return true;

    final fp = (source.fingerprint ?? '').replaceAll(':', '').trim().toUpperCase();

    // 2) 原始指纹（允许带/不带冒号、大小写不敏感）
    if (fp.isNotEmpty && s.replaceAll(':', '').trim().toUpperCase() == fp) {
      return true;
    }

    // 3) 旧逻辑身份的 fp:<HEX>
    if (s.length > 3 && s.substring(0, 3).toLowerCase() == 'fp:') {
      final hex = s.substring(3).replaceAll(':', '').trim().toUpperCase();
      return fp.isNotEmpty && hex == fp;
    }

    // 4) 旧逻辑身份的 url:<归一化地址>，或裸的归一化地址
    final storedUrl = (s.length > 4 && s.substring(0, 4).toLowerCase() == 'url:')
        ? s.substring(4)
        : s;
    if (storedUrl.startsWith('http://') || storedUrl.startsWith('https://')) {
      return normalizeRepoUrl(storedUrl).toLowerCase() ==
          normalizeRepoUrl(source.repoUrl).toLowerCase();
    }

    return false;
  }

  /// 两个源配置是否属于**同一个逻辑仓库**（指纹优先 / 归一化地址）。
  ///
  /// 供 `FdroidRepoManager.updateSource` 判定"仓库身份是否变化"：只有逻辑身份
  /// 变了才需要清空该源的库槽。身份规则只在本库内实现，调用方无需接触
  /// [sourceIdentity]（避免生产路径直接引用测试专用成员）。
  static bool sameLogicalIdentity({
    String? oldFingerprint,
    required String oldRepoUrl,
    String? newFingerprint,
    required String newRepoUrl,
  }) =>
      sourceIdentity(fingerprint: oldFingerprint, repoUrl: oldRepoUrl) ==
      sourceIdentity(fingerprint: newFingerprint, repoUrl: newRepoUrl);

  /// 每个源一个库文件：apps / repo_meta 等表**不再跨源串数据**
  @visibleForTesting
  static String dbPathForIdentity(String identity, String docsPath) {
    final hash = sha1.convert(utf8.encode(identity)).toString().substring(0, 16);
    return path.join(docsPath, 'fdroid_$hash.db');
  }

  /// 切换活动源（由 FdroidRepoManager 在选中源变化时调用）
  static void setActiveSource(FdroidSource? source) {
    // 即便身份键未变也刷新引用：`updateSource` 会换入新的源配置，
    // `_ensureInstance` 需要拿到最新引用解析身份。
    _activeSource = source;
    final key = source == null ? null : storageIdentity(source);
    if (key == _activeSourceKey) return;
    _activeSourceKey = key;
    appLog.info(
        'FdroidRustRepoManager: 活动源切换 → ${source?.name ?? '(无)'} (key=${key ?? 'default'})');
  }

  /// 确保模块挂载 + 实例化（当前活动源对应的库作为 create config）
  ///
  /// 身份**必须**由 [_activeSource] 解析，绝不使用任何地址兜底：没有活动源
  /// 说明调用方没配对（读/写都会落错库），直接抛错暴露问题。
  static Future<RustModuleInstance> _ensureInstance() {
    final source = _activeSource;
    if (source == null) {
      throw StateError('FdroidRustRepoManager: 未设置活动源');
    }
    return _instanceFor(
      storageIdentity(source),
    );
  }

  /// 指定源身份的实例（多源：**每个源一个库 + 一个实例**，"源"维度即库文件）
  static Future<RustModuleInstance> instanceForSource(FdroidSource source) => _instanceFor(
        storageIdentity(source),
      );

  /// 获取（必要时安装并创建）指定源身份的实例。
  ///
  /// 安装确保/实例创建/缓存/单飞全部委托 [ModuleBootstrap] 门：`repo` 只确保
  /// **一次**（按模块去重），而每个身份键各自创建一个实例（按 `instanceKey`
  /// 去重）——因此「两个源 = 两个实例 + 一次 ensure」。
  static Future<RustModuleInstance> _instanceFor(String key) async {
    final factory = debugInstanceFactory ??
        (ModuleHandle handle) async {
          // 数据库路径按**存储身份**（`storageIdentity(source)` == 源 id）派生；
          // 身份→文件的映射完全在 Dart 侧（`dbPathForIdentity`），Rust 只打开给定路径。
          // 用应用文档目录（不能用 Platform.environment['HOME']，
          // 否则可能得到 /.gstore/... 这类不可写路径导致 create 失败 code=-7）
          final docs = await getApplicationDocumentsDirectory();
          final dbPath = dbPathForIdentity(key, docs.path);
          return RustModuleInstance.createWithContext('repo', handle,
              dbPath: dbPath);
        };
    try {
      final inst = await ModuleBootstrap.instance.acquire(
        'repo',
        instanceKey: key,
        factory: factory,
      );
      appLog.info('FdroidRustRepoManager: repo 实例就绪 (key=$key)');
      return inst;
    } on ModuleInstallFailedException {
      throw StateError('FdroidRustRepoManager: repo 模块不可用');
    }
  }

  /// 初始化（幂等；保留兼容签名——实际挂载在首次调用时发生）
  ///
  /// 启动路径禁止下载：精简包无内置 `repo` 产物时，模块在首次真实使用
  /// （[instanceForSource]/[downloadRepositoryTaskFor]）时才按需安装，避免首帧卡黑。
  static Future<void> initialize({String? dbPath}) async {
    await RustModuleManager.instance.ensureReady();
    // prepareExisting 只挂载已有本地/内置产物，**绝不触发远程下载**。
    await ModuleBootstrap.instance.prepareExisting('repo');
    appLog.info('FdroidRustRepoManager: bridge 就绪（repo 模块按需安装）');
  }

  /// 下载**指定源**（Task 版）：镜像与开关都取自该源自己的配置，
  /// 数据落在该源自己的库里（多源互不覆盖）。
  static Future<RustTask> downloadRepositoryTaskFor(FdroidSource source) async {
    final starter = debugTaskStarter;
    if (starter != null) return starter(source);
    final inst = await instanceForSource(source);
    final enabledMirrors = [
      for (final m in source.mirrors)
        if (m.enabled) m.url,
    ];
    final spec = jsonEncode({
      'url': source.repoUrl,
      if (source.useMirrors && enabledMirrors.isNotEmpty) 'mirrors': enabledMirrors,
      'mirror_first': source.useMirrors && enabledMirrors.isNotEmpty,
    });
    final numericId = int.tryParse(await inst.instanceId);
    return RustTasks.start(
      module: 'repo',
      instance: numericId,
      method: 'download_repo',
      payload: Uint8List.fromList(utf8.encode(spec)),
    );
  }

  /// 在**指定源**内搜索
  static Future<List<AppInfo>> searchAppsIn(FdroidSource source, String keyword, {int limit = 50}) async {
    final inst = await instanceForSource(source);
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(keyword))
      ..addByte(0)
      ..add(_i32le(limit));
    final resp = await inst.callModule('search_apps', payload.takeBytes());
    final list = jsonDecode(utf8.decode(resp)) as List<dynamic>;
    return list.map((e) => _appInfoFromJson(e as Map<String, dynamic>)).toList();
  }

  /// **指定源**的应用总数
  static Future<int> appCountIn(FdroidSource source) async {
    final inst = await instanceForSource(source);
    final resp = await inst.callModule('get_app_count');
    final json = jsonDecode(utf8.decode(resp)) as Map<String, dynamic>;
    return json['count'] as int? ?? 0;
  }

  /// 仓库元信息：索引 `repo` 头部（名称/描述/图标/时间戳）+ 镜像列表 + 完整性校验结果。
  ///
  /// 用于「按索引自动回填仓库名称」「展示声明的镜像数」「展示是否通过 SHA-256 校验」。
  static Future<Map<String, dynamic>?> getRepoMeta() async {
    try {
      final inst = await _ensureInstance();
      final bytes = await inst.callModule('get_repo_meta');
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 读取仓库元信息失败 - $e');
      return null;
    }
  }

  /// **指定源**的仓库元信息（含下载时实际生效的 `resolved_url`）。
  ///
  /// 与 [getRepoMeta] 是同一个模块方法，区别只是走**该源自己的实例/库**——
  /// 资源基址必须与索引走同一个可达地址，不能由宿主另猜一套（见 FdroidChannel._assetBaseFor）。
  static Future<Map<String, dynamic>?> getRepoMetaIn(FdroidSource source) async {
    try {
      final inst = await instanceForSource(source);
      final bytes = await inst.callModule('get_repo_meta');
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 读取源「${source.name}」元信息失败 - $e');
      return null;
    }
  }

  /// 获取应用数量
  static Future<int> getAppCount() async {
    final inst = await _ensureInstance();
    final resp = await inst.callModule('get_app_count');
    final json = jsonDecode(utf8.decode(resp)) as Map<String, dynamic>;
    return json['count'] as int? ?? 0;
  }

  /// 清空所有应用数据
  static Future<int> clearApps() async {
    final inst = await _ensureInstance();
    final resp = await inst.callModule('clear_apps');
    final json = jsonDecode(utf8.decode(resp)) as Map<String, dynamic>;
    final n = json['count'] as int? ?? 0;
    appLog.info('FdroidRustRepoManager: 已清空 $n 个应用');
    return n;
  }

  /// 获取一个应用（用于调试）
  static Future<AppInfo?> getOneApp() async {
    final inst = await _ensureInstance();
    final resp = await inst.callModule('get_one_app');
    final text = utf8.decode(resp, allowMalformed: true);
    if (text == 'null') return null;
    final json = jsonDecode(text) as Map<String, dynamic>;
    return _appInfoFromJson(json);
  }

  /// JSON → FRB 生成 AppInfo（字段与 Rust serde 序列化对齐）
  static AppInfo _appInfoFromJson(Map<String, dynamic> json) {
    return AppInfo(
      packageName: json['package_name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      license: json['license'] as String?,
      authorName: json['author_name'] as String?,
      sourceCode: json['source_code'] as String?,
      webSite: json['web_site'] as String?,
      categories: (json['categories'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      added: (json['added'] as num?)?.toInt(),
      lastUpdated: (json['last_updated'] as num?)?.toInt(),
      metadata: json['metadata'] as String?,
      versions: json['versions'] as String?,
    );
  }

  static Uint8List _i32le(int v) {
    final b = ByteData(4)..setInt32(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  /// 转换 Rust 模型到 Dart 模型（Map）——兼容旧调用方（FdroidRepoManager 服务层）
  static Map<String, dynamic> appInfoToMap(AppInfo rustApp) {
    return {
      'packageName': rustApp.packageName,
      'name': rustApp.name,
      'summary': rustApp.summary,
      'icon': rustApp.icon,
      'license': rustApp.license,
      'authorName': rustApp.authorName,
      'sourceCode': rustApp.sourceCode,
      'webSite': rustApp.webSite,
      'categories': rustApp.categories,
      'added': rustApp.added,
      'lastUpdated': rustApp.lastUpdated,
      'metadata': rustApp.metadata,
      'versions': rustApp.versions,
    };
  }
}
