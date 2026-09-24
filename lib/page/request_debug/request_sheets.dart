/// 「请求调试」集合 / 编辑器共用的**统一底部弹层**表单（plan todo 31）。
///
/// 全部经设计系统骨架 [AppSheet.showCustom] 呈现（AGENTS.md：弹层一律走统一
/// 底部弹层，禁止 `showDialog` + `AlertDialog` / `Get.defaultDialog`）。
library;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_sheet.dart';

/// 弹出单行文本输入弹层，返回确认后的去空白文本（取消 / 关闭返回 `null`）。
///
/// 用于新建集合 / 新建子文件夹 / 重命名集合。字段与确认按钮带固定 key，
/// 便于 widget 测试定位。
Future<String?> promptDebugName(
  BuildContext context, {
  required String title,
  String? subtitle,
  String hint = '名称',
  String initial = '',
}) {
  return AppSheet.showCustom<String>(
    context: context,
    builder: (_) => _NamePromptSheet(
      title: title,
      subtitle: subtitle,
      hint: hint,
      initial: initial,
    ),
  );
}

/// 弹出 cURL 导入弹层，返回用户粘贴的 cURL 文本（取消 / 关闭返回 `null`）。
Future<String?> importCurlSheet(BuildContext context) {
  return AppSheet.showCustom<String>(
    context: context,
    builder: (_) => const _CurlImportSheet(),
  );
}

class _NamePromptSheet extends StatefulWidget {
  const _NamePromptSheet({
    required this.title,
    this.subtitle,
    required this.hint,
    required this.initial,
  });

  final String title;
  final String? subtitle;
  final String hint;
  final String initial;

  @override
  State<_NamePromptSheet> createState() => _NamePromptSheetState();
}

class _NamePromptSheetState extends State<_NamePromptSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _controller.text.trim();
    Navigator.of(context).pop(value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: TextField(
        key: const Key('request-debug-prompt-field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.hint,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('request-debug-prompt-confirm'),
          onPressed: _confirm,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _CurlImportSheet extends StatefulWidget {
  const _CurlImportSheet();

  @override
  State<_CurlImportSheet> createState() => _CurlImportSheetState();
}

class _CurlImportSheetState extends State<_CurlImportSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _controller.text.trim();
    Navigator.of(context).pop(value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '导入 cURL',
      subtitle: '粘贴 curl 命令；文件引用等无法解析的选项会被明确忽略',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: TextField(
        key: const Key('request-debug-curl-field'),
        controller: _controller,
        minLines: 4,
        maxLines: 8,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: "curl -X POST https://api.example/x -d '{\"a\":1}'",
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('request-debug-curl-confirm'),
          onPressed: _confirm,
          child: const Text('导入'),
        ),
      ],
    );
  }
}
