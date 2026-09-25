// Todo 23 widget tests：全屏抓包详情页（分段）。
//
// 密闭式：只注入假门面（[ProxyCaptureDetailFacade]），不触碰 FFI / 原生模块。
// 弹层宿主复用生产全局通道 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`，
// 因此动作菜单走真实 `AppSheet` 呈现路径。
//
// 覆盖（Todo 23 验收）：
// * h1 / h2 / ws 协议渲染；
// * 未解密（`mitmFailed`）+ 流级信息；
// * 超长 Body：限高 + 内部滚动，不溢出；
// * Cookie 表（`Set-Cookie` 解析）；
// * 空态（空 Body / 缺省字段占位）；
// * 详情拉取失败 → 可重试错误态，重试后成功；
// * Body 原始 / 格式化切换（断言真实格式化结果）；
// * 动作菜单三个可注入接缝 + 默认为空不崩。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 解析一帧（避免 `pumpAndSettle` 与常驻 [AppLoading] 动画冲突）。
Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

// ==================== 假门面 ====================

class _FakeDetailFacade implements ProxyCaptureDetailFacade {
  _FakeDetailFacade({
    CaptureDetail detail = const CaptureDetail(),
    this.fail = false,
  }) : value = detail;

  CaptureDetail value;
  bool fail;

  int calls = 0;
  int? lastRecordId;

  @override
  Future<CaptureDetail> detail(int recordId) async {
    calls++;
    lastRecordId = recordId;
    if (fail) {
      throw const ProxyModuleException(code: 'BOOM', message: '拉取失败');
    }
    return value;
  }
}

class _NotFoundFacade implements ProxyCaptureDetailFacade {
  int calls = 0;

  @override
  Future<CaptureDetail> detail(int recordId) async {
    calls++;
    throw const ProxyModuleException(
      code: 'PROXY_CAPTURE_NOT_FOUND',
      message: '记录不存在',
    );
  }
}

/// 假删除门面（D8b）：记录被删除的 `recordId`，可注入失败。
class _FakeDeleteFacade implements ProxyCaptureDeleteFacade {
  _FakeDeleteFacade({this.fail = false});

  bool fail;
  int calls = 0;
  int? lastRecordId;

  @override
  Future<CaptureDeleteResult> delete(int recordId) async {
    calls++;
    lastRecordId = recordId;
    if (fail) {
      throw const ProxyModuleException(code: 'DEL_FAIL', message: '删除失败');
    }
    return const CaptureDeleteResult(ok: true, removed: true);
  }
}

// ==================== 样例数据 ====================

CaptureDetail _detail({
  int recordId = 7,
  int requestRecordId = 3,
  String connId = 'conn-1',
  String host = 'example.com',
  String method = 'GET',
  String scheme = 'https',
  String url = 'https://example.com/api/data',
  int statusCode = 200,
  String protocol = 'h2',
  String reqHeaders = 'Accept: application/json\r\nX-Test: 1',
  String respHeaders = 'Content-Type: application/json',
  List<int> reqBody = const <int>[],
  List<int> respBody = const <int>[],
  int reqBytes = 0,
  int respBytes = 0,
  String contentType = 'application/json',
  int startedAtMs = 1700000000000,
  int finishedAtMs = 1700000000100,
  int durationMs = 100,
  bool truncated = false,
  bool mitmFailed = false,
  String failureReason = '',
  List<CaptureWsFrame> wsFrames = const <CaptureWsFrame>[],
}) {
  return CaptureDetail(
    recordId: recordId,
    requestRecordId: requestRecordId,
    connId: connId,
    host: host,
    method: method,
    scheme: scheme,
    url: url,
    statusCode: statusCode,
    protocol: protocol,
    reqHeaders: reqHeaders,
    respHeaders: respHeaders,
    reqBody: reqBody,
    respBody: respBody,
    reqBytes: reqBytes,
    respBytes: respBytes,
    contentType: contentType,
    startedAtMs: startedAtMs,
    finishedAtMs: finishedAtMs,
    durationMs: durationMs,
    truncated: truncated,
    mitmFailed: mitmFailed,
    failureReason: failureReason,
    wsFrames: wsFrames,
  );
}

