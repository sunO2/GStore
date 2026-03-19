import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';

/// VivoChannel 详情数据代理
/// 代理 vivo 应用商店 API 的数据
class VivoChannelDetailProxy extends ChannelDetailProxy {
  VivoChannelDetailProxy(super.data);


  ChannelType get channelType => ChannelType.vivo;


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
            result.add(DownloadInfo(
              url: item['url']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              size: item['size'] as int?,
              downloadCount: item['downloadCount'] as int?,
              version: item['version']?.toString(),
              publishedAt: item['publishedAt'] is DateTime
                  ? item['publishedAt'] as DateTime
                  : (item['publishedAt'] is String
                      ? DateTime.tryParse(item['publishedAt'])
                      : null),
              platform: item['platform']?.toString(),
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

    // 从原始数据中获取应用商店统计数据
    final downloadCount = data['downloadCount'] as int?; // 下载量
    final rating = data['rating'] as double?;
    final ratingCount = data['ratingCount'] as int?;
    final favorites = data['favorites'] as int?;

    if (downloadCount != null && downloadCount > 0) {
      tags.add(StatTag.downloads(downloadCount));
    }
    if (rating != null && rating > 0) {
      tags.add(StatTag.rating(rating, ratingCount));
    }
    if (favorites != null && favorites > 0) {
      tags.add(StatTag.favorites(favorites));
    }

    return tags;
  }
}
