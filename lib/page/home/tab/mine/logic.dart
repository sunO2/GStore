import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'state.dart';

class MineLogic extends GetxController {
  final MineState state = MineState();

  @override
  void onReady() {
    super.onReady();
  }

  Future<List<AppCategory>> getCategory() async {
    var dao = (await appInfoDatabase).dao;
    return dao.getAllCategory();
  }

  search() {}
}