RequestRecord _flow({
  String src = '10.0.0.5:52344',
  String dstIp = '93.184.216.34',
  int dstPort = 443,
  int? uid = 10123,
  List<String> packages = const <String>['com.example.app'],
  String closeReason = 'eof',
  String domain = 'example.com',
}) {
  return RequestRecord(
    recordId: 3,
    connId: 'conn-1',
    openTsMs: 1700000000000,
    domain: domain,
    dstIp: dstIp,
    dstPort: dstPort,
    src: src,
    uid: uid,
    packages: packages,
    closeReason: closeReason,
  );
}

Future<void> _tapSegment(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(Key('seg_$name')));
  await tester.pump();
  await tester.pump();
}

/// 以真实 Navigator 承载详情页（push 后才能断言删除成功后的 pop）。
Widget _routeHost(Widget detail) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open_detail'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => detail),
              ),
              child: const Text('HOME'),
            ),
          ),
        ),
      ),
    );

/// push 详情页并等首帧加载完成（避免 `pumpAndSettle` 与常驻 AppLoading 动画冲突）。
Future<void> _openDetail(WidgetTester tester, Widget detail) async {
  await tester.pumpWidget(_routeHost(detail));
  await tester.tap(find.byKey(const Key('open_detail')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _settleLoad(tester);
}

/// 打开动作菜单并点击某一动作项。
Future<void> _tapAction(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(const Key('detail_actions_menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

// ==================== 测试 ====================

void main() {
  testWidgets('AppBar 标题 = 方法 + 域名/路径', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(detail: _detail()),
    )));
    await _settleLoad(tester);
    expect(find.text('GET example.com/api/data'), findsOneWidget);
  });

  testWidgets('h1 / h2 / ws 协议均渲染（概览）', (tester) async {
    for (final proto in <String>['h1', 'h2', 'ws']) {
      final frames = proto == 'ws'
          ? const <CaptureWsFrame>[
              CaptureWsFrame(
                direction: 'up',
                opcode: 'text',
                payloadLen: 5,
                preview: <int>[104, 101, 108, 108, 111],
              ),
            ]
          : const <CaptureWsFrame>[];
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        key: ValueKey<String>(proto),
        recordId: 7,
        facade: _FakeDetailFacade(
          detail: _detail(protocol: proto, wsFrames: frames),
        ),
      )));
      await _settleLoad(tester);
      expect(find.text(proto), findsOneWidget, reason: '协议 $proto 应展示');
    }
  });

  testWidgets('上游失败（mitmFailed）显示提示条 + 照常展示已解密请求', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      flow: _flow(),
      facade: _FakeDetailFacade(
        detail: _detail(
          mitmFailed: true,
          statusCode: 0,
          failureReason: 'dial via DIRECT exceeded the 12s deadline',
          reqBody: const <int>[],
        ),
      ),
    )));
    await _settleLoad(tester);
    // 提示条命中，且带失败原因。
    expect(find.byKey(const Key('detail_mitm_failed')), findsOneWidget);
    expect(find.text('已拦截·上游连接失败'), findsOneWidget);
    expect(
      find.text('dial via DIRECT exceeded the 12s deadline'),
      findsOneWidget,
    );
    // 不再整页「未解密」。
    expect(find.byKey(const Key('detail_undecrypted')), findsNothing);
    expect(find.text('未解密'), findsNothing);
    // 请求段仍可见已解密的 method / URL（无请求体优雅降级）。
    await _tapSegment(tester, 'request');
    expect(find.text('GET'), findsOneWidget);
    expect(find.text('https://example.com/api/data'), findsOneWidget);
    expect(find.text('（空）'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上游失败且 failureReason 为空：仍显示提示条与请求段，不崩', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      flow: _flow(),
      facade: _FakeDetailFacade(
        detail: _detail(mitmFailed: true, statusCode: 0),
      ),
    )));
    await _settleLoad(tester);
    expect(find.byKey(const Key('detail_mitm_failed')), findsOneWidget);
    expect(find.text('已拦截·上游连接失败'), findsOneWidget);
    await _tapSegment(tester, 'request');
    expect(find.text('GET'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未失败详情：不显示任何失败 / 未解密提示条', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(detail: _detail()),
    )));
    await _settleLoad(tester);
    expect(find.byKey(const Key('detail_mitm_failed')), findsNothing);
    expect(find.byKey(const Key('detail_undecrypted')), findsNothing);
  });

  testWidgets('captures.detail 未命中（NOT_FOUND）降级为未解密', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 99,
      flow: _flow(),
      facade: _NotFoundFacade(),
    )));
    await _settleLoad(tester);
    expect(find.byKey(const Key('detail_undecrypted')), findsOneWidget);
    expect(find.text('未解密'), findsOneWidget);
  });

  testWidgets('超长 Body：限高 + 内部滚动，不溢出', (tester) async {
    final huge = List<int>.filled(200000, 65); // 200k × 'A'
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(detail: _detail(reqBody: huge)),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'request');
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byKey(const Key('body_scroll_req')));
    expect(size.height, lessThanOrEqualTo(320));
    expect(
      find.descendant(
        of: find.byKey(const Key('body_scroll_req')),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
  });

  testWidgets('二进制 Body 安全展示（base64，不崩）', (tester) async {
    final binary = <int>[0, 1, 2, 255, 254, 0, 10, 13, 7, 8, 9, 3, 4, 5, 6, 11];
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(detail: _detail(respBody: binary)),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');
    expect(tester.takeException(), isNull);
    expect(find.textContaining('base64 预览'), findsOneWidget);
  });

  testWidgets('Cookie 表解析 Set-Cookie', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        detail: _detail(
          respHeaders: 'Content-Type: text/html\r\n'
              'Set-Cookie: sid=abc123; Path=/; HttpOnly\r\n'
              'Set-Cookie: theme=dark; Max-Age=3600',
        ),
      ),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');
    expect(find.text('sid'), findsOneWidget);
    expect(find.text('abc123'), findsOneWidget);
    expect(find.textContaining('Path=/'), findsOneWidget);
    expect(find.text('theme'), findsOneWidget);
    expect(find.text('dark'), findsOneWidget);
  });

  testWidgets('空态：空 Body 显示占位，字段缺省显示 —', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(detail: const CaptureDetail()),
    )));
    await _settleLoad(tester);
    expect(find.text('—'), findsWidgets);
    await _tapSegment(tester, 'request');
    expect(find.text('（空）'), findsWidgets);
    await _tapSegment(tester, 'response');
    expect(find.text('（无 Cookie）'), findsOneWidget);
  });

  testWidgets('详情拉取失败 → 可重试错误态，重试后成功', (tester) async {
    final facade = _FakeDetailFacade(detail: _detail(), fail: true);
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: facade,
    )));
    await _settleLoad(tester);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('拉取失败'), findsOneWidget);

    facade.fail = false;
    await tester.tap(find.text('重试'));
    await _settleLoad(tester);
    expect(find.text('重试'), findsNothing);
    expect(find.text('GET example.com/api/data'), findsOneWidget);
    expect(facade.calls, 2);
  });

  testWidgets('Body 原始 / 格式化切换（断言真实格式化结果）', (tester) async {
    const raw = '{"a":1,"b":2}';
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        detail: _detail(reqBody: utf8.encode(raw)),
      ),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'request');
    expect(find.text(raw), findsOneWidget);

    await tester.tap(find.byKey(const Key('body_format_req')));
    await tester.pump();
    expect(find.text(raw), findsNothing);
    expect(find.text('{\n  "a": 1,\n  "b": 2\n}'), findsOneWidget);

    await tester.tap(find.byKey(const Key('body_raw_req')));
    await tester.pump();
    expect(find.text(raw), findsOneWidget);
  });

  testWidgets('元数据段展示 recordId/connId/src/dst/uid/packages/closeReason',
      (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      flow: _flow(),
      facade: _FakeDetailFacade(detail: _detail()),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'metadata');
    expect(find.text('7'), findsOneWidget); // recordId
    expect(find.text('conn-1'), findsWidgets); // connId
    expect(find.text('10.0.0.5:52344'), findsOneWidget); // src
    expect(find.text('93.184.216.34:443'), findsOneWidget); // dst
    expect(find.text('10123'), findsOneWidget); // uid
    expect(find.text('com.example.app'), findsOneWidget); // packages
    expect(find.text('eof'), findsOneWidget); // closeReason
  });

  testWidgets('动作菜单经可注入接缝回调（默认空不崩）', (tester) async {
    CaptureDetail? copied;
    CaptureDetail? saved;
    CaptureDetail? rule;
    String? rewriteBody;

    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        detail: _detail(respBody: utf8.encode('{"x":1}')),
      ),
      onCopyCurl: (d) => copied = d,
      onSaveToDebug: (d) => saved = d,
      onCreateRewriteRule: (d) => rule = d,
      onUseAsRewriteResponse: (b) => rewriteBody = b,
    )));
    await _settleLoad(tester);

    Future<void> tapAction(String key) async {
      await tester.tap(find.byKey(const Key('detail_actions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    await tapAction('action_copy_curl');
    expect(copied?.recordId, 7);
    await tapAction('action_save_debug');
    expect(saved?.recordId, 7);
    await tapAction('action_create_rule');
    expect(rule?.recordId, 7);

    await _tapSegment(tester, 'response');
    await tester.tap(find.byKey(const Key('body_rewrite_resp')));
    await tester.pump();
    expect(rewriteBody, '{"x":1}');

    // 默认（无回调）也应安全：重新挂载并点击全部动作，不抛异常。
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(detail: _detail()),
    )));
    await _settleLoad(tester);
    await tapAction('action_copy_curl');
    await tapAction('action_save_debug');
    await tapAction('action_create_rule');
    expect(tester.takeException(), isNull);
  });

  // ==================== D8b 删除该记录 ====================

  testWidgets('删除：确认后以正确 recordId 调用 delete 并 pop 返回', (tester) async {
    final deleteFacade = _FakeDeleteFacade();
    await _openDetail(
      tester,
      ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(detail: _detail()),
        deleteFacade: deleteFacade,
      ),
    );
    expect(find.byType(ProxyCaptureDetailPage), findsOneWidget);

    await _tapAction(tester, 'detail_delete_record');
    // 危险确认弹层文案必须出现，且确认前不得下发删除。
    expect(find.text('删除该抓包记录？不可撤销'), findsOneWidget);
    expect(deleteFacade.calls, 0, reason: '确认前不得调用 delete');

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(deleteFacade.calls, 1, reason: '确认后必须调用 delete 一次');
    expect(deleteFacade.lastRecordId, 7, reason: '必须携带本页 recordId');
    expect(
      find.byType(ProxyCaptureDetailPage),
      findsNothing,
      reason: '删除成功后必须 pop 返回列表',
    );
    expect(find.text('HOME'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：取消确认 -> 不调用 delete、不 pop、留在详情页', (tester) async {
    final deleteFacade = _FakeDeleteFacade();
    await _openDetail(
      tester,
      ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(detail: _detail()),
        deleteFacade: deleteFacade,
      ),
    );

    await _tapAction(tester, 'detail_delete_record');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(deleteFacade.calls, 0, reason: '取消不得调用 delete');
    expect(
      find.byType(ProxyCaptureDetailPage),
      findsOneWidget,
      reason: '取消不得 pop',
    );
    expect(find.text('HOME'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：删除失败 -> showError 且留在详情页不 pop', (tester) async {
    final deleteFacade = _FakeDeleteFacade(fail: true);
    await _openDetail(
      tester,
      ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(detail: _detail()),
        deleteFacade: deleteFacade,
      ),
    );

    await _tapAction(tester, 'detail_delete_record');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(deleteFacade.calls, 1);
    expect(deleteFacade.lastRecordId, 7);
    expect(find.text('删除失败'), findsWidgets, reason: '必须走统一 showError');
    expect(
      find.byType(ProxyCaptureDetailPage),
      findsOneWidget,
      reason: '删除失败不得 pop',
    );
    expect(find.text('HOME'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
