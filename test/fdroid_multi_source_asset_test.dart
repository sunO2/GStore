import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/FdroidChannel.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';

/// 多源资源地址回归（P0-1 / P1-1）
///
/// 三条契约：
/// 1. 下载地址 / 截图必须按**记录所属源**取址，不得用"当前选中源"
///    （真机事故：Bitwarden 记录的图标/资源被拼上官方源镜像前缀 → 404）
/// 2. 基址优先取模块 `resolved_url`（镜像回退后**真正可达**的地址），
///    而不是宿主自己"猜第一个启用镜像"——否则搜索正常、列表/详情 404
/// 3. 模块出口已绝对化的值**幂等透传**，不得二次拼接出 `https://镜像/https://源/…`
class _FakeFdroidRepoService implements IFdroidRepoService {
  _FakeFdroidRepoService({
    required this.sources,
    required this.currentSource,
    required this.resolvedBases,
    required this.detail,
  });

  @override
  final List<FdroidSource> sources;

  @override
  final FdroidSource? currentSource;

  /// 源身份键 → 模块 resolved_url（真正生效的基址）
  final Map<String, String> resolvedBases;

  final Map<String, dynamic> detail;
  String? lastRequestedSourceId;

  @override
  String identityKeyFor(FdroidSource source) => 'test:${source.id}';

  @override
  String? cachedBaseFor(FdroidSource source) => resolvedBases[identityKeyFor(source)];

  @override
  Future<void> ensureBaseFor(FdroidSource source) async {}

