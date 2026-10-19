import 'package:flutter/material.dart';

import 'package:gstore/core/perf/third_party_perf_service.dart';

import 'third_party_section.dart';

/// 性能「第三方应用」内容部件。
///
/// 以可滚动列表包裹 [ThirdPartyAppSection]（Shizuku 逐应用 CPU / 内存 / 帧卡顿 /
/// 启动耗时 / 告警），并入 [PerfMonitorPage]「第三方」tab。section 内部实现与 Key
/// 逐字沿用，行为不变。
///
/// [service] 为可选注入：生产传 `null` → section 使用默认
/// （Shizuku + `PerfModule.instance`）；测试注入假服务以避开真实平台通道。
///
/// **纯内容部件**：不含 Scaffold / AppBar，返回可滚动内容供页面 tab body 直接复用。
///
/// 全部颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
class PerfThirdPartyPage extends StatelessWidget {
  const PerfThirdPartyPage({super.key, this.service});

  /// 可注入第三方性能服务；为 `null` 时由 [ThirdPartyAppSection] 使用默认实现。
  final ThirdPartyPerfService? service;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ThirdPartyAppSection(service: service),
      ],
    );
  }
}
