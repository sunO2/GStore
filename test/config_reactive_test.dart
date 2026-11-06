import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/design/config_reactive.dart';

/// 仅用于统计 `initState` 次数的探测组件。
///
/// 每次 State 被重新创建（子树因 key 变化而重建）都会让 [initCount] 自增。
class _Probe extends StatefulWidget {
  const _Probe();

  /// 该组件 State 的初始化次数。
  static int initCount = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.initCount++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 初始化内存配置后端与 [ConfigService]。
  ///
  /// 注意：必须在 `testWidgets` 的 FakeAsync 区域内执行。若在 `setUp`
  /// （真实 Zone）里完成 `ensureReady`，测试内再 `await ConfigService.set`
  /// 会一直挂起。
  Future<void> initConfig() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: [
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);
    await ConfigService.instance.ensureReady();
  }

  setUp(() {
    _Probe.initCount = 0;
  });

  tearDown(() {
    _Probe.initCount = 0;
    ConfigStore.instance.resetForTest();
  });

  Widget buildApp() {
    return const MaterialApp(
      home: Scaffold(
        body: ConfigReactive(
          keys: <String>{ConfigKeys.downloadMultiSegmentEnabled},
          child: _Probe(),
        ),
      ),
    );
  }

  testWidgets('监听 key 变化时重建子树', (tester) async {
    await initConfig();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(_Probe.initCount, 1);

    // 写入被监听的配置：子树应被销毁并重建。
    await ConfigService.instance.set(
      ConfigKeys.downloadMultiSegmentEnabled,
      true,
      source: ConfigChangeSource.internal,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_Probe.initCount, 2);
  });

  testWidgets('无关 key 变化不重建子树', (tester) async {
    await initConfig();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(_Probe.initCount, 1);

    // 写入未监听的已注册配置：initState 次数应保持不变。
    await ConfigService.instance.set(
      ConfigKeys.downloadMaxRetries,
      4,
      source: ConfigChangeSource.internal,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_Probe.initCount, 1);
  });
}
