import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/image/app_image.dart';
import 'package:gstore/core/image/app_image_loader.dart';
import 'package:gstore/core/image/image_type_detector.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---- fixture ----

/// 1×1 RGBA 透明 PNG（标准魔数 + 有效 CRC + zlib 流，可被 Flutter 解码）。
final Uint8List kPngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

/// 100×20 SVG 文本。
final Uint8List kSvgBytes = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="20">'
  '<rect width="100" height="20" fill="red"/></svg>',
);

const String kPngUrl = 'https://example.com/icon.png';
const String kSvgUrl = 'https://example.com/icon.svg';
const String kBadgeUrl =
    'https://img.shields.io/badge/build-passing-brightgreen.svg';
const String k404Url = 'https://example.com/missing.png';

/// 构造按 URL 分发响应的 MockClient；[requestCount] 记录请求次数。
MockClient buildMockClient({void Function(int count)? onRequest}) {
  var count = 0;
  final mock = MockClient((request) async {
    count++;
    onRequest?.call(count);
    // 引入真实定时器延迟：保证首个 pumpWidget 帧必然停留在 placeholder。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final url = request.url.toString();
    switch (url) {
      case kPngUrl:
        return http.Response.bytes(
          kPngBytes,
          200,
          headers: const {'content-type': 'image/png'},
        );
      case kSvgUrl:
        return http.Response.bytes(
          kSvgBytes,
          200,
          headers: const {'content-type': 'image/svg+xml'},
        );
      case kBadgeUrl:
        return http.Response.bytes(
          kSvgBytes,
          200,
          headers: const {'content-type': 'image/svg+xml'},
        );
      default:
        return http.Response('Not Found', 404);
    }
  });
  return mock;
}

void main() {
  group('isBadgeUrl', () {
    test('含 img.shields.io 的 URL → true', () {
      expect(isBadgeUrl('https://img.shields.io/badge/ok-green.svg'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isBadgeUrl('https://IMG.SHIELDS.IO/badge/ok'), isTrue);
    });

    test('普通图片 URL → false', () {
      expect(isBadgeUrl('https://example.com/icon.png'), isFalse);
    });

    test('空字符串 → false', () {
      expect(isBadgeUrl(''), isFalse);
    });
  });

  group('resolveImageDisplaySize', () {
    test('svg + badge URL → 宽保留，高钳制为 badgeHeight（默认 30）', () {
      expect(
        resolveImageDisplaySize(
          url: kBadgeUrl,
          format: ImageFormat.svg,
          width: 300,
          height: 200,
        ),
        const Size(300, 30),
      );
    });

    test('svg + badge URL + 自定义 badgeHeight', () {
      expect(
        resolveImageDisplaySize(
          url: kBadgeUrl,
          format: ImageFormat.svg,
          width: 300,
          height: 200,
          badgeHeight: 24,
        ),
        const Size(300, 24),
      );
    });

    test('svg + 非 badge URL → 原样宽高', () {
      expect(
        resolveImageDisplaySize(
          url: kSvgUrl,
          format: ImageFormat.svg,
          width: 200,
          height: 100,
        ),
        const Size(200, 100),
      );
    });

    test('非 svg（png）+ badge URL → 原样宽高', () {
      expect(
        resolveImageDisplaySize(
          url: kBadgeUrl,
          format: ImageFormat.png,
          width: 200,
          height: 100,
        ),
        const Size(200, 100),
      );
    });

    test('未知格式 → 原样宽高', () {
      expect(
        resolveImageDisplaySize(
          url: 'https://example.com/x.zzz',
          format: ImageFormat.unknown,
          width: 48,
          height: 48,
        ),
        const Size(48, 48),
      );
    });
  });

  group('AppImage widget', () {
    const placeholder = SizedBox(key: Key('placeholder'), width: 10, height: 10);
    const errorBox = SizedBox(key: Key('error'), width: 10, height: 10);

    late MockClient mock;

    setUp(() {
      mock = buildMockClient();
      AppImageLoader.instance.debugClient = mock;
      AppImageLoader.instance.clearCache();
    });

    // 真实用法：AppImage 嵌在布局里（home 直接子节点是 tight 全屏约束，
    // 会钳制子级尺寸），用 Center 提供 loose 约束以便断言 tight 尺寸。
    Widget wrap(Widget child) => MaterialApp(home: Center(child: child));

    testWidgets('PNG URL → 渲染 Image widget', (tester) async {
      await tester.pumpWidget(wrap(
        const AppImage(url: kPngUrl, width: 32, height: 32),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SVG URL → 渲染 SvgPicture', (tester) async {
      await tester.pumpWidget(wrap(
        const AppImage(url: kSvgUrl, width: 32, height: 32),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载完成前显示 placeholder', (tester) async {
      await tester.pumpWidget(wrap(
        const AppImage(
          url: kPngUrl,
          width: 32,
          height: 32,
          placeholder: placeholder,
        ),
      ));
      // 初始帧：下载尚未完成 → placeholder
      expect(find.byKey(const Key('placeholder')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('placeholder')), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('404 → 渲染 errorWidget', (tester) async {
      await tester.pumpWidget(wrap(
        const AppImage(
          url: k404Url,
          width: 32,
          height: 32,
          errorWidget: errorBox,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非 badge SVG：tight 尺寸 200x100', (tester) async {
      await tester.pumpWidget(wrap(
        const AppImage(url: kSvgUrl, width: 200, height: 100),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getSize(find.byType(SvgPicture)), const Size(200, 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('badge SVG：高度钳制为 badgeHeight', (tester) async {
      await tester.pumpWidget(wrap(
        const AppImage(
          url: kBadgeUrl,
          width: 300,
          height: 200,
          badgeHeight: 30,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getSize(find.byType(SvgPicture)), const Size(300, 30));
      expect(tester.takeException(), isNull);
    });

    testWidgets('缓存去重：同 URL 第二个实例命中缓存 → requestCount == 1',
        (tester) async {
      var requestCount = 0;
      AppImageLoader.instance.debugClient =
          buildMockClient(onRequest: (c) => requestCount = c);

      // 首个实例加载完成后，同屏追加第二个同 URL 实例
      await tester.pumpWidget(wrap(
        const AppImage(url: kPngUrl, width: 32, height: 32),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(requestCount, 1);

      await tester.pumpWidget(wrap(Column(
        children: const [
          AppImage(url: kPngUrl, width: 32, height: 32),
          AppImage(url: kPngUrl, width: 32, height: 32),
        ],
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(requestCount, 1);
      expect(find.byType(Image), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('PNG 加载成功 → onSuccess 触发；onError 不触发', (tester) async {
      var success = false;
      var error = false;
      await tester.pumpWidget(wrap(
        AppImage(
          url: kPngUrl,
          width: 32,
          height: 32,
          onSuccess: () => success = true,
          onError: (_) => error = true,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(success, isTrue);
      expect(error, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('404 → onError 触发；onSuccess 不触发', (tester) async {
      var success = false;
      var error = false;
      await tester.pumpWidget(wrap(
        AppImage(
          url: k404Url,
          width: 32,
          height: 32,
          onSuccess: () => success = true,
          onError: (_) => error = true,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(error, isTrue);
      expect(success, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
