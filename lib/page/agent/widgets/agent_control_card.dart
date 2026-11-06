/// Agent 内联控件卡片（滑块 / 分段选择 / 统一分发）
///
/// 在对话列表中把白名单内的数值与枚举配置渲染为原生卡片。
/// 通过 [AgentValueConfigGateway] 抽象读写与监听通道，便于注入假实现做测试；
/// 生产环境默认使用 [ConfigServiceAgentValueGateway]。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gstore/core/agent/agent_inline_cards.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_state_store.dart';

import 'agent_switch_card.dart';

/// 一次通用配置写入的结果。
class AgentValueWriteResult {
  /// 是否写入成功。
  final bool success;

  /// 失败时的可展示文案（成功时通常为 null）。
  final String? message;

  const AgentValueWriteResult({required this.success, this.message});

  /// 成功结果。
  const AgentValueWriteResult.success()
      : success = true,
        message = null;

  /// 失败结果（可携带失败原因）。
  const AgentValueWriteResult.failure([this.message]) : success = false;
}

/// 通用配置读写网关。
///
/// 抽象出读写与监听，使卡片无需直接依赖 [ConfigService]，方便测试注入。
abstract class AgentValueConfigGateway {
  /// 读取配置当前值；未知或类型不符时返回 null。
  Future<Object?> read(String key);

  /// 写入配置。
  Future<AgentValueWriteResult> write(String key, Object? value);

  /// 监听配置变化；清除配置时以 null 表示。
  Stream<Object?> watch(String key);
}

/// 基于 [ConfigService] 的生产网关实现。
class ConfigServiceAgentValueGateway implements AgentValueConfigGateway {
  const ConfigServiceAgentValueGateway();

  @override
  Future<Object?> read(String key) => ConfigService.instance.get(key);

  @override
  Future<AgentValueWriteResult> write(String key, Object? value) async {
    final result = await ConfigService.instance.set(
      key,
      value,
      source: ConfigChangeSource.user,
    );
    return result.success
        ? const AgentValueWriteResult.success()
        : AgentValueWriteResult.failure(result.message);
  }

  @override
  Stream<Object?> watch(String key) async* {
    // 走全局广播流，而不是每个卡片各自创建一条 per-key FFI 流：
    // 同一 key 的多张历史卡片都能收到变更，避免只有触发写入的那张更新。
    await ConfigService.instance.ensureReady();
    yield* ConfigService.instance.onChange
        .where((event) => event.key == key)
        .map((event) => event.newValue);
  }
}

/// 主题模式的权威网关：读写与监听都走共享 [ThemeStateStore]，
/// 写入既持久化又立即更新全局主题状态（不依赖 onChange 回流）。
class ThemeModeConfigGateway implements AgentValueConfigGateway {
  const ThemeModeConfigGateway();

  @override
  Future<Object?> read(String key) => ConfigService.instance.getT<int>(key);

  @override
  Future<AgentValueWriteResult> write(String key, Object? value) async {
    final index = value is int ? value : int.tryParse('$value') ?? 0;
    final safe = index.clamp(0, AppThemeMode.values.length - 1);
    await ThemeStateStore.instance.setThemeMode(AppThemeMode.values[safe]);
    return const AgentValueWriteResult.success();
  }

  @override
  Stream<Object?> watch(String key) {
    final store = ThemeStateStore.instance;
    late StreamController<Object?> controller;
    void listener() {
      if (!controller.isClosed) {
        controller.add(store.state.value.mode.index);
      }
    }

    controller = StreamController<Object?>(
      onListen: () {
        store.state.addListener(listener);
        listener();
      },
      onCancel: () => store.state.removeListener(listener),
    );
    return controller.stream;
  }
}

/// 内联控件统一分发。
///
/// 按 [AgentInlineSwitchSpec.kind] 选择开关、滑块或分段选择卡片。
class AgentControlCard extends StatelessWidget {
  /// 卡片规格（来自 [AgentInlineCards]）。
  final AgentInlineSwitchSpec spec;

