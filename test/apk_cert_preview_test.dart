import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/rust/AnalyzerRustDecoder.dart';
import 'package:gstore/core/rust/Contract.dart' show decodeCertInfo;
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/service/apk_browser_service.dart';
import 'package:gstore/core/utils/unit.dart' show byteSize;
import 'package:gstore/page/apk_browser/preview.dart';
import 'package:mockito/mockito.dart';

/// 伪造的宿主模块句柄：仅经 `loadOverride` 原样返回，不触碰 FFI。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 捕获 `parse_certificate` 实际发出的 payload 字节（不触碰 FFI）。
class _CapturingModuleInstance implements RustModuleInstance {
  _CapturingModuleInstance(this.response);

  final Uint8List response;
  final List<String> methods = <String>[];
  final List<Uint8List?> payloads = <Uint8List?>[];

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async {
    methods.add(method);
    payloads.add(payload);
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 全字段内联金样本（构造样式对齐 Frozen JSON schema (CertInfo v1)）。
///
/// 注意：这是**内联**字面量，用于锁定 `decodeCertInfo` 的逐字段解码；
/// 跨 FFI 的共享金样本文件由 Todo 19 读取
/// `rust/gstore_mod_analyzer/tests/fixtures/cert_info_golden.json`。
const _inlineCertInfoJson = {
  'status': 'ok',
  'format': 'pem',
  'password_protected': false,
  'message': '',
  'certificates': [
    {
      'subject': {
        'common_name': 'example.com',
        'full': 'CN=example.com,O=Example,C=US',
        'fields': [
          {'oid': '2.5.4.3', 'name': 'CN', 'value': 'example.com'},
          {'oid': '2.5.4.10', 'name': 'O', 'value': 'Example'},
        ],
      },
      'issuer': {
        'common_name': 'Example CA',
        'full': 'CN=Example CA,O=Example,C=US',
        'fields': [
          {'oid': '2.5.4.3', 'name': 'CN', 'value': 'Example CA'},
        ],
      },
      'serial_number_hex': '0a1b2c',
      'not_before': '2024-01-01T00:00:00Z',
      'not_after': '2025-01-01T00:00:00Z',
      'signature_algorithm': 'sha256WithRSAEncryption (1.2.840.113549.1.1.11)',
      'public_key_algorithm': 'RSA',
      'public_key_bits': 2048,
      'public_key_curve': '',
      'version': 3,
      'san': [
        {'type': 'DNS', 'value': 'example.com'},
        {'type': 'IP', 'value': '1.2.3.4'},
      ],
      'subject_key_identifier': 'AB:CD:EF',
      'authority_key_identifier': '12:34:56',
      'key_usage': ['digitalSignature', 'keyEncipherment'],
      'extended_key_usage': ['serverAuth'],
      'basic_constraints': {'is_ca': false, 'path_len': null},
      'crl_distribution_points': ['http://crl.example.com/a.crl'],
      'authority_info_access': [
        {'type': 'OCSP', 'url': 'http://ocsp.example.com'},
        {'type': 'caIssuers', 'url': 'http://ca.example.com/ca.crt'},
      ],
      'sha256_fingerprint': 'AA:BB:CC',
      'sha1_fingerprint': 'DD:EE:FF',
      'pem': '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n',
    },
  ],
};

/// 构造一张字段齐全的 [CertEntry]（供证书卡状态分支测试）。
///
/// [san] 为 null 时给一条 DNS SAN；显式传 `const []` 可覆盖为「无 SAN」。
CertEntry _fullCertEntry({List<CertSan>? san}) => CertEntry(
      subject: const CertName(
        commonName: 'example.com',
        full: 'CN=example.com,O=Example,C=US',
        fields: [
          CertNameField(oid: '2.5.4.3', name: 'CN', value: 'example.com'),
          CertNameField(oid: '2.5.4.10', name: 'O', value: 'Example'),
        ],
      ),
      issuer: const CertName(
        commonName: 'Example CA',
        full: 'CN=Example CA,O=Example,C=US',
        fields: [CertNameField(oid: '2.5.4.3', name: 'CN', value: 'Example CA')],
      ),
      serialNumberHex: '0a1b2c',
      notBefore: '2024-01-01T00:00:00Z',
      notAfter: '2025-01-01T00:00:00Z',
      signatureAlgorithm: 'sha256WithRSAEncryption (1.2.840.113549.1.1.11)',
      publicKeyAlgorithm: 'RSA',
      publicKeyBits: 2048,
      publicKeyCurve: '',
      version: 3,
      san: san ?? const [CertSan(type: 'DNS', value: 'example.com')],
      subjectKeyIdentifier: 'AB:CD:EF',
      authorityKeyIdentifier: '12:34:56',
      keyUsage: const ['digitalSignature', 'keyEncipherment'],
      extendedKeyUsage: const ['serverAuth'],
      basicConstraints: const CertBasicConstraints(isCa: false),
      crlDistributionPoints: const ['http://crl.example.com/a.crl'],
      authorityInfoAccess: const [
        CertAia(type: 'OCSP', url: 'http://ocsp.example.com'),
      ],
      sha256Fingerprint: 'AA:BB:CC',
      sha1Fingerprint: 'DD:EE:FF',
      pem: '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n',
    );

/// `ok` 状态、默认单证书的 [CertInfo]（可覆盖证书列表以测链序编号）。
CertInfo _certInfoOk({List<CertEntry>? certs}) => CertInfo(
      status: CertInfoStatus.ok,
      format: CertFormat.pem,
      passwordProtected: false,
      message: '',
      certificates: certs ?? [_fullCertEntry()],
    );

void main() {
  group('decodeCertInfo', () {
    test('金样本 JSON → 全字段 CertInfo', () {
      final info = decodeCertInfo(_inlineCertInfoJson)!;
      expect(info.status, CertInfoStatus.ok);
      expect(info.format, CertFormat.pem);
      expect(info.passwordProtected, isFalse);
      expect(info.message, '');
      expect(info.certificates.length, 1);

      final cert = info.certificates.single;
      expect(cert.subject.commonName, 'example.com');
      expect(cert.subject.full, 'CN=example.com,O=Example,C=US');
      expect(cert.subject.fields.length, 2);
      expect(cert.subject.fields[0].oid, '2.5.4.3');
      expect(cert.subject.fields[0].name, 'CN');
      expect(cert.subject.fields[0].value, 'example.com');
      expect(cert.subject.fields[1].value, 'Example');

      expect(cert.issuer.commonName, 'Example CA');
      expect(cert.issuer.full, 'CN=Example CA,O=Example,C=US');
      expect(cert.issuer.fields.single.value, 'Example CA');

      expect(cert.serialNumberHex, '0a1b2c');
      expect(cert.notBefore, '2024-01-01T00:00:00Z');
      expect(cert.notAfter, '2025-01-01T00:00:00Z');
      expect(
        cert.signatureAlgorithm,
        'sha256WithRSAEncryption (1.2.840.113549.1.1.11)',
      );
      expect(cert.publicKeyAlgorithm, 'RSA');
      expect(cert.publicKeyBits, 2048);
      expect(cert.publicKeyCurve, '');
      expect(cert.version, 3);

      expect(cert.san.length, 2);
      expect(cert.san[0].type, 'DNS');
      expect(cert.san[0].value, 'example.com');
      expect(cert.san[1].type, 'IP');
      expect(cert.san[1].value, '1.2.3.4');

      expect(cert.subjectKeyIdentifier, 'AB:CD:EF');
      expect(cert.authorityKeyIdentifier, '12:34:56');
      expect(cert.keyUsage, ['digitalSignature', 'keyEncipherment']);
      expect(cert.extendedKeyUsage, ['serverAuth']);

      expect(cert.basicConstraints.isCa, isFalse);
      expect(cert.basicConstraints.pathLen, isNull);

      expect(cert.crlDistributionPoints, ['http://crl.example.com/a.crl']);
      expect(cert.authorityInfoAccess.length, 2);
      expect(cert.authorityInfoAccess[0].type, 'OCSP');
      expect(cert.authorityInfoAccess[0].url, 'http://ocsp.example.com');
      expect(cert.authorityInfoAccess[1].type, 'caIssuers');
      expect(cert.authorityInfoAccess[1].url, 'http://ca.example.com/ca.crt');

      expect(cert.sha256Fingerprint, 'AA:BB:CC');
      expect(cert.sha1Fingerprint, 'DD:EE:FF');
      expect(cert.pem, contains('BEGIN CERTIFICATE'));
    });

    test('非 Map 输入（数字）→ null', () {
      expect(decodeCertInfo(3), isNull);
    });

    test('非 Map 输入（字符串）→ null', () {
      expect(decodeCertInfo('x'), isNull);
    });

    test('未知 status/format 回落 unrecognized/unknown', () {
      final info = decodeCertInfo({
        'status': 'totally_unknown',
        'format': 'totally_unknown',
        'certificates': [],
      })!;
      expect(info.status, CertInfoStatus.unrecognized);
      expect(info.format, CertFormat.unknown);
      expect(info.certificates, isEmpty);
    });

    test('缺省可选字段回落 schema 默认值（空串/空列表/0/false/null）', () {
      final info = decodeCertInfo({
        'status': 'unsupported',
        'format': 'bks',
        'certificates': [<String, dynamic>{}],
      })!;
      // 顶层缺省
      expect(info.passwordProtected, isFalse);
      expect(info.message, '');

      final cert = info.certificates.single;
      // 缺省 subject/issuer（整个对象缺失）
      expect(cert.subject.commonName, '');
      expect(cert.subject.full, '');
      expect(cert.subject.fields, isEmpty);
      expect(cert.issuer.commonName, '');
      expect(cert.issuer.full, '');
      expect(cert.issuer.fields, isEmpty);
      // 字符串 → ""
      expect(cert.serialNumberHex, '');
      expect(cert.notBefore, '');
      expect(cert.notAfter, '');
      expect(cert.signatureAlgorithm, '');
      expect(cert.publicKeyAlgorithm, '');
      expect(cert.publicKeyCurve, '');
      expect(cert.subjectKeyIdentifier, '');
      expect(cert.authorityKeyIdentifier, '');
      expect(cert.sha256Fingerprint, '');
      expect(cert.sha1Fingerprint, '');
      expect(cert.pem, '');
      // int → 0
      expect(cert.publicKeyBits, 0);
      expect(cert.version, 0);
      // 列表 → []
      expect(cert.san, isEmpty);
      expect(cert.keyUsage, isEmpty);
      expect(cert.extendedKeyUsage, isEmpty);
      expect(cert.crlDistributionPoints, isEmpty);
      expect(cert.authorityInfoAccess, isEmpty);
      // basic_constraints 缺失 → isCa=false, pathLen=null
      expect(cert.basicConstraints.isCa, isFalse);
      expect(cert.basicConstraints.pathLen, isNull);
    });
  });

  group('service parseCertificate', () {
    // 限制：`ApkBrowserService` 无（也不需要）可注入 decoder 缝——它是直接转发
    // `AnalyzerRustDecoder` 的宿主薄封装（见 apk_browser_service.dart）。因此这里
    // 无法把假 decoder 注入去断言「返回非 null 的 malformed CertInfo」（那需给服务
    // 加注入面，属越界）。测试环境无 analyzer 模块 → 转发链返回 null；本组锁定
    // 「模块不可用 = null 且不抛」这一真实行为。
    test('模块不可用：返回 null 且不抛', () async {
      final result = await ApkBrowserService.instance.parseCertificate(
        '/nonexistent/cert.pem',
      );
      expect(result, isNull);
    });

    test('携带密码转发：模块不可用仍返回 null 且不抛', () async {
      final result = await ApkBrowserService.instance.parseCertificate(
        '/nonexistent/store.p12',
        password: 'secret',
      );
      expect(result, isNull);
    });
  });

  group('injectable preparer', () {
    // 注入缝：`ApkEntryPreviewPage.preparer` 为 null 时才走真实导出；
    // 注入假 data 即可在无真机/Rust 模块下渲染预览（Todo 20 的 widget 测试基础）。

    ApkBrowsableEntry certEntry({String kind = 'cert'}) => ApkBrowsableEntry(
          path: 'META-INF/CERT.RSA',
          name: 'CERT.RSA',
          isDir: false,
          size: 200,
          compressedSize: 180,
          crc32: 0xabcdef,
          stored: false,
          kind: kind,
          browsable: false,
        );

    const pem =
        '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';

    testWidgets('注入 preparer 用注入数据渲染，不触真实服务', (tester) async {
      var calls = 0;
      String? seenApkPath;
      String? seenChain;
      final data = ApkEntryPreviewData(
        path: '/tmp/fake/cert.pem',
        size: pem.length,
        crc32: 0xabcdef,
        bytes: Uint8List.fromList(utf8.encode(pem)),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/no/such.apk',
            entry: certEntry(),
            containerChain: 'inner.jar',
            preparer: ({
              required String apkPath,
              required ApkBrowsableEntry entry,
              required String containerChain,
              String? password,
            }) async {
              calls++;
              seenApkPath = apkPath;
              seenChain = containerChain;
              return data;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 缝被调用一次，且拿到宿主参数
      expect(calls, 1);
      expect(seenApkPath, '/no/such.apk');
      expect(seenChain, 'inner.jar');
      // 证书原文（含 BEGIN）→ 原文卡渲染注入字节（未触碰真实导出）
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.data, contains('BEGIN CERTIFICATE'));
    });

    testWidgets('注入 preparer 返回 null → 降级提示而非崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/no/such.apk',
            entry: certEntry(),
            preparer: ({
              required String apkPath,
              required ApkBrowsableEntry entry,
              required String containerChain,
              String? password,
            }) async =>
                null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ApkEntryPreviewPage), findsOneWidget);
      expect(find.textContaining('导出失败'), findsOneWidget);
    });

    testWidgets('注入含 certInfo 的数据渲染字段卡（缝对字段卡友好）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/no/such.apk',
            entry: certEntry(),
            preparer: ({
              required String apkPath,
              required ApkBrowsableEntry entry,
              required String containerChain,
              String? password,
            }) async =>
                ApkEntryPreviewData(
              path: '/tmp/fake/cert.pem',
              size: 3,
              crc32: 1,
              bytes: Uint8List.fromList([0x30, 0x82, 0x01]),
              certInfo: _certInfoOk(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ApkEntryPreviewPage), findsOneWidget);
      // 注入的 `ok` CertInfo → 字段卡（Todo 14），而非原始十六进制
      expect(find.text('证书字段'), findsOneWidget);
      expect(find.textContaining('CN=example.com'), findsWidgets);
    });
  });

  group('cert status branches', () {
    // 注入缝（Todo 13）让每个 status 分支都能在无真机 / Rust 模块下渲染断言。
    ApkBrowsableEntry certEntry() => const ApkBrowsableEntry(
          path: 'META-INF/CERT.RSA',
          name: 'CERT.RSA',
          isDir: false,
          size: 200,
          compressedSize: 180,
          crc32: 0xabcdef,
          stored: false,
          kind: 'cert',
          browsable: false,
        );

    Future<void> pumpCert(WidgetTester tester, CertInfo? info) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/no/such.apk',
            entry: certEntry(),
            preparer: ({
              required String apkPath,
              required ApkBrowsableEntry entry,
              required String containerChain,
              String? password,
            }) async =>
                ApkEntryPreviewData(
              path: '/tmp/fake/cert.der',
              size: 3,
              crc32: 1,
              bytes: Uint8List.fromList([0x30, 0x82, 0x01]),
              certInfo: info,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('ok → 字段卡（主体/序列号/指纹/版本/公钥/PEM）', (tester) async {
      await pumpCert(tester, _certInfoOk());

      expect(find.text('证书字段'), findsOneWidget);
      expect(find.text('主体'), findsOneWidget);
      expect(find.textContaining('CN=example.com'), findsWidgets);
      expect(find.text('序列号'), findsOneWidget);
      expect(find.text('0a1b2c'), findsOneWidget);
      expect(find.text('SHA-256 指纹'), findsOneWidget);
      expect(find.text('AA:BB:CC'), findsOneWidget);
      expect(find.text('版本'), findsOneWidget);
      expect(find.text('v3'), findsOneWidget);
      // publicKeyBits != 0 → 展示位数
      expect(find.text('RSA · 2048 位'), findsOneWidget);

      final pemTexts = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '')
          .toList();
      expect(pemTexts.any((t) => t.contains('BEGIN CERTIFICATE')), isTrue);
    });

    testWidgets('多证书 → 链序编号分节', (tester) async {
      await pumpCert(
        tester,
        _certInfoOk(certs: [_fullCertEntry(), _fullCertEntry()]),
      );
      expect(find.text('证书 1 / 2'), findsOneWidget);
      expect(find.text('证书 2 / 2'), findsOneWidget);
    });

    testWidgets('无 SAN → SAN 行为「无」', (tester) async {
      await pumpCert(
        tester,
        _certInfoOk(certs: [_fullCertEntry(san: const [])]),
      );
      expect(find.text('SAN'), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(of: find.text('SAN'), matching: find.byType(Row)),
          matching: find.text('无'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('DNS: example.com'), findsNothing);
    });

    testWidgets('unsupported → 容器类型提示（用 message）', (tester) async {
      await pumpCert(
        tester,
        const CertInfo(
          status: CertInfoStatus.unsupported,
          format: CertFormat.bks,
          passwordProtected: false,
          message: 'BKS 容器不支持字段解析',
          certificates: [],
        ),
      );
      expect(find.text('容器格式：BKS'), findsOneWidget);
      expect(find.text('BKS 容器不支持字段解析'), findsOneWidget);
      expect(find.text('证书字段'), findsNothing);
    });

    testWidgets('malformed → 内联错误文案', (tester) async {
      await pumpCert(
        tester,
        const CertInfo(
          status: CertInfoStatus.malformed,
          format: CertFormat.der,
          passwordProtected: false,
          message: '证书数据损坏',
          certificates: [],
        ),
      );
      expect(find.text('证书数据损坏'), findsOneWidget);
      expect(find.textContaining('模块不可用'), findsNothing);
    });

    testWidgets('password_required → 提示 + 密码入口', (tester) async {
      await pumpCert(
        tester,
        const CertInfo(
          status: CertInfoStatus.passwordRequired,
          format: CertFormat.pkcs12,
          passwordProtected: true,
          message: '',
          certificates: [],
        ),
      );
      expect(find.text('需要密码'), findsOneWidget);
      expect(find.textContaining('受密码保护'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '输入密码'), findsOneWidget);
    });

    testWidgets('certInfo == null → 「模块不可用」提示 + 保留原始查看器', (tester) async {
      await pumpCert(tester, null);
      expect(find.textContaining('模块不可用'), findsOneWidget);
      expect(find.textContaining('十六进制预览'), findsOneWidget);
      // 不得误报「解析失败」
      expect(find.textContaining('解析失败'), findsNothing);
    });
  });

  group('raw text/hex toggle', () {
    // Todo 15：证书卡内的「原文 ↔ Hex」分段切换（仅证书条目），经注入缝提供
    // bytes/size/certInfo，不依赖真机 / Rust 模块。
    ApkBrowsableEntry certEntry({String kind = 'cert'}) => ApkBrowsableEntry(
          path: 'META-INF/CERT.RSA',
          name: 'CERT.RSA',
          isDir: false,
          size: 200,
          compressedSize: 180,
          crc32: 0xabcdef,
          stored: false,
          kind: kind,
          browsable: false,
        );

    Future<void> pump(
      WidgetTester tester, {
      required Uint8List bytes,
      required int size,
      CertInfo? certInfo,
      String kind = 'cert',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/no/such.apk',
            entry: certEntry(kind: kind),
            preparer: ({
              required String apkPath,
              required ApkBrowsableEntry entry,
              required String containerChain,
              String? password,
            }) async =>
                ApkEntryPreviewData(
              path: '/tmp/fake/cert.bin',
              size: size,
              crc32: 1,
              bytes: bytes,
              certInfo: certInfo,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 拼接全部 [SelectableText] 的内容（字段卡 PEM 与原始查看器都在其中）。
    String selectableText(WidgetTester tester) => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .join('\n');

    /// 最后一整行的偏移（16 字节/行）：校验 Hex 是否渲染到文件末尾。
    String lastOffsetLine(int n) => (n - 16).toRadixString(16).padLeft(8, '0');

    /// 点按分段（字段卡可能很长，先把控件滚入可视区再点）。
    Future<void> tapView(WidgetTester tester, String label) async {
      final finder = find.text(label);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('非证书类型无 [原文|Hex] 切换', (tester) async {
      await pump(
        tester,
        bytes: Uint8List.fromList(List.filled(64, 0xab)),
        size: 64,
        kind: 'dex',
      );
      expect(find.text('原文'), findsNothing);
      expect(find.text('Hex'), findsNothing);
    });

    testWidgets('PEM 字节 → 默认原文显示 PEM，无二进制误报', (tester) async {
      const pem =
          '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';
      await pump(
        tester,
        bytes: Uint8List.fromList(utf8.encode(pem)),
        size: pem.length,
      );
      // 仅证书条目有该分段控件
      expect(find.text('原文'), findsOneWidget);
      expect(find.text('Hex'), findsOneWidget);
      expect(selectableText(tester), contains('BEGIN CERTIFICATE'));
      expect(find.textContaining('二进制原文'), findsNothing);
    });

    testWidgets('切换 原文 ↔ Hex 两态可用', (tester) async {
      const pem =
          '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';
      await pump(
        tester,
        bytes: Uint8List.fromList(utf8.encode(pem)),
        size: pem.length,
      );
      // 原文态
      expect(selectableText(tester), contains('BEGIN CERTIFICATE'));
      // → Hex
      await tapView(tester, 'Hex');
      expect(find.text('十六进制预览'), findsOneWidget);
      expect(selectableText(tester), contains('00000000'));
      // → 原文
      await tapView(tester, '原文');
      expect(find.text('十六进制预览'), findsNothing);
      expect(selectableText(tester), contains('BEGIN CERTIFICATE'));
    });

    testWidgets('DER 二进制 + 已解析证书 → 原文显示 PEM armor（多证书按序拼接）', (tester) async {
      final bytes = Uint8List.fromList([0x30, 0x82, 0x01, 0x02, 0x03]);
      await pump(
        tester,
        bytes: bytes,
        size: bytes.length,
        certInfo: _certInfoOk(certs: [_fullCertEntry(), _fullCertEntry()]),
      );
      // 二进制默认展示 Hex
      expect(find.text('十六进制预览'), findsOneWidget);
      // 切到原文 → 出现「单块含两张证书」的 armor
      await tapView(tester, '原文');
      final datas = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '');
      expect(
        datas.any((t) => 'BEGIN CERTIFICATE'.allMatches(t).length == 2),
        isTrue,
      );
      expect(find.textContaining('二进制原文'), findsNothing);
    });

    testWidgets('未解析二进制 → 原文宽容 UTF-8 + 「二进制原文，可能不可读」', (tester) async {
      final bytes = Uint8List.fromList([0x30, 0x82, 0x01, 0x00, 0xff, 0xfe]);
      await pump(tester, bytes: bytes, size: bytes.length);
      expect(find.text('十六进制预览'), findsOneWidget);
      await tapView(tester, '原文');
      expect(find.text('二进制原文，可能不可读'), findsOneWidget);
    });

    testWidgets('4 KB 边界：Hex 完整渲染且无截断提示', (tester) async {
      const n = 4 * 1024;
      final bytes = Uint8List.fromList(List.generate(n, (i) => i & 0xff));
      await pump(tester, bytes: bytes, size: n);
      // 无截断 → 提示为纯「十六进制预览」
      expect(find.text('十六进制预览'), findsOneWidget);
      final dump = selectableText(tester);
      expect(dump, contains('00000000'));
      expect(dump, contains(lastOffsetLine(n))); // 00000ff0
    });

    testWidgets('256 KB 边界：Hex 渲染全部读到的字节且无截断提示', (tester) async {
      const n = 256 * 1024;
      final bytes = Uint8List.fromList(List.generate(n, (i) => i & 0xff));
      await pump(tester, bytes: bytes, size: n);
      expect(find.text('十六进制预览'), findsOneWidget);
      final dump = selectableText(tester);
      // 旧默认 limit=4096 只能渲染到 00000ff0，这里必须到 0003fff0
      expect(dump, contains(lastOffsetLine(n)));
    });

    testWidgets('300 KB 文件（读 256 KB）→ 截断提示 + 渲染全部读到字节', (tester) async {
      const read = 256 * 1024;
      const total = 300 * 1024;
      final bytes = Uint8List.fromList(List.generate(read, (i) => i & 0xff));
      await pump(tester, bytes: bytes, size: total);
      // 有截断 → 不再是纯提示
      expect(find.text('十六进制预览'), findsNothing);
      expect(
        find.text('十六进制预览（前 ${byteSize(read)}，共 ${byteSize(total)}）'),
        findsOneWidget,
      );
      // 读到的 256 KB 必须完整渲染（不是被默认 4096 截掉）
      expect(selectableText(tester), contains(lastOffsetLine(read)));
    });
  });

  group('password sheet flow', () {
    // Todo 16：加密容器的统一底部密码层（`AppSheet.showCustom`）。
    // 经注入缝提供假 preparer：无密码 → password_required；正确密码 → ok 字段卡；
    // 错误密码 → bad_password。全程不依赖真机 / Rust 模块。

    ApkBrowsableEntry certEntry() => const ApkBrowsableEntry(
          path: 'META-INF/store.p12',
          name: 'store.p12',
          isDir: false,
          size: 200,
          compressedSize: 180,
          crc32: 0xabcdef,
          stored: false,
          kind: 'cert',
          browsable: false,
        );

    CertInfo passwordRequired() => const CertInfo(
          status: CertInfoStatus.passwordRequired,
          format: CertFormat.pkcs12,
          passwordProtected: true,
          message: '',
          certificates: [],
        );

    CertInfo badPassword() => const CertInfo(
          status: CertInfoStatus.badPassword,
          format: CertFormat.pkcs12,
          passwordProtected: true,
          message: '密码错误',
          certificates: [],
        );

    /// 假 preparer：按传入密码返回不同解析结果，并把每次收到的密码记入 [seen]。
    ApkEntryPreparer fakePreparer(List<String?> seen) {
      return ({
        required String apkPath,
        required ApkBrowsableEntry entry,
        required String containerChain,
        String? password,
      }) async {
        seen.add(password);
        final bytes = Uint8List.fromList([0x30, 0x82, 0x01]);
        final CertInfo info;
        if (password == null || password.isEmpty) {
          info = passwordRequired();
        } else if (password == 'changeit') {
          info = _certInfoOk();
        } else {
          info = badPassword();
        }
        return ApkEntryPreviewData(
          path: '/tmp/store.p12',
          size: bytes.length,
          crc32: 1,
          bytes: bytes,
          certInfo: info,
        );
      };
    }

    Future<void> pumpCert(WidgetTester tester, ApkEntryPreparer preparer) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/no/such.apk',
            entry: certEntry(),
            preparer: preparer,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('password_required → 打开底部密码层（obscureText + 确认/取消）', (tester) async {
      await pumpCert(tester, fakePreparer(<String?>[]));

      expect(find.text('需要密码'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '输入密码'));
      await tester.pumpAndSettle();

      // 统一底部弹层：单行密码输入 + obscureText + 确认/取消
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认'), findsOneWidget);
      // 不得使用裸 showDialog（本应用弹层统一 BottomSheet）
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('正确密码 → 重新 prepare 并刷新为字段卡', (tester) async {
      final seen = <String?>[];
      await pumpCert(tester, fakePreparer(seen));
      expect(seen, [null]);

      await tester.tap(find.widgetWithText(OutlinedButton, '输入密码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'changeit');
      await tester.tap(find.byKey(const Key('apk-cert-password-confirm')));
      await tester.pumpAndSettle();

      // 带密码重解析（缝收到密码）
      expect(seen, [null, 'changeit']);
      expect(find.text('证书字段'), findsOneWidget);
      expect(find.text('需要密码'), findsNothing);
      expect(find.textContaining('CN=example.com'), findsWidgets);
    });

    testWidgets('错误密码：自动重试一次后内联提示（无死循环）', (tester) async {
      final seen = <String?>[];
      await pumpCert(tester, fakePreparer(seen));

      await tester.tap(find.widgetWithText(OutlinedButton, '输入密码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'wrong1');
      await tester.tap(find.byKey(const Key('apk-cert-password-confirm')));
      await tester.pumpAndSettle();

      // 第一次错误 → 自动重开一次密码层
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'wrong2');
      await tester.tap(find.byKey(const Key('apk-cert-password-confirm')));
      await tester.pumpAndSettle();

      // 第二次错误 → 不再自动重弹，转为内联提示
      expect(seen, [null, 'wrong1', 'wrong2']);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('密码错误'), findsWidgets);
    });

    testWidgets('取消 → 容器信息 + 原始查看器（保留原文/Hex）', (tester) async {
      await pumpCert(tester, fakePreparer(<String?>[]));

      await tester.tap(find.widgetWithText(OutlinedButton, '输入密码'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      // 降级：容器信息卡 + 原始查看器，不再提示输入密码
      expect(find.text('容器格式：PKCS#12'), findsOneWidget);
      expect(find.text('未提供密码，仅显示原始内容。'), findsOneWidget);
      expect(find.text('原文'), findsOneWidget);
      expect(find.text('Hex'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '输入密码'), findsNothing);
    });

    testWidgets('留空确认 → 同样降级为容器信息 + 原始查看器', (tester) async {
      await pumpCert(tester, fakePreparer(<String?>[]));

      await tester.tap(find.widgetWithText(OutlinedButton, '输入密码'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apk-cert-password-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('容器格式：PKCS#12'), findsOneWidget);
      expect(find.text('原文'), findsOneWidget);
      expect(find.text('Hex'), findsOneWidget);
    });
  });

  group('contract/golden', () {
    // Todo 19：跨 FFI 契约锁定 —— 读取与 Rust `golden_cert_info_json` / 线格式
    // 测试**共享同一文件**（Verification strategy：禁止两侧各写独立字面量）：
    //   - rust/gstore_mod_analyzer/tests/fixtures/cert_info_golden.json（CertInfo JSON）
    //   - rust/gstore_mod_analyzer/tests/fixtures/wire_payload.hex（`path\0password` 字节）
    // `flutter test` 的 CWD = 仓库根，故相对路径可直接解析。

    final bootstrap = ModuleBootstrap.instance;

    setUp(() {
      // 线格式测试经 ModuleBootstrap 注入假模块，确保 binding 已初始化且不留状态。
      TestWidgetsFlutterBinding.ensureInitialized();
      bootstrap.debugReset();
    });

    tearDown(() {
      bootstrap.debugReset();
    });

    String readFixture(String name) =>
        File('rust/gstore_mod_analyzer/tests/fixtures/$name').readAsStringSync();

    Uint8List hexDecode(String hex) {
      final out = <int>[];
      for (var i = 0; i + 1 < hex.length; i += 2) {
        out.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return Uint8List.fromList(out);
    }

    test('共享金样本 JSON → 全字段 CertInfo（多证书 / SAN / path_len:null）', () {
      final golden = jsonDecode(readFixture('cert_info_golden.json'));
      final info = decodeCertInfo(golden);

      expect(info, isNotNull, reason: '金样本必为 Map → 解码出 CertInfo');
      expect(info!.status, CertInfoStatus.ok);
      expect(info.format, CertFormat.pem);
      expect(info.passwordProtected, isFalse);
      expect(info.message, '');
      expect(info.certificates.length, 2, reason: 'chain.pem 含 2 张证书');

      // —— 叶子证书（第 1 张）：逐字段核对真实值（非「非空」占位）——
      final leaf = info.certificates[0];
      expect(leaf.subject.commonName, 'example.com');
      expect(leaf.subject.full, 'CN=example.com, O=Example Org, C=US');
      expect(leaf.subject.fields.length, 3);
      expect(leaf.subject.fields[2].name, 'C');
      expect(leaf.subject.fields[2].value, 'US');
      expect(leaf.issuer.commonName, 'example.com');
      expect(leaf.serialNumberHex, '78853cd0d49c66a421b79748d9133f666b72c698');
      expect(leaf.notBefore, '2026-10-16T16:56:31Z');
      expect(leaf.notAfter, '2036-10-13T16:56:31Z');
      expect(leaf.signatureAlgorithm, 'sha256WithRSAEncryption (1.2.840.113549.1.1.11)');
      expect(leaf.publicKeyAlgorithm, 'RSA');
      expect(leaf.publicKeyBits, 2048);
      expect(leaf.version, 3);

      // SAN 列表：DNS×2 / IP / EMAIL / URI
      expect(leaf.san.length, 5);
      expect(leaf.san.map((s) => s.type).toList(),
          ['DNS', 'DNS', 'IP', 'EMAIL', 'URI']);
      expect(leaf.san[0].value, 'example.com');
      expect(leaf.san[1].value, 'www.example.com');
      expect(leaf.san[2].value, '127.0.0.1');
      expect(leaf.san[3].value, 'admin@example.com');
      expect(leaf.san[4].value, 'https://example.com/');

      expect(leaf.subjectKeyIdentifier,
          '14:F7:85:C5:17:E9:A9:CE:C1:D0:63:DD:FB:D7:8B:CF:6A:A2:72:82');
      // 空可选字段：叶片证书无 AKI → 空串（非 null）
      expect(leaf.authorityKeyIdentifier, '');
      expect(leaf.keyUsage, ['digitalSignature', 'keyEncipherment']);
      expect(leaf.extendedKeyUsage, ['serverAuth', 'clientAuth']);
      expect(leaf.basicConstraints.isCa, isFalse);
      expect(leaf.basicConstraints.pathLen, isNull);
      expect(leaf.crlDistributionPoints, ['http://crl.example.com/a.crl']);
      expect(leaf.authorityInfoAccess.length, 2);
      expect(leaf.authorityInfoAccess[1].type, 'caIssuers');
      expect(leaf.authorityInfoAccess[1].url, 'http://ca.example.com/ca.crt');
      expect(leaf.sha256Fingerprint,
          '64:77:9E:22:81:E3:C4:89:3A:D6:2A:F0:FD:07:E4:51:FB:FE:69:87:21:69:06:E2:23:C7:9F:6B:63:FF:D0:2E');
      expect(leaf.sha1Fingerprint,
          'E7:F1:35:AF:AB:4D:E2:18:46:2E:A3:62:7E:FA:AF:AA:E4:29:E6:77');
      expect(leaf.pem, contains('BEGIN CERTIFICATE'));

      // —— CA 证书（第 2 张）：空可选列表 + path_len:null ——
      final ca = info.certificates[1];
      expect(ca.subject.commonName, 'Example CA');
      expect(ca.serialNumberHex, '557bd44a310dd9d03fafb111c6a91ccab80abaea');
      expect(ca.san, isEmpty);
      expect(ca.extendedKeyUsage, isEmpty);
      expect(ca.crlDistributionPoints, isEmpty);
      expect(ca.authorityInfoAccess, isEmpty);
      expect(ca.basicConstraints.isCa, isTrue);
      expect(ca.basicConstraints.pathLen, isNull);
      expect(ca.keyUsage, ['keyCertSign', 'cRLSign']);
      expect(ca.sha1Fingerprint,
          'F3:6E:C9:BC:4B:FD:17:0A:B8:37:43:15:28:73:CA:1C:42:E3:BB:6D');
    });

    test('非 Map 输入 → null', () {
      expect(decodeCertInfo(3), isNull);
      expect(decodeCertInfo('x'), isNull);
    });

    test('独立内联 JSON（非金样本）：未知 status/format 回落', () {
      final info = decodeCertInfo({
        'status': 'totally_unknown_status',
        'format': 'totally_unknown_format',
        'certificates': [],
      })!;
      expect(info.status, CertInfoStatus.unrecognized);
      expect(info.format, CertFormat.unknown);
      expect(info.certificates, isEmpty);
    });

    test('线格式：parseCertificate 发出的 payload 与 wire_payload.hex 逐字节相同',
        () async {
      // 该 fixture 由 Todo 6 用 path=`store.p12` + password=`changeit` 构造；
      // 独立重建 utf8("store.p12") + 0x00 + utf8("changeit") 校验 fixture 内容。
      final expectedHex = readFixture('wire_payload.hex').trim();
      final expectedBytes = hexDecode(expectedHex);
      final rebuilt = Uint8List.fromList(<int>[
        ...utf8.encode('store.p12'),
        0x00,
        ...utf8.encode('changeit'),
      ]);
      expect(rebuilt, equals(expectedBytes),
          reason: 'fixture 必须等于 path\\0password 的独立重建结果');
      expect(expectedHex, '73746f72652e703132006368616e67656974');

      final instance = _CapturingModuleInstance(
        Uint8List.fromList(
          utf8.encode('{"status":"ok","format":"der","certificates":[]}'),
        ),
      );
      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          expect(module, 'analyzer');
          return true;
        },
        loadOverride: (String module) async => _FakeModuleHandle(),
        factoryOverride: (ModuleHandle handle) async => instance,
      );

      final info = await AnalyzerRustDecoder.parseCertificate(
        'store.p12',
        password: 'changeit',
      );
      expect(info, isNotNull, reason: '假模块返回合法 JSON → 解码成功');
      expect(instance.methods, ['parse_certificate']);
      expect(instance.payloads, hasLength(1));
      // 逐字节比对解码器实际发出的 payload 与共享 fixture。
      expect(instance.payloads.single, equals(expectedBytes));
    });
  });
}
