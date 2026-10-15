/// 「节点弹层列表 / 宫格排布」持久化接缝（page 层）。
///
/// 节点弹层的排布模式只存在于当前打开的实例，弹层关闭后即销毁；本接口把用户的
/// 选择固化下来，重开弹层 / 重启应用时回显。
///
/// 生产实现沿用统一 [ConfigStore]（`proxy_sheet_view_mode`，值为 `grid`|`list`），
/// 测试注入内存实现即可。所有读写 best-effort：`ConfigStore` 未初始化 / 存储异常
/// 时读返回 `null`、写静默忽略，绝不因持久化失败而崩溃页面。
library;

import 'package:gstore/core/config/config_store.dart';

/// 节点弹层排布模式的读取 + 写入接缝。
abstract class ProxySheetViewModeStore {
  /// 读取上次选择的排布模式；`true` = 宫格，`false` = 列表，
  /// 未设置 / 读取失败返回 `null`。
  Future<bool?> readGridMode();

  /// 持久化排布模式（`true` = 宫格，`false` = 列表）。
  Future<void> writeGridMode(bool grid);
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
class ConfigStoreProxySheetViewModeStore implements ProxySheetViewModeStore {
  const ConfigStoreProxySheetViewModeStore();

  /// 持久化 key（沿用代理设置页 `proxy_*` 命名）。
  static const String key = 'proxy_sheet_view_mode';

  @override
  Future<bool?> readGridMode() async {
    try {
      final String? value = await ConfigStore.instance.readString(key);
      if (value == null || value.isEmpty) return null;
      return value == 'grid';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeGridMode(bool grid) async {
    try {
      await ConfigStore.instance.writeString(key, grid ? 'grid' : 'list');
    } catch (_) {
      // 持久化失败不阻断切换（本次会话仍以内存选择为准）。
    }
  }
}
