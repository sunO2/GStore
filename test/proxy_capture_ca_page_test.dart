// Todo 19 widget tests：抓包 MITM CA 管理页（状态 / 生成 / 重置 / 导出 / 安装）。
//
// 全部密闭式：只注入假门面（[ProxyCaptureCaFacade]）+ 假 CA 服务
// （[ProxyCaService]）+ 假另存接缝，不触碰 FFI / 原生模块 / 平台通道。弹层宿主
// 复用生产全局通道 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`，因此走
// 真实的 `AppSheet` / `AppDialogs` 呈现路径。
//
// 覆盖：
// * 未生成态：空态展示（**无错误**），导出 / 安装按钮禁用；
// * 已生成态：状态 + SHA-256 指纹；
// * 生成 / 重置：确认（危险）后**精确调用**契约并回填；
// * 导出：PEM / CRT 分别校验扩展名与字节；取消 → 静默；
// * root vs 用户分支：系统证书先 `detectRoot`，非 root 不发 `installSystemCa`；
// * 失败提示：安装失败 / 平台异常 → `showError` 且不崩；加载失败可重试。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/service/proxy_ca_service.dart';
import 'package:gstore/page/proxy/proxy_capture_ca_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

const String _pem = '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n';
final Uint8List _der = Uint8List.fromList(<int>[1, 2, 3, 4]);

CaptureCaInfo _generatedInfo() => CaptureCaInfo(
      generated: true,
      pem: _pem,
      derBase64: base64Encode(_der),
      fingerprintSha256: 'AA:BB:CC:DD',
    );

// ==================== 假实现 ====================

class _FakeCaFacade implements ProxyCaptureCaFacade {
  _FakeCaFacade({CaptureCaInfo? info}) : info = info ?? const CaptureCaInfo();

  CaptureCaInfo info;
  bool failGet = false;
  bool failGenerate = false;
  bool failReset = false;
  bool cleared = true;

  int getCalls = 0;
  int generateCalls = 0;
  int resetCalls = 0;
  bool? lastRegenerate;

  @override
  Future<CaptureCaInfo> caGet() async {
    getCalls++;
    if (failGet) throw StateError('状态读取失败（测试注入）');
    return info;
  }

  @override
  Future<CaptureCaInfo> caGenerate({bool regenerate = false}) async {
    generateCalls++;
    lastRegenerate = regenerate;
    if (failGenerate) throw StateError('生成失败（测试注入）');
    info = _generatedInfo();
    return info;
  }

  @override
  Future<CaptureCaResetResult> caReset() async {
    resetCalls++;
    if (failReset) throw StateError('重置失败（测试注入）');
    info = const CaptureCaInfo();
    return CaptureCaResetResult(ok: true, cleared: cleared);
  }
}

class _FakeCaService implements ProxyCaService {
  bool rooted = true;
  bool throwDetectRoot = false;

  CaInstallResult? userResult;
  CaInstallResult? systemResult;
  Exception? userError;
  Exception? systemError;

  int userCalls = 0;
  int systemCalls = 0;
  int detectCalls = 0;
  Uint8List? lastUserBytes;
  String? lastSystemPem;

  @override
  Future<CaInstallResult> installUserCa(Uint8List bytes) async {
    userCalls++;
    lastUserBytes = bytes;
    final error = userError;
    if (error != null) throw error;
    return userResult ??
        const CaInstallResult(
          ok: true,
          code: 'USER_KEYCHAIN_LAUNCHED',
          action: 'keychain',
          userActionRequired: true,
          installed: false,
        );
  }

  @override
  Future<CaInstallResult> installSystemCa(String pem) async {
    systemCalls++;
    lastSystemPem = pem;
    final error = systemError;
    if (error != null) throw error;
    return systemResult ??
        const CaInstallResult(
          ok: true,
          code: 'SYSTEM_CA_INSTALLED',
          action: 'legacy_fs',
          installed: true,
        );
  }

  @override
  Future<bool> detectRoot() async {
    detectCalls++;
    if (throwDetectRoot) {
      throw const ProxyCaException('CA_DETECT_ROOT', 'root 检测失败（测试注入）');
    }
    return rooted;
  }

  @override
  Future<bool> systemCaInstalled({String? pem}) async => false;
}

class _FakeSaveFile {
  String? result;
  int calls = 0;
  String? lastFileName;
  Uint8List? lastBytes;
  List<String>? lastExtensions;

  Future<String?> call({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) async {
    calls++;
    lastFileName = fileName;
    lastBytes = bytes;
    lastExtensions = allowedExtensions;
    return result;
  }
}

// ==================== 工具 ====================

/// 让整个页面在测试视口内完整布局（默认 800x600 会截断下方小节）。
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// `initState` 的加载已解析（不依赖 `pumpAndSettle`，避免 `AppLoading` 动画干扰）。
Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// 让 Snackbar 出现 / 动画结束。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('ProxyCaptureCaPage', () {
    testWidgets('未生成 → 空态展示（无错误），导出/安装按钮禁用', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade();
      await tester.pumpWidget(_host(ProxyCaptureCaPage(facade: facade)));
      await _settleLoad(tester);

      expect(find.byKey(const Key('capture_ca_status_empty')), findsOneWidget);
      expect(find.byKey(const Key('capture_ca_empty_hint')), findsOneWidget);
      expect(find.byKey(const Key('capture_ca_fingerprint')), findsNothing);
      // 未生成不是错误：无错误态。
      expect(find.text('证书状态加载失败'), findsNothing);

      // 导出 / 安装按钮禁用。
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('capture_ca_export')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('capture_ca_install_user')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('capture_ca_install_system')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('已生成 → 展示状态与 SHA-256 指纹', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      await tester.pumpWidget(_host(ProxyCaptureCaPage(facade: facade)));
      await _settleLoad(tester);

      expect(find.byKey(const Key('capture_ca_status_generated')), findsOneWidget);
      expect(find.byKey(const Key('capture_ca_fingerprint')), findsOneWidget);
      expect(find.text('AA:BB:CC:DD'), findsOneWidget);
    });

