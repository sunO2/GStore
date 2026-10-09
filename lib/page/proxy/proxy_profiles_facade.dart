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

  /// `profile.update`：重命名 / 编辑 profile（内容、名称、`appBackup`、刷新标记）。
  ///
  /// 负载为 `profile.update` 的请求体（至少含 `id`，可含 `name` / `profile` /
  /// `appBackup` / `refresh`）；本门面只透传，不做任何字段改写。
  Future<StoredProfile> profileUpdate(Map<String, dynamic> payload);

  /// `profile.export_clash`：导出单个存储 profile 的 Clash 生成配置。
  Future<GeneratedConfig> profileExportClash(ProfileExportRequest request);

  /// `profile.set_schedule`：设置 / 清除自动更新间隔（`intervalMs: 0` 清除）。
  Future<StoredProfile> profileSetSchedule(String id, int intervalMs);

  /// `config.apply`：把 [profileId] 热应用到正在运行的引擎。
  ///
  /// 订阅切换后调用，避免「已换订阅但运行中引擎仍用旧订阅」。引擎未运行时
  /// Rust 只记录 active profile 并返回 `applied:false`（不报错），离线
  /// node.select/delay_test 会解析到新订阅；调用方的 try/catch 仅作防御性兜底。
  /// `config.apply` 同时会把该 id 落盘为 Rust 侧 active profile
  /// （见 `rust/gstore_mod_proxy/src/lib.rs`）。
  Future<void> applyProfile(String profileId);

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
  Future<StoredProfile> profileUpdate(Map<String, dynamic> payload) =>
      _module.profileUpdate(payload);

  @override
  Future<GeneratedConfig> profileExportClash(ProfileExportRequest request) =>
      _module.profileExportClash(request);

  @override
  Future<StoredProfile> profileSetSchedule(String id, int intervalMs) =>
      _module.profileSetSchedule(id, intervalMs);

  @override
  Future<void> applyProfile(String profileId) async {
    await _module.configApply(GenerateRequest(profileId: profileId));
  }

  @override
  Stream<ProxyEvent> get events => _module.events;
}
