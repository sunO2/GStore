import 'package:get/get.dart';
import 'package:dio/dio.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/http/github/github_client.dart';

mixin GithubRequestMix on GetxController {
  final githubApi = ModuleManager.instance.require<GithubRestClient>();
  final cancelToken = CancelToken();

  @override
  void onClose() {
    cancelToken.cancel();
    super.onClose();
  }
}
