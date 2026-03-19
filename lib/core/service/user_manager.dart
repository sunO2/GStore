import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';

/// 用户管理服务
///
/// 负责用户登录、token 管理、用户信息存储等功能
class UserManager extends GetxService {
  final _authApi = Get.find<GithubAuthApi>();
  final _githubApi = Get.find<GithubRestClient>();
  final _storage = const FlutterSecureStorage();
  final userInfo = const UserInfo().obs;
  Timer? _loginRequestTimer;

  /// 存储键
  static const String _tokenKey = 'github_token';
  static const String _userInfoKey = 'user_info';

  /// 获取当前用户信息
  Future<UserInfo?> getUserInfo() async {
    return _githubApi.user();
  }

  @override
  onInit() {
    debugPrint('UserManager: onInit 被调用');
    _initialize();
    super.onInit();
  }

  /// 初始化用户登录状态
  Future<void> _initialize() async {
    debugPrint('UserManager: 开始初始化，检查登录状态...');

    // 先读取 token
    final token = await _storage.read(key: _tokenKey);
    debugPrint('UserManager: Token 是否存在: ${token != null && token.isNotEmpty}');

    if (token != null && token.isNotEmpty) {
      // 设置全局授权头
      DioClient.instance.authorization = token;
      debugPrint('UserManager: 已设置授权头');

      // 尝试读取用户信息
      final userInfoJson = await _storage.read(key: _userInfoKey);
      if (userInfoJson != null && userInfoJson.isNotEmpty) {
        try {
          userInfo.value = UserInfo.fromJsonString(userInfoJson);
          debugPrint('UserManager: 已加载用户信息 - ${userInfo.value.login}');
        } catch (e) {
          debugPrint('UserManager: 解析用户信息失败 - $e');
          // 如果解析失败，清除数据
          await logout();
        }
      } else {
        debugPrint('UserManager: 未找到用户信息，尝试重新获取...');
        // 如果有 token 但没有用户信息，尝试重新获取
        try {
          final user = await getUserInfo();
          if (user != null) {
            userInfo.value = user;
            await _storage.write(key: _userInfoKey, value: user.toJson());
            debugPrint('UserManager: 已重新获取用户信息 - ${user.login}');
          } else {
            // token 无效，清除
            debugPrint('UserManager: Token 无效，清除登录状态');
            await logout();
          }
        } catch (e) {
          debugPrint('UserManager: 重新获取用户信息失败 - $e');
          await logout();
        }
      }
    } else {
      debugPrint('UserManager: 未找到 Token，用户未登录');
    }
  }

  /// 公共初始化方法（可在 app 启动时手动调用）
  Future<void> initialize() async {
    await _initialize();
  }

  /// 取消登录请求
  void cancelLogin() {
    if (_loginRequestTimer?.isActive ?? false) {
      _loginRequestTimer?.cancel();
    }
  }

  /// 开始登录轮询
  Future<UserInfo?> startLoginOfTimer(
      String deviceCode, int interval, CancelToken cancelToken) {
    final completer = Completer<UserInfo?>();
    _nextTimer(deviceCode, interval, completer, cancelToken);
    return completer.future;
  }

  /// 下一次轮询
  void _nextTimer(
    String deviceCode,
    int interval,
    Completer<UserInfo?> completer,
    CancelToken cancelToken,
  ) {
    if (_loginRequestTimer?.isActive ?? false) {
      _loginRequestTimer?.cancel();
    }
    _loginRequestTimer = Timer.periodic(Duration(seconds: interval), (timer) {
      if (_loginRequestTimer?.isActive ?? false) {
        _loginRequestTimer?.cancel();
      }
      _login(deviceCode, completer, cancelToken);
    });
  }

  /// 执行登录请求
  Future<void> _login(
    String deviceCode,
    Completer<UserInfo?> completer,
    CancelToken cancelToken,
  ) async {
    try {
      // 检查是否已取消
      if (cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: '登录请求已取消',
        );
      }

      // 调用 GitHub OAuth API
      final auth = await _authApi.login(
        AppConfig.githubClientId,
        deviceCode,
      );

      // 检查 access_token
      if (auth.accessToken?.isEmpty ?? true) {
        // token 还没准备好，继续轮询
        if (cancelToken.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: '登录请求已取消',
          );
        }
        _nextTimer(deviceCode, auth.interval ?? 5, completer, cancelToken);
        return;
      }

