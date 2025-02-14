// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'github_auth_api.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AuthDeviceResponse _$AuthDeviceResponseFromJson(Map<String, dynamic> json) =>
    AuthDeviceResponse(
      deviceCode: json['device_code'] as String?,
      userCode: json['user_code'] as String?,
      verificationUri: json['verification_uri'] as String?,
      expiresIn: (json['expires_in'] as num?)?.toInt(),
      interval: (json['interval'] as num?)?.toInt(),
    );

Map<String, dynamic> _$AuthDeviceResponseToJson(AuthDeviceResponse instance) =>
    <String, dynamic>{
      'device_code': instance.deviceCode,
      'user_code': instance.userCode,
      'verification_uri': instance.verificationUri,
      'expires_in': instance.expiresIn,
      'interval': instance.interval,
    };

AuthLoginResponse _$AuthLoginResponseFromJson(Map<String, dynamic> json) =>
    AuthLoginResponse(
      json['error'] as String?,
      (json['interval'] as num?)?.toInt(),
      accessToken: json['access_token'] as String?,
      tokenType: json['token_type'] as String?,
      scope: json['scope'] as String?,
    );

Map<String, dynamic> _$AuthLoginResponseToJson(AuthLoginResponse instance) =>
    <String, dynamic>{
      'access_token': instance.accessToken,
      'token_type': instance.tokenType,
      'scope': instance.scope,
      'error': instance.error,
      'interval': instance.interval,
    };

// **************************************************************************
// RetrofitGenerator
// **************************************************************************

// ignore_for_file: unnecessary_brace_in_string_interps,no_leading_underscores_for_local_identifiers,unused_element,unnecessary_string_interpolations

class _GithubAuthApi implements GithubAuthApi {
  _GithubAuthApi(
    this._dio, {
    this.baseUrl,
    this.errorLogger,
  }) {
    baseUrl ??= 'https://github.com/login';
  }

  final Dio _dio;

  String? baseUrl;

  final ParseErrorLogger? errorLogger;

  @override
  Future<AuthDeviceResponse> device(
    String clientId, {
    String scope = "repo",
  }) async {
    final _extra = <String, dynamic>{};
    final queryParameters = <String, dynamic>{};
    final _headers = <String, dynamic>{};
    final _data = {
      'client_id': clientId,
      'scope': scope,
    };
    final _options = _setStreamType<AuthDeviceResponse>(Options(
      method: 'POST',
      headers: _headers,
      extra: _extra,
    )
        .compose(
          _dio.options,
          '/device/code',
          queryParameters: queryParameters,
          data: _data,
        )
        .copyWith(
            baseUrl: _combineBaseUrls(
          _dio.options.baseUrl,
          baseUrl,
        )));
    final _result = await _dio.fetch<Map<String, dynamic>>(_options);
    late AuthDeviceResponse _value;
    try {
      _value = AuthDeviceResponse.fromJson(_result.data!);
    } on Object catch (e, s) {
      errorLogger?.logError(e, s, _options);
      rethrow;
    }
    return _value;
  }

  @override
  Future<AuthLoginResponse> login(
    String clientId,
    String deviceCode, {
    String gratType = "urn:ietf:params:oauth:grant-type:device_code",
  }) async {
    final _extra = <String, dynamic>{};
    final queryParameters = <String, dynamic>{};
    final _headers = <String, dynamic>{};
    final _data = {
      'client_id': clientId,
      'device_code': deviceCode,
      'grant_type': gratType,
    };
    final _options = _setStreamType<AuthLoginResponse>(Options(
      method: 'POST',
      headers: _headers,
      extra: _extra,
    )
        .compose(
          _dio.options,
          '/oauth/access_token',
          queryParameters: queryParameters,
          data: _data,
        )
        .copyWith(
            baseUrl: _combineBaseUrls(
          _dio.options.baseUrl,
          baseUrl,
        )));
    final _result = await _dio.fetch<Map<String, dynamic>>(_options);
    late AuthLoginResponse _value;
    try {
      _value = AuthLoginResponse.fromJson(_result.data!);
    } on Object catch (e, s) {
      errorLogger?.logError(e, s, _options);
      rethrow;
    }
    return _value;
  }

  RequestOptions _setStreamType<T>(RequestOptions requestOptions) {
    if (T != dynamic &&
        !(requestOptions.responseType == ResponseType.bytes ||
            requestOptions.responseType == ResponseType.stream)) {
      if (T == String) {
        requestOptions.responseType = ResponseType.plain;
      } else {
        requestOptions.responseType = ResponseType.json;
      }
    }
    return requestOptions;
  }

  String _combineBaseUrls(
    String dioBaseUrl,
    String? baseUrl,
  ) {
    if (baseUrl == null || baseUrl.trim().isEmpty) {
      return dioBaseUrl;
    }

    final url = Uri.parse(baseUrl);

    if (url.isAbsolute) {
      return url.toString();
    }

    return Uri.parse(dioBaseUrl).resolveUri(url).toString();
  }
}
