import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/catalog/catalog_update_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    CatalogUpdateChecker.releasesOverride = null;
    CatalogUpdateChecker.currentVersionOverride = null;
  });

  test('读取远端 release 版本并返回本地当前版本', () async {
    CatalogUpdateChecker.releasesOverride = (owner, repo) async {
      expect(owner, 'sunO2');
      expect(repo, 'GStore-Repositorys');
      return '[{"name":"1.2.3"}]';
    };
    CatalogUpdateChecker.currentVersionOverride = () async => '1.2.2';

    final info = await CatalogUpdateChecker.check();

    expect(info?.current, '1.2.2');
    expect(info?.latest, '1.2.3');
  });

  test('release 无版本字段时返回 null', () async {
    CatalogUpdateChecker.releasesOverride = (_, __) async => '[{}]';
    CatalogUpdateChecker.currentVersionOverride = () async => '1.2.2';

    expect(await CatalogUpdateChecker.check(), isNull);
  });
}
