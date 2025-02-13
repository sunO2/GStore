import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:retrofit/retrofit.dart';

part 'github_auth_api.g.dart';

@RestApi(baseUrl: 'https://github.com/login')
abstract class GithubAuthApi with GetxServiceMixin {
  factory GithubAuthApi(Dio dio, {String? baseUrl}) => _GithubAuthApi(dio);

  @POST('/device/code')
  Future<AuthDeviceResponse> device(@Field("client_id") String clientId,
      {@Field("scope") String scope = "repo"});
  @POST('/oauth/access_token')
  Future<AuthLoginResponse> login(@Field("client_id") String clientId,
      @Field("device_code") String deviceCode,
      {@Field("grant_type")
      String gratType = "urn:ietf:params:oauth:grant-type:device_code"});
}

@JsonSerializable()
class AuthDeviceResponse {
  @JsonKey(name: "device_code")
  final String? deviceCode;
  @JsonKey(name: "user_code")
  final String? userCode;
  @JsonKey(name: "verification_uri")
  final String? verificationUri;
  @JsonKey(name: "expires_in")
  final int? expiresIn;
  final int? interval;

  AuthDeviceResponse(
      {this.deviceCode,
      this.userCode,
      this.verificationUri,
      this.expiresIn,
      this.interval});

  factory AuthDeviceResponse.fromJson(Map<String, dynamic> json) =>
      _$AuthDeviceResponseFromJson(json);
  Map<String, dynamic> toJson() => _$AuthDeviceResponseToJson(this);
}

@JsonSerializable()
class AuthLoginResponse {
  @JsonKey(name: "access_token")
  final String? accessToken;
  @JsonKey(name: "token_type")
  final String? tokenType;
  final String? scope;

  AuthLoginResponse({this.accessToken, this.tokenType, this.scope});

  factory AuthLoginResponse.fromJson(Map<String, dynamic> json) =>
      _$AuthLoginResponseFromJson(json);
  Map<String, dynamic> toJson() => _$AuthLoginResponseToJson(this);
}