    testWidgets('生成 → 危险确认后调用 capture.ca.generate 并回填', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade();
      await tester.pumpWidget(_host(ProxyCaptureCaPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_generate')));
      await tester.pumpAndSettle();
      expect(find.text('生成抓包证书？'), findsOneWidget);

      await tester.tap(find.text('确认生成'));
      await tester.pumpAndSettle();
      await _flush(tester);

      expect(facade.generateCalls, 1);
      expect(facade.lastRegenerate, isFalse);
      expect(find.byKey(const Key('capture_ca_status_generated')), findsOneWidget);
      expect(find.textContaining('抓包证书已生成'), findsOneWidget);
    });

    testWidgets('重置 → 危险确认后调用 capture.ca.reset 并回到未生成', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      await tester.pumpWidget(_host(ProxyCaptureCaPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_reset')));
      await tester.pumpAndSettle();
      expect(find.text('重置抓包证书？'), findsOneWidget);

      await tester.tap(find.text('确认重置'));
      await tester.pumpAndSettle();
      await _flush(tester);

      expect(facade.resetCalls, 1);
      expect(facade.getCalls, 2); // 初次加载 + 重置后刷新
      expect(find.byKey(const Key('capture_ca_status_empty')), findsOneWidget);
      expect(find.textContaining('抓包证书已重置'), findsOneWidget);
    });

    testWidgets('导出 PEM 成功 → saveFile 收到 .pem 与文本字节', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final saver = _FakeSaveFile()..result = '/tmp/gstore-capture-ca.pem';
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, saveFile: saver.call)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_export')));
      await _flush(tester);

      expect(saver.calls, 1);
      expect(saver.lastExtensions, <String>['pem']);
      expect(saver.lastFileName, endsWith('.pem'));
      expect(saver.lastBytes, equals(Uint8List.fromList(utf8.encode(_pem))));
      expect(find.textContaining('证书已导出'), findsOneWidget);
    });

    testWidgets('导出 CRT 成功 → saveFile 收到 .crt 与 DER 字节', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final saver = _FakeSaveFile()..result = '/tmp/gstore-capture-ca.crt';
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, saveFile: saver.call)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_export_crt_segment')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture_ca_export')));
      await _flush(tester);

      expect(saver.calls, 1);
      expect(saver.lastExtensions, <String>['crt']);
      expect(saver.lastFileName, endsWith('.crt'));
      expect(saver.lastBytes, equals(_der));
    });

    testWidgets('导出取消 → 静默：不报错、不提示成功', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final saver = _FakeSaveFile()..result = null; // 取消
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, saveFile: saver.call)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_export')));
      await _flush(tester);

      expect(saver.calls, 1);
      expect(find.textContaining('导出失败'), findsNothing);
      expect(find.textContaining('导出成功'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('安装用户证书 → 调用 installUserCa（DER 字节）并提示待确认', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService();
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_install_user')));
      await _flush(tester);

      expect(service.userCalls, 1);
      expect(service.lastUserBytes, equals(_der));
      expect(service.systemCalls, 0);
      expect(find.textContaining('用户证书安装引导已下发'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('安装系统证书 root 分支 → detectRoot + installSystemCa(pem)', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService()..rooted = true;
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_install_system')));
      await _flush(tester);

      expect(service.detectCalls, 1);
      expect(service.systemCalls, 1);
      expect(service.lastSystemPem, _pem);
      expect(find.textContaining('系统证书安装完成'), findsOneWidget);
    });

    testWidgets('安装系统证书 非 root → 不安装 + 诚实错误提示', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService()..rooted = false;
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_install_system')));
      await _flush(tester);

      expect(service.detectCalls, 1);
      expect(service.systemCalls, 0); // 非 root 绝不尝试系统写入
      expect(find.textContaining('未检测到 root'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('安装失败（ok=false）→ showError 且不崩', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService()
        ..userResult = const CaInstallResult(
          ok: false,
          code: 'CA_INSTALL_USER',
          message: 'boom（测试注入）',
        );
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_install_user')));
      await _flush(tester);

      expect(service.userCalls, 1);
      expect(find.textContaining('boom（测试注入）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('安装用户证书平台异常 → showError 且不崩', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService()
        ..userError = const ProxyCaException('CA_INSTALL_USER', '通道炸了');
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_install_user')));
      await _flush(tester);

      expect(find.textContaining('用户证书安装失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('安装用户证书 取消 → showInfo 且不崩', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService()
        ..userResult = const CaInstallResult(
          ok: false,
          code: CaInstallResult.userCancelledCode,
          installed: false,
        );
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_install_user')));
      await _flush(tester);

      expect(find.textContaining('用户证书安装已取消'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载失败 → 错误态可重试', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade()..failGet = true;
      await tester.pumpWidget(_host(ProxyCaptureCaPage(facade: facade)));
      await _settleLoad(tester);

      expect(find.text('证书状态加载失败'), findsOneWidget);

      facade.failGet = false;
      await tester.tap(find.byKey(const Key('capture_ca_retry')));
      await _settleLoad(tester);

      expect(find.text('证书状态加载失败'), findsNothing);
      expect(find.byKey(const Key('capture_ca_status_empty')), findsOneWidget);
      expect(facade.getCalls, 2);
    });
  });
}
