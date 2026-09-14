import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/fdroid_repo/add_source_dialog.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('AddSourceDialog：深链粘贴 + 指纹确认', () {
    test('默认源名称取域名并去掉 www.', () {
      expect(AddSourceDialog.defaultSourceName('https://www.example.com/fdroid/repo'),
          'example.com');
      expect(AddSourceDialog.defaultSourceName('https://releases.bitwarden.com/fdroid/repo'),
          'releases.bitwarden.com');
    });

    test('指纹按 2 位一组加冒号，便于逐段核对', () {
      expect(AddSourceDialog.formatFingerprint('abcdef'), 'AB:CD:EF');
      expect(AddSourceDialog.formatFingerprint('AB:CD:EF'), 'AB:CD:EF');
      expect(AddSourceDialog.formatFingerprint('abc'), 'AB:C');
    });

    testWidgets('粘贴 fdroidrepos 深链 → 地址归一化 + 展示指纹 + 自动填名称', (tester) async {
      await tester.pumpWidget(_wrap(const AddSourceDialog()));

      await tester.enterText(
        find.byType(TextField).first,
        'fdroidrepos://releases.bitwarden.com/fdroid/repo?fingerprint=abcdef1234',
      );
      await tester.pumpAndSettle();

      // 地址被归一化为 https 且去掉 query
      final urlField = tester.widget<TextField>(find.byType(TextField).first);
      expect(urlField.controller!.text, 'https://releases.bitwarden.com/fdroid/repo');
      // 指纹区出现，且是分组展示
      expect(find.text('仓库指纹（SHA-256）'), findsOneWidget);
      expect(find.text('AB:CD:EF:12:34'), findsOneWidget);
      // 名称自动填成域名
      final nameField = tester.widget<TextField>(find.byType(TextField).at(1));
      expect(nameField.controller!.text, 'releases.bitwarden.com');
    });

    testWidgets('普通 https 地址不显示指纹区', (tester) async {
      await tester.pumpWidget(_wrap(const AddSourceDialog()));
      await tester.enterText(find.byType(TextField).first, 'https://f-droid.org');
      await tester.pumpAndSettle();
      expect(find.text('仓库指纹（SHA-256）'), findsNothing);
    });

    testWidgets('提交返回归一化地址与指纹', (tester) async {
      AddSourceResult? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                captured = await AddSourceDialog.show(ctx);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'fdroidrepos://example.com/fdroid/repo?fingerprint=AB12',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.url, 'https://example.com/fdroid/repo');
      expect(captured!.fingerprint, 'AB12');
      expect(captured!.name, 'example.com');
    });
  });
}
