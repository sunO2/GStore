import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:retrofit/retrofit.dart';

part 'github_client.g.dart';

@RestApi(baseUrl: 'https://api.github.com')
abstract class GithubRestClient with GetxServiceMixin {
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

  @GET('/octocat')
  Future<HttpResponse> octocat();
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
