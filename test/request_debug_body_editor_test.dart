/// 「请求调试」请求体 JSON 校验 / 格式化测试（plan todo 14）。
///
/// 覆盖验收标准：
/// - 非法 JSON → `request-editor-body-format-error` 显示且 body 不变；
/// - 合法 JSON 点按 `request-editor-body-format` → body 等于 2 空格美化输出；
/// - `AppEditorToolbar.onFormat` 走同一函数（单一事实来源）产生相同结果；
/// - 非 JSON 类型不显示格式化入口；
/// - 再次编辑 / 成功格式化后错误清除。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 假发送器：**不触碰网络**（本测试不发送，仅满足门面依赖）。
class _FakeSender implements DebugSender {
  @override
  final DebugCookieJar cookieJar = DebugCookieJar();

  @override
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
  }) async {
    return const DebugResponse(statusCode: 200, bodyText: 'ok', sizeBytes: 2);
  }

  @override
  void close() {}
}

/// 测试门面：真实内存 store（不落盘，避免 fake-async 下的文件 IO）。
class _TestFacade extends DefaultRequestDebugFacade {
  _TestFacade()
      : super(
          store: RequestDebugStore(
            directoryProvider: () async => Directory.systemTemp,
          ),
          sender: _FakeSender(),
        );

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

/// 压入编辑器并切到「体」分段，seed 指定 body 与 bodyKind。
Future<void> _pumpBodyEditor(
  WidgetTester tester, {
  required String body,
  DebugBodyKind kind = DebugBodyKind.json,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: RequestEditorPage(
      facade: _TestFacade(),
      request: DebugRequest(
        id: 'req-body-test',
        name: 'body-test',
        method: 'POST',
        url: 'https://example.com',
        body: body,
        bodyKind: kind,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('request-editor-segment-body')));
  await tester.pumpAndSettle();
}

/// 当前 body 控制器的文本。
String _bodyText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('request-editor-body')))
    .controller!
    .text;

/// 期望的 2 空格缩进美化输出（与被测实现解耦，独立计算）。
String _pretty(String raw) =>
    const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '非法 JSON 显示 request-editor-body-format-error 且 body 不变',
    (tester) async {
      const broken = '{invalid json';
      await _pumpBodyEditor(tester, body: broken);

      await tester.tap(find.byKey(const Key('request-editor-body-format')));
      await tester.pump();

      expect(
        find.byKey(const Key('request-editor-body-format-error')),
        findsOneWidget,
      );
      expect(_bodyText(tester), broken);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '合法 JSON 点按 request-editor-body-format → 2 空格美化输出',
    (tester) async {
      const raw = '{"b":2,"a":[1,2]}';
      await _pumpBodyEditor(tester, body: raw);

      await tester.tap(find.byKey(const Key('request-editor-body-format')));
      await tester.pump();

      expect(_bodyText(tester), _pretty(raw));
      expect(
        find.byKey(const Key('request-editor-body-format-error')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'AppEditorToolbar.onFormat 与专用按钮走同一函数（单一事实来源）',
    (tester) async {
      const raw = '{"nested":{"k":"v"},"list":[1,{"x":true}]}';
      await _pumpBodyEditor(tester, body: raw);

      final toolbar =
          tester.widget<AppEditorToolbar>(find.byType(AppEditorToolbar));
      expect(toolbar.onFormat, isNotNull);
      toolbar.onFormat!();
      await tester.pump();

      expect(_bodyText(tester), _pretty(raw));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('非 JSON body 类型不显示格式化入口', (tester) async {
    await _pumpBodyEditor(
      tester,
      body: 'a=1&b=2',
      kind: DebugBodyKind.formUrlEncoded,
    );

    expect(find.byKey(const Key('request-editor-body-format')), findsNothing);
    expect(find.byKey(const Key('editor-toolbar-format')), findsNothing);
  });

  testWidgets('再次编辑后错误清除', (tester) async {
    await _pumpBodyEditor(tester, body: '{oops');

    await tester.tap(find.byKey(const Key('request-editor-body-format')));
    await tester.pump();
    expect(
      find.byKey(const Key('request-editor-body-format-error')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('request-editor-body')),
      '{"ok":1}',
    );
    await tester.pump();

    expect(
      find.byKey(const Key('request-editor-body-format-error')),
      findsNothing,
    );
  });
}
