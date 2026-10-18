import 'package:flutter/material.dart';

import 'package:gstore/core/perf/third_party_perf_service.dart';

import 'third_party_section.dart';

/// 性能「第三方应用」页。
///
/// 独立路由页面，以 [Scaffold] 包裹原 `PerfMonitorPage` 概览中的
/// [ThirdPartyAppSection]（Shizuku 逐应用 CPU / 内存 / 帧卡顿 / 启动耗时 /
/// 告警）。section 内部实现与 Key 逐字沿用，行为不变。
///
/// [service] 为可选注入：生产传 `null` → section 使用默认
/// （Shizuku + `PerfModule.instance`）；测试注入假服务以避开真实平台通道。
///
/// 全部颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
class PerfThirdPartyPage extends StatelessWidget {
  const PerfThirdPartyPage({super.key, this.service});

  /// 可注入第三方性能服务；为 `null` 时由 [ThirdPartyAppSection] 使用默认实现。
  final ThirdPartyPerfService? service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('第三方应用')),
      body: ListView(
        children: [
          ThirdPartyAppSection(service: service),
        ],
      ),
    );
  }
}
