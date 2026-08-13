import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/cache/ReadmeCache.dart';
import 'package:gstore/core/channel/impl/GitHubChannel.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
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
  }) : apiListData = apiList ??
            ApiList(
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

  @override
  Future<ApiList> apiList(
      String user, dynamic repositories, CancelToken cancelToken) async {
    if (throwOnApiList) throw Exception('apiList 失败');
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

    String readmeJson(String content) => jsonEncode({
          'name': 'README.md',
          'content': base64Encode(utf8.encode(content)),
          'encoding': 'base64',
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

    test('首次 200 + etag → readme 文本 + 缓存写入', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(readmeJson('# Termux\n分块加载'), 200,
                headers: {'etag': '"etag1"'});
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, '# Termux\n分块加载');

      final entry = await ReadmeCache.instance.get('termux', 'termux-app');
      expect(entry, isNotNull);
      expect(entry!.etag, '"etag1"');
      expect(entry.readme, '# Termux\n分块加载');
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

    test('default_branch 为空 → 不发起 contents 请求 → success(null)', () async {
      MetadataRepository.instance.debugClient =
          MockClient((request) async => http.Response('Not Found', 404));

      final requestedUrls = <String>[];
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(
          apiList: ApiList(
            full_name: 'termux/termux-app',
            html_url: 'https://github.com/termux/termux-app',
            stargazers_count: 100,
            forks: 20,
            default_branch: null,
          ),
        ),
        httpClient: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.fetchReadme('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data, isNull);
      expect(
        requestedUrls.any((u) => u.contains('/contents/')),
        isFalse,
      );
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
}
