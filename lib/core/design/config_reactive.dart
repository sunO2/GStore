import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:gstore/core/config/config_service.dart';

/// 配置联动重建组件。
///
/// 监听 [ConfigService.onChange] 中指定的配置 key；当其中任意一个 key 发生
/// 外部变更（Agent / configManager / 备份恢复等非本组件触发的写入）时，本组件
/// 会重建其子树。借助 [KeyedSubtree] 更换 key，子树的 State 会被销毁并重新
/// 创建，从而让像设置页开关/滑杆这类「只在 `initState` 读一次配置」的
/// Stateful 组件能够重新读取最新值。
///
/// 典型用法：
/// ```dart
/// ConfigReactive(
///   keys: const <String>{ConfigKeys.downloadWifiOnly},
///   child: const _WifiOnlyDownloadTile(),
/// )
/// ```
///
/// 注意：本组件只负责「配置变化 → 子树重建」，不改变子组件自身的内部状态
/// 管理逻辑；子树在两次重建之间仍然保持自己的内部 State。
class ConfigReactive extends StatefulWidget {
  /// 需要监听的配置 key 集合（wire key，如 `download.wifi_only`）。
  final Set<String> keys;

  /// 需要在其 key 变化时重建的子树。
  final Widget child;

  const ConfigReactive({
    super.key,
    required this.keys,
    required this.child,
  });

  @override
  State<ConfigReactive> createState() => _ConfigReactiveState();
}

class _ConfigReactiveState extends State<ConfigReactive> {
  /// 配置变更事件订阅。
  StreamSubscription<ConfigChangeEvent>? _sub;

  /// 30ms 防抖计时器：合并短时间内的多次配置写入，避免重复重建。
  Timer? _debounce;

  /// 重建版本号；作为 [KeyedSubtree] 的 key，变化即触发子树重建。
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ConfigReactive oldWidget) {
    super.didUpdateWidget(oldWidget);
    // key 集合发生变化时重新订阅，避免监听过期或漏掉新增 key。
    if (!setEquals(oldWidget.keys, widget.keys)) {
      _cancelSubscription();
      _subscribe();
    }
  }

  /// 订阅配置变更事件。
  void _subscribe() {
    _sub = ConfigService.instance.onChange.listen(
      _onConfigChanged,
      onError: (Object error, StackTrace stackTrace) {
        // 流错误不应中断 UI：仅记录日志，保持当前子树不变。
        debugPrint('ConfigReactive: 配置变更流错误: $error');
      },
    );
  }

  /// 处理配置变更事件。
  void _onConfigChanged(ConfigChangeEvent event) {
    // 忽略不关心的 key。
    if (!widget.keys.contains(event.key)) return;
    // 防抖：短时间内的多次写入只在最后一次后触发一次重建。
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 30), () {
      if (!mounted) return;
      setState(() => _revision++);
    });
  }

  /// 取消事件订阅与防抖计时器。
  void _cancelSubscription() {
    _debounce?.cancel();
    _debounce = null;
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _cancelSubscription();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 版本号变化 → KeyedSubtree 使用新 key → 子树 State 重建。
    return KeyedSubtree(
      key: ValueKey<int>(_revision),
      child: widget.child,
    );
  }
}
