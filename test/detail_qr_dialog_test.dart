import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// buildQrDialogContent 测试
///
/// 验证下载二维码弹窗内容：
/// - 白底 QR 平板（AppColors.white 可扫码性）
/// - QrImageView：data=下载链接、size=108、无 embeddedImage
/// - 下方 AppIcon(24×24) + 应用名称（bodySmall）
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
  String get channelId => 'github';
  @override
  ChannelType get channelType => ChannelType.github;
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
  testWidgets('渲染 QR 平板：白底、无 embeddedImage、size 108', (tester) async {
    final detail = _FakeDetailInfo();
    final download = DownloadInfo(
      url: 'https://example.com/app.apk',
      name: 'app.apk',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: buildQrDialogContent(detail, download),
          ),
        ),
      ),
    );

    // QrImageView：size=108 + 无 embeddedImage
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.size, 108);
    expect(qr.embeddedImage, isNull);

    // 白底容器
    final whiteContainer = tester.widget<Container>(
      find
          .ancestor(
              of: find.byType(QrImageView), matching: find.byType(Container))
          .first,
    );
    expect((whiteContainer.decoration! as BoxDecoration).color,
        const Color(0xFFFFFFFF));

    // 应用名称可见（bodySmall 字号）
    final nameText = tester.widget<Text>(find.text('测试应用'));
    expect(
        nameText.style?.fontSize,
        Theme.of(tester.element(find.text('测试应用')))
            .textTheme
            .bodySmall
            ?.fontSize);
    expect(tester.takeException(), isNull);
  });
}
