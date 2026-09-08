import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/page.dart';

import '../routers.dart';

/// 返回首页时重置键盘焦点（原 main.dart 的 HomeFocusResetObserver，随路由迁移）
///
/// Flutter 路由 pop 存在焦点恢复机制：pop 回首页时会把焦点恢复到
/// 推入二级页前持有焦点的首页 TextField（搜索框/AI 输入栏），导致键盘自动弹出。
/// 此 observer 在 pop 回首页（previousRoute 为 home）后统一 unfocus。
class HomeFocusResetObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute?.settings.name == AppRoute.home) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    }
  }
}

/// 全局导航 key 定义见 lib/core/navigation/nav_key.dart（appNavigatorKey）。

/// 读取当前 GoRouter 路由的 extra（原 Get.arguments）。
///
/// 容错版本：测试/非 GoRouter 环境（直接 pump 页面）无路由 scope 时返回 null，
/// 与 GetX 时代"无参数时 Get.arguments == null"语义一致。
Object? goRouterExtraOf(BuildContext context) {
  try {
    return GoRouterState.of(context).extra;
  } catch (_) {
    return null;
  }
}

/// 全局 GoRouter 实例（logic/service/通知/深链无 context 导航统一入口）。
final GoRouter appRouter = GoRouter(
  navigatorKey: appNavigatorKey,
  initialLocation: AppRoute.home,
  observers: [HomeFocusResetObserver()],
  routes: [
    GoRoute(
      path: AppRoute.home,
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: AppRoute.appDetail,
      builder: (context, state) => const DetailPage(),
    ),
    GoRoute(
      path: AppRoute.categoryPage,
      builder: (context, state) => const SearchPage(),
    ),
    GoRoute(
      path: AppRoute.search,
      builder: (context, state) => const SearchPage(),
    ),
    GoRoute(
      path: AppRoute.downloadCenter,
      builder: (context, state) => const DownloadManager(),
    ),
    GoRoute(
      path: AppRoute.updateCenter,
      builder: (context, state) => const UpdateManager(),
    ),
    GoRoute(
      path: AppRoute.webView,
      builder: (context, state) => const WebPage(),
    ),
    GoRoute(
      path: AppRoute.auth,
      builder: (context, state) => const AuthPage(),
    ),
    GoRoute(
      path: AppRoute.fdroidRepo,
      builder: (context, state) => FdroidRepoPage(),
    ),
    GoRoute(
      path: AppRoute.logViewer,
      builder: (context, state) => const LogViewerPage(),
    ),
    GoRoute(
      path: AppRoute.qrTool,
      builder: (context, state) => const QrToolPage(),
    ),
    GoRoute(
      path: AppRoute.settings,
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: AppRoute.themeSettings,
      builder: (context, state) => const ThemeSettingsPage(),
    ),
    GoRoute(
      path: AppRoute.backup,
      builder: (context, state) => const BackupPage(),
    ),
    GoRoute(
      path: AppRoute.webdavConfig,
      builder: (context, state) => const WebDavConfigPage(),
    ),
    GoRoute(
      path: AppRoute.agent,
      builder: (context, state) => const AgentPage(),
    ),
    GoRoute(
      path: AppRoute.agentSettings,
      builder: (context, state) => const AgentSettingsPage(),
    ),
    GoRoute(
      path: AppRoute.installedApps,
      builder: (context, state) => const InstalledAppsPage(),
    ),
    GoRoute(
      path: AppRoute.moduleManage,
      builder: (context, state) => const ModuleManagePage(),
    ),
    GoRoute(
      path: AppRoute.cacheManage,
      builder: (context, state) => const CacheManagePage(),
    ),
    GoRoute(
      path: AppRoute.databaseManage,
      builder: (context, state) => const DatabaseManagePage(),
    ),
    GoRoute(
      path: AppRoute.licenses,
      builder: (context, state) => const LicensesPage(),
    ),
  ],
);
