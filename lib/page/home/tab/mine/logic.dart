import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'state.dart';

class MineLogic extends GetxController {
  final MineState state = MineState();


  Future<List<AppCategory>> getCategory() async {
    var database = (await appInfoDatabase);
    var data = database.dao.getAllCategory();
    database.close();
    return data;
  }

  search() {
    Get.toNamed(AppRoute.search);
  }

  category(AppCategory category) {
    Get.toNamed(AppRoute.categoryPage, arguments: category);
  }
}
