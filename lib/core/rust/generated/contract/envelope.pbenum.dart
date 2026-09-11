//
//  Generated code. Do not modify.
//  source: envelope.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// ============ payload 编码格式 ============
class PayloadFormat extends $pb.ProtobufEnum {
  static const PayloadFormat PAYLOAD_PROTOBUF =
      PayloadFormat._(0, _omitEnumNames ? '' : 'PAYLOAD_PROTOBUF');
  static const PayloadFormat PAYLOAD_JSON =
      PayloadFormat._(1, _omitEnumNames ? '' : 'PAYLOAD_JSON');
  static const PayloadFormat PAYLOAD_RAW_BYTES =
      PayloadFormat._(2, _omitEnumNames ? '' : 'PAYLOAD_RAW_BYTES');

  static const $core.List<PayloadFormat> values = <PayloadFormat>[
    PAYLOAD_PROTOBUF,
    PAYLOAD_JSON,
    PAYLOAD_RAW_BYTES,
  ];

  static final $core.Map<$core.int, PayloadFormat> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static PayloadFormat? valueOf($core.int value) => _byValue[value];

  const PayloadFormat._($core.int v, $core.String n) : super(v, n);
}

class CancelReason extends $pb.ProtobufEnum {
  static const CancelReason CANCEL_USER =
      CancelReason._(0, _omitEnumNames ? '' : 'CANCEL_USER');
  static const CancelReason CANCEL_TIMEOUT =
      CancelReason._(1, _omitEnumNames ? '' : 'CANCEL_TIMEOUT');
  static const CancelReason CANCEL_SHUTDOWN =
      CancelReason._(2, _omitEnumNames ? '' : 'CANCEL_SHUTDOWN');

  static const $core.List<CancelReason> values = <CancelReason>[
    CANCEL_USER,
    CANCEL_TIMEOUT,
    CANCEL_SHUTDOWN,
  ];

  static final $core.Map<$core.int, CancelReason> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static CancelReason? valueOf($core.int value) => _byValue[value];

  const CancelReason._($core.int v, $core.String n) : super(v, n);
}

/// ============ 状态码规范 ============
/// 同 HTTP 逻辑：status 决定处理策略（重试/降级/提示/报 bug），
/// error_code 决定具体原因（日志与排障）。
class StatusCode extends $pb.ProtobufEnum {
  static const StatusCode STATUS_UNKNOWN =
      StatusCode._(0, _omitEnumNames ? '' : 'STATUS_UNKNOWN');
  static const StatusCode STATUS_OK =
      StatusCode._(200, _omitEnumNames ? '' : 'STATUS_OK');
  static const StatusCode STATUS_CREATED =
      StatusCode._(201, _omitEnumNames ? '' : 'STATUS_CREATED');
  static const StatusCode STATUS_MODULE_NOT_LOADED =
      StatusCode._(301, _omitEnumNames ? '' : 'STATUS_MODULE_NOT_LOADED');
  static const StatusCode STATUS_INSTANCE_EXPIRED =
      StatusCode._(302, _omitEnumNames ? '' : 'STATUS_INSTANCE_EXPIRED');
  static const StatusCode STATUS_BAD_REQUEST =
      StatusCode._(400, _omitEnumNames ? '' : 'STATUS_BAD_REQUEST');
  static const StatusCode STATUS_MODULE_NOT_FOUND =
      StatusCode._(404, _omitEnumNames ? '' : 'STATUS_MODULE_NOT_FOUND');
  static const StatusCode STATUS_METHOD_NOT_FOUND =
      StatusCode._(405, _omitEnumNames ? '' : 'STATUS_METHOD_NOT_FOUND');
  static const StatusCode STATUS_INSTANCE_NOT_FOUND =
      StatusCode._(410, _omitEnumNames ? '' : 'STATUS_INSTANCE_NOT_FOUND');
  static const StatusCode STATUS_INVALID_ARGUMENT =
      StatusCode._(422, _omitEnumNames ? '' : 'STATUS_INVALID_ARGUMENT');
  static const StatusCode STATUS_VERSION_MISMATCH =
      StatusCode._(426, _omitEnumNames ? '' : 'STATUS_VERSION_MISMATCH');
  static const StatusCode STATUS_ABORTED =
      StatusCode._(499, _omitEnumNames ? '' : 'STATUS_ABORTED');
  static const StatusCode STATUS_INTERNAL_ERROR =
      StatusCode._(500, _omitEnumNames ? '' : 'STATUS_INTERNAL_ERROR');
  static const StatusCode STATUS_PANIC_CAUGHT =
      StatusCode._(5001, _omitEnumNames ? '' : 'STATUS_PANIC_CAUGHT');
  static const StatusCode STATUS_RESOURCE_EXHAUSTED =
      StatusCode._(507, _omitEnumNames ? '' : 'STATUS_RESOURCE_EXHAUSTED');
  static const StatusCode STATUS_TIMEOUT =
      StatusCode._(504, _omitEnumNames ? '' : 'STATUS_TIMEOUT');

  static const $core.List<StatusCode> values = <StatusCode>[
    STATUS_UNKNOWN,
    STATUS_OK,
    STATUS_CREATED,
    STATUS_MODULE_NOT_LOADED,
    STATUS_INSTANCE_EXPIRED,
    STATUS_BAD_REQUEST,
    STATUS_MODULE_NOT_FOUND,
    STATUS_METHOD_NOT_FOUND,
    STATUS_INSTANCE_NOT_FOUND,
    STATUS_INVALID_ARGUMENT,
    STATUS_VERSION_MISMATCH,
    STATUS_ABORTED,
    STATUS_INTERNAL_ERROR,
    STATUS_PANIC_CAUGHT,
    STATUS_RESOURCE_EXHAUSTED,
    STATUS_TIMEOUT,
  ];

  static final $core.Map<$core.int, StatusCode> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static StatusCode? valueOf($core.int value) => _byValue[value];

  const StatusCode._($core.int v, $core.String n) : super(v, n);
}

const _omitEnumNames = $core.bool.fromEnvironment('protobuf.omit_enum_names');
