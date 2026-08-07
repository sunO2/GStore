import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// 当前设备平台架构信息
/// 用于在 GitHub 等渠道的下载资产中匹配对应 CPU 架构的 APK
class PlatformArch {
  static String? _abi;

  /// 当前设备 ABI（如 arm64-v8a / armeabi-v7a / x86_64 / x86）
  static String? get abi => _abi;

  /// 获取设备 ABI（Android）
  static Future<String?> detectAbi() async {
    if (_abi != null) return _abi;

    try {
      if (kIsWeb) return null;

      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        final abis = info.supportedAbis;
        debugPrint('PlatformArch: 设备 ABI = $abis');
        if (abis.isNotEmpty) {
          _abi = _normalizeAbi(abis.first);
          return _abi;
        }
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
        _abi = 'x86_64';
        return _abi;
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        _abi = 'macos';
        return _abi;
      } else if (defaultTargetPlatform == TargetPlatform.windows) {
        _abi = 'x86_64';
        return _abi;
      }
    } catch (e) {
      appLog.error('PlatformArch: 获取 ABI 失败 - $e');
    }
    return null;
  }

  /// 归一化 ABI 名称（统一格式）
  static String _normalizeAbi(String abi) {
    if (abi.contains('arm64') && abi.contains('v8a')) return 'arm64-v8a';
    if (abi.contains('armeabi-v7a')) return 'armeabi-v7a';
    if (abi.contains('x86_64')) return 'x86_64';
    if (abi.contains('x86')) return 'x86';
    return abi;
  }

  /// 平台描述（用于 agent 提示词）
  static String get platformDescription {
    if (_abi != null) {
      return '当前设备 CPU 架构: $_abi（Android ABI）';
    }
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return '当前设备 CPU 架构: x86_64（Linux）';
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return '当前设备 CPU 架构: macos（macOS）';
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return '当前设备 CPU 架构: x86_64（Windows）';
    }
    return '当前设备 CPU 架构: 未知';
  }

  /// 判断资产文件名是否匹配当前设备架构
  static bool assetMatchesDevice(String fileName) {
    final lower = fileName.toLowerCase();
    if (_abi == null) return true; // 无法判断时视为匹配

    // universal 通用包总是匹配
    if (lower.contains('universal')) return true;

    switch (_abi) {
      case 'arm64-v8a':
        return lower.contains('arm64') || lower.contains('arm64-v8a');
      case 'armeabi-v7a':
        return lower.contains('armeabi-v7a') || lower.contains('arm32');
      case 'x86_64':
        return lower.contains('x86_64');
      case 'x86':
        return lower.contains('x86') && !lower.contains('x86_64');
      default:
        return true;
    }
  }

  /// 从文件列表中选择匹配当前架构的项
  /// 优先匹配架构，其次选择 APK 文件，最后回退到第一项
  static T? selectBestAsset<T>(
    List<T> items,
    String Function(T item) nameExtractor, {
    bool Function(T item)? isApk,
  }) {
    if (items.isEmpty) return null;

    // 1. 匹配架构的 APK
    for (final item in items) {
      final name = nameExtractor(item).toLowerCase();
      final isApkFile = isApk?.call(item) ?? name.endsWith('.apk');
      if (isApkFile && assetMatchesDevice(nameExtractor(item))) {
        return item;
      }
    }

    // 2. 匹配架构的任何文件
    for (final item in items) {
      if (assetMatchesDevice(nameExtractor(item))) {
        return item;
      }
    }

    // 3. 回退：任何 APK
    if (isApk != null) {
      for (final item in items) {
        if (isApk(item)) return item;
      }
    }

    // 4. 回退：第一项
    return items.first;
  }

  /// 从下载列表中选择匹配当前设备架构的最佳包
  /// 规则：
  ///   1. 匹配设备架构的 APK（如 arm64-v8a 设备优先选 arm64 APK）
  ///   2. universal 通用包兜底
  ///   3. 任意 APK
  ///   4. 第一项
  /// 单一项时直接返回（无需选择）
  static Future<DownloadInfo?> selectBestDownload(
    List<DownloadInfo> downloads,
  ) async {
    if (downloads.isEmpty) return null;
    if (downloads.length == 1) return downloads.first;

    // 确保 ABI 已检测
    await detectAbi();

    return selectBestAsset<DownloadInfo>(
      downloads,
      (d) => d.name,
      isApk: (d) => d.name.toLowerCase().endsWith('.apk'),
    );
  }
}