  /// 配置读写网关；为 null 时滑块/分段卡片使用生产网关。
  final AgentValueConfigGateway? gateway;

  /// 点击标题区域查看详情；为 null 时不显示详情入口。
  final VoidCallback? onShowDetail;

  const AgentControlCard({
    super.key,
    required this.spec,
    this.gateway,
    this.onShowDetail,
  });

  @override
  Widget build(BuildContext context) {
    AgentValueConfigGateway? effectiveGateway = gateway;
    if (spec.kind == AgentInlineControlKind.segmented &&
        spec.configKey == ConfigKeys.themeMode &&
        gateway == null) {
      effectiveGateway = const ThemeModeConfigGateway();
    }

    switch (spec.kind) {
      case AgentInlineControlKind.switchControl:
        return AgentSwitchCard(
          spec: spec,
          onShowDetail: onShowDetail,
        );
      case AgentInlineControlKind.slider:
        return AgentSliderCard(
          spec: spec,
          gateway: effectiveGateway,
          onShowDetail: onShowDetail,
        );
      case AgentInlineControlKind.segmented:
        return AgentSegmentedCard(
          spec: spec,
          gateway: effectiveGateway,
          onShowDetail: onShowDetail,
        );
    }
  }
}

/// 内联滑块卡片。
///
/// 拖动时只更新本地状态以保证顺滑，松手（`onChangeEnd`）才真正写入配置，
/// 避免连续拖动产生大量配置写入。写入采用乐观更新，失败回滚并提示。
class AgentSliderCard extends StatefulWidget {
  /// 卡片规格（来自 [AgentInlineCards]）。
  final AgentInlineSwitchSpec spec;

  /// 配置读写网关；为 null 时使用 [ConfigServiceAgentValueGateway]。
  final AgentValueConfigGateway? gateway;

  /// 点击标题区域查看详情；为 null 时不显示详情入口。
  final VoidCallback? onShowDetail;

  const AgentSliderCard({
    super.key,
    required this.spec,
    this.gateway,
    this.onShowDetail,
  });

  @override
  State<AgentSliderCard> createState() => _AgentSliderCardState();
}

class _AgentSliderCardState extends State<AgentSliderCard> {
  StreamSubscription<Object?>? _subscription;
  num? _value;
  num? _dragStartValue;
  bool _loading = true;
  bool _saving = false;

  AgentValueConfigGateway get _gateway =>
      widget.gateway ?? const ConfigServiceAgentValueGateway();

  double get _min => (widget.spec.min ?? 0).toDouble();

  double get _max => (widget.spec.max ?? 100).toDouble();

  num get _fallback => widget.spec.min ?? 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant AgentSliderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = oldWidget.spec.configKey != widget.spec.configKey;
    final gatewayChanged = oldWidget.gateway != widget.gateway;
    if (keyChanged || gatewayChanged) {
      _subscription?.cancel();
      _subscription = null;
      _loading = true;
      _saving = false;
      _value = null;
      _dragStartValue = null;
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
    _subscription = _gateway.watch(widget.spec.configKey).listen(
      (value) {
        if (!mounted) return;
        final numeric = _asNum(value);
        if (numeric != null) {
          setState(() {
            _value = numeric;
            _loading = false;
          });
        } else {
          _load();
        }
      },
      onError: (_) {
        if (mounted) _load();
      },
    );
    _load();
  }

