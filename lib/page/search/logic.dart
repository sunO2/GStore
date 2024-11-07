import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github_request_mix.dart';

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
    super.onReady();
  }

  void inputListener() async {
    var inputText = textEditingController.text;
    if (inputText.isEmpty) {
      return;
    }
    var searchList = await database?.dao.search(inputText);
    if (null != searchList) {
      searchController.sink.add(searchList);
    }
  }

  @override
  void onClose() {
    database?.close();
    searchController.close();
    super.onClose();
  }
}
