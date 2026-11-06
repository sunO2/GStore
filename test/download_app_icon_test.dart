import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/download/widgets/download_app_icon.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('无效/缺失图标 URL 时回退应用名首字母头像', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const DownloadAppIcon(
          appId: 'com.example.gstore',
          appName: 'GStore',
          iconUrl: null,
        ),
      ),
    );
    await tester.pump();

    // 测试宿主非 Android：不触碰已安装应用平台通道，直接显示首字母头像。
    expect(find.text('G'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('相对路径图标不上网，回退首字母头像', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const DownloadAppIcon(
          appId: 'com.example.relative',
          appName: '相对路径',
          iconUrl: 'icons/app.png',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('相'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
