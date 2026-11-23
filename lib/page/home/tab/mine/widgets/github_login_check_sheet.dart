import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/progress_log_sheet.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/service/github_login_check.dart';

/// 检查 GitHub 登录状态（底部日志面板）
///
/// 点击「我的 → 已登录卡片 → 检查」弹出；逐行输出 Token 信息、`GET /user`
/// 结果与 Rust 渠道实测，用于定位 401。
class GithubLoginCheckSheet {
  GithubLoginCheckSheet._();

  static Future<void> show(BuildContext context) {
    return AppSheet.showCustom<void>(
      context: context,
      builder: (_) => ProgressLogSheet(
        title: '检查 GitHub 登录状态',
        icon: TablerIcons.brand_github,
        task: (onLog) => GithubLoginCheck.run(onLog),
      ),
    );
  }
}
