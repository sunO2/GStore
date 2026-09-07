import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/http/github/user_info/user_info.dart';

import 'user_manager.dart';

/// 当前登录用户信息（Riverpod 主状态源）。
///
/// 权威真源仍是 [UserManager]（GetX 服务，登录/登出/启动恢复写入 userInfo）；
/// 本 Notifier 订阅其 userInfo Rx 并镜像，使已迁移 Riverpod 的页面
/// 无需再 `Get.find<UserManager>()` 也能响应登录状态变化。
class UserInfoNotifier extends Notifier<UserInfo> {
  StreamSubscription<UserInfo>? _sub;

  @override
  UserInfo build() {
    // 订阅 UserManager.userInfo：登录/登出/启动恢复 → 同步
    try {
      final manager = UserManager.instance;
      _sub = manager.userInfo.listen((user) {
        state = user;
      });
      ref.onDispose(() => _sub?.cancel());
      // 初始同步当前值（登录返回后 userInfo 已写入，先订阅再取值保证不丢帧）
      return manager.userInfo.value;
    } catch (_) {
      // UserManager 不可用（极端降级）：保持默认
      return const UserInfo();
    }
  }
}

/// 用户信息 Provider（登录态 UI：头像/昵称/登出）。
final userInfoProvider = NotifierProvider<UserInfoNotifier, UserInfo>(
  UserInfoNotifier.new,
);
