import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/app_version_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppVersionService', () {
    setUp(AppVersionService.resetForTest);
    tearDown(AppVersionService.resetForTest);

    test('versionName() 测试环境返回 null（MissingPluginException 被捕获不崩）',
        () async {
      expect(await AppVersionService.versionName(), isNull);
    });

    test('versionCode() 测试环境返回 null', () async {
      expect(await AppVersionService.versionCode(), isNull);
    });

    test('resetForTest 清除缓存且可再次调用', () async {
      await AppVersionService.versionName();
      AppVersionService.resetForTest();
      expect(await AppVersionService.versionName(), isNull);
    });
  });
}
