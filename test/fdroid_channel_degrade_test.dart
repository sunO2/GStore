import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/FdroidChannel.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';

/// FdroidChannel 注册表注入 + 下线降级测试（todo 13）
///
/// 验证：
/// - `ModuleManager.get<IFdroidRepoService>()` 未绑定（fdroid 模块下线）时
///   searchApps / getAppDetail / checkAppUpdate 安全降级不抛：
///   searchApps/checkAppUpdate 返回 failure「F-Droid 模块未启用」，
///   getAppDetail 本地仓库短路后走网络降级返回 failure
/// - 服务已绑定（bind 假实现）时功能路径正常：搜索返回成功结果、
///   本地 Rust 数据解析详情/检查更新成功（不触网）
class _FakeFdroidRepoService implements IFdroidRepoService {
  int searchCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> searchApps(
    String keyword, {
    int limit = 50,
  }) async {
    searchCalls++;
    return [
      {
        'packageName': 'com.example.app',
        'name': 'Example App',
        'summary': '示例应用',
        'icon': 'https://example.com/icon.png',
        'authorName': 'Author',
        'categories': ['Games'],
      },
    ];
  }

  @override
  Future<Map<String, dynamic>?> getAppByPackageName(String packageName) async {
    return {
      'packageName': packageName,
      'name': 'Example App',
      'summary': '示例应用',
      'license': 'MIT',
      'authorName': 'Author',
      'categories': ['Games'],
      'icon': 'com.example.app.png',
      'metadata':
          '{"screenshots": {}, "description": {"en-US": "详细描述"}, '
              '"name": {"en-US": "Example App"}, "summary": {"en-US": "示例应用"}}',
      'versions':
          '{"v1": {"added": 1700000000, "file": {"name": "app-v1.apk", '
              '"size": 1024, "sha256": "abc"}, '
              '"manifest": {"versionName": "1.0", "versionCode": 1}}}',
    };
  }

  @override
  Future<void> loadRepository({bool forceRefresh = false}) async {}

  @override
  Future<List<Map<String, dynamic>>> getAllApps() async => [];

  @override
  Future<int> getAppCount() async => 0;

  @override
  Future<Map<String, int>> getStatistics() async => {'apps': 0};

  @override
  Future<void> switchSource(String sourceId) async {}

  @override
  Future<void> addSource(FdroidSource source) async {}

  @override
  Future<void> removeSource(String sourceId) async {}

  @override
  Future<void> clearData() async {}
}

/// 立即返回 500 的假 HTTP 适配器（避免测试发出真实网络请求）
class _FakeHttpClientAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{}',
      500,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
  });

  FdroidChannel buildChannel() {
    final dio = Dio()..httpClientAdapter = _FakeHttpClientAdapter();
    return FdroidChannel(dio: dio);
  }

  group('FdroidChannel 服务未绑定（get<IFdroidRepoService>() null）→ 安全降级', () {
    test('searchApps：返回 failure「F-Droid 模块未启用」，不抛异常', () async {
      final channel = buildChannel();
      final result = await channel.searchApps('termux');
      expect(result.success, isFalse);
      expect(result.error, contains('未启用'));
    });

    test('checkAppUpdate：返回 failure「F-Droid 模块未启用」，不抛异常', () async {
      final channel = buildChannel();
      final result = await channel.checkAppUpdate('com.termux');
      expect(result.success, isFalse);
      expect(result.error, contains('未启用'));
    });

    test('getAppDetail：本地仓库短路后走网络降级，返回 failure 不抛', () async {
      final channel = buildChannel();
      final result = await channel.getAppDetail('com.termux');
      expect(result.success, isFalse);
    });
  });

  group('FdroidChannel 服务已绑定（假实现）→ 功能路径正常', () {
    test('searchApps：走注册表服务搜索并返回成功结果', () async {
      final fake = _FakeFdroidRepoService();
      ModuleManager.instance.bind<IFdroidRepoService>(fake);

      final channel = buildChannel();
      final result = await channel.searchApps('example');
      expect(result.success, isTrue);
      expect(result.data, isNotNull);
      expect(result.data!.single.appId, 'com.example.app');
      expect(fake.searchCalls, 1);
    });

    test('getAppDetail：本地 Rust 数据解析详情成功，不触网', () async {
      ModuleManager.instance.bind<IFdroidRepoService>(_FakeFdroidRepoService());

      final channel = buildChannel();
      final result = await channel.getAppDetail('com.example.app');
      expect(result.success, isTrue);
      expect(result.data, isNotNull);
      expect(result.data!.packageName, 'com.example.app');
    });

    test("getAppDetail：extra['readme'] 非空且与 description 同源", () async {
      ModuleManager.instance.bind<IFdroidRepoService>(_FakeFdroidRepoService());

      final channel = buildChannel();
      final result = await channel.getAppDetail('com.example.app');
      expect(result.success, isTrue);
      final data = result.data!;
      // extra['readme'] 必须存在且与 description 同源（metadata.en-US 描述）
      expect(data.extra['readme'], isNotNull);
      expect(data.extra['readme'], isNotEmpty);
      expect(data.extra['readme'], data.description);
    });

    test('checkAppUpdate：本地索引检查更新成功', () async {
      ModuleManager.instance.bind<IFdroidRepoService>(_FakeFdroidRepoService());

      final channel = buildChannel();
      final result = await channel.checkAppUpdate('com.example.app');
      expect(result.success, isTrue);
      expect(result.data, isNotNull);
      expect(result.data!.packageName, 'com.example.app');
      expect(result.data!.name, 'Example App');
    });
  });
}
