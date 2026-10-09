import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

import 'collection_section.dart';
import 'environment_section.dart';
import 'history_section.dart';
import 'request_debug_facade_provider.dart';
import 'rules_section.dart';
import '../proxy/proxy_capture_bridge.dart';

/// 「请求调试」工作台分区（plan todo 30）。
enum RequestDebugSection {
  /// 集合（收藏的请求 / 文件夹树）。todo 31 深化。
  collections,

  /// 历史（发送记录）。todo 32 深化。
  history,

  /// 环境（`{{var}}` 变量表）。todo 34 深化。
  environments,

  /// 改写规则（Rust 引擎全局捕获改写）。todo 34 深化。
  rules,
}

/// 「请求调试」原生工作台页（Postman-like，非 it-tools WebView 内）。
///
/// 本页（plan todo 30）只搭骨架：顶部 [AppTabBar] 4 分区
/// `集合 / 历史 / 环境 / 改写规则` + 各分区空态 / 极简列表；分区内容由
/// todos 31-34 深化。门面经构造函数注入；[facade] 为空时取共享
/// [RequestDebugFacadeProvider.instance]（与抓包桥同一 store，消除双门面覆盖）。
/// 测试注入假 store / 端口，不触碰原生 FFI。
///
/// 设计约束：全部取主题令牌（[Theme.of]），颜色 / 字号零硬编码；空态图标用
/// [ColoredAliIcon] 染色以适配夜间模式。
class RequestDebugPage extends StatefulWidget {
  const RequestDebugPage({
    super.key,
    this.facade,
    this.initialSection,
    this.rulePrefill,
  });

  /// 窄门面（测试可注入；为空时用生产组合）。
  final RequestDebugFacade? facade;

  /// 初始分区（抓包透传时落到「改写规则」）；`null` = 默认「集合」。
  final RequestDebugSection? initialSection;

  /// 抓包透传的改写规则预填（plan todo 7）；`null` = 无预填，行为不变。
  final CaptureRulePrefill? rulePrefill;

  @override
  State<RequestDebugPage> createState() => _RequestDebugPageState();
}

class _RequestDebugPageState extends State<RequestDebugPage> {
  late final RequestDebugFacade _facade;

  late RequestDebugSection _section;

  /// 待消费的抓包预填（构造后只生效一次，避免切换分区后重复弹出编辑器）。
  CaptureRulePrefill? _rulePrefill;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection ?? RequestDebugSection.collections;
    _rulePrefill = widget.rulePrefill;
    _facade = widget.facade ?? RequestDebugFacadeProvider.instance;
    unawaited(_load());
  }

  Future<void> _load() async {
    // store 语义：损坏降级为空、不抛；页面仅需完成后重绘。
    await _facade.load();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('请求调试')),
      body: Column(
        children: [
          _buildSectionSwitch(context),
          const Divider(height: 1),
          Expanded(child: _buildSectionBody(context)),
        ],
      ),
    );
  }

  /// 顶部 4 分区切换（复用设计系统 [AppTabBar]/[AppSegment]）。
  ///
  /// [AppTabBar] 基于 `TabBar(isScrollable: true)` 且标签宽度随文本，
  /// 窄屏自身可横向滚动，无需外层 `SingleChildScrollView`，选中宽标签
  /// 也不会拉伸其余标签。
  Widget _buildSectionSwitch(BuildContext context) {
    return Padding(
      padding: AppSpacing.allLG,
      child: AppTabBar<RequestDebugSection>(
        key: const Key('request-debug-section-switch'),
        value: _section,
        segments: const <AppSegment<RequestDebugSection>>[
          AppSegment(
            value: RequestDebugSection.collections,
            label: '集合',
            key: Key('request-debug-segment-collections'),
          ),
          AppSegment(
            value: RequestDebugSection.history,
            label: '历史',
            key: Key('request-debug-segment-history'),
          ),
          AppSegment(
            value: RequestDebugSection.environments,
            label: '环境',
            key: Key('request-debug-segment-environments'),
          ),
          AppSegment(
            value: RequestDebugSection.rules,
            label: '改写规则',
            key: Key('request-debug-segment-rules'),
          ),
        ],
        onChanged: (section) => setState(() => _section = section),
      ),
    );
  }

  Widget _buildSectionBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    switch (_section) {
      case RequestDebugSection.collections:
        return RequestDebugCollectionSection(facade: _facade);

      case RequestDebugSection.history:
        return RequestDebugHistorySection(facade: _facade);

      case RequestDebugSection.environments:
        return RequestDebugEnvironmentSection(facade: _facade);

      case RequestDebugSection.rules:
        // 消费一次抓包预填：仅首次构建「改写规则」分区时透传，避免切换分区
        // 回来后重复弹出预填编辑器。
        final prefill = _rulePrefill;
        _rulePrefill = null;
        return RequestDebugRulesSection(facade: _facade, prefill: prefill);
    }
  }
}
