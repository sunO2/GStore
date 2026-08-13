import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/cache/ReadmeCache.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/impl/GitHubChannel.dart';
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:retrofit/retrofit.dart' show HttpResponse;
import 'package:shared_preferences/shared_preferences.dart';

/// GitHubChannel metadata 覆盖测试
///
/// 验证 getAppInfo / getAppDetail 的"优先读取仓库元数据"策略：
/// - metadata 已收录 → 图标 / 应用名 / 包名 / 版本用真实数据
/// - metadata 未收录 → 回退 GitHub API 数据（占位）
class FakeGithubRestClient implements GithubRestClient {
  @override
  Future<ApiList> apiList(
      String user, dynamic repositories, CancelToken cancelToken) async {
    return ApiList(
      full_name: '$user/$repositories',
      description: '仓库描述',
      html_url: 'https://github.com/$user/$repositories',
      stargazers_count: 100,
      forks: 20,
      default_branch: 'master',
    );
  }

  @override
  Future<String> releases(
      String user, String repositories, int page, CancelToken cancelToken) async {
    // 空 releases：避免详情页构建下载列表的复杂性
    return '[]';
  }

  @override
  Future<String> searchRepositories(
      String query, int perPage, CancelToken cancelToken) async {
    return '{"items": []}';
  }

  @override
  Future<String> readme(
      String user, String repositories, CancelToken cancelToken) async {
    return '{}';
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

void main() {
  const metaJson = {
    'owner': 'termux',
    'repo': 'termux-app',
    'packageName': 'com.termux',
    'appName': 'Termux',
    'versionName': '0.119.0-beta.3',
    'versionCode': '1022',
    'icon': 'metadata/termux@termux-app/icon.png',
  };

  final proxy = 'https://gh-proxy.org/';
  final metadataIconUrl =
      '${proxy}https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/'
      'metadata/termux@termux-app/icon.png';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MetadataRepository.instance.clearCache();
  });

