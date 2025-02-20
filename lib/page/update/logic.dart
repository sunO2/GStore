import 'package:flutter/widgets.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

class UpdateLogic extends GetxController with GithubRequestMix {
  final UpdateState state = UpdateState();
}
