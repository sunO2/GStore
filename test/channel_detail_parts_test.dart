import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/cache/ReadmeCache.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/impl/GitHubChannel.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/core/channel/impl/standard_detail_channel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart' show getProxy;
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/detail/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:retrofit/retrofit.dart' show HttpResponse;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 详情页分块加载（W1）：渠道层 fetchDownloads / fetchReadme / fetchStatistics
///
/// - GitHubChannel：releases JSON 解析 / contents API + ETag 条件缓存 / apiList → Map
/// - LocalDbChannel：_githubApi.releases（失败→空）/ readme base64 解码 + DB 兜底 /
///   apiList → Map（失败→null）
class FakeGithubRestClient implements GithubRestClient {
  FakeGithubRestClient({
    this.releasesBody = '[]',
    this.readmeBody = '{}',
    ApiList? apiList,
    this.throwOnReleases = false,
    this.throwOnReadme = false,
    this.throwOnApiList = false,
    this.apiListFailuresRemaining = 0,
  }) : apiListData = apiList ??
            const ApiList(
              full_name: 'termux/termux-app',
              description: '仓库描述',
              html_url: 'https://github.com/termux/termux-app',
              stargazers_count: 100,
              forks: 20,
              default_branch: 'master',
            );

  String releasesBody;
  String readmeBody;
  ApiList apiListData;
  bool throwOnReleases;
  bool throwOnReadme;
  bool throwOnApiList;

  /// 前 N 次 apiList 调用抛异常（之后恢复成功）：
  /// 用于构造"getAppInfo 成功但 fetchReadme 内部 apiList 失败"的场景
  int apiListFailuresRemaining;

  /// apiList 调用次数（断言 fetchReadme 不再额外调 apiList：getAppInfo 内 1 次）
  int apiListCallCount = 0;

  @override
  Future<ApiList> apiList(
      String user, dynamic repositories, CancelToken cancelToken) async {
    apiListCallCount++;
    if (throwOnApiList) throw Exception('apiList 失败');
    if (apiListFailuresRemaining > 0) {
      apiListFailuresRemaining--;
      throw Exception('apiList 失败（第 N 次）');
    }
    return apiListData;
  }

  @override
  Future<String> releases(
      String user, String repositories, int page, CancelToken cancelToken) async {
    if (throwOnReleases) throw Exception('releases 失败');
    return releasesBody;
  }

  @override
  Future<String> searchRepositories(
      String query, int perPage, CancelToken cancelToken) async {
    return '{"items": []}';
  }

  @override
  Future<String> readme(
      String user, String repositories, CancelToken cancelToken) async {
    if (throwOnReadme) throw Exception('readme 失败');
    return readmeBody;
  }

  @override
  Future<UserInfo?> user() async => null;

  @override
  Future<HttpResponse> octocat() async {
    throw UnimplementedError();
  }

  @override
  Future<CreateIssueResponse> createIssue(
      String owner, String repo, Map<String, dynamic> body) async {
    throw UnimplementedError();
  }
}

/// 构造 GitHub releases API 响应体（单 release + 可选 assets）
String releasesBodyJson({
  String version = 'v1.2.3',
  List<Map<String, dynamic>> assets = const [],
}) {
  return jsonEncode([
    {
      'name': version,
      'tag_name': version,
      'published_at': '2024-01-01T00:00:00Z',
      'assets': assets,
    }
  ]);
}

