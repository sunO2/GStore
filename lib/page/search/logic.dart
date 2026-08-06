import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

class SearchLogic extends GetxController with GithubRequestMix {
  final SearchState state = SearchState();
  TextEditingController textEditingController = TextEditingController();
  late AppInfoDatabase? database;
  Timer? _searchDebounce;

  @override
  void onReady() async {
    database = "gstore".repoDB.db;
    textEditingController.addListener(inputListener);
    queryCaertory();
    super.onReady();
  }

  void inputListener() async {
    var inputText = textEditingController.text;
    if (inputText.isEmpty) {
      state.searchList.clear();
      return;
    }

    // 防抖，避免频繁查询（尤其英文 FTS+LIKE 兜底较慢）
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () async {
      var searchList = await database?.dao.search(inputText);
      if (textEditingController.text != inputText) {
        return; // 输入已变化，丢弃过期结果
      }
      if (searchList?.isNotEmpty ?? false) {
        state.searchList.value = searchList!;
      } else {
        state.searchList.clear();
      }
    });
  }

  void queryCaertory() async {
    var category = Get.arguments;
    if (category is AppCategory) {
      var searchList = await database?.dao.queryCategory(category.id);
      if (searchList?.isNotEmpty ?? false) {
        state.searchList.value = searchList!;
      }
    }
  }

  @override
  void onClose() {
    _searchDebounce?.cancel();
    super.onClose();
  }
}
