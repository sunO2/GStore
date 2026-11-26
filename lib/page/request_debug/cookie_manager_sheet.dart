/// 「请求调试」Cookie jar 管理弹层（plan todo 2）。
///
/// 按 host 列出 [DebugCookieJar] 中的 cookie，支持按 host 清除、全部清除与
/// 手动新增。全部经**统一底部弹层系统**（[AppSheet] / [AppSheetScaffold]）
/// 呈现，颜色 / 字号取主题令牌，符合 `AGENTS.md` 设计系统约束。
///
/// **统一 Cookie 层**：jar 生产实例由 [UnifiedCookieJar] 提供，Cookie 会
/// 持久化到安全存储，并与 Android WebView 原生 Cookie 双向同步。清除操作
/// 会同时清理 WebView 对应登录态（全部清除会清空 WebView Cookie）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';

/// Cookie jar 管理弹层。
class CookieManagerSheet extends StatefulWidget {
  const CookieManagerSheet({super.key, required this.jar});

  /// 待管理的 jar（由调用方持有，变更就地进行）。
  final DebugCookieJar jar;

  /// 以统一底部弹层打开管理器（先加载持久化 Cookie）。
  static Future<void> show(
    BuildContext context, {
    required DebugCookieJar jar,
  }) async {
    await jar.ensureLoaded();
    if (!context.mounted) return;
    await AppSheet.showCustom<void>(
      context: context,
      builder: (_) => CookieManagerSheet(jar: jar),
    );
  }

  @override
  State<CookieManagerSheet> createState() => _CookieManagerSheetState();
}

class _CookieManagerSheetState extends State<CookieManagerSheet> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _value = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _clearAll() async {
    if (widget.jar.hasWebViewBridge) {
      final ok = await AppDialogs.showConfirmSheet(
        title: '清除全部 Cookie',
        message: '将同时清除 WebView 登录态（所有站点），并删除持久化 Cookie。',
        confirmText: '清除',
        isDangerous: true,
      );
      if (ok != true || !mounted) return;
    }
    await widget.jar.clearAllCookies(includeWebView: true);
    if (!mounted) return;
    setState(() => _error = null);
  }

  Future<void> _clearHost(String host) async {
    await widget.jar.clearHostCookies(host, includeWebView: true);
    if (!mounted) return;
    setState(() => _error = null);
  }

  Future<void> _add() async {
    final host = _host.text.trim();
    final name = _name.text.trim();
    final value = _value.text;
    if (host.isEmpty || name.isEmpty) {
      setState(() => _error = 'Host 与 Cookie 名不能为空');
      return;
    }
    final uri = Uri.tryParse('https://$host/');
    if (uri == null || uri.host.isEmpty) {
      setState(() => _error = 'Host 格式无效');
      return;
    }
    // 走标准 Set-Cookie 解析路径，复用 domain/path 校验；同时持久化并同步
    // 到 WebView，避免只在请求调试里生效。
    await widget.jar.captureResponse(
      uri,
      <String, String>{'set-cookie': '$name=$value; Path=/'},
    );
    if (!mounted) return;
    setState(() {
      _host.clear();
      _name.clear();
      _value.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final snapshot = widget.jar.snapshot();
    return AppSheetScaffold(
      title: 'Cookie 管理',
      subtitle: '与 WebView 登录态同步，持久化到安全存储',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (snapshot.isEmpty)
            Padding(
              padding: AppSpacing.onlyVerticalMD,
              child: Text(
                '暂无 Cookie',
                key: const Key('cookie-manager-empty'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final entry in snapshot.entries) ...[
              Row(
                key: Key('cookie-manager-host-${entry.key}'),
                children: [
                  Expanded(
                    child: Text(
                      entry.key,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('cookie-manager-clear-${entry.key}'),
                    tooltip: '清除该域 Cookie',
                    icon: const Icon(TablerIcons.trash),
                    onPressed: () => _clearHost(entry.key),
                  ),
                ],
              ),
              for (final cookie in entry.value)
                Padding(
                  key: Key('cookie-manager-item-${entry.key}-${cookie.name}'),
                  padding: AppSpacing.onlyVerticalXS,
                  child: Text(
                    '${cookie.name} = ${cookie.value}',
                    style: AppTypography.code,
                  ),
                ),
              const Divider(height: 1),
            ],
          const SizedBox(height: AppSpacing.md),
          Text('新增 Cookie', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const Key('cookie-manager-add-host'),
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: 'example.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const Key('cookie-manager-add-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Cookie 名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const Key('cookie-manager-add-value'),
            controller: _value,
            decoration: const InputDecoration(
              labelText: '值',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: AppSpacing.onlyTopXS,
              child: Text(
                _error!,
                key: const Key('cookie-manager-add-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('cookie-manager-add-confirm'),
          onPressed: _add,
          child: const Text('添加'),
        ),
        TextButton(
          key: const Key('cookie-manager-clear-all'),
          onPressed: snapshot.isEmpty ? null : _clearAll,
          child: const Text('全部清除'),
        ),
        FilledButton(
          key: const Key('cookie-manager-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
