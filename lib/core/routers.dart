import 'package:gstore/core/core.dart';
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
  static String fdroidRepo = "/GStore/fdroidRepo";
  static String logViewer = "/GStore/logViewer";
  static String settings = "/GStore/settings";
  static String themeSettings = "/GStore/themeSettings";
  static String backup = "/GStore/backup";
  static String webdavConfig = "/GStore/webdavConfig";
  static String workflowDesigner = "/GStore/workflowDesigner";

  static List<GetPage> pages = [
    GetPage(
        name: home,
        page: () => const HomePage(),
        transitionDuration: const Duration(milliseconds: 0),
        transition: Transition.noTransition),
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
    GetPage(name: fdroidRepo, page: () => FdroidRepoPage()),
    GetPage(name: logViewer, page: () => const LogViewerPage()),
    GetPage(name: settings, page: () => const SettingsPage()),
    GetPage(name: themeSettings, page: () => const ThemeSettingsPage()),
    GetPage(name: backup, page: () => const BackupPage()),
    GetPage(name: webdavConfig, page: () => const WebDavConfigPage()),
    GetPage(name: workflowDesigner, page: () => const WorkflowDesignerPage()),
  ];
}
