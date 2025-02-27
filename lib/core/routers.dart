import 'package:gstore/core/core.dart';
import 'package:gstore/page/ai_test/home.dart';
import 'package:gstore/page/page.dart';

class AppRoute {
  static String home = "/";
  static String appDetail = "/GStore/appDetail";
  static String search = "/GStore/seawrch";
  static String categoryPage = "/GStore/categoryPage";
  static String downloadCenter = "/GStore/downloadCenter";
  static String updateCenter = "/GStore/updateCenter";
  static String webView = "/GStore/webView";
  static String auth = "/GStore/auth";
  static String test_home = "/GStore/test/home";

  static List<GetPage> pages = [
    GetPage(
      name: home,
      page: () => const HomePage(),
      // transitionDuration: const Duration(milliseconds: 0),
      // transition: Transition.noTransition
    ),
    GetPage(name: appDetail, page: () => const DetailPage()),
    GetPage(name: categoryPage, page: () => const SearchPage()),
    GetPage(
        name: search,
        page: () => const SearchPage(),
        transitionDuration: const Duration(milliseconds: 0),
        transition: Transition.noTransition),
    GetPage(name: downloadCenter, page: () => const DownloadManager()),
    GetPage(name: updateCenter, page: () => const UpdateManager()),
    GetPage(name: webView, page: () => const WebPage()),
    GetPage(name: auth, page: () => const AuthPage()),
    GetPage(name: test_home, page: () => const AppStoreHomePage()),
  ];
}

launcherBrow(String url, {AppInfo? appinfo}) {
  Get.toNamed(AppRoute.webView, arguments: {
    "url": url,
    "appInfo": appinfo,
  });
}