  @override
  Future<Map<String, dynamic>?> getAppByPackageName(
    String packageName, {
    String? sourceId,
  }) async {
    lastRequestedSourceId = sourceId;
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> searchApps(String keyword, {int limit = 50}) async =>
      const [];

  @override
  Future<void> loadRepository({bool forceRefresh = false}) async {}

  @override
  Future<List<Map<String, dynamic>>> getAllApps() async => const [];

  @override
  Future<int> getAppCount() async => 0;

  @override
  Future<List<FdroidSourceStat>> getStatistics() async => const [];

  @override
  Future<void> switchSource(String sourceId) async {}

  @override
  Future<void> addSource(FdroidSource source) async {}

  @override
  Future<void> updateSource(FdroidSource source) async {}

  @override
  Future<void> setSourceEnabled(String sourceId, bool enabled) async {}

  @override
  Future<int> loadAllEnabled() async => 0;

  @override
  Future<void> removeSource(String sourceId) async {}

  @override
  Future<void> clearData() async {}
}

/// 立即返回 500 的假适配器（详情解析成功时不触网；触网即失败，便于暴露问题）
class _FailingHttpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('{}', 500, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const officialMirror = 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo';
  const bitwarden = 'https://mobileapp.bitwarden.com/fdroid/repo';

  final official = FdroidSource(
    id: 'official',
    name: 'F-Droid Official',
    repoUrl: 'https://f-droid.org/repo',
    mirrors: const [FdroidMirror(url: officialMirror)],
  );
  final thirdParty = FdroidSource(
    id: 'bitwarden',
    name: 'Bitwarden',
    repoUrl: bitwarden,
    useMirrors: false,
  );

  setUp(() async {
    await ModuleManager.instance.clear();
  });

  tearDown(() async {
    await ModuleManager.instance.clear();
  });

  /// resolved_url 场景：官方源实际走的是镜像，第三方源用自己的地址
  _FakeFdroidRepoService buildService({
    required String versionsJson,
    required String metadataJson,
  }) =>
      _FakeFdroidRepoService(
        sources: [official, thirdParty],
        currentSource: official, // 当前选中源故意设为官方源
        resolvedBases: {
          'test:official': officialMirror,
          'test:bitwarden': bitwarden,
        },
        detail: {
          'packageName': 'com.x8bit.bitwarden',
          'name': 'Bitwarden',
          'summary': '密码管理器',
          'icon': '$bitwarden/com.x8bit.bitwarden/en-US/icon_a=.png',
          // 服务层回带**实际命中源**（真实实现里 getAppByPackageName 会打标）
          'sourceId': 'bitwarden',
          'metadata': metadataJson,
          'versions': versionsJson,
        },
      );

  FdroidChannel buildChannel() =>
      FdroidChannel(dio: Dio()..httpClientAdapter = _FailingHttpAdapter());

  test('下载地址按记录所属源取址，不用"当前选中源"的镜像', () async {
    // 相对文件名（旧格式/兜底路径）：应由**记录所属源**拼接
    final service = buildService(
      versionsJson:
          '{"1000":{"added":1700000000,"file":{"name":"com.x8bit.bitwarden_1000.apk",'
              '"size":1024,"sha256":"abc"},'
              '"manifest":{"versionName":"1.0","versionCode":1000}}}',
      metadataJson: '{"screenshots":{},"description":{"en-US":"描述"}}',
    );
    ModuleManager.instance.bind<IFdroidRepoService>(service);

    final result = await buildChannel().getAppDetail('com.x8bit.bitwarden');
    expect(result.success, isTrue);
    final downloads = result.data!.downloads;
    expect(downloads, hasLength(1));
    expect(downloads.single.url, '$bitwarden/com.x8bit.bitwarden_1000.apk');
    expect(downloads.single.url, isNot(contains('tuna.tsinghua')));
    // 本用例没有渠道库记录 → 定位源为 null（**不猜当前源**），
    // 实际基址由服务层回带的 sourceId 决定；真实链路里则由记录的 sourceId 列决定。
    expect(service.lastRequestedSourceId, isNull);
  });

  test('模块已绝对化的下载地址幂等透传（不二次前缀）', () async {
    final abs = '$bitwarden/com.x8bit.bitwarden_1000.apk';
    final service = buildService(
      versionsJson:
          '{"1000":{"added":1700000000,"file":{"name":"$abs","size":1024},'
              '"manifest":{"versionName":"1.0","versionCode":1000}}}',
      metadataJson: '{"screenshots":{},"description":{"en-US":"描述"}}',
    );
    ModuleManager.instance.bind<IFdroidRepoService>(service);

    final result = await buildChannel().getAppDetail('com.x8bit.bitwarden');
    final url = result.data!.downloads.single.url;
    expect(url, abs);
    expect(url, isNot(contains('/https://')));
  });

  test('截图按记录所属源取址，且绝对地址不二次拼接', () async {
    final absShot = '$bitwarden/com.x8bit.bitwarden/en-US/ss_abs.png';
    final service = buildService(
      versionsJson: '{"1000":{"file":{"name":"a.apk"},"manifest":{"versionCode":1000}}}',
      metadataJson:
          '{"description":{"en-US":"描述"},"screenshots":{"phone":{"en-US":['
              '{"name":"$absShot"},{"name":"/com.x8bit.bitwarden/en-US/ss_rel.png"}'
              ']}}}',
    );
    ModuleManager.instance.bind<IFdroidRepoService>(service);

    final result = await buildChannel().getAppDetail('com.x8bit.bitwarden');
    final shots = result.data!.screenshots!.map((s) => s.url).toList();
    // 绝对地址原样、相对路径按所属源拼接
    expect(shots, [
      absShot,
      '$bitwarden/com.x8bit.bitwarden/en-US/ss_rel.png',
    ]);
    for (final s in shots) {
      expect(s, isNot(contains('/https://')));
      expect(s, isNot(contains('tuna.tsinghua')));
    }
  });

  test('resolved_url 未命中时按镜像配置兜底（仍是所属源的镜像）', () async {
    final service = buildService(
      versionsJson: '{"1000":{"file":{"name":"a.apk"},"manifest":{"versionCode":1000}}}',
      metadataJson: '{"screenshots":{},"description":{"en-US":"描述"}}',
    );
    // 清掉 resolved_url 缓存 → 走镜像配置兜底
    service.resolvedBases.clear();
    ModuleManager.instance.bind<IFdroidRepoService>(service);

    final result = await buildChannel().getAppDetail('com.x8bit.bitwarden');
    // 第三方源关闭镜像回退 → 用源地址；绝不能继承官方源镜像
    expect(result.data!.downloads.single.url,
        '$bitwarden/a.apk');
  });
}
