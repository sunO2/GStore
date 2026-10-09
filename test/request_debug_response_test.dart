/// 「请求调试」响应查看器测试。
///
/// 覆盖验收标准：
/// - 各 `Content-Type` 渲染（JSON 高亮 / XML 缩进 / HTML / 文本）；
/// - `格式化 / 原始` 切换**确实改变**渲染文本；
/// - JSON 高亮树：多 token 样式、行号 gutter、折叠子树、全量搜索；
/// - 超过 256KB 的 JSON 回退到分块纯文本路径；
/// - Cookie 表（名称 / 值 / 域 / 过期）行内容精确；
/// - 超长 Body 分块（首屏只建首个分块的字符数，展开后增长）；
/// - 搜索基于完整 bodyText，可展开可见文本以包含命中位置；
/// - 二进制 / 非文本安全占位，不渲染原始字节、不崩；
/// - 360dp 下头部 / Cookie 表无溢出；
/// - `复制` 写入剪贴板；`保存为改写响应` 生成的规则字段精确。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/page/request_debug/response_viewer.dart';

DebugResponse _response({
  int statusCode = 200,
  Map<String, List<String>> headers = const <String, List<String>>{},
  String body = '',
  List<int> bytes = const <int>[],
  List<DebugCookie> cookies = const <DebugCookie>[],
  int durationMs = 0,
  int? sizeBytes,
  String? error,
  bool truncated = false,
}) =>
    DebugResponse(
      statusCode: statusCode,
      headers: headers,
      bodyBytes: bytes,
      bodyText: body,
      cookies: cookies,
      durationMs: durationMs,
      sizeBytes: sizeBytes ?? body.length,
      error: error,
      truncated: truncated,
    );

Widget _host(Widget child) => MaterialApp(      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

Future<void> _pump(WidgetTester tester, DebugResponse response,
        {ResponseViewer? viewer}) async {
  await tester.pumpWidget(
    _host(viewer ?? ResponseViewer(response: response)),
  );
  await tester.pumpAndSettle();
}

/// 行内 Body → 点「全屏查看」进入全屏响应体页。
Future<void> _openFullscreen(WidgetTester tester, DebugResponse response) async {
  await _pump(tester, response);
  await tester.tap(find.byKey(const Key('response-body-fullscreen')));
  await tester.pumpAndSettle();
}

/// 缩放相关 key（全屏页）。
const Key _zoomIn = Key('response-fullscreen-zoom-in');
const Key _zoomOut = Key('response-fullscreen-zoom-out');
const Key _zoomReset = Key('response-fullscreen-zoom-reset');
const Key _zoomLevel = Key('response-fullscreen-zoom-level');

/// 读取缩放级别标签文本。
String _zoomLabel(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_zoomLevel)).data ?? '';

/// 读取某个 key 下文本控件（`Text` / `SelectableText`）的纯文本。
///
/// 新的高亮/搜索渲染使用 `Text.rich` / `SelectableText.rich`（`data == null`，
/// `textSpan != null`），故不能只读 `SelectableText.data`。
String _plainTextOf(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return '';
  final widget = tester.widget(finder);
  if (widget is SelectableText) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  return '';
}

String _bodyText(WidgetTester tester, {String prefix = 'response-body'}) =>
    _plainTextOf(tester, '$prefix-text');

/// JSON 高亮树中渲染的全部文本（含 gutter 行号）。
String _treeText(WidgetTester tester) {
  final buffer = StringBuffer();
  final finder = find.descendant(
    of: find.byKey(const Key('response-body-tree')),
    matching: find.byType(Text),
  );
  for (final element in finder.evaluate()) {
    final text = element.widget as Text;
    buffer.writeln(text.data ?? text.textSpan?.toPlainText() ?? '');
  }
  return buffer.toString();
}

/// JSON 高亮树中出现的 token 颜色集合（用于证明存在多种 token 样式）。
Set<Color?> _treeTokenColors(WidgetTester tester) {
  final colors = <Color?>{};
  final finder = find.descendant(
    of: find.byKey(const Key('response-body-tree')),
    matching: find.byType(Text),
  );
  for (final element in finder.evaluate()) {
    final text = element.widget as Text;
    text.textSpan?.visitChildren((span) {
      if (span is TextSpan && span.text != null && span.style != null) {
        colors.add(span.style!.color);
      }
      return true;
    });
  }
  return colors;
}

