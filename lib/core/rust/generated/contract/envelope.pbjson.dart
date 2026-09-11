//
//  Generated code. Do not modify.
//  source: envelope.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use payloadFormatDescriptor instead')
const PayloadFormat$json = {
  '1': 'PayloadFormat',
  '2': [
    {'1': 'PAYLOAD_PROTOBUF', '2': 0},
    {'1': 'PAYLOAD_JSON', '2': 1},
    {'1': 'PAYLOAD_RAW_BYTES', '2': 2},
  ],
};

/// Descriptor for `PayloadFormat`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List payloadFormatDescriptor = $convert.base64Decode(
    'Cg1QYXlsb2FkRm9ybWF0EhQKEFBBWUxPQURfUFJPVE9CVUYQABIQCgxQQVlMT0FEX0pTT04QAR'
    'IVChFQQVlMT0FEX1JBV19CWVRFUxAC');

@$core.Deprecated('Use cancelReasonDescriptor instead')
const CancelReason$json = {
  '1': 'CancelReason',
  '2': [
    {'1': 'CANCEL_USER', '2': 0},
    {'1': 'CANCEL_TIMEOUT', '2': 1},
    {'1': 'CANCEL_SHUTDOWN', '2': 2},
  ],
};

/// Descriptor for `CancelReason`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List cancelReasonDescriptor = $convert.base64Decode(
    'CgxDYW5jZWxSZWFzb24SDwoLQ0FOQ0VMX1VTRVIQABISCg5DQU5DRUxfVElNRU9VVBABEhMKD0'
    'NBTkNFTF9TSFVURE9XThAC');

@$core.Deprecated('Use statusCodeDescriptor instead')
const StatusCode$json = {
  '1': 'StatusCode',
  '2': [
    {'1': 'STATUS_UNKNOWN', '2': 0},
    {'1': 'STATUS_OK', '2': 200},
    {'1': 'STATUS_CREATED', '2': 201},
    {'1': 'STATUS_MODULE_NOT_LOADED', '2': 301},
    {'1': 'STATUS_INSTANCE_EXPIRED', '2': 302},
    {'1': 'STATUS_BAD_REQUEST', '2': 400},
    {'1': 'STATUS_MODULE_NOT_FOUND', '2': 404},
    {'1': 'STATUS_METHOD_NOT_FOUND', '2': 405},
    {'1': 'STATUS_INSTANCE_NOT_FOUND', '2': 410},
    {'1': 'STATUS_INVALID_ARGUMENT', '2': 422},
    {'1': 'STATUS_VERSION_MISMATCH', '2': 426},
    {'1': 'STATUS_ABORTED', '2': 499},
    {'1': 'STATUS_INTERNAL_ERROR', '2': 500},
    {'1': 'STATUS_PANIC_CAUGHT', '2': 5001},
    {'1': 'STATUS_RESOURCE_EXHAUSTED', '2': 507},
    {'1': 'STATUS_TIMEOUT', '2': 504},
  ],
};

/// Descriptor for `StatusCode`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List statusCodeDescriptor = $convert.base64Decode(
    'CgpTdGF0dXNDb2RlEhIKDlNUQVRVU19VTktOT1dOEAASDgoJU1RBVFVTX09LEMgBEhMKDlNUQV'
    'RVU19DUkVBVEVEEMkBEh0KGFNUQVRVU19NT0RVTEVfTk9UX0xPQURFRBCtAhIcChdTVEFUVVNf'
    'SU5TVEFOQ0VfRVhQSVJFRBCuAhIXChJTVEFUVVNfQkFEX1JFUVVFU1QQkAMSHAoXU1RBVFVTX0'
    '1PRFVMRV9OT1RfRk9VTkQQlAMSHAoXU1RBVFVTX01FVEhPRF9OT1RfRk9VTkQQlQMSHgoZU1RB'
    'VFVTX0lOU1RBTkNFX05PVF9GT1VORBCaAxIcChdTVEFUVVNfSU5WQUxJRF9BUkdVTUVOVBCmAx'
    'IcChdTVEFUVVNfVkVSU0lPTl9NSVNNQVRDSBCqAxITCg5TVEFUVVNfQUJPUlRFRBDzAxIaChVT'
    'VEFUVVNfSU5URVJOQUxfRVJST1IQ9AMSGAoTU1RBVFVTX1BBTklDX0NBVUdIVBCJJxIeChlTVE'
    'FUVVNfUkVTT1VSQ0VfRVhIQVVTVEVEEPsDEhMKDlNUQVRVU19USU1FT1VUEPgD');

@$core.Deprecated('Use envelopeRequestDescriptor instead')
const EnvelopeRequest$json = {
  '1': 'EnvelopeRequest',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {'1': 'module', '3': 2, '4': 1, '5': 9, '10': 'module'},
    {'1': 'instance', '3': 3, '4': 1, '5': 9, '10': 'instance'},
    {'1': 'method', '3': 4, '4': 1, '5': 9, '10': 'method'},
    {'1': 'request_id', '3': 5, '4': 1, '5': 9, '10': 'requestId'},
    {'1': 'timestamp_ms', '3': 6, '4': 1, '5': 3, '10': 'timestampMs'},
    {
      '1': 'payload_format',
      '3': 7,
      '4': 1,
      '5': 14,
      '6': '.gstore.contract.PayloadFormat',
      '10': 'payloadFormat'
    },
    {
      '1': 'metadata',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.gstore.contract.EnvelopeRequest.MetadataEntry',
      '10': 'metadata'
    },
    {'1': 'payload', '3': 10, '4': 1, '5': 12, '10': 'payload'},
  ],
  '3': [EnvelopeRequest_MetadataEntry$json],
};

