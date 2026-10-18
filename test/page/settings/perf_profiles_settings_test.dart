// Todo 26：每应用性能档案的设置入口——全局「按应用性能模式」开关（默认 OFF，
// 开启前必须确认，持久化于配置键 perf.profiles.enabled）+ 进入档案编辑页入口。
//
// 全部用例密闭：开关读写经注入的 reader/writer，能力经注入的
// PerfControlCapabilities，导航经注入回调；确认弹层经全局
// appNavigatorKey 通道（与 lib/main.dart 一致），无 Shizuku / 无原生模块 / 无配置存储。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/page/settings/settings_page.dart';

/// 至少一个类别可用（CPU）的能力图。
const PerfControlCapabilities _availableCaps = PerfControlCapabilities(
  nodeAvailability: <String, bool>{
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor': true,
  },
  binderLevers: <String, bool>{},
  categoryAvailability: <PerfControlCategory, bool>{
    PerfControlCategory.cpu: true,
  },
  nodeCounts: <PerfControlCategory, int>{PerfControlCategory.cpu: 1},
  timeoutAvailable: true,
  probedAtMs: 0,
);

/// 零可用能力（所有类别不可用）。
const PerfControlCapabilities _emptyCaps = PerfControlCapabilities(
  nodeAvailability: <String, bool>{},
  binderLevers: <String, bool>{},
  categoryAvailability: <PerfControlCategory, bool>{},
  nodeCounts: <PerfControlCategory, int>{},
  timeoutAvailable: false,
  probedAtMs: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: Scaffold(body: child),
      );

  bool switchValue(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const Key('perf_profiles_switch')))
      .value;

  bool switchEnabled(WidgetTester tester) => tester
          .widget<SwitchListTile>(find.byKey(const Key('perf_profiles_switch')))
          .onChanged !=
      null;

  testWidgets('渲染：默认关闭（OFF）的全局开关 + 档案编辑入口', (tester) async {
    await tester.pumpWidget(
      host(
        PerfProfilesTile(
          capabilities: _availableCaps,
          enabledReader: () async => false,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('perf_profiles_switch')), findsOneWidget);
    expect(find.text('按应用性能模式'), findsOneWidget);
    expect(switchValue(tester), isFalse, reason: '默认必须关闭（fail-closed）');
    expect(switchEnabled(tester), isTrue);

    expect(find.byKey(const Key('perf_profiles_entry')), findsOneWidget);
    expect(find.text('每应用性能档案'), findsOneWidget);
  });

  testWidgets('开启：先确认，确认后写入 true，且跨重建持久化', (tester) async {
    var stored = false;
    final writes = <bool>[];

    Future<bool> writer(bool value) async {
      writes.add(value);
      stored = value;
      return true;
    }

    await tester.pumpWidget(
      host(
        PerfProfilesTile(
          capabilities: _availableCaps,
          enabledReader: () async => stored,
          enabledWriter: writer,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_profiles_switch')));
    await tester.pumpAndSettle();

    // 第一次开启 → 必须出现说明/危险确认弹层。
    expect(find.text('开启按应用性能模式'), findsOneWidget);
    expect(find.text('开启'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();

    expect(writes, <bool>[true], reason: '确认后恰好写入一次 true');
    expect(stored, isTrue);
    expect(switchValue(tester), isTrue);

    // 重建（重新挂载同一持久化来源）→ 开关应为已开启。
    await tester.pumpWidget(
      host(
        PerfProfilesTile(
          capabilities: _availableCaps,
          enabledReader: () async => stored,
          enabledWriter: writer,
        ),
      ),
    );
    await tester.pump();
    expect(switchValue(tester), isTrue, reason: '重建后应读取到持久化的 true');
  });

  testWidgets('取消确认：不写入、保持关闭（绝不静默开启）', (tester) async {
    var stored = false;
    final writes = <bool>[];

    await tester.pumpWidget(
      host(
        PerfProfilesTile(
          capabilities: _availableCaps,
          enabledReader: () async => stored,
          enabledWriter: (value) async {
            writes.add(value);
            stored = value;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_profiles_switch')));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(writes, isEmpty, reason: '未确认不得写入');
    expect(stored, isFalse);
    expect(switchValue(tester), isFalse);
  });

  testWidgets('入口：点击进入档案编辑页（注入回调捕获）', (tester) async {
    var opened = 0;

    await tester.pumpWidget(
      host(
        PerfProfilesTile(
          capabilities: _availableCaps,
          enabledReader: () async => false,
          openProfiles: () => opened++,
        ),
      ),
    );
    await tester.pump();

    expect(perfProfilesEditorRoute, '/GStore/perfProfiles');
    await tester.tap(find.byKey(const Key('perf_profiles_entry')));
    await tester.pump();

    expect(opened, 1, reason: '点击入口应触发编辑页导航');
  });

  testWidgets('无能力：开关与入口均禁用并给出原因（fail-closed）', (tester) async {
    await tester.pumpWidget(
      host(
        PerfProfilesTile(
          capabilities: _emptyCaps,
          enabledReader: () async => false,
        ),
      ),
    );
    await tester.pump();

    expect(switchEnabled(tester), isFalse, reason: '无能力时开关必须禁用');
    expect(find.textContaining('无可用性能控制能力'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.byKey(const Key('perf_profiles_entry'))).onTap,
      isNull,
      reason: '无能力时入口必须禁用',
    );
    expect(find.textContaining('暂不可编辑'), findsOneWidget);
  });
}