  group('getAppInfo（API 分支）', () {
    test('metadata 已收录：覆盖图标 / 应用名 / 包名', () async {
      MetadataRepository.instance.debugClient = MockClient((request) async {
        if (request.url.path.contains('info.json')) {
          return http.Response(jsonEncode(metaJson), 200);
        }
        return http.Response('Not Found', 404);
      });

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.getAppInfo('termux/termux-app');
      expect(result.success, isTrue);
      final app = result.data!;
      expect(app.appId, 'termux/termux-app');
      // 真实应用名（metadata.appName 覆盖仓库名）
      expect(app.name, 'Termux');
      // 真实图标（metadata icon 覆盖 owner 头像占位）
      expect(app.icon, metadataIconUrl);
      // 真实包名（AppSummary 一级字段）
      expect(app.packageName, 'com.termux');
    });

    test('metadata 未收录：回退 GitHub API 数据（仓库名 / 空图标 / 无包名）', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.getAppInfo('termux/termux-app');
      expect(result.success, isTrue);
      final app = result.data!;
      // 回退：应用名 = 仓库名
      expect(app.name, 'termux-app');
      // 回退：图标为空（无 metadata 时 API 不提供图标）
      expect(app.icon, '');
      expect(app.packageName, isNull);
    });
  });

  group('getAppDetail', () {
    test('metadata 已收录：详情覆盖应用名 / 图标 / 包名 / 版本', () async {
      MetadataRepository.instance.debugClient = MockClient((request) async {
        if (request.url.path.contains('info.json')) {
          return http.Response(jsonEncode(metaJson), 200);
        }
        return http.Response('Not Found', 404);
      });

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      final detail = result.data!;
      expect(detail.name, 'Termux');
      expect(detail.icon, metadataIconUrl);
      expect(detail.packageName, 'com.termux');
      // metadata.versionName 优先于 release 版本
      expect(detail.version, '0.119.0-beta.3');
    });

    test('metadata 未收录：回退 API 数据（仓库名 / 空图标 / 包名占位）', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      final detail = result.data!;
      // 回退：应用名 = 仓库名（无 metadata.appName）
      expect(detail.name, 'termux-app');
      // 回退：图标 = owner 头像占位（无 metadata.icon）
      expect(detail.icon, '');
      // 未收录：不用仓库名占位包名（避免误用于安装检测）
      expect(detail.packageName, '');
      // 回退：版本 = release 版本（空 releases 时为 null）
      expect(detail.version, isNull);
    });
  });

  group('getAppDetail（README contents API）', () {
    test('contents API 200：JSON base64 解码为 readme', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final readmeJson = jsonEncode({
        'name': 'README.md',
        'content': base64Encode(utf8.encode('# Termux\n使用手册')),
        'encoding': 'base64',
      });

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(readmeJson, 200);
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data!.readme, '# Termux\n使用手册');
    });

    test('README 请求走 api.github.com contents 端点（含 ref 分支）', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final requestedUrls = <String>[];
      final readmeJson = jsonEncode({
        'name': 'README.md',
        'content': base64Encode(utf8.encode('# Termux\n使用手册')),
        'encoding': 'base64',
      });

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(readmeJson, 200);
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      // 测试环境 getProxy() 返回默认代理前缀，断言内容端点与 ref 分支（而非代理前缀）
      expect(
        requestedUrls.any((u) => u.contains(
            'https://api.github.com/repos/termux/termux-app/contents/README.md?ref=master')),
        isTrue,
      );
    });

    test('README.md 404 → 回退 README.MD（JSON base64 解码）', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final readmeJson = jsonEncode({
        'name': 'README.MD',
        'content': base64Encode(utf8.encode('# Fallback\n回退手册')),
        'encoding': 'base64',
      });

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response('Not Found', 404);
          }
          if (request.url.path.endsWith('/contents/README.MD')) {
            return http.Response(readmeJson, 200);
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data!.readme, '# Fallback\n回退手册');
    });
  });

  group('getAppDetail（README ETag 条件缓存）', () {
    late Directory tempDir;

    String readmeJson(String content) => jsonEncode({
          'name': 'README.md',
          'content': base64Encode(utf8.encode(content)),
          'encoding': 'base64',
        });

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('readme_cache_it');
      ReadmeCache.instanceForTest = ReadmeCache(directory: tempDir);
    });

    tearDown(() {
      ReadmeCache.instanceForTest = ReadmeCache();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('首次 200 + etag 响应头 → readme 正确 + 缓存写入', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            return http.Response(readmeJson('# Termux\n使用手册'), 200,
                headers: {'etag': '"etag1"'});
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      expect(result.data!.readme, '# Termux\n使用手册');

      // 断言缓存已写入（etag 与 readme 均正确）
      final entry = await ReadmeCache.instance.get('termux', 'termux-app');
      expect(entry, isNotNull);
      expect(entry!.etag, '"etag1"');
      expect(entry.readme, '# Termux\n使用手册');
    });

    test('二次请求带 If-None-Match → 304 空 body → readme 用缓存值（不重新解码）', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      // 预置缓存（绝对化后文本，与原始解码结果刻意不同，验证直接复用）
      const cachedReadme = '# Termux\n![图](https://raw.githubusercontent.com/termux/termux-app/refs/heads/master/a.png)';
      await ReadmeCache.instance
          .put('termux', 'termux-app', etag: '"etag1"', readme: cachedReadme);

      final requestedUrls = <String>[];
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            requestedUrls.add(request.url.toString());
            // 断言 If-None-Match 头正确传递（MockClient 请求头大小写不敏感）
            expect(request.headers['If-None-Match'], '"etag1"');
            return http.Response('', 304);
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result = await channel.getAppDetail('termux/termux-app');
      expect(result.success, isTrue);
      expect(requestedUrls, isNotEmpty);
      // 304 命中：直接用缓存值（已绝对化），不重新解码
      expect(result.data!.readme, cachedReadme);
    });

    test('内容变化：带 If-None-Match 的请求返回 200 + 新内容 + 新 etag → readme 与缓存更新', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      var callCount = 0;
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/contents/README.md')) {
            callCount++;
            if (callCount == 1) {
              // 首次：无条件头
              expect(request.headers.containsKey('If-None-Match'), isFalse);
              return http.Response(readmeJson('# V1'), 200,
                  headers: {'etag': '"etag1"'});
            }
            // 二次：带缓存 etag
            expect(request.headers['If-None-Match'], '"etag1"');
            return http.Response(readmeJson('# V2\n更新内容'), 200,
                headers: {'etag': '"etag2"'});
          }
          return http.Response('Not Found', 404);
        }),
      );

      final result1 = await channel.getAppDetail('termux/termux-app');
      expect(result1.success, isTrue);
      expect(result1.data!.readme, '# V1');

      final result2 = await channel.getAppDetail('termux/termux-app');
      expect(result2.success, isTrue);
      expect(result2.data!.readme, '# V2\n更新内容');

      // 缓存 etag 已更新
      final entry = await ReadmeCache.instance.get('termux', 'termux-app');
      expect(entry, isNotNull);
      expect(entry!.etag, '"etag2"');
      expect(entry.readme, '# V2\n更新内容');
    });
  });

  group('decodeContentsReadme（纯函数）', () {
    test('合法 base64 JSON → 解码文本', () {
      final body = jsonEncode({
        'name': 'README.md',
        'content': base64Encode(utf8.encode('# Termux\n使用手册')),
        'encoding': 'base64',
      });
      expect(decodeContentsReadme(body), '# Termux\n使用手册');
    });

    test('content base64 带换行 → 解码成功', () {
      final b64 = base64Encode(utf8.encode('# Termux\n使用手册'));
      // GitHub contents API 会在 base64 中插入换行，需去空白后解码
      final b64WithNewline = '${b64.substring(0, 10)}\n${b64.substring(10)}';
      final body = jsonEncode({'content': b64WithNewline, 'encoding': 'base64'});
      expect(decodeContentsReadme(body), '# Termux\n使用手册');
    });

    test('无 content 字段的 JSON → 原样返回 body', () {
      const body = '{"name":"README.md"}';
      expect(decodeContentsReadme(body), body);
    });

    test('非 JSON 文本（raw 内容）→ 原样返回', () {
      const raw = '# Termux\n使用手册';
      expect(decodeContentsReadme(raw), raw);
    });

    test('损坏 base64（非 JSON 且无法解码）→ 原样返回 body（兼容 fallback）', () {
      const corrupted = '!!!not-base64!!!';
      expect(decodeContentsReadme(corrupted), corrupted);
    });
  });

  group('searchApps（repositories 语义）', () {
    test('repositories 存仓库名而非完整名（根治 search-add 产脏）', () async {
      MetadataRepository.instance.debugClient = MockClient(
          (request) async => http.Response('Not Found', 404));

      const searchBody = '''
      {
        "items": [
          {
            "full_name": "gkd-kit/gkd",
            "name": "gkd",
            "owner": {"login": "gkd-kit", "avatar_url": "https://avatar"},
            "description": "自定义屏幕点击"
          }
        ]
      }
      ''';
      final channel = GitHubChannel(
        githubApi: FakeGithubRestClient(),
        httpClient: MockClient((request) async => http.Response.bytes(
              utf8.encode(searchBody),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      );

      final result = await channel.searchApps('gkd');
      expect(result.success, isTrue);
      final app = result.data!.single;
      expect(app.appId, 'gkd-kit/gkd');
      expect(app.user, 'gkd-kit');
      // 关键断言：repositories 必须是仓库名（无 '/'），完整名由 appId/apprepo 承载
      expect(app.repositories, 'gkd');
      expect(app.repositories.contains('/'), isFalse);
    });
  });

  group('normalizeStoredRecord（历史脏数据自愈）', () {
    ChannelAddedApp record({
      String appId = 'li.songe.gkd',
      String user = 'li.songe.gkd',
      String repositories = 'gkd-kit/gkd',
      String? apprepo,
    }) {
      return ChannelAddedApp(
        appId: appId,
        name: 'GKD',
        user: user,
        repositories: repositories,
        apprepo: apprepo,
        icon: '',
        description: '',
        category: null,
        addTime: 0,
        channelCode: 'github',
        extra: null,
      );
    }

    test('repositories 含完整名（历史 bug 产物）：拆分 user/repositories，apprepo 兜底完整名', () {
      final normalized =
          GitHubChannel.normalizeStoredRecord(record(repositories: 'gkd-kit/gkd'));
      expect(normalized.user, 'gkd-kit');
      expect(normalized.repositories, 'gkd');
      expect(normalized.apprepo, 'gkd-kit/gkd');
      expect(normalized.appId, 'li.songe.gkd'); // appId（真实包名）不变
    });

    test('apprepo 已有值时保留原值，不覆盖', () {
      final normalized = GitHubChannel.normalizeStoredRecord(
          record(repositories: 'gkd-kit/gkd', apprepo: '旧完整名'));
      expect(normalized.apprepo, '旧完整名');
      expect(normalized.user, 'gkd-kit');
      expect(normalized.repositories, 'gkd');
    });

    test('repositories 无斜杠（干净记录）：原样返回', () {
      final clean = record(user: 'gkd-kit', repositories: 'gkd');
      expect(identical(GitHubChannel.normalizeStoredRecord(clean), clean), isTrue);
    });

    test('repositories 含多个斜杠（异常数据）：不做拆分', () {
      final weird = record(repositories: 'a/b/c');
      final normalized = GitHubChannel.normalizeStoredRecord(weird);
      expect(identical(normalized, weird), isTrue);
    });
  });
}
