// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';

/// 字体大小调节（Android `textZoom`）。拖动即生效，关闭弹层保留最后值。
Future<void> showWebFontSizeSheet(
  BuildContext context, {
  required int current,
  required ValueChanged<int> onChanged,
}) {
  return AppSheet.show<void>(
    context: context,
    title: '字体大小',
    icon: const Icon(TablerIcons.typography),
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
    content: _FontSizeContent(current: current, onChanged: onChanged),
  );
}

class _FontSizeContent extends StatefulWidget {
  const _FontSizeContent({required this.current, required this.onChanged});

  final int current;
  final ValueChanged<int> onChanged;

  @override
  State<_FontSizeContent> createState() => _FontSizeContentState();
}

class _FontSizeContentState extends State<_FontSizeContent> {
  static const int _min = 70;
  static const int _max = 200;
  static const int _step = 10;

  late int _value = widget.current.clamp(_min, _max);

  void _apply(int next) {
    final value = next.clamp(_min, _max);
    if (value == _value) return;
    setState(() => _value = value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: '减小',
              icon: const Icon(TablerIcons.minus),
              onPressed: _value <= _min ? null : () => _apply(_value - _step),
            ),
            SizedBox(
              width: 96,
              child: Text(
                '$_value%',
                textAlign: TextAlign.center,
                style: text.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '增大',
              icon: const Icon(TablerIcons.plus),
              onPressed: _value >= _max ? null : () => _apply(_value + _step),
            ),
          ],
        ),
        Text(
          '只影响网页正文，不影响 App 界面',
          style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}

/// 页面源码（当前 DOM 的 outerHTML），可复制。
Future<void> showWebSourceSheet(
  BuildContext context, {
  required String html,
  required String url,
}) {
  final trimmed = html.length > 200000
      ? '${html.substring(0, 200000)}\n\n…（已截断，共 ${html.length} 字符）'
      : html;
  return AppSheet.show<void>(
    context: context,
    title: '页面源码',
    subtitle: url,
    icon: const Icon(TablerIcons.code),
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    actions: [
      TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: trimmed));
          AppDialogs.showSuccess('源码已复制');
        },
        icon: const Icon(TablerIcons.copy, size: 16),
        label: const Text('复制'),
      ),
    ],
    content: Container(
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allMD,
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          trimmed,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    ),
  );
}

/// 页面信息：标题 / 地址 / 证书。
Future<void> showWebInfoSheet(
  BuildContext context, {
  required String title,
  required String url,
  SslCertificate? certificate,
}) {
  final scheme = Theme.of(context).colorScheme;
  final text = Theme.of(context).textTheme;
  Widget row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                label,
                style: text.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(value, style: text.bodySmall),
            ),
          ],
        ),
      );

  return AppSheet.show<void>(
    context: context,
    title: '页面信息',
    icon: const Icon(TablerIcons.info_circle),
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row('标题', title.isEmpty ? '(无标题)' : title),
        row('地址', url),
        if (certificate != null) ...[
          row('颁发给', certificate.issuedTo?.CName ?? '-'),
          row('颁发者', certificate.issuedBy?.CName ?? '-'),
          row('有效期至', _formatDate(certificate.validNotAfterDate)),
        ] else
          row('证书', '非 https 页面'),
      ],
    ),
  );
}

String _formatDate(DateTime? date) {
  if (date == null) return '-';
  final local = date.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 资源列表（图片/音视频/附件链接），点条目打开，右侧按钮复制。
Future<void> showWebResourcesSheet(
  BuildContext context, {
  required List<String> urls,
  required ValueChanged<String> onOpen,
}) {
  return AppSheet.show<void>(
    context: context,
    title: '资源嗅探',
    subtitle: urls.isEmpty ? null : '共 ${urls.length} 个地址',
    icon: const Icon(TablerIcons.photo_search),
    scrollable: false,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
    content: urls.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: Text(
              '当前页面没有可识别的资源',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        : Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (final url in urls)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(TablerIcons.photo, size: 18),
                    title: Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      tooltip: '复制地址',
                      icon: const Icon(TablerIcons.copy, size: 18),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        AppDialogs.showSuccess('已复制资源地址');
                      },
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpen(url);
                    },
                  ),
              ],
            ),
          ),
  );
}
