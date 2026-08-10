import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';

/// 用户管理服务
///
/// 负责用户登录、token 管理、用户信息存储等功能
class UserManager extends GetxService {
  static UserManager? _instance;

  static UserManager get instance {
    _instance ??= UserManager._internal();
    return _instance!;
  }

  late final GithubAuthApi _authApi;
  late final GithubRestClient _githubApi;
  final _secureStorage = const FlutterSecureStorage();
  final userInfo = const UserInfo().obs;
  Timer? _loginRequestTimer;

  /// SharedPreferences 实例（备用存储）
  SharedPreferences? _prefs;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 存储键
  static const String _tokenKey = 'github_token';
  static const String _userInfoKey = 'user_info';

  /// 初始化 SharedPreferences
  Future<void> _initPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 私有构造函数
  UserManager._internal() {
    // 在 initialize() 中初始化依赖
  }

  @override
  onInit() {
    debugPrint('UserManager: onInit 被调用 (instance: ${identityHashCode(this)})');
    // 不要在这里调用 _initialize()，因为 initialize() 会调用它
    super.onInit();
  }

  /// 初始化（必须在使用前调用）
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('UserManager: 已经初始化过，跳过');
      return;
    }

    appLog.info('UserManager: 开始公共初始化');
    // 初始化依赖
    _authApi = Get.find<GithubAuthApi>();
    _githubApi = Get.find<GithubRestClient>();

    // 调用内部初始化
    await _initialize();
  }

  /// 获取当前用户信息
  Future<UserInfo?> getUserInfo() async {
    return _githubApi.user();
  }

  /// 初始化用户登录状态
  Future<void> _initialize() async {
    // 防止重复初始化
    if (_isInitialized) {
      debugPrint('UserManager: 已初始化，跳过重复初始化');
      return;
    }

    appLog.info('UserManager: 开始初始化，检查登录状态...');
    debugPrint('  - 存储键: $_tokenKey');

    // 先读取 token（使用新的 getToken 方法）
    final token = await getToken();

    debugPrint('UserManager: Token 是否存在: ${token != null}');
    if (token != null) {
      debugPrint('  - Token 长度: ${token.length}');
      debugPrint('  - Token 前缀: ${token.substring(0, 10)}...');
    }

    if (token != null && token.isNotEmpty) {
      // 设置全局授权头
      DioClient.instance.authorization = token;
      debugPrint('UserManager: 已设置授权头');

      // 尝试读取用户信息
      final userInfoJson = await _secureStorage.read(key: _userInfoKey);
      if (userInfoJson != null && userInfoJson.isNotEmpty) {
        try {
          userInfo.value = UserInfo.fromJsonString(userInfoJson);
          appLog.info('UserManager: 已加载用户信息 - ${userInfo.value.login}');
        } catch (e) {
          appLog.error('UserManager: 解析用户信息失败 - $e');
          appLog.error('UserManager: ⚠️ 解析失败，清除 Token');
          // 如果解析失败，清除数据
          await logout();
        }
      } else {
        debugPrint('UserManager: 未找到用户信息，尝试重新获取...');
        // 有 token 但没有用户信息：异步重新获取，不阻塞启动
        // （网络请求可能较慢，放在启动路径外；失败不清除 token）
        unawaited(_fetchUserInfoAsync());
      }
    } else {
      debugPrint('UserManager: 未找到 Token，用户未登录');
    }

    // 标记为已初始化
    _isInitialized = true;
    appLog.info('UserManager: 初始化完成');
  }

  /// 异步获取用户信息（不阻塞启动）
  Future<void> _fetchUserInfoAsync() async {
    try {
      final user = await getUserInfo();
      if (user != null) {
        userInfo.value = user;
        await _secureStorage.write(key: _userInfoKey, value: user.toJson());
        appLog.info('UserManager: 已异步获取用户信息 - ${user.login}');
      } else {
        // token 无效，清除
        appLog.error('UserManager: Token 无效（API 返回 null），清除登录状态');
        await logout();
      }
    } catch (e) {
      // 网络错误或其他异常，不清除 Token
      appLog.error('UserManager: 异步获取用户信息失败，保留 Token - $e');
    }
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
          await _secureStorage.write(key: _userInfoKey, value: user.toJson());
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
        appLog.error('UserManager: 认证失败 - ${e.response?.statusCode}');
        completer.completeError(e);
      } else {
        appLog.error('UserManager: 登录请求失败 - $e');
        AppDialogs.showError('网络错误，请检查网络连接', title: '登录失败');
        completer.completeError(e);
      }
    } catch (e) {
      // 其他错误处理
      appLog.error('UserManager: 登录异常 - $e');
      AppDialogs.showError('发生未知错误，请重试', title: '登录失败');
      completer.completeError(e);
    }
  }

  /// 获取设备码
  Future<AuthDeviceResponse> get deviceId async {
    try {
      debugPrint('UserManager: 开始获取设备码...');
      debugPrint('  - Client ID: ${AppConfig.githubClientId}');
      debugPrint('  - 请求 URL: https://github.com/login/device/code');

      final value = await _authApi.device(AppConfig.githubClientId);

      debugPrint('UserManager: 获取设备码响应:');
      debugPrint('  - device_code: ${value.deviceCode}');
      debugPrint('  - user_code: ${value.userCode}');
      debugPrint('  - verification_uri: ${value.verificationUri}');
      debugPrint('  - expires_in: ${value.expiresIn}');
      debugPrint('  - interval: ${value.interval}');

      // 自动复制验证码（静默复制，不显示提示，避免在无 Overlay 时报错）
      if (value.userCode?.isNotEmpty ?? false) {
        try {
          await Clipboard.setData(ClipboardData(text: value.userCode!));
          debugPrint('UserManager: 验证码已自动复制到剪贴板 - ${value.userCode}');
        } catch (e) {
          appLog.error('UserManager: 复制验证码失败 - $e');
        }
      }

      return value;
    } on DioException catch (e) {
      appLog.error('UserManager: ❌ Dio 错误 - 获取设备码失败');
      debugPrint('  - 错误类型: ${e.type}');
      debugPrint('  - 错误消息: ${e.message}');
      debugPrint('  - 响应状态码: ${e.response?.statusCode}');
      debugPrint('  - 响应数据: ${e.response?.data}');
      debugPrint('  - 请求 URL: ${e.requestOptions.uri}');

      String errorMsg = '网络请求失败';
      if (e.type == DioExceptionType.connectionTimeout) {
        errorMsg = '连接超时，请检查网络';
      } else if (e.type == DioExceptionType.receiveTimeout) {
        errorMsg = '接收超时，请稍后重试';
      } else if (e.type == DioExceptionType.badResponse) {
        final statusCode = e.response?.statusCode;
        if (statusCode == 404) {
          errorMsg = 'OAuth App 配置错误，请检查 Client ID';
        } else if (statusCode == 401) {
          errorMsg = 'Client ID 无效或未启用 Device Flow';
        } else if (statusCode == 429) {
          errorMsg = '请求过于频繁，请稍后重试';
        } else {
          errorMsg = '服务器错误 ($statusCode)';
        }
      } else if (e.type == DioExceptionType.connectionError) {
        errorMsg = '无法连接到 GitHub，请检查网络或代理设置';
      }

      AppDialogs.showError(errorMsg, title: '获取验证码失败');
      return AuthDeviceResponse();
    } catch (e) {
      appLog.error('UserManager: ❌ 未知错误 - 获取设备码失败 - $e');
      AppDialogs.showError('发生未知错误: $e', title: '获取验证码失败');
      return AuthDeviceResponse();
    }
  }

  /// 保存 token（同时使用 FlutterSecureStorage 和 SharedPreferences）
  Future<bool> saveToken(String token) async {
    try {
      debugPrint('UserManager: 开始保存 Token...');
      debugPrint('  - Token 长度: ${token.length}');
      debugPrint('  - Token 前缀: ${token.substring(0, 10)}...');

      // 确保 SharedPreferences 已初始化
      await _initPrefs();

      // 保存到 FlutterSecureStorage
      await _secureStorage.write(key: _tokenKey, value: token);

      // 保存到 SharedPreferences（同步操作）
      await _prefs!.setString(_tokenKey, token);

      appLog.info('UserManager: ✅ Token 已保存到 FlutterSecureStorage 和 SharedPreferences');
      return true;
    } catch (e) {
      appLog.error('UserManager: ❌ 保存 token 异常 - $e');
      return false;
    }
  }

  /// 获取 token（优先从 FlutterSecureStorage 读取，失败则从 SharedPreferences 读取）
  Future<String?> getToken() async {
    try {
      // 确保 SharedPreferences 已初始化
      await _initPrefs();

      // 优先从 FlutterSecureStorage 读取
      final secureToken = await _secureStorage.read(key: _tokenKey);

      if (secureToken != null && secureToken.isNotEmpty) {
        debugPrint('UserManager: 从 FlutterSecureStorage 读取 Token 成功 (长度: ${secureToken.length})');
        return secureToken;
      }

      // FlutterSecureStorage 失败，尝试从 SharedPreferences 读取
      final prefsToken = _prefs!.getString(_tokenKey);
      if (prefsToken != null && prefsToken.isNotEmpty) {
        debugPrint('UserManager: ⚠️ FlutterSecureStorage 为空，从 SharedPreferences 读取 Token 成功 (长度: ${prefsToken.length})');
        // 同步回 FlutterSecureStorage
        try {
          await _secureStorage.write(key: _tokenKey, value: prefsToken);
          appLog.info('UserManager: 已同步 Token 到 FlutterSecureStorage');
        } catch (e) {
          appLog.error('UserManager: 同步到 FlutterSecureStorage 失败 - $e');
        }
        return prefsToken;
      }

      debugPrint('UserManager: 从存储读取 Token 为空');
      return null;
    } catch (e) {
      appLog.error('UserManager: 读取 Token 异常 - $e');
      return null;
    }
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
      appLog.error('UserManager: ⚠️ Token 验证失败（API 返回 null），清除 Token');
      await logout();
      return false;
    } catch (e) {
      appLog.error('UserManager: Token 验证失败 - $e');
      appLog.error('UserManager: ⚠️ Token 验证异常，清除 Token');
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
      appLog.info('UserManager: ⚠️⚠️⚠️ 开始退出登录，清除 Token ⚠️⚠️⚠️');
      debugPrint('  - 调用堆栈: ${StackTrace.current}');

      // 清除内存中的用户信息
      userInfo.value = const UserInfo();

      // 确保 SharedPreferences 已初始化
      await _initPrefs();

      // 清除所有存储的数据
      await _secureStorage.delete(key: _userInfoKey);
      await _secureStorage.delete(key: _tokenKey);
      await _prefs!.remove(_userInfoKey);
      await _prefs!.remove(_tokenKey);

      appLog.info('UserManager: 已清除 FlutterSecureStorage 和 SharedPreferences 中的数据');

      // 清除 Dio 的授权头
      DioClient.instance.authorization = null;

      // 取消任何进行中的登录
      cancelLogin();

      appLog.info('UserManager: ✅ 已退出登录，Token 已清除');
    } catch (e) {
      appLog.error('UserManager: 退出登录失败 - $e');
    }
  }
}
