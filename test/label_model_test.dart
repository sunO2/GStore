/// Plan-Todo 14 — dynamic labels carried into the Dart models.
///
/// Proves `appDetailFromRust` / `appSummaryFromRust` carry the FRB
/// `ChannelLabel` values into `AppDetailInfo.labels` / `AppSummary.labels`
/// **field-for-field** (key/label/value/icon), and that an empty Rust `labels`
/// list yields an empty Dart list — the model layer never fabricates a label.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailInfoView.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

rust.ChannelAppDetailInfo _detail({required List<rust.ChannelLabel> labels}) =>
    rust.ChannelAppDetailInfo(
      appId: 'com.example.one',
      name: 'Example',
      icon: 'icon://x',
      description: 'desc',
      version: '1.0',
      channel: 'github',
      sections: const ['downloads'],
      downloads: const [],
      extraJson: '{}',
      labels: labels,
    );

rust.ChannelAppInfo _summary({required List<rust.ChannelLabel> labels}) =>
    rust.ChannelAppInfo(
      appId: 'owner/repo',
      name: 'Example',
      user: 'owner',
      repositories: 'repo',
      icon: 'icon://x',
      des: 'desc',
      category: const <String>[],
      labels: labels,
    );

void main() {
  group('carries the FRB labels field-for-field (not synthesized)', () {
    test('appDetailFromRust maps every ChannelLabel field into AppDetailInfo',
        () {
      // Given a detail whose Rust labels carry distinct, non-default values.
      final detail = appDetailFromRust(_detail(labels: const [
        rust.ChannelLabel(
            key: 'version', label: '版本', value: '9.9.9', icon: 'tag'),
        rust.ChannelLabel(key: 'downloads', label: '下载量', value: '1.2万'),
      ]));

      // Then the Dart model holds exactly the FRB values, in order.
      expect(detail.labels, hasLength(2));
      expect(detail.labels[0].key, 'version');
      expect(detail.labels[0].label, '版本');
      expect(detail.labels[0].value, '9.9.9');
      expect(detail.labels[0].icon, 'tag');
      expect(detail.labels[1].key, 'downloads');
      expect(detail.labels[1].label, '下载量');
      expect(detail.labels[1].value, '1.2万');
      expect(detail.labels[1].icon, isNull);
    });

    test('appSummaryFromRust maps every ChannelLabel field into AppSummary', () {
      // Given a summary whose Rust labels carry distinct, non-default values.
      final summary = appSummaryFromRust(_summary(labels: const [
        rust.ChannelLabel(
            key: 'stars', label: 'Star', value: '4242', icon: 'star'),
      ]));

      // Then the Dart model holds exactly the FRB values.
      expect(summary.labels, hasLength(1));
      expect(summary.labels.single.key, 'stars');
      expect(summary.labels.single.label, 'Star');
      expect(summary.labels.single.value, '4242');
      expect(summary.labels.single.icon, 'star');
    });

    test('IDetailInfo surface (AppDetailInfoView) exposes the same labels', () {
      final view = AppDetailInfoView(appDetailFromRust(_detail(labels: const [
        rust.ChannelLabel(key: 'developer', label: '开发者', value: 'ACME'),
      ])));

      expect(view.labels, hasLength(1));
      expect(view.labels.single.value, 'ACME');
    });
  });

  group('empty Rust labels stay empty (no fabrication)', () {
    test('appDetailFromRust: empty Rust labels → empty Dart list', () {
      final detail = appDetailFromRust(_detail(labels: const []));
      expect(detail.labels, isEmpty);
    });

    test('appSummaryFromRust: empty Rust labels → empty Dart list', () {
      final summary = appSummaryFromRust(_summary(labels: const []));
      expect(summary.labels, isEmpty);
    });

    test('AppDetailInfo default labels are empty', () {
      final info = AppDetailInfo(
        appId: 'a',
        name: 'n',
        icon: '',
        description: '',
        channel: appDetailFromRust(_detail(labels: const [])).channel,
        sections: const [],
      );
      expect(info.labels, isEmpty);
    });
  });

  group('AppLabel.toJson round-trip', () {
    test('keeps key/label/value and includes a present icon', () {
      const label = AppLabel(key: 'k', label: 'L', value: 'V', icon: 'tag');
      expect(label.toJson(), <String, dynamic>{
        'key': 'k',
        'label': 'L',
        'value': 'V',
        'icon': 'tag',
      });
    });

    test('omits a null icon', () {
      const label = AppLabel(key: 'k', label: 'L', value: 'V');
      expect(label.toJson(), <String, dynamic>{
        'key': 'k',
        'label': 'L',
        'value': 'V',
      });
    });
  });

  test('AppSummary.copyWith preserves labels when not overridden', () {
    final summary = appSummaryFromRust(_summary(labels: const [
      rust.ChannelLabel(key: 'k', label: 'L', value: 'V'),
    ]));
    final copy = summary.copyWith(name: 'Renamed');
    expect(copy.name, 'Renamed');
    expect(copy.labels.single.value, 'V');
  });
}
