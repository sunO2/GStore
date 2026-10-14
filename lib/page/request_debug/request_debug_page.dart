import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/request_debug/import_export/import_export.dart';
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

  /// 集合分区状态句柄：导航头动作（添加集合 / 更多菜单）经此驱动集合分区。
  final GlobalKey<RequestDebugCollectionSectionState> _collectionKey =
      GlobalKey<RequestDebugCollectionSectionState>();

  /// 待消费的抓包预填（构造后只生效一次，避免切换分区后重复弹出编辑器）。
  CaptureRulePrefill? _rulePrefill;

  /// 集合分区是否处于排序态（导航头据此把「更多」替换为「完成」）。
  bool _collectionSorting = false;

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
      appBar: AppBar(
        title: const Text('请求调试'),
        actions: _buildCollectionActions(),
      ),
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
        onChanged: (section) => setState(() {
          _section = section;
          // 离开「集合」分区会销毁其状态（含排序态），此处复位避免导航头
          // 切回来后仍停留在「完成」。
          if (section != RequestDebugSection.collections) {
            _collectionSorting = false;
          }
        }),
      ),
    );
  }

  /// 导航头动作：仅在「集合」分区显示 `[添加集合]` + `[更多]`。
  ///
  /// 集合分区的排序 / 导入 / 导出动作经 [_collectionKey] 驱动，避免把集合
  /// 分区自身的操作塞进分区头部（Wave 8）。排序态下「更多」替换为「完成」
  /// 文字按钮（Wave 9）：点「完成」直接退出排序，无需重开菜单取消。
  List<Widget> _buildCollectionActions() {
    if (_section != RequestDebugSection.collections) {
      return const <Widget>[];
    }
    return <Widget>[
      IconButton(
        key: const Key('request-debug-collection-add'),
        tooltip: '添加集合',
        icon: const Icon(TablerIcons.plus),
        onPressed: () => _collectionKey.currentState?.createCollection(),
      ),
      if (_collectionSorting)
        TextButton(
          key: const Key('request-debug-collection-sort-done'),
          onPressed: () => _collectionKey.currentState?.toggleSort(),
          child: const Text('完成'),
        )
      else
        PopupMenuButton<String>(
          key: const Key('request-debug-collection-transfer'),
          tooltip: '更多',
          icon: const Icon(TablerIcons.dots_vertical),
          onSelected: (value) {
            switch (value) {
              case 'sort':
                _collectionKey.currentState?.toggleSort();
              case 'import-curl':
                _collectionKey.currentState?.importCurl();
              case 'import-file':
                _collectionKey.currentState?.importCollections();
              case 'export-har':
                _collectionKey.currentState?.exportCollections(
                  DebugTransferFormat.har,
                );
              case 'export-postman':
                _collectionKey.currentState?.exportCollections(
                  DebugTransferFormat.postman,
                );
              case 'export-openapi':
                _collectionKey.currentState?.exportCollections(
                  DebugTransferFormat.openapi,
                );
              case 'export-raw':
                _collectionKey.currentState?.exportCollections(
                  DebugTransferFormat.rawHttp,
                );
            }
          },
          itemBuilder: (_) {
            return <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                key: Key('request-debug-collection-sort-toggle'),
                value: 'sort',
                child: Text('排序'),
              ),
              const PopupMenuItem<String>(
                key: Key('request-debug-curl-import'),
                value: 'import-curl',
                child: Text('导入 cURL'),
              ),
              const PopupMenuItem<String>(
                key: Key('request-debug-collection-import-file'),
                value: 'import-file',
                child: Text('导入集合文件…'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                key: Key('request-debug-collection-export-har'),
                value: 'export-har',
                child: Text('导出为 HAR 1.2'),
              ),
              const PopupMenuItem<String>(
                key: Key('request-debug-collection-export-postman'),
                value: 'export-postman',
                child: Text('导出为 Postman v2.1'),
              ),
              const PopupMenuItem<String>(
                key: Key('request-debug-collection-export-openapi'),
                value: 'export-openapi',
                child: Text('导出为 OpenAPI 3'),
              ),
              const PopupMenuItem<String>(
                key: Key('request-debug-collection-export-raw'),
                value: 'export-raw',
                child: Text('导出为原始 HTTP'),
              ),
            ];
          },
        ),
    ];
  }

  Widget _buildSectionBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    switch (_section) {
      case RequestDebugSection.collections:
        return RequestDebugCollectionSection(
          key: _collectionKey,
          facade: _facade,
          onSortModeChanged: (on) {
            if (mounted) setState(() => _collectionSorting = on);
          },
        );

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