@$core.Deprecated('Use envelopeRequestDescriptor instead')
const EnvelopeRequest_MetadataEntry$json = {
  '1': 'MetadataEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `EnvelopeRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List envelopeRequestDescriptor = $convert.base64Decode(
    'Cg9FbnZlbG9wZVJlcXVlc3QSKQoQcHJvdG9jb2xfdmVyc2lvbhgBIAEoDVIPcHJvdG9jb2xWZX'
    'JzaW9uEhYKBm1vZHVsZRgCIAEoCVIGbW9kdWxlEhoKCGluc3RhbmNlGAMgASgJUghpbnN0YW5j'
    'ZRIWCgZtZXRob2QYBCABKAlSBm1ldGhvZBIdCgpyZXF1ZXN0X2lkGAUgASgJUglyZXF1ZXN0SW'
    'QSIQoMdGltZXN0YW1wX21zGAYgASgDUgt0aW1lc3RhbXBNcxJFCg5wYXlsb2FkX2Zvcm1hdBgH'
    'IAEoDjIeLmdzdG9yZS5jb250cmFjdC5QYXlsb2FkRm9ybWF0Ug1wYXlsb2FkRm9ybWF0EkoKCG'
    '1ldGFkYXRhGAggAygLMi4uZ3N0b3JlLmNvbnRyYWN0LkVudmVsb3BlUmVxdWVzdC5NZXRhZGF0'
    'YUVudHJ5UghtZXRhZGF0YRIYCgdwYXlsb2FkGAogASgMUgdwYXlsb2FkGjsKDU1ldGFkYXRhRW'
    '50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVlOgI4AQ==');

@$core.Deprecated('Use envelopeResponseDescriptor instead')
const EnvelopeResponse$json = {
  '1': 'EnvelopeResponse',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {'1': 'request_id', '3': 2, '4': 1, '5': 9, '10': 'requestId'},
    {
      '1': 'status',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.gstore.contract.StatusCode',
      '10': 'status'
    },
    {'1': 'error_code', '3': 4, '4': 1, '5': 9, '10': 'errorCode'},
    {'1': 'error_message', '3': 5, '4': 1, '5': 9, '10': 'errorMessage'},
    {'1': 'timestamp_ms', '3': 6, '4': 1, '5': 3, '10': 'timestampMs'},
    {'1': 'duration_ms', '3': 7, '4': 1, '5': 3, '10': 'durationMs'},
    {
      '1': 'metadata',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.gstore.contract.EnvelopeResponse.MetadataEntry',
      '10': 'metadata'
    },
    {'1': 'payload', '3': 10, '4': 1, '5': 12, '10': 'payload'},
  ],
  '3': [EnvelopeResponse_MetadataEntry$json],
};

@$core.Deprecated('Use envelopeResponseDescriptor instead')
const EnvelopeResponse_MetadataEntry$json = {
  '1': 'MetadataEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `EnvelopeResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List envelopeResponseDescriptor = $convert.base64Decode(
    'ChBFbnZlbG9wZVJlc3BvbnNlEikKEHByb3RvY29sX3ZlcnNpb24YASABKA1SD3Byb3RvY29sVm'
    'Vyc2lvbhIdCgpyZXF1ZXN0X2lkGAIgASgJUglyZXF1ZXN0SWQSMwoGc3RhdHVzGAMgASgOMhsu'
    'Z3N0b3JlLmNvbnRyYWN0LlN0YXR1c0NvZGVSBnN0YXR1cxIdCgplcnJvcl9jb2RlGAQgASgJUg'
    'llcnJvckNvZGUSIwoNZXJyb3JfbWVzc2FnZRgFIAEoCVIMZXJyb3JNZXNzYWdlEiEKDHRpbWVz'
    'dGFtcF9tcxgGIAEoA1ILdGltZXN0YW1wTXMSHwoLZHVyYXRpb25fbXMYByABKANSCmR1cmF0aW'
    '9uTXMSSwoIbWV0YWRhdGEYCCADKAsyLy5nc3RvcmUuY29udHJhY3QuRW52ZWxvcGVSZXNwb25z'
    'ZS5NZXRhZGF0YUVudHJ5UghtZXRhZGF0YRIYCgdwYXlsb2FkGAogASgMUgdwYXlsb2FkGjsKDU'
    '1ldGFkYXRhRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVlOgI4'
    'AQ==');

@$core.Deprecated('Use envelopeCancelDescriptor instead')
const EnvelopeCancel$json = {
  '1': 'EnvelopeCancel',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {'1': 'request_id', '3': 2, '4': 1, '5': 9, '10': 'requestId'},
    {'1': 'module', '3': 3, '4': 1, '5': 9, '10': 'module'},
    {'1': 'instance', '3': 4, '4': 1, '5': 9, '10': 'instance'},
    {'1': 'method', '3': 5, '4': 1, '5': 9, '10': 'method'},
    {
      '1': 'reason',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.gstore.contract.CancelReason',
      '10': 'reason'
    },
  ],
};

/// Descriptor for `EnvelopeCancel`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List envelopeCancelDescriptor = $convert.base64Decode(
    'Cg5FbnZlbG9wZUNhbmNlbBIpChBwcm90b2NvbF92ZXJzaW9uGAEgASgNUg9wcm90b2NvbFZlcn'
    'Npb24SHQoKcmVxdWVzdF9pZBgCIAEoCVIJcmVxdWVzdElkEhYKBm1vZHVsZRgDIAEoCVIGbW9k'
    'dWxlEhoKCGluc3RhbmNlGAQgASgJUghpbnN0YW5jZRIWCgZtZXRob2QYBSABKAlSBm1ldGhvZB'
    'I1CgZyZWFzb24YBiABKA4yHS5nc3RvcmUuY29udHJhY3QuQ2FuY2VsUmVhc29uUgZyZWFzb24=');
