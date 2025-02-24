import 'package:floor/floor.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/main.dart';

import 'package:flutter/material.dart';

class WebPageState {
  Rx<Color> appBarColor =
      (Get.theme.appBarTheme.backgroundColor ?? Colors.white).obs;
  var loadingStatus = 1.obs;
  WebPageState() {
    ///Initialize variables
  }
}
