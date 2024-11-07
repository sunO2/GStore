import 'package:gstore/core/core.dart';
import 'package:gstore/page/page.dart';

class AppRoute {
  static String home = "/";
  static String appDetail = "/GStore/appDetail";
  static String search = "/GStore/seawrch";

  static List<GetPage> pages = [
    GetPage(
        name: home,
        page: () => const HomePage(),
        transitionDuration: const Duration(milliseconds: 0),
        transition: Transition.noTransition),
    GetPage(name: appDetail, page: () => const DetailPage()),
    GetPage(
        name: search,
        page: () => const SearchPage(),
        transitionDuration: const Duration(milliseconds: 0),
        transition: Transition.noTransition),
  ];
}