/// 真实 loopback 客户端覆盖：绕过 `TestWidgetsFlutterBinding` 注入的假客户端
/// （它会让所有 `HttpClient` 请求返回 400）。空子类沿用基类的真实客户端实现。
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('头部（状态 / 耗时 / 大小 / 开关）', () {
    testWidgets('渲染状态码、耗时、大小，且格式化/原始开关存在', (tester) async {
      await _pump(
        tester,
        _response(
          statusCode: 201,
          durationMs: 1500,
          sizeBytes: 2048,
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'hello',
        ),
      );

      final status = tester.widget<Text>(
        find.byKey(const Key('request-editor-response-status')),
      );
      expect(status.data, '201');
      final duration = tester.widget<Text>(
        find.byKey(const Key('response-duration')),
      );
      expect(duration.data, '1.50 s');
      final size = tester.widget<Text>(find.byKey(const Key('response-size')));
      expect(size.data, '2.00 KB');
      expect(
        find.byKey(const Key('response-format-formatted')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('response-format-raw')), findsOneWidget);
      expect(find.byKey(const Key('response-copy')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Body · 按 Content-Type 渲染 + 格式化切换', () {
    testWidgets('application/json → 高亮树格式化；原始为单行原文', (tester) async {
      const raw = '{"a":1,"b":[2,3]}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json; charset=utf-8'],
          },
          body: raw,
        ),
      );

      expect(find.byKey(const Key('response-body-tree')), findsOneWidget);
      expect(find.byKey(const Key('response-body-gutter')), findsOneWidget);
      final formatted = _treeText(tester);
      expect(formatted, contains('"a": 1'));
      expect(formatted, contains('\n'));

      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), raw);
      expect(find.byKey(const Key('response-body-tree')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('application/xml → 格式化按标签缩进', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/xml'],
          },
          body: '<root><a>1</a></root>',
        ),
      );

      final formatted = _bodyText(tester);
      expect(formatted, contains('<root>'));
      expect(formatted, contains('  <a>'));
      expect(formatted, contains('</a>'));
      expect(formatted.split('\n').length, greaterThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('text/html → 渲染 HTML 源文本', (tester) async {
      const html = '<h1>hi</h1><p>x</p>';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/html; charset=utf-8'],
          },
          body: html,
        ),
      );
      expect(_bodyText(tester), html);
      expect(tester.takeException(), isNull);
    });

    testWidgets('text/plain → 原文渲染', (tester) async {
      const text = 'hello world\nsecond line';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: text,
        ),
      );
      expect(_bodyText(tester), text);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法 JSON → 回退原文并提示解析失败', (tester) async {
      const raw = '{not json}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: raw,
        ),
      );
      expect(_bodyText(tester), raw);
      expect(find.textContaining('JSON 解析失败'), findsOneWidget);
      expect(find.byKey(const Key('response-body-tree')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('原始分段始终展示未格式化原文', (tester) async {
      const raw = '{"a":1}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: raw,
        ),
      );
      await tester.tap(find.byKey(const Key('response-tab-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester, prefix: 'response-raw'), raw);
      expect(tester.takeException(), isNull);
    });
  });

  group('JSON 高亮树 · token / gutter / 折叠 / 搜索', () {
    testWidgets('多类型 JSON → 多种 token 样式 + gutter', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1,"b":[true,null,"s"],"c":3.5}',
        ),
      );

      final tree = find.byKey(const Key('response-body-tree'));
      expect(tree, findsOneWidget);
      expect(find.byKey(const Key('response-body-gutter')), findsOneWidget);
      // RichText / TextSpan 数量 > 1（高亮要求多种 token 样式）。
      expect(
        find.descendant(of: tree, matching: find.byType(RichText)),
        findsWidgets,
      );
      expect(_treeTokenColors(tester).length, greaterThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('折叠子树 → 该子树文本消失', (tester) async {
      const raw = '{"outer":{"marker":"unique1337"},"tail":1}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: raw,
        ),
      );

      expect(find.textContaining('unique1337'), findsOneWidget);
      final lines = tryPrettyJson(raw)!.split('\n');
      final markerLine = lines.indexWhere((line) => line.contains('unique1337'));
      final region = jsonFoldRegions(lines).firstWhere(
        (r) => r.openLine < markerLine && r.closeLine >= markerLine,
      );
      expect(region.id, isNonNegative);

      await tester.tap(
        find.byKey(Key('response-body-collapse-${region.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('unique1337'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('inline Body（JSON 树）不渲染搜索框，仅提供全屏入口', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1}',
        ),
      );

      expect(find.byKey(const Key('response-body-tree')), findsOneWidget);
      expect(find.byKey(const Key('response-body-search')), findsNothing);
      expect(find.byKey(const Key('response-body-search-input')), findsNothing);
      expect(find.byKey(const Key('response-body-fullscreen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('inline Body（分块纯文本）不渲染搜索框，仅提供全屏入口', (tester) async {
      final huge = 'A' * 120000;
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: huge,
        ),
      );

      expect(find.byKey(const Key('response-body-text')), findsOneWidget);
      expect(find.byKey(const Key('response-body-more')), findsOneWidget);
      expect(find.byKey(const Key('response-body-search')), findsNothing);
      expect(find.byKey(const Key('response-body-search-input')), findsNothing);
      expect(find.byKey(const Key('response-body-fullscreen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏查看：搜索基于完整 bodyText 并展开命中，关闭返回 Body', (tester) async {
      const marker = 'NEEDLE_AT_TAIL_917';
      final huge = 'A' * 190000 + marker + 'B' * 9000;
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: huge,
        ),
      );

      expect(find.byKey(const Key('response-body-search-input')), findsNothing);
      await tester.tap(find.byKey(const Key('response-body-fullscreen')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('response-body-fullscreen-view')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('response-fullscreen-search-input')),
        findsOneWidget,
      );
      // 搜索前只渲染首个分块，命中不在可见文本中。
      expect(
        _bodyText(tester, prefix: 'response-fullscreen').contains(marker),
        isFalse,
      );

      await tester.enterText(
        find.byKey(const Key('response-fullscreen-search-input')),
        marker,
      );
      await tester.pumpAndSettle();

      // 全量搜索：可见文本已包含命中且超过单块长度。
      final shown = _bodyText(tester, prefix: 'response-fullscreen');
      expect(shown.contains(marker), isTrue);
      expect(shown.length, greaterThan(ResponseViewer.chunkChars));

      // 关闭全屏返回 Body 分段。
      await tester.tap(find.byKey(const Key('response-body-fullscreen-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('response-body-fullscreen-view')), findsNothing);
      expect(find.byKey(const Key('response-tab-body')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏查看：>256KB JSON 走分块路径，关闭无异常', (tester) async {
      final big = '{"data":"${'x' * (256 * 1024)}"}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: big,
        ),
      );

      expect(find.byKey(const Key('response-body-more')), findsOneWidget);
      expect(find.byKey(const Key('response-body-tree')), findsNothing);

      await tester.tap(find.byKey(const Key('response-body-fullscreen')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('response-fullscreen-more')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('response-fullscreen-tree')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏查看：非法 JSON 回退纯文本无异常', (tester) async {
      const raw = '{not json}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: raw,
        ),
      );

      await tester.tap(find.byKey(const Key('response-body-fullscreen')));
      await tester.pumpAndSettle();

      expect(_bodyText(tester, prefix: 'response-fullscreen'), raw);
      expect(find.textContaining('JSON 解析失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('超过 256KB 的 JSON → 分块纯文本路径，无异常', (tester) async {
      final big = '{"data":"${'x' * (256 * 1024)}"}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: big,
        ),
      );

      expect(find.byKey(const Key('response-body-more')), findsOneWidget);
      expect(find.byKey(const Key('response-body-tree')), findsNothing);
      expect(find.byKey(const Key('response-body-gutter')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('全屏缩放 · 行号对齐', () {
    testWidgets('放大 → JSON 字号与 gutter 行高同比增大且始终对齐', (tester) async {
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1,"b":[true,null,"s"],"c":3.5}',
        ),
      );

      final gutterFinder = find.byKey(const Key('response-fullscreen-gutter'));
      final jsonFinder = find.byKey(const Key('response-fullscreen-json'));
      expect(gutterFinder, findsOneWidget);
      expect(jsonFinder, findsOneWidget);

      double contentFontSize() =>
          tester.widget<Text>(jsonFinder).style!.fontSize!;
      double gutterHeight() => tester.getSize(gutterFinder).height;
      double jsonHeight() => tester.getSize(jsonFinder).height;

      final font0 = contentFontSize();
      final gutter0 = gutterHeight();
      expect(font0, AppTypography.sizeSM);
      // 1.0 时行号 gutter 与 JSON 内容等高（对齐）。
      expect(gutter0, closeTo(jsonHeight(), 0.01));

      // 放大一步（1.0 → 1.25）：字号按步长增大，gutter 同步变高。
      await tester.tap(find.byKey(_zoomIn));
      await tester.pumpAndSettle();
      expect(contentFontSize(), closeTo(font0 * 1.25, 0.001));
      expect(gutterHeight(), greaterThan(gutter0));
      // 放大后行号仍与内容行等高（对齐）。
      expect(gutterHeight(), closeTo(jsonHeight(), 0.01));

      // 放大到 2.0：缩放因子为整数倍，字号与 gutter 行高来自同一缩放源，
      // 均为 2×（行盒取整的误差在此归零）。
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(_zoomIn));
        await tester.pumpAndSettle();
      }
      final fontMax = contentFontSize();
      final gutterMax = gutterHeight();
      expect(fontMax, closeTo(font0 * 2.0, 0.001));
      expect(gutterMax / gutter0, closeTo(fontMax / font0, 1e-6));
      expect(gutterMax, closeTo(jsonHeight(), 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('缩小 / 级别标签 / 重置回 1.0', (tester) async {
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1}',
        ),
      );

      final jsonFinder = find.byKey(const Key('response-fullscreen-json'));
      double fontSize() => tester.widget<Text>(jsonFinder).style!.fontSize!;

      expect(_zoomLabel(tester), '100%');
      final base = fontSize();

      await tester.tap(find.byKey(_zoomIn));
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '125%');

      await tester.tap(find.byKey(_zoomOut));
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '100%');

      await tester.tap(find.byKey(_zoomIn));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_zoomIn));
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '150%');

      await tester.tap(find.byKey(_zoomReset));
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '100%');
      expect(fontSize(), closeTo(base, 0.001));

      // 缩小：字号变小。
      await tester.tap(find.byKey(_zoomOut));
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '75%');
      expect(fontSize(), lessThan(base));
      expect(tester.takeException(), isNull);
    });

    testWidgets('在上下限 0.75 / 2.0 处钳制且不抛异常', (tester) async {
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1}',
        ),
      );

      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byKey(_zoomIn));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '200%');

      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byKey(_zoomOut));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '75%');
      expect(tester.takeException(), isNull);
    });

    testWidgets('分块纯文本同样按缩放因子变大', (tester) async {
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'line1\nline2\nline3',
        ),
      );

      final textFinder = find.byKey(const Key('response-fullscreen-text'));
      expect(textFinder, findsOneWidget);
      double fontSize() =>
          tester.widget<SelectableText>(textFinder).style!.fontSize!;

      final base = fontSize();
      expect(base, AppTypography.sizeSM);

      await tester.tap(find.byKey(_zoomIn));
      await tester.pumpAndSettle();
      expect(fontSize(), closeTo(base * 1.25, 0.001));
      expect(tester.takeException(), isNull);
    });

    testWidgets('行内 Body 无缩放控件且保持默认字号', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1}',
        ),
      );

      final jsonFinder = find.byKey(const Key('response-body-json'));
      expect(jsonFinder, findsOneWidget);
      expect(tester.widget<Text>(jsonFinder).style!.fontSize,
          AppTypography.sizeSM);
      expect(find.byKey(_zoomIn), findsNothing);
      expect(find.byKey(_zoomOut), findsNothing);
      expect(find.byKey(_zoomLevel), findsNothing);
      expect(find.byKey(_zoomReset), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('放大到 2.0× → gutter 行号框宽度同步 2×，不裁切/不抛异常', (tester) async {
      // ≥10 行 JSON：行号可达两位数。
      final body = '{"k0":0,${[for (var i = 1; i < 12; i++) '"k$i":$i'].join(',')}}';
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: body,
        ),
      );

      // 行数 ≥ 10（含两位数行号）。
      expect(tryPrettyJson(body)!.split('\n').length, greaterThanOrEqualTo(10));

      final numFinder = find.byKey(const Key('response-fullscreen-num-0'));
      expect(numFinder, findsOneWidget);
      final width0 = tester.getSize(numFinder).width;
      expect(width0, greaterThan(0));

      // 放大到 2.0×（1.0 → 1.25 → 1.5 → 1.75 → 2.0）。
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(_zoomIn));
        await tester.pumpAndSettle();
      }
      expect(_zoomLabel(tester), '200%');

      final widthMax = tester.getSize(numFinder).width;
      expect(widthMax / width0, closeTo(2.0, 0.001));
      expect(tester.takeException(), isNull);
    });
  });

  group('Cookie 表', () {
    testWidgets('名称 / 值 / 域 / 过期 行内容精确', (tester) async {
      final response = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['text/plain'],
          'set-cookie': <String>[
            'sid=abc; Path=/; Max-Age=3600',
            'theme=dark; Domain=.example.com',
          ],
        },
        body: 'ok',
        cookies: const <DebugCookie>[
          DebugCookie(name: 'sid', value: 'abc', domain: 'api.example.com', path: '/'),
          DebugCookie(name: 'theme', value: 'dark', domain: '.example.com'),
        ],
      );
      await _pump(tester, response);

      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('response-cookie-row-sid-0')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-sid-name')))
            .data,
        'sid',
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('response-cookie-sid-value')),
            )
            .data,
        'abc',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-sid-domain')))
            .data,
        'api.example.com',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-sid-expires')))
            .data,
        'Max-Age 3600 s',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-theme-expires')))
            .data,
        '会话',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 Cookie → 空态', (tester) async {
      await _pump(tester, _response(body: 'ok'));
      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();
      expect(find.text('无 Cookie'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('头 表', () {
    testWidgets('逐条渲染响应头', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
            'server': <String>['nginx'],
          },
          body: '{}',
        ),
      );
      await tester.tap(find.byKey(const Key('response-tab-headers')));
      await tester.pumpAndSettle();
      expect(find.text('content-type'), findsOneWidget);
      expect(find.text('application/json'), findsOneWidget);
      expect(find.text('server'), findsOneWidget);
      expect(find.text('nginx'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360dp 下头部 / Cookie 表无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final response = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['text/plain'],
          'content-security-policy-report-only': <String>[
            'default-src https:; report-uri https://example.com/report',
          ],
          'set-cookie': <String>[
            'session=abcdefghijklmnopqrstuvwxyz0123456789; Path=/; Domain=.example.com',
          ],
        },
        body: 'ok',
        cookies: const <DebugCookie>[
          DebugCookie(
            name: 'session',
            value: 'abcdefghijklmnopqrstuvwxyz0123456789',
            domain: 'api.example.com',
          ),
        ],
      );
      await _pump(tester, response);

      await tester.tap(find.byKey(const Key('response-tab-headers')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('重发重置', () {
    testWidgets('换一次响应 → 回到 Body 默认态，格式化回默认，且不抛异常', (tester) async {
      final first = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
        },
        body: '{"first":1}',
      );
      final second = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
        },
        body: '{"second":2}',
      );

      await _pump(tester, first);
      // 手动切到原始分段 + 原始格式，模拟用户上一次交互残留。
      await tester.tap(find.byKey(const Key('response-tab-raw')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester, prefix: 'response-raw'), '{"first":1}');

      // 重发：换一个响应实例，查看器应重置回 Body + 格式化（高亮树）。
      await _pump(tester, second);
      expect(_treeText(tester), contains('"second": 2'));
      expect(find.byKey(const Key('response-body-gutter')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('超长 Body 分块', () {
    testWidgets('首屏只建首个分块，展开更多后字符数增长且不崩', (tester) async {
      final huge = 'A' * 200000;
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: huge,
        ),
      );

      expect(_bodyText(tester).length, ResponseViewer.chunkChars);
      final more = find.byKey(const Key('response-body-more'));
      expect(more, findsOneWidget);
      expect(find.textContaining('剩余 180000 字符'), findsOneWidget);

      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(_bodyText(tester).length, ResponseViewer.chunkChars * 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('二进制 / 非文本安全展示', () {
    testWidgets('image/png → 安全占位，不渲染原始文本，不崩', (tester) async {
      final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03];
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['image/png'],
          },
          body: DebugResponse.textPreview(bytes),
          bytes: bytes,
          sizeBytes: bytes.length,
        ),
      );

      expect(find.byKey(const Key('response-body-binary')), findsOneWidget);
      expect(find.text('二进制 / 非文本内容'), findsOneWidget);
      expect(find.byKey(const Key('response-body-text')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 Content-Type 但含 NUL → 判为二进制并安全占位', (tester) async {
      await _pump(
        tester,
        _response(body: 'ab\u0000cd'),
      );
      expect(find.byKey(const Key('response-body-binary')), findsOneWidget);
      expect(find.byKey(const Key('response-body-text')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('二进制复制 → base64，解码后字节完全一致；卡片可点击', (tester) async {
      final bytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF,
      ];
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['image/png'],
          },
          body: DebugResponse.textPreview(bytes),
          bytes: bytes,
          sizeBytes: bytes.length,
        ),
      );

      // 卡片必须真正可点（旧实现无任何手势，点击不产生复制）。
      await tester.tap(find.byKey(const Key('response-body-binary')));
      await tester.pumpAndSettle();

      expect(copied, isNotEmpty, reason: '点击二进制卡片必须触发复制');
      // 复制内容必须是 base64，解码后与原始字节逐字节一致（旧实现走 UTF-8
      // 预览会损坏任意二进制）。
      expect(base64.decode(copied.last), bytes);
      expect(tester.takeException(), isNull);
    });
  });

  group('截断 / 真实大小', () {
    test('>cap 响应：truncated=true 且 size 为 Content-Length 真实值', () async {
      final total = DebugSender.maxBodyBytes + 8192;
      final body = Uint8List(total)..fillRange(0, total, 0x41);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.text;
        request.response.contentLength = total;
        try {
          request.response.add(body);
          await request.response.close();
        } catch (_) {
          // 客户端达到上限后停止读取，服务端写入可能抛错，属预期。
        }
      });

      // `TestWidgetsFlutterBinding` 会把 `HttpOverrides` 换成返回 400 的假客户端；
      // 本用例需要真实 loopback 连接。注意 `IOClient` 在**构造时**就创建
      // `HttpClient`，故 sender 必须在真实覆盖的 zone 内创建（仅作用于本 zone）。
      late final DebugSender sender;
      final response = await HttpOverrides.runWithHttpOverrides(
        () {
          sender = DebugSender();
          return sender.send(
            method: 'GET',
            url: 'http://127.0.0.1:${server.port}/big',
            timeout: const Duration(seconds: 30),
          );
        },
        _RealHttpOverrides(),
      );
      addTearDown(sender.close);

      expect(response.error, isNull);
      expect(response.statusCode, 200);
      expect(response.truncated, isTrue, reason: '超过读取上限必须标记 truncated');
      expect(response.bodyBytes.length, DebugSender.maxBodyBytes,
          reason: '原始字节必须在 cap 处截断');
      expect(response.sizeBytes, total,
          reason: 'sizeBytes 必须是 Content-Length 声明的真实大小，而非截断后长度');
    });

    testWidgets('UI 标注「已截断」且大小显示真实值', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
            'content-length': <String>['9000000'],
          },
          body: 'A' * 100,
          sizeBytes: 9000000,
          truncated: true,
        ),
      );

      expect(find.byKey(const Key('response-truncated')), findsOneWidget);
      expect(find.text('已截断'), findsOneWidget);
      final size = tester.widget<Text>(find.byKey(const Key('response-size')));
      expect(size.data, byteSize(9000000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('未截断响应不显示「已截断」', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'small',
        ),
      );
      expect(find.byKey(const Key('response-truncated')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大响应回退分块渲染且无异常', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'A' * 120000,
        ),
      );
      expect(find.byKey(const Key('response-body-more')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('保存为改写响应 · 头卫生 / 错误禁存', () {
    test('剥离 hop-by-hop / content-encoding / content-length / transfer-encoding', () {
      final response = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
          'content-encoding': <String>['gzip'],
          'content-length': <String>['123'],
          'transfer-encoding': <String>['chunked'],
          'connection': <String>['keep-alive, x-custom-hop'],
          'keep-alive': <String>['timeout=5'],
          'x-custom-hop': <String>['secret'],
          'x-extra': <String>['v1'],
        },
        body: '{}',
      );

      final headers = response.rewriteRuleHeaders();
      final names = headers.map((h) => h.name.toLowerCase()).toSet();
      for (final banned in const <String>[
        'content-encoding',
        'content-length',
        'transfer-encoding',
        'connection',
        'keep-alive',
        'x-custom-hop',
      ]) {
        expect(names.contains(banned), isFalse, reason: '$banned 必须被剥离');
      }
      expect(
        headers.any((h) =>
            h.name.toLowerCase() == 'content-type' &&
            h.value == 'application/json'),
        isTrue,
        reason: '语义头必须保留',
      );
      expect(
        headers.any(
            (h) => h.name.toLowerCase() == 'x-extra' && h.value == 'v1'),
        isTrue,
        reason: '普通头必须保留',
      );
    });

    testWidgets('错误响应禁用保存为改写', (tester) async {
      DebugRewriteRule? captured;
      final response = _response(error: '连接失败', statusCode: 0);
      await _pump(
        tester,
        response,
        viewer: ResponseViewer(
          response: response,
          method: 'GET',
          url: 'https://api.example/x',
          onSaveAsRewrite: (rule) async {
            captured = rule;
            return CaptureRulesResult<DebugRewriteRule>.success(rule);
          },
        ),
      );

      final button = tester.widget<TextButton>(
        find.byKey(const Key('response-save-rewrite')),
      );
      expect(button.onPressed, isNull, reason: '错误响应必须禁用保存');
      await tester.tap(
        find.byKey(const Key('response-save-rewrite')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(captured, isNull);
      expect(find.text('保存为改写响应？'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('动作', () {
    testWidgets('复制 → 剪贴板写入当前展示文本', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'copy me',
        ),
      );
      await tester.tap(find.byKey(const Key('response-copy')));
      await tester.pumpAndSettle();
      expect(copied, isNotEmpty);
      expect(copied.last, 'copy me');
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存为改写响应 → 生成的规则字段精确并经门面结果提示', (tester) async {
      DebugRewriteRule? captured;
      final response = _response(
        statusCode: 503,
        durationMs: 12,
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
          'content-encoding': <String>['gzip'],
          'content-length': <String>['17'],
          'transfer-encoding': <String>['chunked'],
          'connection': <String>['keep-alive'],
          'x-extra': <String>['v1'],
        },
        body: '{"error":"down"}',
      );
      await _pump(
        tester,
        response,
        viewer: ResponseViewer(
          response: response,
          method: 'POST',
          url: 'https://api.example/x',
          onSaveAsRewrite: (rule) async {
            captured = rule;
            return CaptureRulesResult<DebugRewriteRule>.success(rule);
          },
        ),
      );

      await tester.tap(find.byKey(const Key('response-save-rewrite')));
      await tester.pumpAndSettle();
      expect(find.text('保存为改写响应？'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.url, 'https://api.example/x');
      expect(captured!.method, 'POST');
      expect(captured!.kind, DebugRewriteKind.replaceResponse);
      expect(captured!.statusCode, 503);
      expect(captured!.respBody, '{"error":"down"}');
      expect(
        captured!.respHeaders!.any(
          (h) => h.name == 'x-extra' && h.value == 'v1',
        ),
        isTrue,
      );
      final rewriteNames =
          captured!.respHeaders!.map((h) => h.name.toLowerCase()).toSet();
      for (final banned in const <String>[
        'content-encoding',
        'content-length',
        'transfer-encoding',
        'connection',
      ]) {
        expect(rewriteNames.contains(banned), isFalse,
            reason: '$banned 不得出现在改写响应头中');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('JSON 词法 / 折叠（纯逻辑）', () {
    test('tokenizeJsonLine 识别 key / string / number / keyword / 标点', () {
      final kinds = tokenizeJsonLine('  "name": "value", "ok": true, "n": -3.5e2')
          .map((token) => token.kind)
          .toSet();
      expect(kinds, contains(JsonTokenKind.key));
      expect(kinds, contains(JsonTokenKind.string));
      expect(kinds, contains(JsonTokenKind.number));
      expect(kinds, contains(JsonTokenKind.keyword));
      expect(kinds, contains(JsonTokenKind.punctuation));
    });

    test('jsonFoldRegions 找到对象与数组区间', () {
      const raw = '{"a":[1,2],"b":{"c":3}}';
      final regions = jsonFoldRegions(tryPrettyJson(raw)!.split('\n'));
      expect(regions.length, 3);
      expect(regions.map((r) => r.id).toSet().length, 3);
      for (final region in regions) {
        expect(region.closeLine, greaterThan(region.openLine));
      }
    });

    test('jsonFoldRegions 忽略空容器单行', () {
      final regions = jsonFoldRegions(
        tryPrettyJson('{"a":{},"b":[]}')!.split('\n'),
      );
      // 仅根对象形成区间；内联的空 `{}` / `[]` 不新增区间。
      expect(regions.length, 1);
      expect(regions.single.openLine, 0);
    });
  });
}
