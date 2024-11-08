import 'package:flutter/widgets.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

class SearchLogic extends GetxController with GithubRequestMix {
  final SearchState state = SearchState();
  final StreamController<List<AppInfo>> searchController =
      StreamController<List<AppInfo>>();
  TextEditingController textEditingController = TextEditingController();
  late AppInfoDatabase? database;

  @override
  void onReady() async {
    database = await appInfoDatabase;
    textEditingController.addListener(inputListener);
    queryCaertory();
    super.onReady();
  }

  void inputListener() async {
    var inputText = textEditingController.text;
    if (inputText.isEmpty) {
      return;
    }
    var searchList = await database?.dao.search(inputText);
    if (searchList?.isNotEmpty ?? false) {
      searchController.sink.add(searchList!);
    }
  }

  void queryCaertory() async {
    var category = Get.arguments;
    if (category is AppCategory) {
      var searchList = await database?.dao.queryCategory(category.id);
      if (searchList?.isNotEmpty ?? false) {
        searchController.sink.add(searchList!);
      }
    }
  }

  @override
  void onClose() {
    database?.close();
    searchController.close();
    super.onClose();
  }
}
