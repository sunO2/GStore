import 'package:flutter/material.dart';

/// 统计标签数据模型
/// 用于统一不同渠道的统计数据展示
class StatTag {
  /// 标签文本
  final String text;

  /// 图标
  final IconData icon;

  /// 背景颜色
  final Color backgroundColor;

  /// 边框颜色
  final Color borderColor;

  /// 文本颜色
  final Color textColor;

  /// 提示文字（可选）
  final String? tooltip;

  StatTag({
    required this.text,
    required this.icon,
    required this.backgroundColor,
    required this.borderColor,
    required this.textColor,
    this.tooltip,
  });

  /// 创建 stars 标签（GitHub）
  factory StatTag.stars(int count) {
    String formattedCount;
    if (count >= 1000) {
      formattedCount = '${(count / 1000).toStringAsFixed(1)}k';
    } else {
      formattedCount = '$count';
    }

    return StatTag(
      text: formattedCount,
      icon: Icons.star_rounded,
      backgroundColor: const Color(0xFFFFF9C4).withAlpha(40), // 黄色
      borderColor: const Color(0xFFFFF9C4).withAlpha(80),
      textColor: const Color(0xFFF9A825), // yellow[700]
      tooltip: 'Stars',
    );
  }

  /// 创建 watchers 标签（GitHub）
  factory StatTag.watchers(int count) {
    String formattedCount;
    if (count >= 1000) {
      formattedCount = '${(count / 1000).toStringAsFixed(1)}k';
    } else {
      formattedCount = '$count';
    }

    return StatTag(
      text: formattedCount,
      icon: Icons.visibility,
      backgroundColor: const Color(0xFF2196F3).withAlpha(40), // 蓝色
      borderColor: const Color(0xFF2196F3).withAlpha(80),
      textColor: const Color(0xFF1976D2),
      tooltip: 'Watchers',
    );
  }

  /// 创建 forks 标签（GitHub）
  factory StatTag.forks(int count) {
    String formattedCount;
    if (count >= 1000) {
      formattedCount = '${(count / 1000).toStringAsFixed(1)}k';
    } else {
      formattedCount = '$count';
    }

    return StatTag(
      text: formattedCount,
      icon: Icons.call_split,
      backgroundColor: const Color(0xFF4CAF50).withAlpha(40), // 绿色
      borderColor: const Color(0xFF4CAF50).withAlpha(80),
      textColor: const Color(0xFF388E3C),
      tooltip: 'Forks',
    );
  }

  /// 创建下载量标签（应用商店）
  factory StatTag.downloads(int count) {
    String formattedCount;
    if (count >= 100000000) {
      formattedCount = '${(count / 100000000).toStringAsFixed(1)}亿';
    } else if (count >= 10000) {
      formattedCount = '${(count / 10000).toStringAsFixed(1)}万';
    } else {
      formattedCount = '$count';
    }

    return StatTag(
      text: formattedCount,
      icon: Icons.cloud_download_outlined,
      backgroundColor: const Color(0xFFFF9800).withAlpha(40), // 橙色
      borderColor: const Color(0xFFFF9800).withAlpha(80),
      textColor: const Color(0xFFF57C00),
      tooltip: '下载量',
    );
  }

  /// 创建评分标签（应用商店）
  factory StatTag.rating(double rating, [int? ratingCount]) {
    String text = rating.toStringAsFixed(1);
    if (ratingCount != null && ratingCount > 0) {
      text += ' ($ratingCount)';
    }

    return StatTag(
      text: text,
      icon: Icons.grade,
      backgroundColor: const Color(0xFFFFC107).withAlpha(40), // 琥珀色
      borderColor: const Color(0xFFFFC107).withAlpha(80),
      textColor: const Color(0xFFFF8F00),
      tooltip: '评分',
    );
  }

  /// 创建收藏标签（应用商店）
  factory StatTag.favorites(int count) {
    String formattedCount;
    if (count >= 10000) {
      formattedCount = '${(count / 10000).toStringAsFixed(1)}万';
    } else {
      formattedCount = '$count';
    }

    return StatTag(
      text: formattedCount,
      icon: Icons.favorite,
      backgroundColor: const Color(0xFFE91E63).withAlpha(40), // 粉色
      borderColor: const Color(0xFFE91E63).withAlpha(80),
      textColor: const Color(0xFFC2185B),
      tooltip: '收藏',
    );
  }

  @override
  String toString() {
    return 'StatTag{text: $text, icon: $icon}';
  }
}
