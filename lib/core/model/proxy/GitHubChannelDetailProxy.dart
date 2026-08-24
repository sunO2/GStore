import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/model/detail_extra_keys.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';

/// GitHubChannel 详情数据代理
/// 代理 GitHub API 的数据
class GitHubChannelDetailProxy extends ChannelDetailProxy {
  GitHubChannelDetailProxy(super.data);


  ChannelType get channelType => ChannelType.github;


  String get appId => data['appId'] ?? '';


  String get name => data['name'] ?? '';


  String get appName => name;


  String get icon => data['icon'] ?? '';


  String get description => data['description'] ?? '';


  String? get version => data['version']?.toString();


  String? get developer => data['developer']?.toString();


  String get packageName => data['packageName']?.toString() ?? '';


  String? get projectUrl => data['projectUrl']?.toString();


  List<DownloadInfo> get downloads {
    final downloadsList = data['downloads'];
    if (downloadsList is List) {
      // 安全地转换每个元素
      final result = <DownloadInfo>[];
      for (final item in downloadsList) {
        if (item is DownloadInfo) {
          result.add(item);
        } else if (item is Map) {
          try {
            final itemSize = item['size'] as int?;
            final itemPlatform = item['platform']?.toString();
            final itemDownloadCount = item['downloadCount'] as int?;
            final itemVersion = item['version']?.toString();
            result.add(DownloadInfo(
              url: item['url']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              size: itemSize,
              downloadCount: itemDownloadCount,
              version: itemVersion,
              publishedAt: item['publishedAt'] is DateTime
                  ? item['publishedAt'] as DateTime
                  : (item['publishedAt'] is String
                      ? DateTime.tryParse(item['publishedAt'])
                      : null),
              platform: itemPlatform,
              extra: {
                DownloadItemExtra.size: DownloadTag(
                  text: formatFileSize(itemSize),
                  iconName: 'sd_storage',
                ),
                DownloadItemExtra.platform: DownloadTag(
                  text: itemPlatform ?? '',
                  iconName: 'phone_android',
                ),
                DownloadItemExtra.downloadCount: DownloadTag(
                  text: itemDownloadCount?.toString() ?? '',
                  iconName: 'download',
                ),
                DownloadItemExtra.version: DownloadTag(
                  text: itemVersion ?? '',
                  iconName: 'tag',
                ),
              },
            ));
          } catch (e) {
            // 忽略无法转换的项
          }
        }
      }
      return result;
    }
    return const [];
  }


  List<DetailSection> get sections {
    final sectionsList = data['sections'];
    if (sectionsList is List) {
      return sectionsList.map((e) {
        if (e is DetailSection) return e;
        if (e is String) {
          return DetailSection.values.firstWhere(
            (v) => v.name == e,
            orElse: () => DetailSection.downloads,
          );
        }
        return DetailSection.downloads;
      }).toList();
    }
    return const [DetailSection.downloads];
  }


  List<StatTag> buildStatTags() {
    final tags = <StatTag>[];

    // 从 extra 中的 apiData 获取 GitHub 统计数据
    final apiData = extra['apiData'] as Map?;
    if (apiData != null) {
      final stars = apiData['stargazers_count'] as int?;
      final watchers = apiData['watchers_count'] as int?;
      final forks = apiData['forks_count'] as int?;

      if (stars != null && stars > 0) {
        tags.add(StatTag.stars(stars));
      }
      if (watchers != null && watchers > 0) {
        tags.add(StatTag.watchers(watchers));
      }
      if (forks != null && forks > 0) {
        tags.add(StatTag.forks(forks));
      }
    }

    return tags;
  }
}


