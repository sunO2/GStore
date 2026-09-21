/// 订阅/配置页（Todo 20）展示层门面契约。
///
/// 冻结的 [`ProxyFacade`]（`lib/core/rust/proxy/ProxyModule.dart`）只暴露
/// `ping` / `version` / `events`；订阅管理页还需要 profile CRUD 与刷新。
/// 为保持「门面注入即可测试」且**不修改冻结契约**，这里定义一个窄接口
/// [ProxyProfilesFacade]，并提供把生产单例 [`ProxyModule`] 适配进来的
/// [ProxyModuleProfilesFacade]。
///
/// **纯展示层**：接口只做参数透传，不含任何解析 / 网络 / 路由逻辑；订阅的
/// 抓取、解析与持久化全部在 Rust 模块内完成（`rust/gstore_mod_proxy/API.md`）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 订阅管理页依赖的只读 + 操作门面（组件测试可注入假实现，无需原生模块）。
abstract class ProxyProfilesFacade {
  /// `profile.list`：稳定排序的存储摘要。
  Future<ProfileList> profileList();

  /// `profile.import_url`：经 protect 感知传输抓取并解析订阅。
  Future<ImportedProfile> profileImportUrl({
    required String url,
    String? name,
    String? userAgent,
  });

  /// `profile.import_text`：解析已抓取的订阅正文。
  Future<ImportedProfile> profileImportText({
    required String text,
    String? name,
    String? contentType,
  });

  /// `profile.import_link`：解析单条分享链接。
  Future<ImportedProfile> profileImportLink({
    required String link,
    String? name,
  });

  /// `profile.create`：持久化已导入的规范 profile。
  Future<StoredProfile> profileCreate(ProfileCreateRequest request);

  /// `profile.delete`：删除 profile（并发出 removed 事件）。
  Future<ProfileDeleteResult> profileDelete(String id);

  /// `profile.refresh`：单 profile 刷新（失败保留旧内容）。
  Future<RefreshResult> profileRefresh(String id, {bool force = false});

  /// `profile.refresh_all`：有界批量刷新。
  Future<RefreshAllResult> profileRefreshAll({bool force = false, int? limit});

  /// 类型化代理事件流（订阅增删改 / 刷新进度）。
  Stream<ProxyEvent> get events;
}

/// 生产门面：[ProxyModule] → [ProxyProfilesFacade] 的薄适配器。
///
/// 只做签名转发，不缓存、不改写任何数据。
class ProxyModuleProfilesFacade implements ProxyProfilesFacade {
  ProxyModuleProfilesFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<ProfileList> profileList() => _module.profileList();

  @override
  Future<ImportedProfile> profileImportUrl({
    required String url,
    String? name,
    String? userAgent,
  }) =>
      _module.profileImportUrl(url: url, name: name, userAgent: userAgent);

  @override
  Future<ImportedProfile> profileImportText({
    required String text,
    String? name,
    String? contentType,
  }) =>
      _module.profileImportText(
        text: text,
        name: name,
        contentType: contentType,
      );

  @override
  Future<ImportedProfile> profileImportLink({
    required String link,
    String? name,
  }) =>
      _module.profileImportLink(link: link, name: name);

  @override
  Future<StoredProfile> profileCreate(ProfileCreateRequest request) =>
      _module.profileCreate(request);

  @override
  Future<ProfileDeleteResult> profileDelete(String id) =>
      _module.profileDelete(id);

  @override
  Future<RefreshResult> profileRefresh(String id, {bool force = false}) =>
      _module.profileRefresh(id, force: force);

  @override
  Future<RefreshAllResult> profileRefreshAll({
    bool force = false,
    int? limit,
  }) =>
      _module.profileRefreshAll(force: force, limit: limit);

  @override
  Stream<ProxyEvent> get events => _module.events;
}
