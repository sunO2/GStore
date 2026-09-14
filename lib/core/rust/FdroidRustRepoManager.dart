import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/RustTask.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/models.dart' show AppInfo;

/// F-Droid 仓库管理器（模块化实现）
///
/// repo 域已拆为独立模块 gstore_mod_repo.so：本门面经模块路由调用
/// （ModuleLoader 内置提取 → dlopen → 信封路由），不再走宿主强类型。
class FdroidRustRepoManager {
  FdroidRustRepoManager._();

  /// 当前活动源的稳定身份键（决定数据落在哪个库）
  static String? _activeSourceKey;

  /// 身份键 → 实例（切回旧源无需重建；各源数据天然隔离）
  static final Map<String, RustModuleInstance> _instances = {};

  /// 源的稳定身份键：**优先指纹**（仓库身份就是签名密钥），否则用归一化地址。
  ///
  /// 这样换域名/换镜像**不会**换数据槽；改地址或换指纹才会落到新槽。
  @visibleForTesting
  static String sourceIdentity({String? fingerprint, required String repoUrl}) {
    final fp = (fingerprint ?? '').replaceAll(':', '').trim().toUpperCase();
    if (fp.isNotEmpty) return 'fp:$fp';
    return 'url:${normalizeRepoUrl(repoUrl)}';
  }

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

  /// 每个源一个库文件：apps / repo_meta 等表**不再跨源串数据**
  @visibleForTesting
  static String dbPathForIdentity(String identity, String docsPath) {
    final hash = sha1.convert(utf8.encode(identity)).toString().substring(0, 16);
    return path.join(docsPath, 'fdroid_$hash.db');
  }

  /// 切换活动源（由 FdroidRepoManager 在选中源变化时调用）
  static void setActiveSource(FdroidSource? source) {
    final key = source == null
        ? null
        : sourceIdentity(fingerprint: source.fingerprint, repoUrl: source.repoUrl);
    if (key == _activeSourceKey) return;
    _activeSourceKey = key;
    appLog.info(
        'FdroidRustRepoManager: 活动源切换 → ${source?.name ?? '(无)'} (key=${key ?? 'default'})');
  }

  /// 确保模块挂载 + 实例化（当前活动源对应的库作为 create config）
  static Future<RustModuleInstance> _ensureInstance() =>
      _instanceFor(_activeSourceKey ?? 'url:default');

  /// 指定源身份的实例（多源：**每个源一个库 + 一个实例**，"源"维度即库文件）
  static Future<RustModuleInstance> instanceForSource(FdroidSource source) => _instanceFor(
        sourceIdentity(fingerprint: source.fingerprint, repoUrl: source.repoUrl),
      );

  static Future<RustModuleInstance> _instanceFor(String key) async {
    final cached = _instances[key];
    if (cached != null) return cached;
    final ok = await RustModuleLoader.instance.ensureModule('repo');
    if (!ok) {
      throw StateError('FdroidRustRepoManager: repo 模块不可用');
    }
    final handle = await RustModuleManager.instance.loadModule('repo');
    // 数据库路径按源身份派生（应用文档目录；不能用 Platform.environment['HOME']，
    // 否则可能得到 /.gstore/... 这类不可写路径导致 create 失败 code=-7）
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = dbPathForIdentity(key, docs.path);
    final inst = await RustModuleInstance.createWithContext('repo', handle, dbPath: dbPath);
    _instances[key] = inst;
    appLog.info('FdroidRustRepoManager: repo 实例就绪 (key=$key, db=$dbPath)');
    return inst;
  }

  /// 初始化（幂等；保留兼容签名——实际挂载在首次调用时发生）
  static Future<void> initialize({String? dbPath}) async {
    await RustModuleManager.instance.ensureReady();
    await RustModuleLoader.instance.ensureModule('repo');
    appLog.info('FdroidRustRepoManager: bridge + repo 模块就绪');
  }

  /// 下载并解析仓库（Rust 模块 async block_on，返回应用数）
  static Future<int> downloadRepository({required String repoUrl}) async {
    final inst = await _ensureInstance();
    final resp = await inst.callModule('download_repo', Uint8List.fromList(utf8.encode(repoUrl)));
    final json = jsonDecode(utf8.decode(resp)) as Map<String, dynamic>;
    final total = json['total_apps'] as int? ?? 0;
    appLog.info('FdroidRustRepoManager: 下载完成 - $total 个应用');
    return total;
  }

  /// 下载并解析仓库（**Task 版**）：立即返回句柄，进度经 [RustTask.progress] 上报。
  ///
  /// 与 [downloadRepository] 走同一模块方法与信封路由，区别只是**不再阻塞调用线程**、
  /// 并且阶段进度可见（`downloading` → `stored`）。
  static Future<RustTask> downloadRepositoryTask({
    required String repoUrl,
    List<String> mirrors = const [],
    bool mirrorFirst = false,
  }) async {
    final inst = await _ensureInstance();
    // payload：源地址 + 该源**已启用**的镜像 + 是否优先走镜像。
    // 模块侧兼容裸 URL（历史格式），见 DownloadSpec::parse。
    final spec = jsonEncode({
      'url': repoUrl,
      if (mirrors.isNotEmpty) 'mirrors': mirrors,
      'mirror_first': mirrorFirst,
    });
    // 信封 instance 字段的字符串形式即数字 id（宿主 instance_id().to_string()）
    final numericId = int.tryParse(await inst.instanceId);
    return RustTasks.start(
      module: 'repo',
      instance: numericId,
      method: 'download_repo',
      payload: Uint8List.fromList(utf8.encode(spec)),
    );
  }

  /// 下载**指定源**（Task 版）：镜像与开关都取自该源自己的配置，
  /// 数据落在该源自己的库里（多源互不覆盖）。
  static Future<RustTask> downloadRepositoryTaskFor(FdroidSource source) async {
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

  /// 获取应用数量
  static Future<int> getAppCount() async {
    final inst = await _ensureInstance();
    final resp = await inst.callModule('get_app_count');
    final json = jsonDecode(utf8.decode(resp)) as Map<String, dynamic>;
    return json['count'] as int? ?? 0;
  }

  /// 搜索应用
  static Future<List<AppInfo>> searchApps(String keyword, {int limit = 50}) async {
    final inst = await _ensureInstance();
    // payload: keyword UTF-8 + NUL + limit(i32 LE)
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(keyword))
      ..addByte(0)
      ..add(_i32le(limit));
    final resp = await inst.callModule('search_apps', payload.takeBytes());
    final list = jsonDecode(utf8.decode(resp)) as List<dynamic>;
    return list.map((e) => _appInfoFromJson(e as Map<String, dynamic>)).toList();
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
