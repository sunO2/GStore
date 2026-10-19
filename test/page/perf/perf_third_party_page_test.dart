import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/page/perf/third_party_page.dart';
import 'package:gstore/page/perf/third_party_section.dart';

/// 假 Shizuku：binder 不可用、未授权，不触达平台通道。
class _FakeShizuku extends ShizukuApi {
  @override
  Future<bool?> pingBinder() async => false;

  @override
  Future<bool?> checkPermission() async => false;

  @override
  Future<bool?> requestPermission() async => false;

  @override
  Future<String?> runCommand(String command) async => null;
}

/// 假服务：绕过 `installed_apps` 平台通道（测试环境无宿主，调用会挂起）。
///
/// 返回空应用列表 + 未知 Shizuku 状态，保证页面渲染而不触碰真实 Shizuku/FFI。
class _FakeService extends ThirdPartyPerfService {
  _FakeService()
      : super(
          runner: (cmd) async => null,
          shizukuApi: _FakeShizuku(),
        );

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[];
}

/// 推进若干帧完成异步检测（不用 pumpAndSettle：AppLoading 无限动画会超时）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PerfThirdPartyPage：渲染 ThirdPartyAppSection（纯内容部件，不触达 Shizuku）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PerfThirdPartyPage(service: _FakeService())),
      ),
    );
    await _settleAsync(tester);

    // 纯内容部件不含 AppBar；真实 ThirdPartyAppSection 已挂载。
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(ThirdPartyAppSection), findsOneWidget);
    // binder 不可用 → 展示「需要 Shizuku」降级状态，绝不崩溃。
    expect(find.text('需要 Shizuku'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PerfThirdPartyPage：空应用列表下仍渲染选择入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PerfThirdPartyPage(service: _FakeService())),
      ),
    );
    await _settleAsync(tester);

    expect(find.byKey(const Key('perf_third_party_pick')), findsOneWidget);
    expect(find.text('未选择应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
