import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/qr_scan/qr_scan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<CameraDescription>> noCamera() async {
    throw CameraException('noCamera', 'test');
  }

  testWidgets('QrScannerView 相机不可用显示占位并回调错误', (tester) async {
    String? error;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: QrScannerView(
              dimension: 200,
              onResult: (_) {},
              onError: (value) => error = value,
              availableCameras: noCamera,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('相机不可用'), findsOneWidget);
    expect(error, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QrScanPage 是全屏扫码壳且可嵌入统一错误占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QrScanPage(
          title: '扫码测试',
          availableCameras: noCamera,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('扫码测试'), findsOneWidget);
    expect(find.byType(QrScannerView), findsOneWidget);
    expect(find.text('相机不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QrScannerView 可嵌入任意有界容器', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 180,
            child: QrScannerView(
              dimension: 120,
              autoStart: false,
              onResult: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(QrScannerView), findsOneWidget);
    expect(find.text('相机不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