  /// 读取当前值；失败或以非数值返回时回退到规格最小值。
  ///
  /// 读取期间配置 key 可能变化，故在 await 前捕获 key，并在回写前校验，
  /// 避免旧请求覆盖新卡片的状态。
  Future<void> _load() async {
    final key = widget.spec.configKey;
    try {
      final value = await _gateway.read(key);
      if (!mounted || key != widget.spec.configKey) return;
      setState(() {
        _value = _asNum(value) ?? _fallback;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || key != widget.spec.configKey) return;
      setState(() {
        _value = _fallback;
        _loading = false;
      });
    }
  }

  /// 宽松地把配置值转为 num（支持数值字符串）。
  num? _asNum(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  /// 开始拖动时记录旧值，供写入失败回滚。
  void _handleStart(double value) {
    _dragStartValue = _value ?? _fallback;
  }

  /// 拖动过程中只更新本地状态，不写配置。
  void _handleChanged(double value) {
    _dragStartValue ??= _value ?? _fallback;
    setState(() => _value = value);
  }

  /// 松手时按配置类型写入；失败回滚到拖动前的值。
  Future<void> _handleChangeEnd(double value) async {
    if (_loading || _saving) return;
    final previous = _dragStartValue ?? _value ?? _fallback;
    _dragStartValue = null;

    final Object writeValue = switch (widget.spec.valueType) {
      'int' => value.round(),
      'double' => value.toDouble(),
      _ => value,
    };

    setState(() {
      _value = value;
      _saving = true;
    });

    try {
      final result = await _gateway.write(widget.spec.configKey, writeValue);
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

  /// 展示用文本，整数类型不显示多余的小数位。
  String _displayValue(num value) {
    final text = widget.spec.valueType == 'int' || value % 1 == 0
        ? value.round().toString()
        : value.toString();
    return '$text${widget.spec.unit ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    final step = (widget.spec.step ?? 1).toDouble();
    final rawDivisions = step > 0 ? ((_max - _min) / step).round() : 0;
    final divisions = rawDivisions > 0 ? rawDivisions : null;
    final current =
        (_value ?? _fallback).toDouble().clamp(_min, _max).toDouble();
    final display = _displayValue(current);
    final disabled = _loading || _saving;

    return _cardSurface(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ControlHeader(
            title: widget.spec.title,
            subtitle: widget.spec.subtitle,
            saving: _saving,
            onShowDetail: widget.onShowDetail,
            trailing: Text(
              display,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Slider(
            value: current,
            min: _min,
            max: _max,
            divisions: divisions,
            label: display,
            onChangeStart: disabled ? null : _handleStart,
            onChanged: disabled ? null : _handleChanged,
            onChangeEnd: disabled ? null : _handleChangeEnd,
          ),
        ],
      ),
    );
  }
}

/// 内联分段选择卡片。
///
/// 把枚举配置渲染为紧凑的 [SegmentedButton]；选择采用乐观更新，
/// 写入失败回滚并提示，外部变更通过网关监听同步。
class AgentSegmentedCard extends StatefulWidget {
  /// 卡片规格（来自 [AgentInlineCards]）。
  final AgentInlineSwitchSpec spec;

  /// 配置读写网关；为 null 时使用 [ConfigServiceAgentValueGateway]。
  final AgentValueConfigGateway? gateway;

  /// 点击标题区域查看详情；为 null 时不显示详情入口。
  final VoidCallback? onShowDetail;

  const AgentSegmentedCard({
    super.key,
    required this.spec,
    this.gateway,
    this.onShowDetail,
  });

  @override
  State<AgentSegmentedCard> createState() => _AgentSegmentedCardState();
}

class _AgentSegmentedCardState extends State<AgentSegmentedCard> {
  StreamSubscription<Object?>? _subscription;
  String? _selected;
  bool _loading = true;
  bool _saving = false;

  AgentValueConfigGateway get _gateway =>
      widget.gateway ?? const ConfigServiceAgentValueGateway();

  List<String> get _enumValues =>
      widget.spec.enumValues ?? const <String>[];

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant AgentSegmentedCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = oldWidget.spec.configKey != widget.spec.configKey;
    final gatewayChanged = oldWidget.gateway != widget.gateway;
    if (keyChanged || gatewayChanged) {
      _subscription?.cancel();
      _subscription = null;
      _loading = true;
      _saving = false;
      _selected = null;
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
    _subscription = _gateway.watch(widget.spec.configKey).listen(
      (value) {
        if (!mounted) return;
        if (value == null) {
          _load();
          return;
        }
        final normalized = _normalize(value);
        if (normalized != null) {
          setState(() {
            _selected = normalized;
            _loading = false;
          });
        }
      },
      onError: (_) {
        if (mounted) _load();
      },
    );
    _load();
  }

  /// 读取当前值并归一化为字符串。
  ///
  /// `num` 转字符串，使 `theme.mode` 的 0/1/2 能匹配 '0'/'1'/'2'；
  /// 空值回退到第一个枚举值。
  Future<void> _load() async {
    final key = widget.spec.configKey;
    final fallback = _enumValues.isEmpty ? null : _enumValues.first;
    try {
      final value = await _gateway.read(key);
      if (!mounted || key != widget.spec.configKey) return;
      setState(() {
        _selected = _normalize(value) ?? fallback;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || key != widget.spec.configKey) return;
      setState(() {
        _selected = fallback;
        _loading = false;
      });
    }
  }

  /// 把配置值归一化为枚举字符串。
  String? _normalize(Object? value) {
    if (value is num) return value.toString();
    if (value is String) return value;
    return _enumValues.isEmpty ? null : _enumValues.first;
  }

  /// 选择时按配置类型写入；失败回滚到之前的选择。
  Future<void> _select(String value) async {
    if (_loading || _saving || value == _selected) return;
    final previous = _selected;

    final Object writeValue = switch (widget.spec.valueType) {
      'int' => int.tryParse(value) ?? 0,
      'double' => double.tryParse(value) ?? 0,
      _ => value,
    };

    setState(() {
      _selected = value;
      _saving = true;
    });

    try {
      final result = await _gateway.write(widget.spec.configKey, writeValue);
      if (!mounted) return;
      if (result.success) {
        setState(() => _saving = false);
      } else {
        setState(() {
          _selected = previous;
          _saving = false;
        });
        AppDialogs.showError(result.message ?? '设置失败');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selected = previous;
        _saving = false;
      });
      AppDialogs.showError('设置失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = _enumValues;
    final disabled = _loading || _saving;

    final Widget content;
    if (values.isEmpty) {
      content = Text(
        '暂无可选项',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    } else {
      final selected = _selected != null && values.contains(_selected)
          ? _selected!
          : values.first;
      content = SegmentedButton<String>(
        segments: values
            .map(
              (value) => ButtonSegment<String>(
                value: value,
                label: Text(widget.spec.enumLabels?[value] ?? value),
              ),
            )
            .toList(growable: false),
        selected: <String>{selected},
        onSelectionChanged: disabled
            ? null
            : (selection) {
                if (selection.isEmpty) return;
                _select(selection.first);
              },
        showSelectedIcon: false,
        multiSelectionEnabled: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return _cardSurface(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ControlHeader(
            title: widget.spec.title,
            subtitle: widget.spec.subtitle,
            saving: _saving,
            onShowDetail: widget.onShowDetail,
          ),
          const SizedBox(height: AppSpacing.sm),
          content,
        ],
      ),
    );
  }
}

/// 统一的卡片底色 / 圆角 / 边框。
Widget _cardSurface(BuildContext context, {required Widget child}) {
  final scheme = Theme.of(context).colorScheme;
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
    child: child,
  );
}

/// 标题区（标题 + 副标题 + 可选尾部内容 / loading / 详情入口）。
class _ControlHeader extends StatelessWidget {
  const _ControlHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
    this.saving = false,
    this.onShowDetail,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;
  final bool saving;
  final VoidCallback? onShowDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onShowDetail,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.sm),
          trailing!,
        ],
        if (saving) ...[
          const SizedBox(width: AppSpacing.xs),
          const AppLoading(size: AppLoadingSize.small),
        ],
        if (onShowDetail != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ],
    );
  }
}
