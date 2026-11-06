import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_backends.dart';
import 'package:gstore/core/update/update_facade.dart';
import 'package:gstore/core/update/update_report.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A backend without the Rust preference capability.
///
/// Preference storage is Rust-owned; this fake proves the facade does not fall
/// back to a Dart/SharedPreferences write.
class _NoPreferenceBackend implements UpdateBackend {
  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async => const [];

  @override
  Future<List<AppUpdateInfo>> run() async => const [];

  @override
  Future<List<AppUpdateInfo>> list() async => const [];

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async =>
      null;

  @override
  Future<bool> markUpdated(String appId) async => true;

  @override
  Future<bool> hasUpdate(String appId) async => false;

  @override
  Future<int> count() async => 0;

  @override
  Future<bool> cacheValid() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    UpdateFacade.backendOverride = null;
  });

  test('无 core 偏好后端：拒绝写入且不落 SharedPreferences', () async {
    UpdateFacade.backendOverride = _NoPreferenceBackend();

    await expectLater(
      UpdateFacade.instance.setPreferredApk(
        channelId: 'github',
        appId: 'com.example.app',
        fileName: 'app-arm64-v8a.apk',
      ),
      throwsA(isA<CoreUpdateException>()),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_preferred_apk'), isNull);
  });

  test('无 core 偏好后端：读取也直接报错', () async {
    UpdateFacade.backendOverride = _NoPreferenceBackend();

    await expectLater(
      UpdateFacade.instance.preferredApkName(
        channelId: 'github',
        appId: 'com.example.app',
      ),
      throwsA(isA<CoreUpdateException>()),
    );
  });
}
