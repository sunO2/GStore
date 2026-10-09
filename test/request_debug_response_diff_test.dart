/// 「请求调试」响应 diff（plan todo 18）测试。
///
/// 覆盖验收标准：
/// - 纯 diff 按行标出**新增 / 删除 / 未变**三类；
/// - [ResponseDiffView] 对新增行用 `primaryContainer`、删除行用
///   `errorContainer` 高亮（主题令牌，非硬编码颜色）；
/// - 无历史（两个快照均为空）时展示空态；
/// - 历史分区「对比最近两条」在历史不足两条时落到空态。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/request_debug.dart';
import 'package:gstore/page/request_debug/history_section.dart';
import 'package:gstore/page/request_debug/response_diff_view.dart';

DebugResponseSnapshot _snapshot(String body) => DebugResponseSnapshot(
      statusCode: 200,
      bodyText: body,
      sizeBytes: body.length,
    );

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

RequestDebugFacade _facade({int historyCount = 0}) {
  final store = RequestDebugStore(
    directoryProvider: () async => Directory.systemTemp,
  );
  if (historyCount > 0) {
    for (var i = 0; i < historyCount; i++) {
      store.addHistory(DebugHistoryEntry(
        id: 'h$i',
        tsMs: i,
        request: DebugRequest(id: 'r$i', name: 'n$i', url: 'https://x/$i'),
        responseSummary: const DebugResponseSummary(statusCode: 200),
        responseSnapshot: _snapshot('body-$i'),
      ));
    }
  }
  return _TestFacade(store: store);
}

class _TestFacade extends DefaultRequestDebugFacade {
  _TestFacade({required super.store}) : super(sender: DebugSender());

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯 diff（按行增删）', () {
    test('中间行被替换 → 未变 / 删除 / 新增 三类精确', () {
      final lines = diffResponseLines('a\nb\nc', 'a\nx\nc');
      expect(lines.map((l) => l.kind).toList(), <DiffLineKind>[
        DiffLineKind.unchanged,
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.unchanged,
      ]);
      expect(lines.map((l) => l.text).toList(), <String>['a', 'b', 'x', 'c']);
    });

    test('纯新增尾部行 → 仅新增', () {
      final lines = diffResponseLines('a', 'a\nb');
      expect(lines.last.kind, DiffLineKind.added);
      expect(lines.last.text, 'b');
    });

    test('两侧都为空 → 无行', () {
      expect(diffResponseLines(null, null), isEmpty);
      expect(diffResponseLines('', ''), isEmpty);
    });
  });

  group('ResponseDiffView（高亮）', () {
    testWidgets('新增行 primaryContainer、删除行 errorContainer', (tester) async {
      await tester.pumpWidget(_host(ResponseDiffView(
        before: _snapshot('a\nb\nc'),
        after: _snapshot('a\nx\nc'),
      )));
      await tester.pumpAndSettle();

      final removed = find.byKey(const Key('response-diff-removed-1'));
      final added = find.byKey(const Key('response-diff-added-2'));
      expect(removed, findsOneWidget);
      expect(added, findsOneWidget);

      final scheme =
          Theme.of(tester.element(removed)).colorScheme;
      final removedColor = tester.widget<Container>(removed).color;
      final addedColor = tester.widget<Container>(added).color;
      expect(removedColor, scheme.errorContainer);
      expect(addedColor, scheme.primaryContainer);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无历史（两侧为空）→ 空态', (tester) async {
      await tester.pumpWidget(_host(const ResponseDiffView()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('response-diff-empty')), findsOneWidget);
    });
  });

  group('历史分区对比入口', () {
    testWidgets('历史不足两条 → 点对比展示空态', (tester) async {
      final facade = _facade(historyCount: 1);
      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-history-diff')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('response-diff-empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('两条历史 → 点对比展示增删高亮', (tester) async {
      final facade = _facade(historyCount: 2);
      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-history-diff')));
      await tester.pumpAndSettle();

      // body-1 相对 body-0 整体替换：应同时出现新增与删除高亮。
      expect(find.byKey(const Key('response-diff-empty')), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.key.toString().contains('removed'),
        ),
        findsWidgets,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.key.toString().contains('added'),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