      // 登录成功，保存 token 和用户信息
      if (auth.accessToken?.isNotEmpty ?? false) {
        // 保存 token
        await saveToken(auth.accessToken!);

        // 设置全局授权头
        DioClient.instance.authorization = auth.accessToken;

        // 获取用户信息
        final user = await _githubApi.user();
        if (user != null) {
          userInfo.value = user;
          await _storage.write(key: _userInfoKey, value: user.toJson());
          completer.complete(user);
        } else {
          completer.complete(null);
        }
      }
    } on DioException catch (e) {
      // Dio 错误处理
      if (e.type == DioExceptionType.cancel) {
        debugPrint('UserManager: 登录已取消');
      } else if (e.response?.statusCode == 401 ||
          e.response?.statusCode == 403) {
        debugPrint('UserManager: 认证失败 - ${e.response?.statusCode}');
        completer.completeError(e);
      } else {
        debugPrint('UserManager: 登录请求失败 - $e');
        AppDialogs.showError('网络错误，请检查网络连接', title: '登录失败');
        completer.completeError(e);
      }
    } catch (e) {
      // 其他错误处理
      debugPrint('UserManager: 登录异常 - $e');
      AppDialogs.showError('发生未知错误，请重试', title: '登录失败');
      completer.completeError(e);
    }
  }

  /// 获取设备码
  Future<AuthDeviceResponse> get deviceId async {
    try {
      final value = await _authApi.device(AppConfig.githubClientId);

      // 自动复制验证码
      if (value.userCode?.isNotEmpty ?? false) {
        await copyVerificationCode(value.userCode!);
      }

      return value;
    } catch (e) {
      debugPrint('UserManager: 获取设备码失败 - $e');
      AppDialogs.showError('请检查网络连接后重试', title: '获取验证码失败');
      return AuthDeviceResponse();
    }
  }

  /// 保存 token
  Future<bool> saveToken(String token) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
      debugPrint('UserManager: Token 已保存');
      return true;
    } catch (e) {
      debugPrint('UserManager: 保存 token 失败 - $e');
      return false;
    }
  }

  /// 获取 token
  Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  /// 复制验证码到剪贴板
  Future<void> copyVerificationCode(String verificationCode) async {
    await Clipboard.setData(ClipboardData(text: verificationCode));
    AppDialogs.showSuccess(
      '请在 GitHub 页面输入验证码',
      title: '验证码已复制',
      duration: const Duration(seconds: 2),
    );
  }

  /// 验证 token 是否有效
  Future<bool> validateToken() async {
    try {
      final token = await getToken();
      if (token == null || token.isEmpty) {
        return false;
      }

      // 设置 token 并尝试获取用户信息
      DioClient.instance.authorization = token;
      final user = await getUserInfo();

      if (user != null) {
        userInfo.value = user;
        return true;
      }

      // token 无效，清除
      await logout();
      return false;
    } catch (e) {
      debugPrint('UserManager: Token 验证失败 - $e');
      await logout();
      return false;
    }
  }

  /// 检查是否已登录
  Future<bool> isLoggedIn() async {
    final token = await getToken();
    if (token == null || token.isEmpty) {
      return false;
    }
    return userInfo.value.avatarUrl?.isNotEmpty ?? false;
  }

  /// 退出登录
  Future<void> logout() async {
    try {
      // 清除内存中的用户信息
      userInfo.value = const UserInfo();

      // 清除存储的数据
      await _storage.delete(key: _userInfoKey);
      await _storage.delete(key: _tokenKey);

      // 清除 Dio 的授权头
      DioClient.instance.authorization = null;

      // 取消任何进行中的登录
      cancelLogin();

      debugPrint('UserManager: 已退出登录');
    } catch (e) {
      debugPrint('UserManager: 退出登录失败 - $e');
    }
  }
}
