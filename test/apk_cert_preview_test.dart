import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/rust/Contract.dart' show decodeCertInfo;
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_browser_service.dart';
import 'package:gstore/page/apk_browser/preview.dart';

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

    testWidgets('注入含 certInfo 的数据可渲染（缝对字段卡友好）', (tester) async {
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
              certInfo: const CertInfo(
                status: CertInfoStatus.ok,
                format: CertFormat.der,
                passwordProtected: false,
                message: '',
                certificates: [],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ApkEntryPreviewPage), findsOneWidget);
      // DER 二进制（无 BEGIN）→ 十六进制卡；证明注入的 certInfo 不影响既有渲染
      expect(find.textContaining('十六进制预览'), findsOneWidget);
    });
  });
}
