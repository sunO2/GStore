import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回归测试：`json` 类型配置（List<Map>/Map）必须以**合法 JSON** 落盘。
///
/// 历史缺陷：SharedPrefsConfigStorage.setValue 对 List<Map> 走 `value.toString()`
/// 分支，落盘成 Dart 的 `[{id: ...}]`（键无引号，非法 JSON）；读取方 jsonDecode 时
/// 抛 `FormatException: Unexpected character`（如 F-Droid 源配置加载失败）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPrefsConfigStorage JSON 往返', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('List<Map> 落盘为合法 JSON 且可还原', () async {
      final storage = SharedPrefsConfigStorage();
      await storage.initialize();

      final value = [
        {
          'id': 'tuna_mirror',
          'name': 'Tsinghua Mirror',
          'repoUrl': 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
          'enabled': true,
        },
      ];
      expect(await storage.setValue('fdroid_sources', value), true);

      // 原始落盘内容必须能被 jsonDecode（旧实现会在此抛 FormatException）
      final raw = await storage.getString('fdroid_sources');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!);
      expect(decoded, isA<List>());
      expect((decoded as List).first['id'], 'tuna_mirror');

      // getValue 还原为 List<Map>
      final read = await storage.getValue('fdroid_sources');
      expect(read, isA<List>());
      expect((read as List).first, isA<Map>());
      expect(read.first['name'], 'Tsinghua Mirror');
      expect(read.first['enabled'], true);
    });

    test('Map 落盘为合法 JSON 且可还原', () async {
      final storage = SharedPrefsConfigStorage();
      await storage.initialize();

      await storage.setValue('webdav_config', {
        'server': 'https://dav.example.com',
        'password': 'secret',
        'enabled': true,
      });

      final raw = await storage.getString('webdav_config');
      expect(() => jsonDecode(raw!), returnsNormally);

      final read = await storage.getValue('webdav_config');
      expect(read, isA<Map>());
      expect((read as Map)['server'], 'https://dav.example.com');
    });

    test('List<String> 仍走原生 stringList（不误当 JSON）', () async {
      final storage = SharedPrefsConfigStorage();
      await storage.initialize();

      await storage.setValue('str_list', ['a', 'b', 'c']);
      expect(await storage.getStringList('str_list'), ['a', 'b', 'c']);
    });
  });
}