Map<String, dynamic> asset({
  String name = 'app-arm64-v8a.apk',
  String? url,
  int size = 12345,
  int downloadCount = 10,
}) {
  return {
    'name': name,
    'browser_download_url':
        url ?? 'https://github.com/termux/termux-app/releases/download/v1.2.3/$name',
    'size': size,
    'download_count': downloadCount,
  };
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MetadataRepository.instance.clearCache();
  });

  group('GitHubChannel.fetchDownloads（分块下载列表）', () {
    test('releases JSON → DownloadInfo 列表（URL/name/version/size/platform）', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(
          releasesBody: releasesBodyJson(assets: [
            asset(),
            asset(
                name: 'app-universal.apk',
                url: 'https://github.com/termux/termux-app/releases/download/v1.2.3/app-universal.apk',
                size: 67890,
                downloadCount: 20),
          ]),
        ),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchDownloads('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, hasLength(2));

      final d0 = result.data![0];
      expect(
        d0.url,
        'https://github.com/termux/termux-app/releases/download/v1.2.3/app-arm64-v8a.apk',
      );
      expect(d0.name, 'app-arm64-v8a.apk');
      expect(d0.size, 12345);
      expect(d0.version, 'v1.2.3');
      expect(d0.platform, 'arm64-v8a');
      expect(d0.publishedAt, DateTime.parse('2024-01-01T00:00:00Z'));

      final d1 = result.data![1];
      expect(d1.name, 'app-universal.apk');
      expect(d1.size, 67890);
      expect(d1.platform, 'universal');
    });

    test('空 releases → 空列表（success）', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchDownloads('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, isEmpty);
    });

    test('releases API 异常 → failure（不静默空列表）', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(throwOnReleases: true),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchDownloads('termux/termux-app');
      expect(result.success, isFalse);
    });
  });

  group('GitHubChannel.fetchReadme（分块 README：contents API + ETag 缓存）', () {
    late Directory tempDir;

    String readmeJson(String content, {String? downloadUrl}) => jsonEncode({
          'name': 'README.md',
          'content': base64Encode(utf8.encode(content)),
          'encoding': 'base64',
          if (downloadUrl != null) 'download_url': downloadUrl,
        });

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('readme_cache_parts');
      ReadmeCache.instanceForTest = ReadmeCache(directory: tempDir);
    });

    tearDown(() {
      ReadmeCache.instanceForTest = ReadmeCache();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('首次 200（请求不带 ?ref=）+ download_url 提取分支 → 文本 + 图片绝对化 + 缓存写入',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final requestedUrls = <String>[];
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.path.endsWith('/contents/README.md')) {
            // 不再依赖 apiList 分支：请求不带 ref（GitHub 默认分支语义）
            expect(request.url.queryParameters.containsKey('ref'), isFalse);
            return http.Response(
              readmeJson(
                '# Termux\n![截图](images/screenshot.png)',
                downloadUrl:
                    'https://raw.githubusercontent.com/termux/termux-app/main/README.md',
              ),
              200,
              headers: {'etag': '"etag1"'},
            );
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      // 请求 URL 不含 ref=
      final readmeUrl =
          requestedUrls.singleWhere((u) => u.contains('/contents/README.md'));
      expect(readmeUrl.contains('ref='), isFalse);
      // 文本解码正确 + 相对图片绝对化到提取分支（main）
      expect(
        result.data,
        '# Termux\n![截图](https://raw.githubusercontent.com/termux/termux-app/refs/heads/main/images/screenshot.png)',
      );

      final entry = await ReadmeCache.instance.get('termux', 'termux-app');
      expect(entry, isNotNull);
      expect(entry!.etag, '"etag1"');
      expect(
        entry.readme,
        '# Termux\n![截图](https://raw.githubusercontent.com/termux/termux-app/refs/heads/main/images/screenshot.png)',
      );
    });

    test('download_url 分支非 main（master）→ 图片绝对化用提取分支（非兜底）', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(
              readmeJson(
                '![图](img/x.png)',
                downloadUrl:
                    'https://raw.githubusercontent.com/termux/termux-app/master/README.md',
              ),
              200,
              headers: {'etag': '"etagM"'},
            );
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(
        result.data,
        '![图](https://raw.githubusercontent.com/termux/termux-app/refs/heads/master/img/x.png)',
      );
    });

    test('download_url 缺失 → 图片绝对化兜底 main（正文照常显示）', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(
              readmeJson('![图](x.png)'),
              200,
              headers: {'etag': '"etag1"'},
            );
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(
        result.data,
        '![图](https://raw.githubusercontent.com/termux/termux-app/refs/heads/main/x.png)',
      );
    });

    test('二次请求带 If-None-Match → 304 → 直接用缓存值', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      const cachedReadme = '# Termux\n![图](https://raw.githubusercontent.com/termux/termux-app/refs/heads/master/a.png)';
      await ReadmeCache.instance
          .put('termux', 'termux-app', etag: '"etag1"', readme: cachedReadme);

      final requestedUrls = <String>[];
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            requestedUrls.add(request.url.toString());
            expect(request.headers['If-None-Match'], '"etag1"');
            expect(request.url.queryParameters.containsKey('ref'), isFalse);
            return http.Response('', 304);
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(requestedUrls, isNotEmpty);
      expect(result.data, cachedReadme);
    });

    test('README.md 与 README.MD 均 404 → success(null)', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('Not Found', 404)),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, isNull);
    });

    test('fetchReadme 请求 URL 不含代理前缀（直连 api.github.com，gh-proxy 不支持 contents API）',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final requestedUrls = <String>[];
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(
              readmeJson('# Termux'),
              200,
              headers: {'etag': '"etag1"'},
            );
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      final readmeUrl =
          requestedUrls.singleWhere((u) => u.contains('/contents/README.md'));
      // 直连 api.github.com：不含代理前缀（代理下 gh-proxy 返回 403）
      expect(readmeUrl.startsWith(getProxy()), isFalse);
      expect(readmeUrl.startsWith('https://api.github.com/'), isTrue);
    });

    test('403（代理拒绝/限流）+ 缓存预置 → 返回缓存文本（非 200/304 状态码缓存兜底）',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      const cachedReadme = '# 缓存 README（403 兜底）';
      await ReadmeCache.instance.put('termux', 'termux-app',
          etag: '"etag1"', readme: cachedReadme);

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('Forbidden', 403)),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, cachedReadme);
    });

    test('403 + 无缓存 → success(null)（非 200/304 且无缓存不崩溃、不整路失败）',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('Forbidden', 403)),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, isNull);
    });

    test('不再依赖 apiList.default_branch：为 null 时仍发起 contents 请求并返回 README',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final fake = FakeGithubRestClient(
        apiList: const ApiList(
          full_name: 'termux/termux-app',
          html_url: 'https://github.com/termux/termux-app',
          stargazers_count: 100,
          forks: 20,
          default_branch: null,
        ),
      );
      final requestedUrls = <String>[];
      final channel = GitHubChannel(
        githubApi: fake,
        httpClient: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(
              readmeJson(
                '# Termux',
                downloadUrl:
                    'https://raw.githubusercontent.com/termux/termux-app/main/README.md',
              ),
              200,
              headers: {'etag': '"etag1"'},
            );
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, '# Termux');
      // 仍发起了 contents 请求（不再因 default_branch 为空提前返回）
      expect(
        requestedUrls.any((u) => u.contains('/contents/README.md')),
        isTrue,
      );
      // 仅 getAppInfo 内部 1 次 apiList
      expect(fake.apiListCallCount, 1);
    });

    test('fetchReadme 不再额外调 apiList（getAppInfo 内 1 次，fetchReadme 后仍为 1）',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final fake = FakeGithubRestClient();
      final channel = GitHubChannel(
        githubApi: fake,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(
              readmeJson('# Termux'),
              200,
              headers: {'etag': '"etag1"'},
            );
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(fake.apiListCallCount, 1);
    });

    test('contents 请求失败（httpClient 抛异常）+ 有缓存 → 返回缓存文本（catch 兜底）',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      const cachedReadme = '# 离线缓存 README';
      await ReadmeCache.instance.put('termux', 'termux-app',
          etag: '"etag0"', readme: cachedReadme);

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => throw Exception('网络不可用')),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, cachedReadme);
    });

    test('contents 请求失败 + 无缓存 → success(null)（catch 兜底无缓存不整路失败）',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => throw Exception('网络不可用')),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, isNull);
    });

    test('getAppInfo 失败（apiList 抛异常）+ 有缓存 → 按 appId 拆 owner/repo 兜底返回缓存',
        () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      const cachedReadme = '# 全离线缓存 README';
      await ReadmeCache.instance.put('termux', 'termux-app',
          etag: '"etag0"', readme: cachedReadme);

      final channel = GitHubChannel(
        // getAppInfo 内 apiList 即抛异常 → 整路离线
        githubApi: FakeGithubRestClient(throwOnApiList: true),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, cachedReadme);
    });
  });

  group('GitHubChannel.fetchStatistics（分块统计）', () {
    test('apiList → Map（buildStatTags 兼容的 stargazers_count / forks_count）', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchStatistics('termux/termux-app');
      expect(result.success, isTrue);
      final map = result.data!;
      // buildStatTags 按 'stargazers_count' / 'forks_count' 读取
      expect(map['stargazers_count'], 100);
      expect(map['forks_count'], 20);
      expect(map['default_branch'], 'master');
      expect(map['html_url'], 'https://github.com/termux/termux-app');
    });

    test('apiList 异常 → failure', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(throwOnApiList: true),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchStatistics('termux/termux-app');
      expect(result.success, isFalse);
    });

    test('info.json 200 → 并入 metadata（versionName/versionCode/metadata 全量）', () async {
      MetadataRepository.instance.debugClient = MockClient((request) async {
        if (request.url.path.endsWith('/info.json')) {
          return http.Response(
            jsonEncode({
              'versionName': '2.1.0',
              'versionCode': 210,
              'packageName': 'com.termux',
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchStatistics('termux/termux-app');
      expect(result.success, isTrue);
      final map = result.data!;
      expect(map['versionName'], '2.1.0');
      expect(map['versionCode'], 210);
      expect(map['metadata'], isA<Map<String, dynamic>>());
      expect((map['metadata'] as Map)['packageName'], 'com.termux');
      // 原有统计字段保留
      expect(map['stargazers_count'], 100);
      expect(map['forks_count'], 20);
    });

    test('info.json 404（未收录）→ 无 metadata 键不报错', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.fetchStatistics('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data!.containsKey('metadata'), isFalse);
      expect(result.data!.containsKey('versionName'), isFalse);
      expect(result.data!['stargazers_count'], 100);
    });
  });

  group('LocalDbChannel（分块加载）', () {
    late AppInfoDatabase db;

    setUpAll(() {
      // Linux 系统仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      // 真内存库（':memory:' 每次 open 全新实例，无跨用例残留）。
      // 注意：floor 生成器 onCreate 建表名为 `AppInfo`，而 DAO/生产库查询 `apps`
      // （历史命名不一致；生产库为预置文件不受影响）——补建与生产库一致的 apps 表。
      // AppInfoDao 无写接口（生产由整库替换更新），故用原始 sqflite 写入
      db = await ($FloorAppInfoDatabase.inMemoryDatabaseBuilder()).build();
      // fetchStatistics 并入 metadata 会走 fetchInfo：默认未收录（404），避免真网络
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));
      await db.database.execute('''
        CREATE TABLE IF NOT EXISTS apps (
          appId TEXT NOT NULL,
          name TEXT NOT NULL,
          user TEXT NOT NULL,
          repositories TEXT NOT NULL,
          icon TEXT NOT NULL,
          des TEXT NOT NULL,
          readme TEXT,
          category TEXT,
          extra TEXT,
          PRIMARY KEY (appId)
        )
      ''');
      await db.database.insert('apps', {
        'appId': 'com.termux',
        'name': 'Termux',
        'user': 'termux',
        'repositories': 'termux-app',
        'icon': '',
        'des': 'DB 描述',
        'category': null,
        'readme': null,
      });
    });

    tearDown(() async {
      await db.close();
    });

    test('fetchDownloads：releases 解析为下载列表（失败 → 空列表）', () async {
      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(
          releasesBody: releasesBodyJson(assets: [asset()]),
        ),
      );

      final result = await channel.fetchDownloads('com.termux');
      expect(result.success, isTrue);
      expect(result.data, hasLength(1));
      expect(result.data!.single.name, 'app-arm64-v8a.apk');
      expect(result.data!.single.version, 'v1.2.3');
      expect(result.data!.single.size, 12345);
    });

    test('fetchDownloads：releases API 失败 → 空列表（success，不阻塞）', () async {
      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(throwOnReleases: true),
      );

      final result = await channel.fetchDownloads('com.termux');
      expect(result.success, isTrue);
      expect(result.data, isEmpty);
    });

    test('fetchDownloads：_githubApi 未注入 → 空列表（success）', () async {
      final channel = LocalDbChannel(database: db);

      final result = await channel.fetchDownloads('com.termux');
      expect(result.success, isTrue);
      expect(result.data, isEmpty);
    });

    test('fetchStatistics：apiList → Map（失败 → null 仍 success）', () async {
      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(),
      );

      final result = await channel.fetchStatistics('com.termux');
      expect(result.success, isTrue);
      expect(result.data!['stargazers_count'], 100);
      expect(result.data!['forks_count'], 20);
      expect(result.data!['default_branch'], 'master');
    });

    test('fetchStatistics：apiList 失败 → success(null)', () async {
      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(throwOnApiList: true),
      );

      final result = await channel.fetchStatistics('com.termux');
      expect(result.success, isTrue);
      expect(result.data, isNull);
    });

    test('fetchStatistics：info.json 200 → 并入 metadata（versionName/versionCode/metadata）',
        () async {
      MetadataRepository.instance.debugClient = MockClient((request) async {
        if (request.url.path.endsWith('/info.json')) {
          return http.Response(
            jsonEncode({'versionName': '3.0.0', 'versionCode': 300}),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(),
      );

      final result = await channel.fetchStatistics('com.termux');
      expect(result.success, isTrue);
      expect(result.data!['versionName'], '3.0.0');
      expect(result.data!['versionCode'], 300);
      expect(result.data!['metadata'], isA<Map<String, dynamic>>());
      // 原有统计字段保留
      expect(result.data!['stargazers_count'], 100);
    });

    test('fetchStatistics：_githubApi 未注入 → success(null)', () async {
      final channel = LocalDbChannel(database: db);

      final result = await channel.fetchStatistics('com.termux');
      expect(result.success, isTrue);
      expect(result.data, isNull);
    });

    test('fetchReadme：GitHub API base64 解码（优先于 DB）', () async {
      final readmeBody = jsonEncode({
        'name': 'README.md',
        'content': base64Encode(utf8.encode('# API README')),
        'encoding': 'base64',
      });
      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(readmeBody: readmeBody),
      );

      final result = await channel.fetchReadme('com.termux');
      expect(result.success, isTrue);
      expect(result.data, '# API README');
    });

    test('fetchReadme：GitHub API 失败 → DB 兜底（des）', () async {
      final channel = LocalDbChannel(
        database: db,
        githubApi: FakeGithubRestClient(throwOnReadme: true),
      );

      final result = await channel.fetchReadme('com.termux');
      expect(result.success, isTrue);
      expect(result.data, 'DB 描述');
    });

    test('fetchReadme：_githubApi 未注入 → DB 兜底（des）', () async {
      final channel = LocalDbChannel(database: db);

      final result = await channel.fetchReadme('com.termux');
      expect(result.success, isTrue);
      expect(result.data, 'DB 描述');
    });
  });

  group('StandardDetailChannel._loadDetailLegacy（两段式：base 先现 + 骨架 + 全量替换）', () {
    late DetailState state;
    late _LegacyChannelFake fakeChannel;
    late StandardDetailChannel detailChannel;

    setUpAll(() {
      // _checkInstalledState 走 InstalledApps 插件：单测环境 MissingPluginException
      // 由其内部 try/catch 容忍，不阻塞断言
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() {
      state = DetailState();
      fakeChannel = _LegacyChannelFake();
      detailChannel = StandardDetailChannel(
        appId: 'com.example.app',
        channel: fakeChannel,
        request: const AppDetailRequest(
          appId: 'com.example.app',
          name: '请求名应用',
          packageName: 'com.example.app',
          channel: ChannelType.http,
        ),
        channelCode: ChannelType.http.code,
      );
      detailChannel.bind(state, _NoopDetailCallbacks());
    });

    test('T-A) getAppDetail 未完成前 base 已注入且三区块骨架 loading 置位', () async {
      fakeChannel.detailCompleter = Completer<ChannelResult<IDetailInfo>>();

      final future = detailChannel.load();
      await pumpEventQueue();

      // 核心验收：detailInfo 非空（base 先上屏）+ 下载/README/统计骨架标志置位
      expect(fakeChannel.getAppDetailCalls, 1);
      final base = state.detailInfo.value;
      expect(base, isNotNull);
      expect(base!.name, '测试应用', reason: 'base 来自 getAppInfo 基础信息');
      expect(base.packageName, 'com.example.app',
          reason: 'getAppInfo 无包名时回退请求参数（共享 base 构造路径）');
      expect(state.downloadsLoading.value, isTrue);
      expect(state.readmeLoading.value, isTrue);
      expect(state.statisticsLoading.value, isTrue);

      // 收尾放行挂起的 getAppDetail，避免悬挂 future
      fakeChannel.detailCompleter!.complete(
        ChannelResult.success(
          data: _FakeFullDetailInfo(),
          from: ChannelType.http,
        ),
      );
      await future;
    });

    test('T-B) getAppDetail 完成 → detailInfo 全量替换 + 三标志复位', () async {
      fakeChannel.detailCompleter = Completer<ChannelResult<IDetailInfo>>();

      final future = detailChannel.load();
      await pumpEventQueue();
      expect(state.detailInfo.value, isNotNull, reason: '前置：base 先现已注入');

      final full = _FakeFullDetailInfo();
      fakeChannel.detailCompleter!.complete(
        ChannelResult.success(data: full, from: ChannelType.http),
      );
      await future;

      // 全量替换为 getAppDetail 结果（同一实例）
      expect(identical(state.detailInfo.value, full), isTrue);
      expect(state.downloadsLoading.value, isFalse);
      expect(state.readmeLoading.value, isFalse);
      expect(state.statisticsLoading.value, isFalse);
      expect(state.errorMessage.value, isEmpty);
      expect(state.isLoadingDetail.value, isFalse);
    });

    test('T-C) getAppDetail 失败 → errorMessage 设置且三标志经 finally 兜底复位', () async {
      fakeChannel.throwOnGetAppDetail = true;

      await detailChannel.load();

      // 外层 catch 生效
      expect(state.errorMessage.value, isNotEmpty);
      // 失败前已注入的 base 保留（不静默白屏）
      expect(state.detailInfo.value, isNotNull);
      // finally 兜底复位三区块 loading
      expect(state.downloadsLoading.value, isFalse);
      expect(state.readmeLoading.value, isFalse);
      expect(state.statisticsLoading.value, isFalse);
      expect(state.isLoadingDetail.value, isFalse);
    });
  });
}

