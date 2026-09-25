import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';

/// `failureReason`（`API.md` §2.18，Rust `failure_reason`，camelCase serde）解析。
///
/// 该字段为向前兼容的可选新增：旧 payload 无此键时必须缺省为空串，非字符串值
/// 由 `_str` 容错（不崩）。
void main() {
  group('CaptureRecord.failureReason', () {
    test('parses the failureReason value when present', () {
      final record = CaptureRecord.fromJson(<String, dynamic>{
        'recordId': 7,
        'mitmFailed': true,
        'failureReason': 'dial via DIRECT exceeded the 12s deadline',
      });

      expect(
        record.failureReason,
        'dial via DIRECT exceeded the 12s deadline',
      );
      expect(record.recordId, 7);
      expect(record.mitmFailed, isTrue);
    });

    test('defaults to empty string when the key is absent', () {
      final record = CaptureRecord.fromJson(<String, dynamic>{
        'recordId': 8,
        'mitmFailed': false,
      });

      expect(record.failureReason, '');
    });

    test('carries failureReason in toJson', () {
      const record = CaptureRecord(
        recordId: 9,
        failureReason: 'connection refused',
      );

      expect(record.toJson()['failureReason'], 'connection refused');
    });

    test('tolerates a non-string failureReason without throwing', () {
      final record = CaptureRecord.fromJson(<String, dynamic>{
        'failureReason': 42,
      });

      expect(record.failureReason, isA<String>());
      expect(record.failureReason, '42');
    });
  });

  group('CaptureDetail.failureReason', () {
    test('parses the failureReason value when present', () {
      final detail = CaptureDetail.fromJson(<String, dynamic>{
        'recordId': 7,
        'mitmFailed': true,
        'failureReason': 'dial via DIRECT exceeded the 12s deadline',
      });

      expect(
        detail.failureReason,
        'dial via DIRECT exceeded the 12s deadline',
      );
      expect(detail.recordId, 7);
      expect(detail.mitmFailed, isTrue);
    });

    test('defaults to empty string when the key is absent', () {
      final detail = CaptureDetail.fromJson(<String, dynamic>{
        'recordId': 8,
        'mitmFailed': false,
      });

      expect(detail.failureReason, '');
    });

    test('carries failureReason in toJson', () {
      const detail = CaptureDetail(
        recordId: 9,
        failureReason: 'connection refused',
      );

      expect(detail.toJson()['failureReason'], 'connection refused');
    });

    test('tolerates a non-string failureReason without throwing', () {
      final detail = CaptureDetail.fromJson(<String, dynamic>{
        'failureReason': 42,
      });

      expect(detail.failureReason, isA<String>());
      expect(detail.failureReason, '42');
    });
  });
}
