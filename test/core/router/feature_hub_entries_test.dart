import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/page/home/tab/feature_hub/view.dart';

/// scene-to-gstore-parity todo 10：功能网格入口**全量枚举**无死链门禁。
///
/// 本测试**遍历 `kHubGroups` 的每一个条目**，断言其 `route` 已注册于真实
/// `appRouter`（与 `test/core/router/parity_routes_test.dart` 同款：仅在路由
/// 配置层断言，**不 pump 任何页面**，避免 Riverpod / FFI / 平台插件依赖）。
///
/// 关键门禁：遍历计数必须与条目总数相等（防止空集合/提前 return 导致的
/// **静默跳过**）；任何指向未注册路由的条目都会让测试失败（无死链）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 真实 `appRouter` 顶层注册路径集合。
  Set<String> registeredPaths() => appRouter.configuration.routes
      .whereType<GoRoute>()
      .map((r) => r.path)
      .toSet();

  /// 全部条目（跨 5 组展平）。
  List<HubEntry> allEntries() =>
      [for (final g in kHubGroups) ...g.entries];

  test('① 恰好 5 组，且组 id / 标题为 7→5 映射结果', () {
    expect(kHubGroups.length, 5, reason: 'Scene 7 组折叠为 5 组');

    final ids = kHubGroups.map((g) => g.id).toList();
    expect(ids.toSet().length, ids.length, reason: '组 id 不得重复');
    expect(
      ids.toSet(),
      {'scene', 'performance', 'battery', 'advanced', 'auxiliary'},
      reason: '5 组 id 应与 7→5 映射一致',
    );
    expect(
      kHubGroups.map((g) => g.title).toList(),
      ['场景模式', '设备性能', '充电耗电', '进阶功能', '辅助'],
    );
  });

  test('② 每组非空，条目 id 全局唯一（无重复入口）', () {
    for (final g in kHubGroups) {
      expect(g.entries, isNotEmpty, reason: '组 ${g.id} 不应为空');
    }

    final entryIds = allEntries().map((e) => e.id).toList();
    expect(entryIds.toSet().length, entryIds.length,
        reason: '条目 id 全局唯一：$entryIds');
  });

  test('③ 枚举全部条目：每个 route 均注册于真实 appRouter（无死链、无静默跳过）', () {
    final registered = registeredPaths();
    final entries = allEntries();

    var checked = 0;
    for (final e in entries) {
      checked++;

      expect(e.id, isNotEmpty, reason: '条目 id 不得为空');
      expect(e.label, isNotEmpty, reason: '条目 ${e.id} 标签不得为空');
      expect(e.route, isNotEmpty, reason: '条目 ${e.id} 路由不得为空');
      expect(registered.contains(e.route), isTrue,
          reason: '条目 ${e.id} 指向未注册路由 ${e.route}（死链）');
    }

    // 遍历计数 == 条目总数：杜绝「空集合 / 提前退出」造成的静默通过。
    expect(checked, entries.length, reason: '必须遍历到全部条目');
    expect(entries.length, greaterThanOrEqualTo(14),
        reason: '至少覆盖 todo 6 的首轮条目（此处应为全量枚举）');
  });

  test('④ 未知路由确不被解析（未知 route 会失败，不静默通过）', () {
    final registered = registeredPaths();
    expect(registered.contains('/GStore/__does_not_exist__'), isFalse);
    expect(registered.contains(''), isFalse);
  });

  test('⑤ 丢弃组不入网格：Xposed功能 / 交流反馈', () {
    final ids = allEntries().map((e) => e.id).toList();
    final routes = allEntries().map((e) => e.route).toList();

    // Scene 组 5 Xposed功能：GStore 无等价物 → 整组丢弃。
    expect(ids.any((id) => id.toLowerCase().contains('xposed')), isFalse);
    expect(routes.any((r) => r.toLowerCase().contains('xposed')), isFalse);
    // Scene 组 7 交流反馈：非功能组 → 移「设置」tab，不进网格。
    expect(ids.any((id) => id.toLowerCase().contains('feedback')), isFalse);
  });

  test('⑥ 全量覆盖：GStore 面向用户的功能目的地均在网格（关键路由存在）', () {
    final routes = allEntries().map((e) => e.route).toSet();

    // todo 6 首轮 + todo 10 补全的既有路由（均须出现）。
    const expected = <String>[
      // 场景模式 / 设备性能 / 充电耗电
      '/GStore/perfProfiles',
      '/GStore/appList',
      '/GStore/discovery',
      '/GStore/perfMonitor',
      // 进阶功能
      '/GStore/backup',
      '/GStore/moduleManage',
      '/GStore/itTools',
      '/GStore/installedApps',
      '/GStore/appSnapshotList',
      '/GStore/fdroidRepo',
      '/GStore/cacheManage',
      '/GStore/databaseManage',
      // 辅助
      '/GStore/agent',
      '/GStore/settings',
      '/GStore/themeSettings',
      '/GStore/logViewer',
      '/GStore/proxy',
      '/GStore/requestDebug',
      '/GStore/qrTool',
      '/GStore/licenses',
    ];
    for (final path in expected) {
      expect(routes.contains(path), isTrue,
          reason: '功能目的地 $path 未落入 5 组之一');
    }
  });
}
