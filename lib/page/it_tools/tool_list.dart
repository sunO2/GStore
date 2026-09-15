import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';

/// 工具清单条目（由页面通过 `itToolsTools` handler 推来，名称已按当前语言本地化）。
class ItToolItem {
  const ItToolItem({
    required this.path,
    required this.name,
    required this.description,
  });

  final String path;
  final String name;
  final String description;
}

class ItToolGroup {
  const ItToolGroup({required this.category, required this.tools});

  final String category;
  final List<ItToolItem> tools;
}

/// 解析页面通过 `itToolsTools` handler 推来的工具清单。
///
/// 各平台对 `callHandler` 参数的解码不完全一致（多数给已解码的 List，
/// 个别情况给 JSON 字符串），这里两种都接受；结构不符的条目直接跳过，
/// 宁可少几个工具也不能让整页崩掉。
List<ItToolGroup> parseItToolsToolGroups(Object? raw) {
  Object? data = raw;
  if (data is String) {
    try {
      data = jsonDecode(data);
    } catch (_) {
      return const [];
    }
  }
  if (data is! List) return const [];

  final groups = <ItToolGroup>[];
  for (final group in data) {
    if (group is! Map) continue;
    final category = group['category'];
    final toolsRaw = group['tools'];
    if (category is! String || category.isEmpty || toolsRaw is! List) continue;

    final tools = <ItToolItem>[];
    for (final tool in toolsRaw) {
      if (tool is! Map) continue;
      final path = tool['path'];
      final name = tool['name'];
      if (path is! String || path.isEmpty || name is! String) continue;
      final description = tool['description'];
      tools.add(ItToolItem(
        path: path,
        name: name,
        description: description is String ? description : '',
      ));
    }
    if (tools.isNotEmpty) {
      groups.add(ItToolGroup(category: category, tools: tools));
    }
  }
  return groups;
}

/// 原生工具列表弹层（内嵌模式下替代 it-tools 自带的抽屉）。
///
/// 清单由页面推来（分类名/工具名已按当前语言本地化），这里只负责
/// 过滤、展示与回传选择；容器沿用统一的 [AppSheetScaffold]（限高 + 内部滚动）。
///
/// 打开时会**自动把当前工具滚到可视区中间**——清单有 80+ 项，
/// 不定位的话每次都要手动找一遍。
class ItToolListSheet extends StatefulWidget {
  const ItToolListSheet({
    super.key,
    required this.groups,
    required this.currentPath,
  });

  final List<ItToolGroup> groups;

  /// 页面当前所在工具的路径；不在清单里（如停在工具首页）时不定位
  final String currentPath;

  @override
  State<ItToolListSheet> createState() => _ItToolListSheetState();
}

class _ItToolListSheetState extends State<ItToolListSheet> {
  final TextEditingController _queryCtrl = TextEditingController();

  /// 指向「当前工具」那一行，用于开面板时定位
  final GlobalKey _currentItemKey = GlobalKey();

  String _query = '';

  @override
  void initState() {
    super.initState();
    // 等首帧布局完成后再滚：此时各行的 RenderObject 才存在。
    // 用零时长直接跳到位（不用动画）——弹层本身正在上滑，
    // 再叠一层滚动动画会很跳。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final itemContext = _currentItemKey.currentContext;
      if (itemContext == null || !mounted) return;
      Scrollable.ensureVisible(
        itemContext,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 按关键字过滤（工具名 / 路径）；过滤后为空的分类直接隐藏
  List<ItToolGroup> get _filtered {
    if (_query.isEmpty) return widget.groups;

    final q = _query.toLowerCase();
    final result = <ItToolGroup>[];
    for (final group in widget.groups) {
      final tools = group.tools
          .where((t) =>
              t.name.toLowerCase().contains(q) ||
              t.path.toLowerCase().contains(q))
          .toList();
      if (tools.isNotEmpty) {
        result.add(ItToolGroup(category: group.category, tools: tools));
      }
    }
    return result;
  }

  int _countOf(List<ItToolGroup> groups) =>
      groups.fold(0, (sum, g) => sum + g.tools.length);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = _filtered;

    return AppSheetScaffold(
      title: '工具列表',
      subtitle: _query.isEmpty
          ? '共 ${_countOf(widget.groups)} 个工具'
          : '匹配 ${_countOf(groups)} 个',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
            child: TextField(
              controller: _queryCtrl,
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索工具名',
                prefixIcon:
                    const Icon(Icons.search, size: AppTypography.iconSM),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close,
                            size: AppTypography.iconSM),
                        onPressed: () {
                          _queryCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          if (groups.isEmpty)
            Padding(
              padding: AppSpacing.allLG,
              child: Text(
                '没有匹配的工具',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            for (final group in groups) ...[
              Padding(
                padding: AppSpacing.onlyHorizontalLG,
                child: Text(
                  group.category,
                  style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: AppTypography.weightMedium,
                      ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              for (final tool in group.tools)
                // AppSheetScaffold 的容器是「带底色的 DecoratedBox」，直接放
                // ListTile 会把水波纹画在它自己的 Material 上而被遮住
                // （debug 下还会直接断言）。包一层透明 Material，点击反馈才可见。
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    key: tool.path == widget.currentPath
                        ? _currentItemKey
                        : null,
                    title: Text(tool.name),
                    subtitle: tool.description.isEmpty
                        ? null
                        : Text(tool.description, maxLines: 2),
                    trailing: tool.path == widget.currentPath
                        ? Icon(
                            Icons.check,
                            size: AppTypography.iconSM,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(tool.path),
                  ),
                ),
            ],
        ],
      ),
    );
  }
}
