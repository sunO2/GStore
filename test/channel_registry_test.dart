import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/ChannelIntegration.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// channel 按类型绑定注册表 + 幂等化测试（todo 16）
///
/// 验证：
/// - ChannelModule.onRegister 按类型绑定 → get<ChannelManager>() 返回实例；
///   onUnregister 对称解绑 → null
/// - ChannelIntegration.initialize 幂等：重复调用渠道只注册一次、不重复 Get.put
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    Get.reset();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    await ChannelManager.instance.disposeAll();
    // ChannelIntegration.initialize 依赖 DbManager + GithubRestClient
    Get.put(GithubRestClient(DioClient().get()));
    final dm = DbManager();
    dm.dbRepositroies['gstore'] = DBRepository(
      'gstore',
      'sunO2',
      'GStore-Repositorys',
      await ($FloorAppInfoDatabase.inMemoryDatabaseBuilder()).build(),
    );
    Get.put(dm);
  });

  group('ChannelModule 按类型绑定', () {
    test('onRegister 绑定 → get<ChannelManager>() 返回实例；onUnregister 解绑 → null',
        () async {
      final manager = ModuleManager.instance;
      final module = ChannelModule();

      await module.onRegister(ModuleContext(
        config: null,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<ChannelManager>(), same(ChannelManager.instance),
          reason: '按类型绑定后注册表可取到 ChannelManager 实例');

      await module.onUnregister(ModuleContext(
        config: null,
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<ChannelManager>(), isNull,
          reason: '模块下线后注册表解绑，消费方软降级');
    });
  });

  group('ChannelIntegration.initialize 幂等', () {
    test('重复调用：渠道只注册一次、不重复 Get.put、不抛', () async {
      // 首次初始化（真实渠道注册 + Get.put tag）
      await ChannelIntegration.initialize();

      final manager = ChannelManager.instance;
      expect(manager.getChannel(ChannelType.localDb), isNotNull);
      expect(manager.getChannel(ChannelType.github), isNotNull);
      expect(manager.getChannel(ChannelType.vivo), isNotNull);
      expect(manager.getChannel(ChannelType.fdroid), isNotNull);
      expect(Get.find<ChannelManager>(tag: 'channelManager'), same(manager));
      final localDbFirst = manager.getChannel(ChannelType.localDb);

      // 重复调用（re-enable 场景）：幂等直接返回，渠道不重复注册/不重建实例
      await ChannelIntegration.initialize();
      expect(manager.getChannel(ChannelType.localDb), same(localDbFirst),
          reason: '幂等：重复调用 initialize 不重建渠道实例');
      expect(manager.getChannel(ChannelType.github), isNotNull);
      expect(manager.getChannel(ChannelType.vivo), isNotNull);
      expect(manager.getChannel(ChannelType.fdroid), isNotNull);
      expect(Get.find<ChannelManager>(tag: 'channelManager'), same(manager));
    });
  });
}