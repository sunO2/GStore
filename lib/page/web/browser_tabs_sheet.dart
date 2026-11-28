import 'package:flutter/foundation.dart';
// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';

/// 标签页切换器里的一张卡片。
class BrowserTabCardData {
  const BrowserTabCardData({
    required this.index,
    required this.title,
    required this.url,
    required this.active,
    required this.suspended,
    this.thumbnail,
  });

  final int index;
  final String title;
  final String url;
  final bool active;

  /// 超出保活上限后按钮被释放，切回时会重新加载。
  final bool suspended;

  final Uint8List? thumbnail;
}

/// Chrome 风格的标签页切换器（底部弹层，2 列卡片）。
Future<void> showBrowserTabsSheet(
  BuildContext context, {
  required ValueListenable<List<BrowserTabCardData>> cards,
  required ValueChanged<int> onSelect,
  required ValueChanged<int> onClose,
  required VoidCallback onNewTab,
}) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (_) => _TabsSheet(
      cards: cards,
      onSelect: onSelect,
      onClose: onClose,
      onNewTab: onNewTab,
    ),
  );
}

class _TabsSheet extends StatelessWidget {
  const _TabsSheet({
    required this.cards,
    required this.onSelect,
    required this.onClose,
    required this.onNewTab,
  });

  final ValueListenable<List<BrowserTabCardData>> cards;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNewTab;

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '标签页',
      icon: const Icon(TablerIcons.layout_grid),
      actions: [
        TextButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            onNewTab();
          },
          icon: const Icon(TablerIcons.plus, size: 20),
          label: const Text('新建'),
        ),
      ],
      content: ValueListenableBuilder<List<BrowserTabCardData>>(
        valueListenable: cards,
        builder: (context, items, _) {
          if (items.isEmpty) {
            return const SizedBox(
              height: 120,
              child: Center(child: Text('没有标签页')),
            );
          }
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              childAspectRatio: 0.76,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final data = items[index];
              return _TabCard(
                data: data,
                onSelect: () {
                  Navigator.of(context).pop();
                  onSelect(data.index);
                },
                onClose: () => onClose(data.index),
              );
            },
          );
        },
      ),
    );
  }
}

class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.data,
    required this.onSelect,
    required this.onClose,
  });

  final BrowserTabCardData data;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final host = Uri.tryParse(data.url)?.host ?? '';
    final title = data.title.trim().isEmpty
        ? (host.isEmpty ? '新标签页' : host)
        : data.title.trim();
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: data.active ? scheme.primary : scheme.outlineVariant,
              width: data.active ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
                child: Row(
                  children: [
                    _Favicon(host: host, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium,
                      ),
                    ),
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭标签页',
                        onPressed: onClose,
                        icon: const Icon(TablerIcons.x),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: data.thumbnail == null
                    ? ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Center(
                          child: _Favicon(host: host, size: 30),
                        ),
                      )
                    : Image.memory(
                        data.thumbnail!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.low,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                child: Text(
                  data.suspended
                      ? '已释放 · 点按重新加载'
                      : (host.isEmpty ? '新标签页' : host),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 站点首字母色块（拿不到 favicon 时也不会空着）。
class _Favicon extends StatelessWidget {
  const _Favicon({required this.host, this.size = 20});

  final String host;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letter = host.isEmpty
        ? '新'
        : host.replaceFirst('www.', '').substring(0, 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.55,
          fontWeight: FontWeight.w600,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
