import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart' show applyProxyIfNeeded, getProxy;
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

  testWidgets('GitHub URL：默认开启代理前缀，QR 数据为代理 URL 且显示开关', (tester) async {
    final detail = _FakeDetailInfo();
    const url = 'https://github.com/sunO2/GStore/releases/download/v1.0.0/app.apk';
    final download = DownloadInfo(url: url, name: 'app.apk');
    // 未配置代理时 getProxy() 返回 defaultProxy，GitHub URL 会被代理
    final proxied = applyProxyIfNeeded(url, getProxy());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: buildQrDialogContent(detail, download)),
        ),
      ),
    );

    // QrImageView.data 在 qr_flutter 4.1.0 为库私有（无公开 getter），
    // 通过渲染的 URL 小字断言同一份 qrData 值
    expect(_qrCaption(tester), proxied);
    expect(proxied, isNot(url));
    // 开关存在（可切换到原始 URL）
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('代理前缀'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GitHub URL：关闭代理开关后 QR 数据切换为原始 URL', (tester) async {
    final detail = _FakeDetailInfo();
    const url = 'https://github.com/sunO2/GStore/releases/download/v1.0.0/app.apk';
    final download = DownloadInfo(url: url, name: 'app.apk');
    final proxied = applyProxyIfNeeded(url, getProxy());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: buildQrDialogContent(detail, download)),
        ),
      ),
    );
    expect(_qrCaption(tester), proxied);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    // 关闭后切换为原始 URL（重新生成）
    expect(_qrCaption(tester), url);
    expect(find.text(proxied), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 GitHub URL：不显示代理开关，QR 数据为原始 URL', (tester) async {
    final detail = _FakeDetailInfo();
    const url = 'https://example.com/a.apk';
    final download = DownloadInfo(url: url, name: 'a.apk');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: buildQrDialogContent(detail, download)),
        ),
      ),
    );

    expect(_qrCaption(tester), url);
    expect(find.byType(Switch), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 读取二维码弹窗内 URL 小字（与 QrImageView.data 同一份 qrData 值；
/// qr_flutter 4.1.0 的 data 为库私有字段，无公开 getter 可直接断言）
String? _qrCaption(WidgetTester tester) {
  return tester
      .widget<Text>(find.byKey(const Key('qr_data_caption')))
      .data;
}
