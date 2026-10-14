/// 「请求调试」保存失败可见性 + copyWith 哨兵（plan todo 13）测试。
///
/// 覆盖验收标准：
/// - 编辑器 / 集合 / 环境 / 历史分区保存失败必须显示错误，且**不**显示成功；
/// - `copyWith` 支持清空可空字段（哨兵语义：显式传 `null` 清空，缺省保留）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/environment_section.dart';
import 'package:gstore/page/request_debug/history_section.dart';
import 'package:gstore/page/request_debug/request_debug_page.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
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
    bool skipTlsVerify = false,
    DebugCancellationToken? cancelToken,
  }) async =>
      const DebugResponse(statusCode: 200, bodyText: 'ok', sizeBytes: 2);

  @override
  void close() {}
}

/// 落盘必失败的门面：`save()` 恒返回 `false`（且自身不弹提示），
/// 以便断言**分区边界**确实检查了返回值。
class _FailingFacade extends DefaultRequestDebugFacade {
  _FailingFacade({required super.store, required super.sender});

  int saveCalls = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async {
    saveCalls++;
    return false;
  }
}

RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

_FailingFacade _failingFacade() =>
    _FailingFacade(store: _memoryStore(), sender: _FakeSender());

/// 与生产相同全局通道，使 [AppDialogs] 的统一弹层 / Snackbar 可在测试中呈现。
Widget _host(Widget body) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: body),
    );

/// 完整 [RequestDebugPage] 宿主（Wave 8）：集合动作已上移到导航头 AppBar，
/// 「添加集合」经 `request-debug-collection-add` action 触发。
Widget _hostPage(RequestDebugFacade facade) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: RequestDebugPage(facade: facade),
    );

/// 把编辑器压入导航栈（先在宿主页点「open-editor」，再进入编辑器）。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required RequestDebugFacade facade,
  DebugRequest? request,
  String? collectionId,
}) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: appNavigatorKey,
    scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open-editor'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RequestEditorPage(
                facade: facade,
                request: request,
                collectionId: collectionId,
              ),
            ),
          ),
          child: const Text('open-editor'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-editor')));
  await tester.pumpAndSettle();
}

/// 打开右上「更多」溢出菜单并点选其中一项。
Future<void> _tapMore(WidgetTester tester, Key itemKey) async {
  await tester.tap(find.byKey(const Key('request-editor-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(itemKey));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('保存失败必须可见', () {
    testWidgets('编辑器保存失败 → 显示错误且不显示成功', (tester) async {
      final facade = _failingFacade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-fail',
          name: 'fail',
          method: 'GET',
          url: 'https://api.example/x',
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await _tapMore(tester, const Key('request-editor-save'));

      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(find.textContaining('保存失败'), findsWidgets,
          reason: 'save() 返回 false 时必须显示失败');
      expect(find.text('请求已保存'), findsNothing,
          reason: '保存失败绝不能显示成功');
      expect(tester.takeException(), isNull);
    });

    testWidgets('集合分区保存失败 → 显示错误', (tester) async {
      final facade = _failingFacade();
      // Wave 8：「添加集合」是导航头 AppBar action，需 pump 完整页面。
      await tester.pumpWidget(_hostPage(facade));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-collection-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('request-debug-prompt-field')),
        'API',
      );
      await tester.tap(find.byKey(const Key('request-debug-prompt-confirm')));
      await tester.pumpAndSettle();

      expect(facade.store.collections, hasLength(1));
      expect(find.textContaining('保存失败'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('环境分区保存失败 → 显示错误', (tester) async {
      final facade = _failingFacade();
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'a': '1'},
      );
      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(Key('request-debug-environment-active-${env.id}')),
      );
      await tester.pumpAndSettle();

      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(find.textContaining('保存失败'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('历史分区保存失败 → 显示错误', (tester) async {
      final facade = _failingFacade();
      facade.store.addHistory(DebugHistoryEntry(
        id: 'h-1',
        tsMs: 1,
        request: DebugRequest(id: 'r-1', name: 'r', url: 'https://a.example/x'),
        responseSummary: const DebugResponseSummary(statusCode: 200),
      ));
      await tester.pumpWidget(
        _host(RequestDebugHistorySection(facade: facade)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-history-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();

      expect(facade.store.history, isEmpty);
      expect(find.textContaining('保存失败'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('copyWith 哨兵：支持清空可空字段', () {
    test('DebugRequest.copyWith(auth: null/overrides: null) 真正清空；缺省保留', () {
      final request = DebugRequest(
        id: 'r',
        name: 'n',
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 'secret'),
        overrides: DebugResponseOverride(statusCode: 200, body: 'b'),
      );

      // 缺省：保留。
      final kept = request.copyWith(name: 'n2');
      expect(kept.auth, isNotNull);
      expect(kept.overrides, isNotNull);

      // 显式 null：清空。
      final cleared = request.copyWith(auth: null, overrides: null);
      expect(cleared.auth, isNull);
      expect(cleared.overrides, isNull);
    });

    test('DebugAuth.copyWith 支持清空 username/password/token/apiKey 字段', () {
      const auth = DebugAuth(
        type: DebugAuthType.basic,
        username: 'u',
        password: 'p',
        token: 't',
        apiKeyName: 'k',
        apiKeyValue: 'v',
        apiKeyIn: 'header',
      );

      final cleared = auth.copyWith(
        username: null,
        password: null,
        token: null,
        apiKeyName: null,
        apiKeyValue: null,
        apiKeyIn: null,
      );
      expect(cleared.username, isNull);
      expect(cleared.password, isNull);
      expect(cleared.token, isNull);
      expect(cleared.apiKeyName, isNull);
      expect(cleared.apiKeyValue, isNull);
      expect(cleared.apiKeyIn, isNull);
      expect(cleared.type, DebugAuthType.basic, reason: '非空字段必须保留');
    });

    test('DebugRequest.copyWith 支持清空每请求网络选项（回到发送器默认）', () {
      final request = DebugRequest(
        id: 'r',
        name: 'n',
        timeoutMs: 1500,
        followRedirects: false,
        useCookieJar: false,
        skipTlsVerify: true,
      );

      final cleared = request.copyWith(
        timeoutMs: null,
        followRedirects: null,
        useCookieJar: null,
        skipTlsVerify: null,
      );
      expect(cleared.timeoutMs, isNull);
      expect(cleared.followRedirects, isNull);
      expect(cleared.useCookieJar, isNull);
      expect(cleared.skipTlsVerify, isNull);
    });
  });
}
