import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:http/http.dart' as http;
import 'package:installed_apps/installed_apps.dart';
import 'package:gstore/core/core.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'state.dart';

class DetailLogic extends GetxController with GithubRequestMix {
  final StreamController<DownloadStatus> counterController =
      StreamController<DownloadStatus>.broadcast();
  StreamSubscription? downloadListenerSubscription;

  final DetailState state = DetailState();
  AppInfo app = Get.arguments;

  @override
  void onReady() {
    request();
    super.onReady();
  }

  void request() async {
    var apiList =
        await githubApi.apiList(app.user, app.repositories, cancelToken);
    state.apiInfo.value = apiList;
    var task =
        await githubApi.releases(app.user, app.repositories, 1, cancelToken);
    List<dynamic> releases = jsonDecode(task);
    if (task.isNotEmpty) {
      var appId = app.appId;
      // installStatus 0 安装 1 可更新 -1 未安装
      if (await InstalledApps.isAppInstalled(appId) ?? false) {
        state.installInfo = await InstalledApps.getAppInfo(appId);
      }
      state.release.clear();
      state.release.addAll(releases);
    }

    state.sourceUrl =
        "${getProxy()}https://raw.githubusercontent.com/${apiList.full_name}/refs/heads/${apiList.default_branch}/";
    var resp = await http.get(Uri.parse('${state.sourceUrl}README.md'));

    if (resp.statusCode == 404) {
      resp = await http.get(Uri.parse('${state.sourceUrl}README.MD'));
    }
    state.body.value = resp.body;
    update();
  }

  void onTapLink(String text, String? href, String title) {
    if (null != href) {
      openBrowser(href);
    }
  }

  void startDownload(String? url, String version, fileName,
      {int? downloadSize}) async {
    if (null != url) {
      downloadListenerSubscription?.cancel();
      var status = await Get.find<DownloadService>().download(
          app.appId, app.name, version, url, fileName,
          downloadSize: downloadSize);
      counterController.sink.add(status);
      downloadListenerSubscription = status.observer.listen((da) {
        counterController.sink.add(da);
      });
    }
  }

  startApp(String packageName) {
    InstalledApps.startApp(packageName);
  }

  openBrowser(String url) {
    // Get.toNamed(AppRoute.webView, arguments: app);
    if (!url.startsWith("http://") &&
        !url.startsWith("https://") &&
        !url.startsWith("file://")) {
      return;
    }

    // GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser(appInfo: app);

    // final settings = ChromeSafariBrowserSettings(
    //   shareState: CustomTabsShareState.SHARE_STATE_ON,
    //   barCollapsingEnabled: true,
    // );
    // inAppBrowser.open(url: WebUri(url), settings: settings);
    launcherBrow(url, appinfo: app);
  }

  openProjectBrowser() {
    openBrowser("https://github.com/${app.user}/${app.repositories}");
  }

  @override
  void onClose() {
    counterController.close();
    downloadListenerSubscription?.cancel();
    super.onClose();
  }
}
