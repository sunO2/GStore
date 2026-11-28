import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/web/web_address_bar.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    );

void main() {
  testWidgets('输入关键词后建议出现在输入框上方', (tester) async {
    final queries = <String>[];
    await tester.pumpWidget(_host(WebAddressBar(
      initialText: '',
      onSubmit: (_) {},
      suggestionLoader: (query) async {
        queries.add(query);
        return ['termux apk', 'termux wiki'];
      },
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'termux');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(queries, ['termux']);
    expect(find.text('termux apk'), findsOneWidget);

    final suggestionY = tester.getTopLeft(find.text('termux apk')).dy;
    final inputY = tester.getTopLeft(find.byType(TextField)).dy;
    expect(suggestionY, lessThan(inputY), reason: '建议应显示在输入框上方');
  });

  testWidgets('点建议直接提交', (tester) async {
    String? submitted;
    await tester.pumpWidget(_host(WebAddressBar(
      initialText: '',
      onSubmit: (value) => submitted = value,
      suggestionLoader: (_) async => ['termux apk'],
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'termux');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.text('termux apk'));
    await tester.pumpAndSettle();
    expect(submitted, 'termux apk');
  });

  testWidgets('箭头按钮提交当前输入', (tester) async {
    String? submitted;
    await tester.pumpWidget(_host(WebAddressBar(
      initialText: 'https://termux.dev',
      onSubmit: (value) => submitted = value,
      suggestionLoader: (_) async => const [],
    )));
    await tester.pump();

    await tester.tap(find.byTooltip('打开'));
    await tester.pumpAndSettle();
    expect(submitted, 'https://termux.dev');
  });

  testWidgets('网址输入不请求搜索建议', (tester) async {
    var called = false;
    await tester.pumpWidget(_host(WebAddressBar(
      initialText: '',
      onSubmit: (_) {},
      suggestionLoader: (_) async {
        called = true;
        return const [];
      },
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'termux.dev');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(called, isFalse);
  });
}
