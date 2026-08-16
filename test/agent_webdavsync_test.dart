import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/agent/agent_service.dart';

/// 测试用 WebDAV 服务（绑定后走正常路径；降级路径不触碰它）
class FakeWebDavService implements IWebDavService {
  @override
  Future<bool> testWebDavConnection(WebDavConfig config) async => true;

  @override
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async =>
      const [];

  @override
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = true,
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async =>
      'ok';

  @override
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    throw UnimplementedError();
  }
}

/// Agent webdavSync 工具降级测试（todo 12b）
///
/// 验证：WebDavService 未绑定（webdav 模块下线）时，
/// webdavSync 返回降级提示，不抛异常；已绑定时走原逻辑（不抛）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  test('webdavSync：服务未绑定 → 降级提示不抛', () async {
    final agent = AgentService();

    final result = await agent.runTool('webdavSync', {'action': 'status'});

    expect(result, contains('WebDAV 模块未启用'));
  });

  test('webdavSync：服务已绑定 → 走原逻辑不抛', () async {
    ModuleManager.instance.bind<IWebDavService>(FakeWebDavService());
    final agent = AgentService();

    // 未配置 WebDAV（测试环境无 secure storage）→ 原逻辑提示未配置
    final result = await agent.runTool('webdavSync', {'action': 'status'});

    expect(result, contains('尚未配置 WebDAV'));
  });
}
