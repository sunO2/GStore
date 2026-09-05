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
    super.onReady();
  }

  /// 分类浏览入口参数已通过 GoRouter extra 由页面传入（go_router 无 Get.arguments）。
  bool _categoryLoaded = false;

  void loadCategory(AppCategory? category) {
    if (category == null || _categoryLoaded) return;
    _categoryLoaded = true;
    _queryCategory(category);
  }

  void _queryCategory(AppCategory category) async {
    var searchList = await database?.dao.queryCategory(category.id);
    if (searchList?.isNotEmpty ?? false) {
      state.searchList.value = searchList!;
    }
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

  @override
  void onClose() {
    _searchDebounce?.cancel();
    super.onClose();
  }
}
