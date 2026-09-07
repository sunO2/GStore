import 'package:dio/dio.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:retrofit/retrofit.dart';
import 'package:retrofit/http.dart' as retrofit;

part 'github_client.g.dart';

@RestApi(baseUrl: 'https://api.github.com')
abstract class GithubRestClient {
  factory GithubRestClient(Dio dio, {String? baseUrl}) =>
      _GithubRestClient(dio);

  @GET('/repos/{user}/{repositories}')
  Future<ApiList> apiList(
      @Path('user') String user,
      @Path('repositories') repositories,
      @CancelRequest() CancelToken cancelToken);

  @GET('/repos/{user}/{repositories}/releases?per_page={page}')
  Future<String> releases(
      @Path('user') String user,
      @Path('repositories') String repositories,
      @Path('page') int page,
      @CancelRequest() CancelToken cancelToken);

  /// 搜索仓库（用于 GitHub 渠道搜索应用）
  /// 宽松搜索：按名称/描述/README 匹配关键词
  @GET('/search/repositories')
  @retrofit.Headers(<String, String>{
    "Accept": "application/vnd.github+json"
  })
  Future<String> searchRepositories(
      @Query('q') String query,
      @Query('per_page') int perPage,
      @CancelRequest() CancelToken cancelToken);

  /// 获取仓库的 README 文件
  /// 返回包含 Base64 编码内容的 JSON String
  @GET('/repos/{user}/{repositories}/readme')
  @retrofit.Headers(<String, String>{
    "Accept": "application/vnd.github.v3+json"
  })
  Future<String> readme(
      @Path('user') String user,
      @Path('repositories') String repositories,
      @CancelRequest() CancelToken cancelToken);

  @GET('/user')
  Future<UserInfo?> user();

  @GET('/octocat')
  Future<HttpResponse> octocat();

  /// 创建 issue（用于提交应用元数据提取请求到 GStore-Repositorys）
  @POST('/repos/{owner}/{repo}/issues')
  Future<CreateIssueResponse> createIssue(
      @Path('owner') String owner,
      @Path('repo') String repo,
      @Body() Map<String, dynamic> body);
}

@JsonSerializable()
class CreateIssueResponse {
  final int? number;
  @JsonKey(name: 'html_url')
  final String? htmlUrl;
  final String? title;

  const CreateIssueResponse({this.number, this.htmlUrl, this.title});

  factory CreateIssueResponse.fromJson(Map<String, dynamic> json) =>
      _$CreateIssueResponseFromJson(json);
  Map<String, dynamic> toJson() => _$CreateIssueResponseToJson(this);
}

@JsonSerializable()
class Task {
  const Task({this.id, this.name, this.avatar, this.createdAt});

  factory Task.fromJson(Map<String, dynamic> json) => _$TaskFromJson(json);

  final String? id;
  final String? name;
  final String? avatar;
  final String? createdAt;

  Map<String, dynamic> toJson() => _$TaskToJson(this);
}

@JsonSerializable()
class ApiList {
  final int? id;
  final String? default_branch;
  final int? forks;
  final int? stargazers_count;
  final String? html_url;
  final String? description;
  final String? created_at;
  final String? full_name;
  const ApiList(
      {this.id,
      this.default_branch,
      this.forks,
      this.stargazers_count,
      this.description,
      this.created_at,
      this.full_name,
      this.html_url});

  factory ApiList.fromJson(Map<String, dynamic> json) =>
      _$ApiListFromJson(json);
  Map<String, dynamic> toJson() => _$ApiListToJson(this);
}
