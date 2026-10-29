import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';

/// 脚本渠道详情代理：包装脚本 getAppDetail 返回的原始 Map，实现 [IDetailInfo]。
///
/// **它不是 JS 通道的数据转换器（Todo 5）。** Rust 通道上 app/detail 的唯一数据转换
/// 是「typed DTO 投影」：`catalog_facade.dart` 的 `appSummaryFromRust` /
/// `appDetailFromRust`，以及 `rust_script_detail_mapping.dart` 的 `detailToMap`
/// （FRB `ChannelAppDetailInfo` → 本代理消费的 Map）。本类只做页面渲染层的
/// `Map → IDetailInfo` 适配，且仍被 JS 通道渲染路径引用：
/// - `lib/page/detail/logic.dart` 的 `refreshDetail` / `updateDetail`（JS detail channel
///   经 `callbacks.refreshDetail` 推入 typed 投影后的 Map）；
/// - `lib/core/script/script_ui_handler_registry.dart` 的 `updateDownloadList`；
/// - `lib/page/detail/detail_ui_mixins.dart` 的历史构建下载（解析 switchVersion 的
///   `downloads`）。
///
/// 故保留（删除会破坏 JS 详情页渲染）。旧的 `appSummaryFromScript`
/// （`lib/core/channel/impl/js_script_utils.dart`）是已退役的重复转换器，已删除。
class JsChannelDetailProxy extends ChannelDetailProxy {
  JsChannelDetailProxy(super.data);

  @override
  ChannelType get channelType => ChannelType.custom;

  @override
  String get appId => data['appId']?.toString() ?? '';

  @override
  String get name => data['name']?.toString() ?? '';

  @override
  String get appName => name;

  @override
  String get icon => data['icon']?.toString() ?? '';

  @override
  String get description =>
      data['description']?.toString() ?? data['des']?.toString() ?? '';

  @override
  String? get version => data['version']?.toString();

  @override
  String? get developer =>
      data['developer']?.toString() ?? data['user']?.toString();

  @override
  String get packageName =>
      data['packageName']?.toString() ?? (appId.isEmpty ? '' : appId);

  @override
  String? get projectUrl => data['projectUrl']?.toString();

  @override
  String? get readme => data['readme']?.toString() ?? super.readme;

  @override
  List<DownloadInfo> get downloads {
    final raw = data['downloads'];
    if (raw is List) {
      return raw.map((e) {
        if (e is DownloadInfo) return e;
        if (e is Map) {
          return DownloadInfo(
            url: e['url']?.toString() ?? '',
            name: e['name']?.toString() ?? '',
            size: (e['size'] as num?)?.toInt(),
            version: e['version']?.toString(),
            platform: e['platform']?.toString(),
            // 脚本 downloads 契约：downloadable 默认 true（可下载），
            // 仅脚本显式设 false 时才禁止（如未配置凭证/认证失败 → url 空 + note 提示）
            downloadable: (e['downloadable'] as bool?) ?? true,
            note: e['note']?.toString(),
            publishedAt: _parseJsUpdateTime(e),
            // 保留原始 extra（含 updateTime 等）供 UI 标签展示
            extra: _parseJsExtra(e['extra']),
          );
        }
        return DownloadInfo(url: e.toString(), name: e.toString());
      }).toList();
    }
    return const [];
  }

  /// 统一解析 JS 各渠道的更新时间 → DateTime（null=无）
  /// 优先 e['publishedAt']（脚本显式提供），其次 e['updateTime'] / e['extra']['updateTime']
  static DateTime? _parseJsUpdateTime(Map e) {
    final raw = e['publishedAt']?.toString() ??
        e['updateTime']?.toString() ??
        ((e['extra'] is Map)
            ? (e['extra'] as Map)['updateTime']?.toString()
            : null);
    if (raw == null || raw.isEmpty) return null;
    // 数字字符串（时间戳）
    final asNum = num.tryParse(raw);
    if (asNum != null && asNum > 100000000000) {
      // 毫秒时间戳（13位）
      return DateTime.fromMillisecondsSinceEpoch(asNum.toInt());
    }
    if (asNum != null && asNum > 1000000000) {
      // 秒时间戳（10位）
      return DateTime.fromMillisecondsSinceEpoch(asNum.toInt() * 1000);
    }
    // ISO8601 / "yyyy-MM-dd HH:mm:ss" → 把空格替换为 T 后 tryParse
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  /// 解析 JS 传入的 extra 映射（支持 {icon,text} map 格式，向后兼容纯字符串）
  static Map<String, DownloadTag>? _parseJsExtra(dynamic raw) {
    if (raw is! Map) return null;
    final result = <String, DownloadTag>{};
    raw.forEach((key, value) {
      final k = key.toString();
      if (value is Map) {
        result[k] = DownloadTag(
          text: value['text']?.toString() ?? '',
          iconName: value['icon']?.toString(),
        );
      } else {
        result[k] = DownloadTag(text: value?.toString() ?? '');
      }
    });
    return result.isEmpty ? null : result;
  }

  @override
  List<DetailSection> get sections {
    final raw = data['sections'];
    if (raw is List) {
      final sections = <DetailSection>[];
      for (final e in raw) {
        final label = e.toString();
        for (final section in DetailSection.values) {
          if (section.name == label) {
            sections.add(section);
            break;
          }
        }
      }
      return sections;
    }
    return const [];
  }
}
