import 'package:flutter/services.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:yaml/yaml.dart';

import 'state.dart';

class ApplistLogic extends GetxController with GithubRequestMix {
  final ApplistState state = ApplistState();
  AppInfoDatabase? appDatabase;

  @override
  void onReady() async {
    super.onReady();
    await refreshDataOfDB();
    checkUpdata();
  }

  Future<void> checkUpdata() async {
    // getBanner();
    /// 拉取代理
    var proxyConfigRequest = await DioClient.instance.get().get(
        "https://my-json-server.typicode.com/suno2/GStore-Repositorys/proxy");
    var proxyUrl = proxyConfigRequest.data["url"];
    if (proxyUrl?.toString().isNotEmpty ?? false) {
      log("请求代理地址结果： $proxyUrl");
      updateProxy(proxyUrl);
    }

    var downloadStatus = await "gstore".checkUpdate();
    if (downloadStatus == DownloadStatus.DOWNLOAD_SUCCESS) {
      refreshDataOfDB();
    }
  }

  refreshDataOfDB() async {
    appDatabase = "gstore".repoDB.db;
    state.apps = await appDatabase!.dao
        .getAllApps()
        .catchError((error) => List<AppInfo>.empty());
    var config =
        await appDatabase!.dao.getVersion().onError((error, stackTrace) {
      log("数据库版本获取失败： $error");
    });
    state.version = config?.version ?? "0.0.0";
    log("加载数据库数据： ${state.version}");
    updateDataBaseVersion(state.version);
    update();
  }

  Future<List<dynamic>> getBanner() async {
    var bannerString = await rootBundle.loadString("assets/app/banner.yaml");
    bannerString = bannerString.replaceAll("ENV_PROXY:", getProxy());
    return loadYaml(bannerString);
  }

  //搜索页面
  void search() {
    Get.toNamed(AppRoute.search);
  }

  void appDetailOfAppId(String appId) async {
    var appInfo = await appDatabase?.dao.getAppInfo(appId);
    if (null != appInfo) {
      appDetail(appInfo);
    }
  }

  Future<List<AppInfo>> get hotList async {
    return await "gstore"
        .repoDB
        .db
        .dao
        .searchCategoryLike("%HOT%", limit: 6)
        .then((list) async {
      if (list.isEmpty) {
        return await "gstore"
            .repoDB
            .db
            .dao
            .searchCategoryLike("%TOOLS%", limit: 5);
      }
      return list;
    });
  }

  void appDetail(AppInfo app) {
    Get.toNamed(AppRoute.appDetail, arguments: app);
  }

  void toCategory(String category) {
    appDatabase?.dao.queryCategory(category).then((category) {
      Get.toNamed(AppRoute.categoryPage, arguments: category);
    });
  }
}
