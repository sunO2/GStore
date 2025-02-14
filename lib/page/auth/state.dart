import 'package:get/get.dart';

enum AuthStatus {
  empty,
  initial, // 初始状态
  verifying, // 验证中状态
}

class AuthPageState {
  final RxString verificationCode = ''.obs;
  final Rx<AuthStatus> status = AuthStatus.empty.obs;
  AuthPageState() {
    ///Initialize variables
  }
}
