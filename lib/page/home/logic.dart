import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:gstore/http/github_request_mix.dart';

import 'state.dart';

class HomeLogic extends GetxController with GithubRequestMix {
  final HomeState state = HomeState();
  final PageController controller = PageController();

  void jumpToPage(int index) {
    // 进入 AI 助手页时记录来源 tab（AI 页输入栏左侧"返回"按钮使用）
    if (index == 2 && state.index.value != 2) {
      state.sourceIndex.value = state.index.value;
    }
    controller.jumpToPage(index);
    state.index.value = index;
    update();
  }
}