/// legacy 渠道假实现（supportsProgressiveLoading=false → 走 _loadDetailLegacy 两段式）
class _LegacyChannelFake extends IChannel {
  _LegacyChannelFake();

  final ChannelType channelType = ChannelType.http;

  /// getAppDetail 挂起控制（非 null 时挂起等待测试放行，构造两段式中间态）
  Completer<ChannelResult<IDetailInfo>>? detailCompleter;

  /// getAppDetail 抛错（失败路径：外层 catch 设 errorMessage）
  bool throwOnGetAppDetail = false;

  /// getAppDetail 成功返回的完整详情（detailCompleter 为 null 时使用）
  IDetailInfo? fullDetail;

  int getAppInfoCalls = 0;
  int getAppDetailCalls = 0;

  /// getAppInfo 返回的基础信息（packageName 置空以覆盖请求参数回退分支）
  AppSummary basic = const AppSummary(
    appId: 'com.example.app',
    packageName: null,
    name: '测试应用',
    user: '',
    repositories: '',
    icon: 'https://example.com/icon.png',
    des: '基础描述',
  );

  @override
  ChannelInfo get info => ChannelInfo(
        type: channelType,
        name: channelType.code,
        description: '',
        priority: 1,
        enabled: true,
      );

  @override
  bool get supportsProgressiveLoading => false;

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async {
    getAppInfoCalls++;
    return ChannelResult.success(data: basic, from: channelType);
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    getAppDetailCalls++;
    if (throwOnGetAppDetail) {
      throw Exception('详情获取失败');
    }
    if (detailCompleter != null) {
      return detailCompleter!.future;
    }
    return ChannelResult.success(data: fullDetail!, from: channelType);
  }

