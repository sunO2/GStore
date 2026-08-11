import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MetadataRepository 测试：元数据仓库读取（URL 构造 / 解析 / 缓存 / 负缓存 / TTL）
///
/// 默认代理（无配置时 getProxy() 返回 defaultProxy）会影响请求 URL 与图标 URL，
/// 断言时使用带代理前缀的完整 URL。
void main() {
  const owner = 'termux';
  const repo = 'termux-app';
  final proxy = 'https://gh-proxy.org/';

  final infoUrl =
      '${proxy}https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/'
      'metadata/$owner@$repo/info.json';
  final iconUrl =
      '${proxy}https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/'
      'metadata/$owner@$repo/icon.png';

  final metaJson = {
    'owner': owner,
    'repo': repo,
    'packageName': 'com.termux',
    'appName': 'Termux',
    'versionName': '0.119.0-beta.3',
    'versionCode': '1022',
    'icon': 'metadata/termux@termux-app/icon.png',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MetadataRepository.instance.clearCache();
  });

  group('URL 构造', () {
    test('infoUrl / iconUrl 指向仓库 metadata 目录', () {
      expect(MetadataRepository.instance.infoUrl(owner, repo),
          contains('metadata/$owner@$repo/info.json'));
      expect(MetadataRepository.instance.iconUrl(owner, repo),
          contains('metadata/$owner@$repo/icon.png'));
    });

    test('proxiedIconUrl 带默认代理前缀', () {
      expect(MetadataRepository.instance.proxiedIconUrl(owner, repo), iconUrl);
    });
  });

  group('resolveIconUrl（图标 URL 优先 info.json）', () {
    test('info.json 有 icon 字段（含指纹 query）：用它构造 URL', () async {
      MetadataRepository.instance.debugClient = MockClient((request) async {
        return http.Response(
            jsonEncode({...metaJson, 'icon': 'metadata/$owner@$repo/icon.png?r=abc12345'}),
            200);
      });

      final url = await MetadataRepository.instance.resolveIconUrl(owner, repo);
      expect(url, contains('metadata/$owner@$repo/icon.png?r=abc12345'),
          reason: '应使用 info.json 的 icon 字段（内容变化时指纹变化 → 缓存自动失效）');
      expect(url, startsWith('https://gh-proxy.org/'));
    });

    test('info.json 无 icon 字段：回退固定地址', () async {
      MetadataRepository.instance.debugClient = MockClient((request) async {
        return http.Response(jsonEncode({'owner': owner, 'repo': repo}), 200);
      });

      final url = await MetadataRepository.instance.resolveIconUrl(owner, repo);
      expect(url, iconUrl, reason: 'info 无 icon 时回退固定地址');
    });

    test('未收录（404）：回退固定地址', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final url = await MetadataRepository.instance.resolveIconUrl(owner, repo);
      expect(url, iconUrl);
    });
  });

  group('fetchInfo', () {
    test('200 返回解析后的元数据', () async {
      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        expect(request.url.toString(), infoUrl);
        return http.Response(jsonEncode(metaJson), 200);
      });

      final data = await MetadataRepository.instance.fetchInfo(owner, repo);
      expect(data, isNotNull);
      expect(data!['packageName'], 'com.termux');
      expect(data['appName'], 'Termux');
      expect(data['versionName'], '0.119.0-beta.3');
      expect(requestCount, 1);
    });

    test('404（未收录）返回 null', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      expect(await MetadataRepository.instance.fetchInfo(owner, repo), isNull);
    });

    test('网络异常返回 null 且不抛出', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => throw http.ClientException('timeout'));

      expect(await MetadataRepository.instance.fetchInfo(owner, repo), isNull);
    });

    test('网络异常不写负缓存：下次调用重试', () async {
      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          throw http.ClientException('timeout');
        }
        return http.Response(jsonEncode(metaJson), 200);
      });

      // 第一次：网络失败
      expect(await MetadataRepository.instance.fetchInfo(owner, repo), isNull);
      // 第二次：应重新请求（非负缓存命中）并成功
      final data = await MetadataRepository.instance.fetchInfo(owner, repo);
      expect(data, isNotNull);
      expect(data!['packageName'], 'com.termux');
      expect(requestCount, 2, reason: '网络异常不应写负缓存，应允许重试');
    });
  });

  group('缓存', () {
    test('内存缓存：第二次调用不再请求', () async {
      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode(metaJson), 200);
      });

      await MetadataRepository.instance.fetchInfo(owner, repo);
      final data = await MetadataRepository.instance.fetchInfo(owner, repo);

      expect(data, isNotNull);
      expect(requestCount, 1, reason: '第二次应命中内存缓存');
    });

    test('负缓存：404 后短时间内不再重复请求', () async {
      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response('Not Found', 404);
      });

      await MetadataRepository.instance.fetchInfo(owner, repo);
      await MetadataRepository.instance.fetchInfo(owner, repo);

      expect(requestCount, 1, reason: '404 负缓存应阻止重复请求');
    });

    test('负缓存 TTL 较短（15min）：过期后重新请求（应用被收录场景）', () async {
      // 预置 20 分钟前的 404 负缓存（TTL 15min）
      SharedPreferences.setMockInitialValues({
        'metadata_cache_$owner@$repo': jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(minutes: 20))
              .millisecondsSinceEpoch,
          'data': null,
        }),
      });

      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode(metaJson), 200);
      });

      final data = await MetadataRepository.instance.fetchInfo(owner, repo);
      expect(data, isNotNull,
          reason: '负缓存过期后应重新请求（应用可能已被收录）');
      expect(data!['packageName'], 'com.termux');
      expect(requestCount, 1);
    });

    test('ignoreNegativeCache：负缓存有效期内也重新请求（提交 issue 后立即查看场景）',
        () async {
      // 预置 5 分钟前的 404 负缓存（TTL 15min 内）
      SharedPreferences.setMockInitialValues({
        'metadata_cache_$owner@$repo': jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
          'data': null,
        }),
      });

      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode(metaJson), 200);
      });

      // 普通调用：命中负缓存，不发请求
      expect(await MetadataRepository.instance.fetchInfo(owner, repo), isNull);
      expect(requestCount, 0, reason: '负缓存应命中');

      // ignoreNegativeCache：绕过负缓存重新请求 → 拉到新数据
      final data = await MetadataRepository.instance.fetchInfo(
        owner,
        repo,
        ignoreNegativeCache: true,
      );
      expect(data, isNotNull);
      expect(data!['packageName'], 'com.termux');
      expect(requestCount, 1);
    });

    test('removeCache：清除指定应用的负缓存后重新请求', () async {
      SharedPreferences.setMockInitialValues({});

      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response('Not Found', 404);
      });

      // 第一次 404 → 写负缓存
      expect(await MetadataRepository.instance.fetchInfo(owner, repo), isNull);
      // 清除缓存
      await MetadataRepository.instance.removeCache(owner, repo);
      // 再次调用：应重新请求（而非命中负缓存）
      expect(await MetadataRepository.instance.fetchInfo(owner, repo), isNull);
      expect(requestCount, 2, reason: 'removeCache 后应重新请求');
    });

    test('磁盘缓存：预置 SharedPreferences 后直接命中，不请求', () async {
      SharedPreferences.setMockInitialValues({
        'metadata_cache_$owner@$repo': jsonEncode({
          'ts': DateTime.now().millisecondsSinceEpoch,
          'data': metaJson,
        }),
      });

      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode(metaJson), 200);
      });

      final data = await MetadataRepository.instance.fetchInfo(owner, repo);
      expect(data, isNotNull);
      expect(data!['packageName'], 'com.termux');
      expect(requestCount, 0, reason: '磁盘缓存应命中，无需请求');
    });

    test('磁盘缓存过期后重新请求', () async {
      // 预置 25 小时前的旧缓存（TTL 24h）
      SharedPreferences.setMockInitialValues({
        'metadata_cache_$owner@$repo': jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
          'data': metaJson,
        }),
      });

      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode(metaJson), 200);
      });

      final data = await MetadataRepository.instance.fetchInfo(owner, repo);
      expect(data, isNotNull);
      expect(requestCount, 1, reason: '过期缓存应触发重新请求');
    });

    test('clearCache 后重新请求', () async {
      var requestCount = 0;
      MetadataRepository.instance.debugClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode(metaJson), 200);
      });

      await MetadataRepository.instance.fetchInfo(owner, repo);
      await MetadataRepository.instance.clearCache();
      await MetadataRepository.instance.fetchInfo(owner, repo);

      expect(requestCount, 2);
    });
  });
}
