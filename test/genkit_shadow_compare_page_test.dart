import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/genkit_shadow_compare_page.dart';

void main() {
  testWidgets('renders read-only comparison controls', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: GenkitShadowComparePage()),
    );

    expect(find.text('Genkit 对比实验'), findsOneWidget);
    expect(find.text('运行只读对比'), findsOneWidget);
    expect(
      find.textContaining('仅开放 searchApp 和 getAppInfo'),
      findsOneWidget,
    );
  });
}
