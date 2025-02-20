import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';

class UserManager extends GetxService {
  final _authApi = Get.find<GithubAuthApi>();
  final _githubApi = Get.find<GithubRestClient>();
  final _storage = const FlutterSecureStorage();
  final userInfo = const UserInfo().obs;
  Timer? _loginRequestTimer;

  Future<UserInfo?> getUserInfo() async {
    return _githubApi.user();
  }

  @override
  onInit() async {
    var userInfoJson = await _storage.read(key: "user_info");
    if (null != userInfoJson) {
      userInfo.value = UserInfo.fromJsonString(userInfoJson);
    }
    super.onInit();
  }

  cancelLogin() {
    if (_loginRequestTimer?.isActive ?? false) _loginRequestTimer?.cancel();
  }

  Future<UserInfo?> startLoginOfTimer(
      String deviceCode, int interval, CancelToken cancelToken) {
    Completer<UserInfo> completer = Completer();
    _nextTimer(deviceCode, interval, completer, cancelToken);
    return completer.future;
  }

  _nextTimer(String deviceCode, int interval, Completer<UserInfo?> completer,
      CancelToken cancelToken) {
    if (_loginRequestTimer?.isActive ?? false) _loginRequestTimer?.cancel();
    _loginRequestTimer = Timer.periodic(Duration(seconds: interval), (timer) {
      if (_loginRequestTimer?.isActive ?? false) _loginRequestTimer?.cancel();
      _login(deviceCode, completer, cancelToken);
    });
  }

  _login(String deviceCode, Completer<UserInfo?> completer,
      CancelToken cancelLoginToken) async {
    try {
      if (cancelLoginToken.isCancelled) {
        throw DioException.requestCancelled(
            requestOptions: RequestOptions(), reason: "");
      }
      var auth = await _authApi.login("Ov23liK4Xz0eBlefQJJm", deviceCode);
      if (auth.accessToken?.isEmpty ?? true) {
        if (cancelLoginToken.isCancelled) {
          throw DioException.requestCancelled(
              requestOptions: RequestOptions(), reason: "");
        }
        _nextTimer(deviceCode, auth.interval ?? 5, completer, cancelLoginToken);
        return;
      }
      if (auth.accessToken?.isNotEmpty ?? false) {
        Get.find<UserManager>().saveToken = auth.accessToken;
        DioClient.instance.authorization = auth.accessToken;
        completer.complete(await _githubApi.user().then((user) {
          if (null != user) {
            userInfo.value = user;
            _storage.write(key: "user_info", value: user.toJson());
          }
          return Future.value(user);
        }));
      }
      return null;
    } catch (e) {
      Get.snackbar('提示', '用户验证失败！！！！ 请重试');
      return null;
    }
  }

  Future<AuthDeviceResponse> get deviceId =>
      _authApi.device("Ov23liK4Xz0eBlefQJJm").then((value) {
        if (value.userCode?.isNotEmpty ?? false) {
          copyVerificationCode(value.userCode!);
        }
        return value;
      }).onError((error, strack) async {
        Get.snackbar('提示', '获取用户验证码失败！！！！ 请重试');
        return Future.value(AuthDeviceResponse());
      });

  set saveToken(String? token) =>
      _storage.write(key: "github_token", value: token);

  get token => _storage.read(key: "github_token");

  Future<void> copyVerificationCode(String verificationCode) async {
    await Clipboard.setData(ClipboardData(text: verificationCode));
    Get.snackbar('提示', '验证码已复制到剪贴板');
  }
}
