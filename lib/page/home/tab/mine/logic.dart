import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'state.dart';

class MineLogic extends GetxController {
  final MineState state = MineState();

  Future<List<AppCategory>> getCategory() async {
    var database = "gstore".repoDB.db;
    var data = database.dao.getAllCategory();
    return data;
  }

  search() {
    appRouter.push(AppRoute.search);
  }

  category(AppCategory category) {
    appRouter.push(AppRoute.categoryPage, extra: category);
  }
}