  // ==================== 其余 IChannel 抽象成员最小实现 ====================

  @override
  Future<void> initialize() async {}

  @override
  bool get isInitialized => true;

  @override
  Future<bool> checkAvailable() async => true;

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: channelType);

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: channelType);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: channelType);

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async =>
      ChannelResult.success(data: true, from: channelType);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: channelType);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

/// bind 注入的 UI 回调假实现（legacy 两段式路径不触达，全部 no-op）
class _NoopDetailCallbacks extends DetailCallbacks {
  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {}

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {}

  @override
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current,
  }) async =>
      null;

  @override
  Future<void> refreshDetail({required Map<String, dynamic> detailData}) async {}

  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {}

  @override
  Future<void> updateDownloadList({
    required List<DownloadInfo> downloads,
  }) async {}

  @override
  void showSuccess(String message, {String? title}) {}

  @override
  void showError(String message, {String? title}) {}

  @override
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  }) async =>
      null;

  @override
  void startApp(String packageName) {}

  @override
  void openBrowser(String url) {}

  @override
  void openProjectBrowser() {}

  @override
  Future<void> submitAppMetadata() async {}

  @override
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  }) async =>
      null;
}

/// legacy 渠道 getAppDetail 返回的完整详情（截图/下载/更新日志/权限等区块齐备）
class _FakeFullDetailInfo extends IDetailInfo {
  @override
  String get packageName => 'com.example.full';

  @override
  String get appName => '完整详情应用';

  @override
  String get name => '完整详情应用';

  @override
  String get icon => 'https://example.com/full-icon.png';

  @override
  String get description => '完整详情描述';

  @override
  String get appId => 'com.example.app';

  @override
  String get channelId => ChannelType.http.code;

  @override
  ChannelType get channelType => ChannelType.http;

  @override
  String? get version => '2.0.0';

  @override
  String? get developer => null;

  @override
  String? get projectUrl => null;

  @override
  List<DownloadInfo> get downloads => const [];

  @override
  List<DetailSection> get sections => const [
        DetailSection.downloads,
        DetailSection.readme,
      ];

  @override
  Map<String, dynamic> get extra => const {};

  @override
  String? get readme => '# 完整 README';

  @override
  List<ScreenshotInfo>? get screenshots =>
      [ScreenshotInfo(url: 'https://example.com/s1.png')];

  @override
  String? get changelog => '更新日志';

  @override
  List<String>? get permissions => const ['INTERNET'];

  @override
  StatisticsInfo? get statistics => null;

  @override
  List<StatTag> buildStatTags() => const [];
}
