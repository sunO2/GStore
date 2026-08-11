import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
