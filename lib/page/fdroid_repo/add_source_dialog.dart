import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/fdroid/FdroidRepoDeepLink.dart';

/// 添加源对话框的返回值
class AddSourceResult {
  const AddSourceResult({required this.name, required this.url, this.fingerprint});

  final String name;
  final String url;

  /// 深链里给出的仓库签名指纹（SHA-256，大写去冒号）；为空表示用户未固定
  final String? fingerprint;
}

/// 添加 F-Droid 源
///
/// 支持两种输入：
/// - 普通 URL（只给域名即可，下载时模块会自动尝试 `/fdroid/repo`）
/// - **深链** `fdroidrepos://host/path?fingerprint=<sha256>`（第三方源/独立应用私有源常用）
///
/// 粘贴深链时会自动归一化地址、取出指纹并要求用户核对——这正是 F-Droid 客户端
/// 「添加第三方源需确认指纹（TOFU）」的等价流程。
class AddSourceDialog extends StatefulWidget {
  const AddSourceDialog({super.key, this.initial});

  /// 编辑模式：带入现有源的值（name/url/fingerprint）
  final AddSourceResult? initial;

  static Future<AddSourceResult?> show(BuildContext context, {AddSourceResult? initial}) {
    return AppSheet.showCustom<AddSourceResult>(
      context: context,
      builder: (_) => AddSourceDialog(initial: initial),
    );
  }

  /// 根据地址推导默认源名称（去掉 www. 的域名）
  @visibleForTesting
  static String defaultSourceName(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// 指纹展示：每 2 个字符插一个冒号，便于与发布方公布值逐段核对
  @visibleForTesting
  static String formatFingerprint(String fp) {
    final clean = fp.replaceAll(':', '').toUpperCase();
    final buf = StringBuffer();
    for (var i = 0; i < clean.length; i += 2) {
      if (i > 0) buf.write(':');
      final end = i + 2 > clean.length ? clean.length : i + 2;
      buf.write(clean.substring(i, end));
    }
    return buf.toString();
  }

  @override
  State<AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<AddSourceDialog> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();

  /// 从深链解析出的期望指纹（大写去冒号）
  String? _fingerprint;

  /// 该指纹所属的仓库主机（换主机则指纹失效）
  String? _fingerprintHost;

  /// 归一化回写控制器时置位，避免递归触发监听器
  bool _selfEditing = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _nameController.text = init.name;
      _urlController.text = init.url;
      _fingerprint = init.fingerprint;
      _fingerprintHost = Uri.tryParse(init.url)?.host;
    }
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// 地址变化时尝试深链解析：归一化地址 + 提取指纹 + 自动填名称
  ///
  /// 注意：归一化会回写控制器，从而**再次触发本监听器**。若不加 `_selfEditing` 守卫，
  /// 第二次解析看到的是已去掉 query 的地址 → 指纹会被清成 null（实测踩过）。
  void _onUrlChanged() {
    if (_selfEditing) return;
    final text = _urlController.text.trim();
    final parsed = FdroidRepoDeepLink.parse(text);
    if (parsed == null) {
      if (_fingerprint != null) {
        setState(() {
          _fingerprint = null;
          _fingerprintHost = null;
        });
      }
      return;
    }

    final host = Uri.tryParse(parsed.url)?.host ?? '';
    // 深链带指纹 → 记录；换成别的主机 → 原指纹失效（避免张冠李戴）
    var fp = _fingerprint;
    if (parsed.fingerprint != null) {
      fp = parsed.fingerprint;
    } else if (_fingerprintHost != null && host != _fingerprintHost) {
      fp = null;
    }

    final needsUrlFix = parsed.url != text;
    final nameEmpty = _nameController.text.trim().isEmpty;
    if (!needsUrlFix && fp == _fingerprint && !nameEmpty) return;

    setState(() {
      _fingerprint = fp;
      if (fp == null) {
        _fingerprintHost = null;
      } else {
        _fingerprintHost ??= host;
      }
      if (needsUrlFix) {
        _selfEditing = true; // 本次回写不再进入本监听器
        _urlController.value = TextEditingValue(
          text: parsed.url,
          selection: TextSelection.collapsed(offset: parsed.url.length),
        );
        _selfEditing = false;
      }
      if (nameEmpty) {
        _nameController.text = AddSourceDialog.defaultSourceName(parsed.url);
      }
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      AppDialogs.showError('请填写完整信息');
      return;
    }
    final parsed = FdroidRepoDeepLink.parse(url);
    if (parsed == null) {
      AppDialogs.showError('请输入有效的仓库地址（http/https 或 fdroidrepos:// 深链）');
      return;
    }
    Navigator.of(context).pop(
      AddSourceResult(name: name, url: parsed.url, fingerprint: _fingerprint),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: '添加 F-Droid 源',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: '仓库地址',
                hintText: 'example.com 或 fdroidrepos://…?fingerprint=…',
                helperText: '只填域名即可，会自动尝试 /fdroid/repo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '源名称',
                border: OutlineInputBorder(),
              ),
            ),
            if (_fingerprint != null) ...[
              const SizedBox(height: AppSpacing.md),
              // 指纹确认区：第三方源的身份由此确定，必须让用户看到并核对
              Container(
                padding: AppSpacing.allMD,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: AppRadius.allMD,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.verified_user_outlined,
                            size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: AppSpacing.xs),
                        Text('仓库指纹（SHA-256）',
                            style: theme.textTheme.labelMedium),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    SelectableText(
                      AddSourceDialog.formatFingerprint(_fingerprint!),
                      style: AppTypography.code.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '请与仓库发布方公布的值核对；确认后该指纹随源保存',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
