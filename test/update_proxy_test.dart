import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';

void main() {
  tearDown(() {
    Get.reset();
  });

  test('updateConfig 替换已注册实例（getProxy 返回新值）', () {
    // 模拟启动时 db_manager 已注册旧 config
    updateConfig(AppInfoConfig('1.0.0', 'https://old-proxy.org/'));

    expect(getProxy(), 'https://old-proxy.org/');

    // 更新代理：必须替换内存实例（Get.put 已注册时不替换——回归点）
    updateProxy('https://new-proxy.org/');

    expect(getProxy(), 'https://new-proxy.org/');
  });

  test('updateProxy 空值：清除代理（getProxy 返回空）', () {
    updateConfig(AppInfoConfig('1.0.0', 'https://old-proxy.org/'));

    updateProxy(null);

    expect(getProxy(), '');
  });
}
