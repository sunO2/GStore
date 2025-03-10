import 'package:gstore/core/core.dart';
import 'state.dart';

class MineLogic extends GetxController {
  final MineState state = MineState();

  Future<List<AppCategory>> getCategory() async {
    var database = "gstore".repoDB.db;
    var data = database.dao.getAllCategory();
    return data;
  }

  search() {
    Get.toNamed(AppRoute.search);
  }

  category(AppCategory category) {
    Get.toNamed(AppRoute.categoryPage, arguments: category);
  }
}
