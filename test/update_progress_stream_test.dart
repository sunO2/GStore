import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_facade.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';

AppUpdateInfo _info(String id, String name) => AppUpdateInfo(
      channelId: 'github',
      appId: id,
      appName: name,
      packageName: id,
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: DownloadInfo(
        url: 'https://example.com/app.apk',
        name: 'app.apk',
        size: 1,
        version: '2.0.0',
      ),
    );

rust.UpdateProgressDto _event({
  required int total,
  required int index,
  String appId = '',
  String appName = '',
  String? iconUrl,
  String? logLevel,
  String? logText,
  String? namesJson,
  bool isResult = true,
}) =>
    rust.UpdateProgressDto(
      total: total,
      index: index,
      appId: appId,
      appName: appName,
      iconUrl: iconUrl,
      logLevel: logLevel,
      logText: logText,
      isResult: isResult,
      namesJson: namesJson,
      finished: false,
      error: null,
      checkedAt: 0,
      updatesJson: '',
      skippedJson: '',
      eventsJson: '',
      usedCache: false,
    );

class _StreamingBackend
    implements UpdateBackend, UpdateReportSource, UpdateProgressBackend {
  final Completer<void> firstEvents = Completer<void>();
  final Completer<void> release = Completer<void>();
  final Completer<void> secondEvents = Completer<void>();
  final Completer<void> finish = Completer<void>();
  final List<AppUpdateInfo> items = [_info('a', 'App A'), _info('b', 'App B')];

  @override
  CoreCheckReport? lastReport;

  @override
  Future<List<AppUpdateInfo>> checkWithProgress({
    required bool force,
    required void Function(rust.UpdateProgressDto event) onProgress,
  }) async {
    onProgress(_event(
      total: 2,
      index: 0,
      logLevel: 'info',
      logText: '开始检测应用更新...',
      isResult: false,
      namesJson: '["App A","App B"]',
    ));
    onProgress(_event(
      total: 2,
      index: 0,
      appId: 'a',
      appName: 'App A',
      iconUrl: 'https://example.com/a.png',
      logLevel: 'update',
      logText: 'App A：发现更新',
    ));
    firstEvents.complete();
    await release.future;
    onProgress(_event(
      total: 2,
      index: 1,
      appId: 'b',
      appName: 'App B',
      iconUrl: 'https://example.com/b.png',
      logLevel: 'none',
      logText: 'App B：已是最新（已安装 1.0.0）',
    ));
    onProgress(_event(
      total: 2,
      index: 1,
      logLevel: 'update',
      logText: '检测完成：共 2 个应用，更新 2 个，跳过 0 个',
    ));
    secondEvents.complete();
    await finish.future;
    lastReport = CoreCheckReport(
      updates: List.of(items),
      skipped: const <UpdateSkip>[],
      checkedAt: DateTime.now(),
      total: 2,
      usedCache: false,
    );
    return items;
  }

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async => items;

  @override
  Future<List<AppUpdateInfo>> run() async => items;

  @override
  Future<List<AppUpdateInfo>> list() async => items;

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async =>
      null;

  @override
  Future<bool> markUpdated(String appId) async => true;

  @override
  Future<bool> hasUpdate(String appId) async => false;

  @override
  Future<int> count() async => items.length;

  @override
  Future<bool> cacheValid() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StreamingBackend backend;

  setUp(() {
    backend = _StreamingBackend();
    UpdateFacade.backendOverride = backend;
  });

  tearDown(() {
    UpdateFacade.backendOverride = null;
  });

  test('check progress mirrors logs, names and icon while the check is running',
      () async {
    final state = UpdateManagerService.instance;
    final future = UpdateFacade.instance.checkUpdates(force: true);
    await backend.firstEvents.future;

    expect(state.checkList, ['App A', 'App B']);
    expect(state.totalCount, 2);
    expect(state.checkedCount, 1);
    expect(state.checkingAppName, 'App A');
    expect(state.checkingIconUrl, 'https://example.com/a.png');
    expect(state.checkLog.map((entry) => entry.text), [
      '开始检测应用更新...',
      'App A：发现更新',
    ]);
    expect(state.checkLog.last.level, CheckLogLevel.update);

    backend.release.complete();
    await backend.secondEvents.future;

    // 无更新的应用也带着图标回传，覆盖“只有有更新才显示图标”的回归。
    expect(state.checkingAppName, 'App B');
    expect(state.checkingIconUrl, 'https://example.com/b.png');
    expect(state.checkedCount, 2);

    backend.finish.complete();
    await future;

    expect(state.isChecking, isFalse);
    expect(state.updateList.length, 2);
    expect(
      state.checkLog.map((entry) => entry.text),
      contains('检测完成：共 2 个应用，更新 2 个，跳过 0 个'),
    );
  });
}
