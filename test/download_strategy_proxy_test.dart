import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart' show applyProxyIfNeeded, getProxy, resetProxyForTest;
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';

/// 下载代理前缀修复测试
///
/// 覆盖：
/// - BaseDownloadStrategy.applyProxy：releases 下载 URL 拼代理 / 已带代理防重 /
///   非下载 GitHub URL 不拼 / 空代理不拼
/// - applyProxyIfNeeded（渠道层语义）：完整 URL 前置代理 / 已带代理原样 / 空代理原样
/// - LocalDbDownloadStrategy.createRequest：复用 applyProxy（含防重，不二次拼）
class _TestStrategy extends BaseDownloadStrategy {
  @override
  ChannelType get supportedChannel => ChannelType.localDb;

  @override
  Future<DownloadRequest?> createRequest(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async => null;
}

class _FakeDetailInfo implements IDetailInfo {
  @override
  String get packageName => 'com.example.app';
  @override
  String get appName => '测试应用';
  @override
  String get icon => 'https://example.com/icon.png';
  @override
  String get description => '';
  @override
  String get appId => 'com.example.app';
  @override
  String get name => appName;
  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
  @override
  String get channelId => 'localdb';
  @override
  ChannelType get channelType => ChannelType.localDb;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => null;
  @override
  String? get projectUrl => null;
  @override
  List<DownloadInfo> get downloads => const [];
  @override
  List<DetailSection> get sections => const [DetailSection.downloads];
  @override
  Map<String, dynamic> get extra => const {};
  @override
  String? get readme => null;
  @override
  List<ScreenshotInfo>? get screenshots => null;
  @override
  String? get changelog => null;
  @override
  List<String>? get permissions => null;
  @override
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

void main() {
  const releaseUrl =
      'https://github.com/u/r/releases/download/v1.0/a.apk';
  const proxy = 'https://gh-proxy.org/';
  const proxiedUrl = 'https://gh-proxy.org/https://github.com/u/r/releases/download/v1.0/a.apk';

  setUp(() {
    // 保证 getProxy() 返回 defaultProxy（https://gh-proxy.org/）
    resetProxyForTest();
  });

  group('BaseDownloadStrategy.applyProxy', () {
    final strategy = _TestStrategy();

    test('releases 下载 URL → 拼代理前缀（路径模式）', () {
      expect(
        strategy.applyProxy(releaseUrl, proxy),
        'https://gh-proxy.org/u/r/releases/download/v1.0/a.apk',
      );
    });

    test('代理无尾斜杠 → 归一化后拼接', () {
      expect(
        strategy.applyProxy(releaseUrl, 'https://gh-proxy.org'),
        'https://gh-proxy.org/u/r/releases/download/v1.0/a.apk',
      );
    });

    test('已带代理 → 返回 null（不二次拼）', () {
      expect(strategy.applyProxy(proxiedUrl, proxy), isNull);
    });

    test('非下载 GitHub URL（api.github.com）→ 返回 null（不拼）', () {
      expect(
        strategy.applyProxy('https://api.github.com/repos/u/r/releases', proxy),
        isNull,
      );
    });

    test('proxy 为空 → 返回 null（不拼）', () {
      expect(strategy.applyProxy(releaseUrl, ''), isNull);
    });
  });

  group('applyProxyIfNeeded（渠道层语义）', () {
    test('GitHub 下载 URL → 完整 URL 前置代理', () {
      expect(applyProxyIfNeeded(releaseUrl, proxy), proxiedUrl);
    });

    test('已带代理 → 原样返回（不二次拼）', () {
      expect(applyProxyIfNeeded(proxiedUrl, proxy), proxiedUrl);
    });

    test('proxy 为空 → 原样返回（不拼）', () {
      expect(applyProxyIfNeeded(releaseUrl, ''), releaseUrl);
    });
  });

  group('LocalDbDownloadStrategy.createRequest（复用 applyProxy）', () {
    final strategy = LocalDbDownloadStrategy();
    final detail = _FakeDetailInfo();

    test('原始 GitHub 下载 URL → 拼代理前缀', () async {
      final request = await strategy.createRequest(
        DownloadInfo(url: releaseUrl, name: 'a.apk'),
        detail,
      );
      expect(request!.url, 'https://gh-proxy.org/u/r/releases/download/v1.0/a.apk');
    });

    test('已带代理 URL → 原样保留（不二次拼）', () async {
      final request = await strategy.createRequest(
        DownloadInfo(url: proxiedUrl, name: 'a.apk'),
        detail,
      );
      expect(request!.url, proxiedUrl);
    });
  });
}