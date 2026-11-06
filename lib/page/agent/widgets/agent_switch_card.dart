/// Agent 内联开关卡片（实验特性 · 阶段一）
///
/// 在对话列表中把白名单内的布尔配置渲染为原生开关卡片。
/// 通过 [AgentSwitchConfigGateway] 抽象读写通道，便于注入假实现做测试；
/// 生产环境默认使用 [ConfigServiceAgentSwitchGateway]。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';

import 'package:gstore/core/agent/agent_inline_cards.dart';

/// 一次配置写入的结果。
class AgentSwitchWriteResult {
  /// 是否写入成功。
  final bool success;

  /// 失败时的可展示文案（成功时通常为 null）。
  final String? message;

  const AgentSwitchWriteResult({required this.success, this.message});

  /// 成功结果。
  const AgentSwitchWriteResult.success()
      : success = true,
        message = null;

  /// 失败结果（可携带失败原因）。
  const AgentSwitchWriteResult.failure([this.message]) : success = false;
}

/// 开关卡片的配置读写网关。
///
/// 抽象出读写与监听，使卡片无需直接依赖 [ConfigService]，方便测试注入。
abstract class AgentSwitchConfigGateway {
  /// 读取布尔配置；未知或类型不符时返回 null。
  Future<bool?> read(String key);

  /// 写入布尔配置。
  Future<AgentSwitchWriteResult> write(String key, bool value);

  /// 监听配置变化；非布尔值（如 clear）以 null 表示。
  Stream<bool?> watch(String key);
}

/// 基于 [ConfigService] 的生产网关实现。
class ConfigServiceAgentSwitchGateway implements AgentSwitchConfigGateway {
  const ConfigServiceAgentSwitchGateway();

  @override
  Future<bool?> read(String key) => ConfigService.instance.getT<bool>(key);

  @override
  Future<AgentSwitchWriteResult> write(String key, bool value) async {
    final result = await ConfigService.instance.set(
      key,
      value,
      source: ConfigChangeSource.user,
    );
    return result.success
        ? const AgentSwitchWriteResult.success()
        : AgentSwitchWriteResult.failure(result.message);
  }

  @override
  Stream<bool?> watch(String key) async* {
    // 走全局广播流，而不是每个卡片各自创建一条 per-key FFI 流：
    // 同一 key 的多张历史卡片都能收到变更，避免只有触发写入的那张更新。
    await ConfigService.instance.ensureReady();
    yield* ConfigService.instance.onChange
        .where((event) => event.key == key)
        .map((event) => event.newValue is bool ? event.newValue as bool : null);
  }
}

/// 内联开关卡片。
///
/// 初始值优先取自网关；读取完成前开关禁用，并以注册表默认值兜底。
/// 切换采用乐观更新：先本地生效，写入失败再回滚并提示。
class AgentSwitchCard extends StatefulWidget {
  /// 卡片规格（来自 [AgentInlineCards]）。
  final AgentInlineSwitchSpec spec;

  /// 配置读写网关；为 null 时使用 [ConfigServiceAgentSwitchGateway]。
  final AgentSwitchConfigGateway? gateway;

  /// 点击标题区域查看详情；为 null 时不显示详情入口。
  final VoidCallback? onShowDetail;

  const AgentSwitchCard({
    super.key,
    required this.spec,
    this.gateway,
    this.onShowDetail,
  });

  @override
  State<AgentSwitchCard> createState() => _AgentSwitchCardState();
}

class _AgentSwitchCardState extends State<AgentSwitchCard> {
  StreamSubscription<bool?>? _subscription;
  bool? _value;
  bool _loading = true;
  bool _saving = false;

  AgentSwitchConfigGateway get _gateway =>
      widget.gateway ?? const ConfigServiceAgentSwitchGateway();

  /// 从配置注册表读取该项的默认值；未注册时兜底为 false。
  bool get _defaultValue {
    for (final entry in ConfigRegistry.entries) {
      if (entry.key == widget.spec.configKey) {
        return entry.defaultValue == true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant AgentSwitchCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = oldWidget.spec.configKey != widget.spec.configKey;
    final gatewayChanged = oldWidget.gateway != widget.gateway;
    if (keyChanged || gatewayChanged) {
      _subscription?.cancel();
      _subscription = null;
      _loading = true;
      _saving = false;
      _value = null;
      _bind();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// 订阅变化并读取当前值。
  void _bind() {
    _subscription = _gateway.watch(widget.spec.configKey).listen((value) {
      if (!mounted) return;
      if (value is bool) {
        setState(() {
          _value = value;
          _loading = false;
        });
      } else {
        _load();
      }
    });
    _load();
  }

  /// 读取当前值；失败或以 null 返回时回退到注册表默认值。
  ///
  /// 读取期间配置 key 可能变化，故在 await 前捕获 key，并在回写前校验，
  /// 避免旧请求覆盖新卡片的状态。读取失败不弹提示，默认值即可继续操作。
  Future<void> _load() async {
    final key = widget.spec.configKey;
    try {
      final value = await _gateway.read(key);
      if (!mounted || key != widget.spec.configKey) return;
      setState(() {
        _value = value ?? _defaultValue;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || key != widget.spec.configKey) return;
      setState(() {
        _value = _defaultValue;
        _loading = false;
      });
    }
  }

  /// 乐观切换：先本地生效，写入失败或异常时回滚。
  Future<void> _toggle(bool value) async {
    if (_loading || _saving) return;
    final previous = _value ?? _defaultValue;
    setState(() {
      _value = value;
      _saving = true;
    });
    try {
      final result = await _gateway.write(widget.spec.configKey, value);
      if (!mounted) return;
      if (result.success) {
        setState(() => _saving = false);
      } else {
        setState(() {
          _value = previous;
          _saving = false;
        });
        AppDialogs.showError(result.message ?? '设置失败');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _value = previous;
        _saving = false;
      });
      AppDialogs.showError('设置失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onShowDetail,
              child: Row(
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.spec.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          widget.spec.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onShowDetail != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 20,
            height: 20,
            child: _saving
                ? const AppLoading(size: AppLoadingSize.small)
                : null,
          ),
          const SizedBox(width: AppSpacing.xs),
          Switch(
            value: _value ?? _defaultValue,
            onChanged: (_loading || _saving) ? null : _toggle,
          ),
        ],
      ),
    );
  }
}
