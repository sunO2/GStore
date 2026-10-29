/// Public [IDetailInfo] adapter over [AppDetailInfo].
///
/// `AppDetailInfo` is the channel-agnostic detail model, but it does **not**
/// implement [IDetailInfo] (channel proxies do). Core (FRB) detail payloads are
/// mapped to [AppDetailInfo] by `appDetailFromRust`, so the shared detail page —
/// which consumes [IDetailInfo] — needs a bridge. This adapter is that bridge;
/// it mirrors the private `_ProgressiveDetailInfo` used by
/// `StandardDetailChannel` so both render identically.
library;

import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';

/// Adapts an [AppDetailInfo] to [IDetailInfo].
class AppDetailInfoView implements IDetailInfo {
  AppDetailInfoView(this.inner);

  /// Inner channel-agnostic detail payload.
  final AppDetailInfo inner;

  @override
  String get packageName => inner.packageName ?? '';

  @override
  String get appName => inner.name;

  @override
  String get name => inner.name;

  @override
  String get icon => inner.icon;

  @override
  String get description => inner.description;

  @override
  String get appId => inner.appId;

  @override
  String get channelId => inner.channel.code;

  @override
  ChannelType get channelType => inner.channel;

  @override
  String? get version => inner.version;

  @override
  String? get developer => inner.developer;

  @override
  String? get projectUrl => inner.projectUrl;

  @override
  List<DownloadInfo> get downloads => inner.downloads;

  @override
  List<DetailSection> get sections => inner.sections;

  @override
  Map<String, dynamic> get extra => inner.extra;

  @override
  List<AppLabel> get labels => inner.labels;

  @override
  String? get readme {
    final direct = inner.readme;
    if (direct != null && direct.isNotEmpty) return direct;
    final fromExtra = inner.extra['readme'];
    return fromExtra?.toString();
  }

  @override
  List<ScreenshotInfo>? get screenshots {
    final direct = inner.screenshots;
    if (direct != null && direct.isNotEmpty) return direct;
    final raw = inner.extra['screenshots'];
    if (raw is List) {
      final items = <ScreenshotInfo>[];
      for (final entry in raw) {
        if (entry is String && entry.isNotEmpty) {
          items.add(ScreenshotInfo(url: entry));
        } else if (entry is Map) {
          final url = entry['url']?.toString();
          if (url != null && url.isNotEmpty) {
            items.add(ScreenshotInfo(
              url: url,
              description: entry['description']?.toString(),
            ));
          }
        }
      }
      return items.isEmpty ? null : items;
    }
    return null;
  }

  @override
  String? get changelog {
    final direct = inner.changelog;
    if (direct != null && direct.isNotEmpty) return direct;
    return inner.extra['changelog']?.toString();
  }

  @override
  List<String>? get permissions {
    final direct = inner.permissions;
    if (direct != null && direct.isNotEmpty) return direct;
    final raw = inner.extra['permissions'];
    if (raw is List) {
      final items = raw
          .map((entry) => entry.toString())
          .where((entry) => entry.isNotEmpty)
          .toList();
      return items.isEmpty ? null : items;
    }
    return null;
  }

  @override
  StatisticsInfo? get statistics {
    final s = inner.statistics;
    if (s != null) return s;
    // 与渠道代理一致：从 extra.apiData 解析 GitHub 统计
    final apiData = inner.extra['apiData'];
    if (apiData is Map) {
      final stars = apiData['stargazers_count'];
      final watchers = apiData['watchers_count'];
      final forks = apiData['forks_count'];
      if (stars is int || watchers is int || forks is int) {
        return StatisticsInfo(
          stars: stars is int ? stars : null,
          watchers: watchers is int ? watchers : null,
          forks: forks is int ? forks : null,
        );
      }
    }
    return null;
  }

  @override
  List<StatTag> buildStatTags() {
    final tags = <StatTag>[];
    final apiData = inner.extra['apiData'];
    if (apiData is Map) {
      final stars = apiData['stargazers_count'];
      final watchers = apiData['watchers_count'];
      final forks = apiData['forks_count'];
      if (stars is int && stars > 0) tags.add(StatTag.stars(stars));
      if (watchers is int && watchers > 0) tags.add(StatTag.watchers(watchers));
      if (forks is int && forks > 0) tags.add(StatTag.forks(forks));
    }
    if (tags.isNotEmpty) return tags;
    // 应用商店型渠道（vivo 等）把下载量/评分/收藏写在 extra 顶层（键名与
    // GitHub 的 apiData 不同），与 VivoChannelDetailProxy.buildStatTags 对齐。
    final downloads = inner.extra['downloads'] ?? inner.extra['downloadCount'];
    final rating = inner.extra['rating'];
    final ratingCount = inner.extra['ratingCount'];
    final favorites = inner.extra['favorites'];
    if (downloads is int && downloads > 0) {
      tags.add(StatTag.downloads(downloads));
    }
    if (rating is num && rating > 0) {
      tags.add(StatTag.rating(
        rating.toDouble(),
        ratingCount is int ? ratingCount : null,
      ));
    }
    if (favorites is int && favorites > 0) {
      tags.add(StatTag.favorites(favorites));
    }
    return tags;
  }

  @override
  bool get isValid => inner.isValid;
}
