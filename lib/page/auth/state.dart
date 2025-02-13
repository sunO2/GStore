import 'package:get/get.dart';

enum AuthStatus {
  initial, // 初始状态
  verifying, // 验证中状态
}

class AuthPageState {
  final RxString verificationCode = ''.obs;
  final Rx<AuthStatus> status = AuthStatus.initial.obs;
  final RxInt remainingSeconds = 900.obs; // 15分钟 = 900秒
  AuthPageState() {
    ///Initialize variables
  }
}
