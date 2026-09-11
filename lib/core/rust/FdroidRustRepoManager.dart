import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/models.dart' show AppInfo;

/// F-Droid 仓库管理器（模块化实现）
///
/// repo 域已拆为独立模块 gstore_mod_repo.so：本门面经模块路由调用
/// （ModuleLoader 内置提取 → dlopen → 信封路由），不再走宿主强类型。
class FdroidRustRepoManager {
  FdroidRustRepoManager._();

  static RustModuleInstance? _instance;

  /// 确保模块挂载 + 实例化（SQLite 库路径作为 create config）
  static Future<RustModuleInstance> _ensureInstance() async {
    if (_instance != null) return _instance!;
    final ok = await RustModuleLoader.instance.ensureModule('repo');
    if (!ok) {
      throw StateError('FdroidRustRepoManager: repo 模块不可用');
    }
    final handle = await RustModuleManager.instance.loadModule('repo');
    final dbPath = await _dbPath();
    _instance = await RustModuleInstance.create('repo', handle, config: Uint8List.fromList(utf8.encode(dbPath)));
    appLog.info('FdroidRustRepoManager: repo 模块实例化成功 (db=$dbPath)');
    return _instance!;
  }

  /// 数据库路径：优先传入，否则应用文档目录 fdroid_rust.db
  static Future<String> _dbPath() async {
    final home = Platform.environment['HOME'];
    if (home != null) {
      return path.join(home, '.gstore', 'fdroid_rust.db');
    }
    return path.join(Directory.current.path, 'fdroid_rust.db');
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
