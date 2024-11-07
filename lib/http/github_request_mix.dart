
import 'package:get/get.dart';
import 'package:dio/dio.dart';
import 'package:gstore/http/github/github_client.dart';

mixin GithubRequestMix on GetxController{
  final githubApi = Get.find<GithubRestClient>();
  final cancelToken = CancelToken();

  @override
  void onClose() {
    cancelToken.cancel();
    super.onClose();
  }
}