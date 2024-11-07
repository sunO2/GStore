
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:gstore/http/github_request_mix.dart';

import 'state.dart';

class HomeLogic extends GetxController with GithubRequestMix{
  final HomeState state = HomeState();
  final PageController controller = PageController();



  void jumpToPage(int index) {
    controller.jumpToPage(index);
    state.index.value = index;
    update();
  }
}
