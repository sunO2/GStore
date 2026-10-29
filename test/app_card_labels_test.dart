/// Home card labels are no longer rendered.
///
/// The dynamic label row (开发者/包名/渠道) was removed from the home grid card
/// (`AppCardWidget`) and horizontal card (`HorizontalAppRow`) because the values
/// are too long to fit. This file now proves:
/// - `AppLabelChips` (the shared renderer, still used on discovery/search/detail)
///   keeps its bounded/label-value behavior,
/// - the home cards render **no** label chips even when labels are present,
/// - the cards keep their fixed fields (name/description) and never throw.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/compent/app_label_chips.dart';
import 'package:gstore/compent/app_widget.dart';
import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart' show AppLabel;
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/page/home/tab/applist/widgets/app_card_widget.dart';
import 'package:gstore/page/home/tab/applist/widgets/horizontal_app_row.dart';

AppLabel _label(String key, String label, String value, [String? icon]) =>
    AppLabel(key: key, label: label, value: value, icon: icon);

List<AppLabel> _manyLabels(int n) => List.generate(
      n,
      (i) => _label('k$i', 'L$i', 'VAL$i'),
      growable: false,
    );

AppSummary _summary({List<AppLabel> labels = const []}) => AppSummary(
      appId: 'a',
      packageName: 'com.example.a',
      name: 'App A',
      user: 'owner',
      repositories: 'owner/a',
      icon: '',
      des: 'desc',
      labels: labels,
    );

AggregatedAppInfo _agg({List<AppLabel> labels = const []}) => AggregatedAppInfo(
      addedAppInfo: AddedAppInfo(channelId: 'github', appId: 'a'),
      appInfo: _summary(labels: labels),
      channel: ChannelType.github,
      channelCode: 'github',
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 220,
  double height = 320,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('AppLabelChips — the shared card label renderer', () {
    testWidgets('renders each label value as text (value, not just a widget)',
        (tester) async {
      await _pump(
        tester,
        const AppLabelChips(
          labels: [
            AppLabel(key: 'version', label: '版本', value: '1.2.3'),
            AppLabel(key: 'developer', label: '开发者', value: 'ACME'),
          ],
        ),
      );

      // Both labels' label+value render; the values are present verbatim.
      expect(find.text('版本 1.2.3'), findsOneWidget);
      expect(find.text('开发者 ACME'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty labels render nothing and never error', (tester) async {
      await _pump(tester, const AppLabelChips(labels: []));

      expect(find.byType(Text), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('bounded: first N render, the rest collapse into +N',
        (tester) async {
      await _pump(
        tester,
        AppLabelChips(labels: _manyLabels(5)),
        width: 400,
      );

      // maxVisible defaults to 2 → first two values + overflow indicator.
      expect(find.text('L0 VAL0'), findsOneWidget);
      expect(find.text('L1 VAL1'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);
      // The hidden ones are NOT rendered.
      expect(find.textContaining('VAL2'), findsNothing);
      expect(find.textContaining('VAL3'), findsNothing);
      expect(find.textContaining('VAL4'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('many labels in a narrow box do not overflow', (tester) async {
      await _pump(
        tester,
        AppLabelChips(labels: _manyLabels(50)),
        width: 90,
        height: 200,
      );

      expect(find.text('+48'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppCardWidget — grid card does not render labels', () {
    testWidgets('non-empty labels → no chips, name/description still render',
        (tester) async {
      await _pump(
        tester,
        AppCardWidget(
          app: _agg(labels: [
            _label('version', '版本', '1.2.3'),
            _label('developer', '开发者', 'ACME'),
          ]),
          onTap: () {},
        ),
      );

      // Dynamic labels are no longer rendered under the title.
      expect(find.byType(AppLabelChips), findsNothing);
      // Fixed fields unchanged: name + description still present.
      expect(find.text('App A'), findsOneWidget);
      expect(find.text('desc'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('many labels in a narrow box → no exception, no label text',
        (tester) async {
      await _pump(
        tester,
        AppCardWidget(app: _agg(labels: _manyLabels(50)), onTap: () {}),
        width: 120,
        height: 220,
      );

      expect(find.byType(AppLabelChips), findsNothing);
      expect(find.textContaining('VAL'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('HorizontalAppRow — horizontal card does not render labels', () {
    testWidgets('non-empty labels → no chips, name still rendered',
        (tester) async {
      await _pump(
        tester,
        HorizontalAppRow(
          apps: [
            _agg(labels: [
              _label('version', '版本', '9.9.9'),
            ]),
          ],
          onTap: (_) {},
        ),
        width: 400,
        height: 200,
      );

      expect(find.byType(AppLabelChips), findsNothing);
      expect(find.text('App A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MANY labels → no chips, no layout exception', (tester) async {
      await _pump(
        tester,
        HorizontalAppRow(apps: [_agg(labels: _manyLabels(50))], onTap: (_) {}),
        width: 400,
        height: 200,
      );

      expect(find.byType(AppLabelChips), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppItemWidget — optional labels', () {
    testWidgets('renders provided label values', (tester) async {
      await _pump(
        tester,
        const AppItemWidget(
          appName: 'Widget App',
          labels: [AppLabel(key: 'k', label: '渠道', value: 'github')],
        ),
      );

      expect(find.text('Widget App'), findsOneWidget);
      expect(find.text('渠道 github'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no labels → no chips, no error', (tester) async {
      await _pump(tester, const AppItemWidget(appName: 'Widget App'));

      expect(find.byType(AppLabelChips), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
