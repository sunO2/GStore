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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'envelope.pbenum.dart';

export 'envelope.pbenum.dart';

/// ============ 请求信封（类似 HTTP Request） ============
class EnvelopeRequest extends $pb.GeneratedMessage {
  factory EnvelopeRequest({
    $core.int? protocolVersion,
    $core.String? module,
    $core.String? instance,
    $core.String? method,
    $core.String? requestId,
    $fixnum.Int64? timestampMs,
    PayloadFormat? payloadFormat,
    $core.Map<$core.String, $core.String>? metadata,
    $core.List<$core.int>? payload,
  }) {
    final $result = create();
    if (protocolVersion != null) {
      $result.protocolVersion = protocolVersion;
    }
    if (module != null) {
      $result.module = module;
    }
    if (instance != null) {
      $result.instance = instance;
    }
    if (method != null) {
      $result.method = method;
    }
    if (requestId != null) {
      $result.requestId = requestId;
    }
    if (timestampMs != null) {
      $result.timestampMs = timestampMs;
    }
    if (payloadFormat != null) {
      $result.payloadFormat = payloadFormat;
    }
    if (metadata != null) {
      $result.metadata.addAll(metadata);
    }
    if (payload != null) {
      $result.payload = payload;
    }
    return $result;
  }
  EnvelopeRequest._() : super();
  factory EnvelopeRequest.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory EnvelopeRequest.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EnvelopeRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'gstore.contract'),
      createEmptyInstance: create)
    ..a<$core.int>(
        1, _omitFieldNames ? '' : 'protocolVersion', $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'module')
    ..aOS(3, _omitFieldNames ? '' : 'instance')
    ..aOS(4, _omitFieldNames ? '' : 'method')
    ..aOS(5, _omitFieldNames ? '' : 'requestId')
    ..aInt64(6, _omitFieldNames ? '' : 'timestampMs')
    ..e<PayloadFormat>(
        7, _omitFieldNames ? '' : 'payloadFormat', $pb.PbFieldType.OE,
        defaultOrMaker: PayloadFormat.PAYLOAD_PROTOBUF,
        valueOf: PayloadFormat.valueOf,
        enumValues: PayloadFormat.values)
    ..m<$core.String, $core.String>(8, _omitFieldNames ? '' : 'metadata',
        entryClassName: 'EnvelopeRequest.MetadataEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('gstore.contract'))
    ..a<$core.List<$core.int>>(
        10, _omitFieldNames ? '' : 'payload', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  EnvelopeRequest clone() => EnvelopeRequest()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  EnvelopeRequest copyWith(void Function(EnvelopeRequest) updates) =>
      super.copyWith((message) => updates(message as EnvelopeRequest))
          as EnvelopeRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EnvelopeRequest create() => EnvelopeRequest._();
  EnvelopeRequest createEmptyInstance() => create();
  static $pb.PbList<EnvelopeRequest> createRepeated() =>
      $pb.PbList<EnvelopeRequest>();
  @$core.pragma('dart2js:noInline')
  static EnvelopeRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EnvelopeRequest>(create);
  static EnvelopeRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int v) {
    $_setUnsignedInt32(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => clearField(1);

  /// --- 路由头（代替 URL）---
  @$pb.TagNumber(2)
  $core.String get module => $_getSZ(1);
  @$pb.TagNumber(2)
  set module($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasModule() => $_has(1);
  @$pb.TagNumber(2)
  void clearModule() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get instance => $_getSZ(2);
  @$pb.TagNumber(3)
  set instance($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasInstance() => $_has(2);
  @$pb.TagNumber(3)
  void clearInstance() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get method => $_getSZ(3);
  @$pb.TagNumber(4)
  set method($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasMethod() => $_has(3);
  @$pb.TagNumber(4)
  void clearMethod() => clearField(4);

  /// --- 元数据 ---
  @$pb.TagNumber(5)
  $core.String get requestId => $_getSZ(4);
  @$pb.TagNumber(5)
  set requestId($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasRequestId() => $_has(4);
  @$pb.TagNumber(5)
  void clearRequestId() => clearField(5);

  @$pb.TagNumber(6)
  $fixnum.Int64 get timestampMs => $_getI64(5);
  @$pb.TagNumber(6)
  set timestampMs($fixnum.Int64 v) {
    $_setInt64(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasTimestampMs() => $_has(5);
  @$pb.TagNumber(6)
  void clearTimestampMs() => clearField(6);

  @$pb.TagNumber(7)
  PayloadFormat get payloadFormat => $_getN(6);
  @$pb.TagNumber(7)
  set payloadFormat(PayloadFormat v) {
    setField(7, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasPayloadFormat() => $_has(6);
  @$pb.TagNumber(7)
  void clearPayloadFormat() => clearField(7);

  @$pb.TagNumber(8)
  $core.Map<$core.String, $core.String> get metadata => $_getMap(7);

  @$pb.TagNumber(10)
  $core.List<$core.int> get payload => $_getN(8);
  @$pb.TagNumber(10)
  set payload($core.List<$core.int> v) {
    $_setBytes(8, v);
  }

  @$pb.TagNumber(10)
  $core.bool hasPayload() => $_has(8);
  @$pb.TagNumber(10)
  void clearPayload() => clearField(10);
}

/// ============ 响应信封（类似 HTTP Response） ============
class EnvelopeResponse extends $pb.GeneratedMessage {
  factory EnvelopeResponse({
    $core.int? protocolVersion,
    $core.String? requestId,
    StatusCode? status,
    $core.String? errorCode,
    $core.String? errorMessage,
    $fixnum.Int64? timestampMs,
    $fixnum.Int64? durationMs,
    $core.Map<$core.String, $core.String>? metadata,
    $core.List<$core.int>? payload,
  }) {
    final $result = create();
    if (protocolVersion != null) {
      $result.protocolVersion = protocolVersion;
    }
    if (requestId != null) {
      $result.requestId = requestId;
    }
    if (status != null) {
      $result.status = status;
    }
    if (errorCode != null) {
      $result.errorCode = errorCode;
    }
    if (errorMessage != null) {
      $result.errorMessage = errorMessage;
    }
    if (timestampMs != null) {
      $result.timestampMs = timestampMs;
    }
    if (durationMs != null) {
      $result.durationMs = durationMs;
    }
    if (metadata != null) {
      $result.metadata.addAll(metadata);
    }
    if (payload != null) {
      $result.payload = payload;
    }
    return $result;
  }
  EnvelopeResponse._() : super();
  factory EnvelopeResponse.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory EnvelopeResponse.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EnvelopeResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'gstore.contract'),
      createEmptyInstance: create)
    ..a<$core.int>(
        1, _omitFieldNames ? '' : 'protocolVersion', $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'requestId')
    ..e<StatusCode>(3, _omitFieldNames ? '' : 'status', $pb.PbFieldType.OE,
        defaultOrMaker: StatusCode.STATUS_UNKNOWN,
        valueOf: StatusCode.valueOf,
        enumValues: StatusCode.values)
    ..aOS(4, _omitFieldNames ? '' : 'errorCode')
    ..aOS(5, _omitFieldNames ? '' : 'errorMessage')
    ..aInt64(6, _omitFieldNames ? '' : 'timestampMs')
    ..aInt64(7, _omitFieldNames ? '' : 'durationMs')
    ..m<$core.String, $core.String>(8, _omitFieldNames ? '' : 'metadata',
        entryClassName: 'EnvelopeResponse.MetadataEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('gstore.contract'))
    ..a<$core.List<$core.int>>(
        10, _omitFieldNames ? '' : 'payload', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  EnvelopeResponse clone() => EnvelopeResponse()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  EnvelopeResponse copyWith(void Function(EnvelopeResponse) updates) =>
      super.copyWith((message) => updates(message as EnvelopeResponse))
          as EnvelopeResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EnvelopeResponse create() => EnvelopeResponse._();
  EnvelopeResponse createEmptyInstance() => create();
  static $pb.PbList<EnvelopeResponse> createRepeated() =>
      $pb.PbList<EnvelopeResponse>();
  @$core.pragma('dart2js:noInline')
  static EnvelopeResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EnvelopeResponse>(create);
  static EnvelopeResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int v) {
    $_setUnsignedInt32(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get requestId => $_getSZ(1);
  @$pb.TagNumber(2)
  set requestId($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasRequestId() => $_has(1);
  @$pb.TagNumber(2)
  void clearRequestId() => clearField(2);

  /// --- 状态（仿 HTTP 语义分层）---
  @$pb.TagNumber(3)
  StatusCode get status => $_getN(2);
  @$pb.TagNumber(3)
  set status(StatusCode v) {
    setField(3, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasStatus() => $_has(2);
  @$pb.TagNumber(3)
  void clearStatus() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get errorCode => $_getSZ(3);
  @$pb.TagNumber(4)
  set errorCode($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasErrorCode() => $_has(3);
  @$pb.TagNumber(4)
  void clearErrorCode() => clearField(4);

  @$pb.TagNumber(5)
  $core.String get errorMessage => $_getSZ(4);
  @$pb.TagNumber(5)
  set errorMessage($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasErrorMessage() => $_has(4);
  @$pb.TagNumber(5)
  void clearErrorMessage() => clearField(5);

  /// --- 元数据 ---
  @$pb.TagNumber(6)
  $fixnum.Int64 get timestampMs => $_getI64(5);
  @$pb.TagNumber(6)
  set timestampMs($fixnum.Int64 v) {
    $_setInt64(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasTimestampMs() => $_has(5);
  @$pb.TagNumber(6)
  void clearTimestampMs() => clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get durationMs => $_getI64(6);
  @$pb.TagNumber(7)
  set durationMs($fixnum.Int64 v) {
    $_setInt64(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasDurationMs() => $_has(6);
  @$pb.TagNumber(7)
  void clearDurationMs() => clearField(7);

  @$pb.TagNumber(8)
  $core.Map<$core.String, $core.String> get metadata => $_getMap(7);

  @$pb.TagNumber(10)
  $core.List<$core.int> get payload => $_getN(8);
  @$pb.TagNumber(10)
  set payload($core.List<$core.int> v) {
    $_setBytes(8, v);
  }

  @$pb.TagNumber(10)
  $core.bool hasPayload() => $_has(8);
  @$pb.TagNumber(10)
  void clearPayload() => clearField(10);
}

/// ============ 取消消息（主动中断长任务） ============
class EnvelopeCancel extends $pb.GeneratedMessage {
  factory EnvelopeCancel({
    $core.int? protocolVersion,
    $core.String? requestId,
    $core.String? module,
    $core.String? instance,
    $core.String? method,
    CancelReason? reason,
  }) {
    final $result = create();
    if (protocolVersion != null) {
      $result.protocolVersion = protocolVersion;
    }
    if (requestId != null) {
      $result.requestId = requestId;
    }
    if (module != null) {
      $result.module = module;
    }
    if (instance != null) {
      $result.instance = instance;
    }
    if (method != null) {
      $result.method = method;
    }
    if (reason != null) {
      $result.reason = reason;
    }
    return $result;
  }
  EnvelopeCancel._() : super();
  factory EnvelopeCancel.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory EnvelopeCancel.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EnvelopeCancel',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'gstore.contract'),
      createEmptyInstance: create)
    ..a<$core.int>(
        1, _omitFieldNames ? '' : 'protocolVersion', $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'requestId')
    ..aOS(3, _omitFieldNames ? '' : 'module')
    ..aOS(4, _omitFieldNames ? '' : 'instance')
    ..aOS(5, _omitFieldNames ? '' : 'method')
    ..e<CancelReason>(6, _omitFieldNames ? '' : 'reason', $pb.PbFieldType.OE,
        defaultOrMaker: CancelReason.CANCEL_USER,
        valueOf: CancelReason.valueOf,
        enumValues: CancelReason.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  EnvelopeCancel clone() => EnvelopeCancel()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  EnvelopeCancel copyWith(void Function(EnvelopeCancel) updates) =>
      super.copyWith((message) => updates(message as EnvelopeCancel))
          as EnvelopeCancel;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EnvelopeCancel create() => EnvelopeCancel._();
  EnvelopeCancel createEmptyInstance() => create();
  static $pb.PbList<EnvelopeCancel> createRepeated() =>
      $pb.PbList<EnvelopeCancel>();
  @$core.pragma('dart2js:noInline')
  static EnvelopeCancel getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EnvelopeCancel>(create);
  static EnvelopeCancel? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int v) {
    $_setUnsignedInt32(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get requestId => $_getSZ(1);
  @$pb.TagNumber(2)
  set requestId($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasRequestId() => $_has(1);
  @$pb.TagNumber(2)
  void clearRequestId() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get module => $_getSZ(2);
  @$pb.TagNumber(3)
  set module($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasModule() => $_has(2);
  @$pb.TagNumber(3)
  void clearModule() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get instance => $_getSZ(3);
  @$pb.TagNumber(4)
  set instance($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasInstance() => $_has(3);
  @$pb.TagNumber(4)
  void clearInstance() => clearField(4);

  @$pb.TagNumber(5)
  $core.String get method => $_getSZ(4);
  @$pb.TagNumber(5)
  set method($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasMethod() => $_has(4);
  @$pb.TagNumber(5)
  void clearMethod() => clearField(5);

  @$pb.TagNumber(6)
  CancelReason get reason => $_getN(5);
  @$pb.TagNumber(6)
  set reason(CancelReason v) {
    setField(6, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasReason() => $_has(5);
  @$pb.TagNumber(6)
  void clearReason() => clearField(6);
}

const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
