
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/core/service/login_notification_service.dart';

/// 用户管理服务
///
/// 负责用户登录、token 管理、用户信息存储等功能
class UserManager {
  static UserManager? _instance;

  static UserManager get instance {
    _instance ??= UserManager._internal();
    return _instance!;
  }

  late GithubAuthApi _authApi;
  late GithubRestClient _githubApi;
  final _secureStorage = const FlutterSecureStorage();
  UserInfo _userInfo = const UserInfo();
  final _userInfoController = StreamController<UserInfo>.broadcast();

  /// 当前用户信息（只读）
  UserInfo get userInfo => _userInfo;

  /// 用户信息变更流（登录/登出/启动恢复写入时推送）
  Stream<UserInfo> get userInfoStream => _userInfoController.stream;

  /// 仅测试使用：直接注入用户信息（等价原 test 写 `userInfo.value = ...`）
  @visibleForTesting
  void setUserInfoForTest(UserInfo user) => _setUserInfo(user);

  void _setUserInfo(UserInfo user) {
    _userInfo = user;
    _userInfoController.add(user);
  }

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
  UserManager._internal();

  /// 初始化（必须在使用前调用；依赖经 ModuleManager 解析——DbModule 先于 UserModule 初始化）
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('UserManager: 已经初始化过，跳过');
      return;
    }

    appLog.info('UserManager: 开始公共初始化');
    // 初始化依赖（ModuleManager lazyPut 首次解析即创建）
    _authApi = ModuleManager.instance.require<GithubAuthApi>();
    _githubApi = ModuleManager.instance.require<GithubRestClient>();

    // 调用内部初始化
    await _initialize();
  }

  /// 测试用：重置登录状态与依赖绑定（UserManager 是全局单例，跨测试需
  /// 重新注入 fake 后才能再次 initialize——否则残留上一用例的 _authApi/_githubApi；
  /// 同时清空 _prefs 缓存，避免读取到上一用例写入的存储残留）
  @visibleForTesting
  void resetForTest() {
    cancelLogin();
    _isInitialized = false;
    _setUserInfo(const UserInfo());
    _prefs = null;
    _resetLoginPollState();
    _secureStorage.deleteAll();
  }

  /// 清空登录轮询链状态（测试重置 / 链结束）。
  void _resetLoginPollState() {
    _loginDeviceCode = null;
    _loginInterval = 5;
    _loginExpiresIn = null;
    _loginCompleter = null;
    _loginCancelToken = null;
    _loginDeadline = null;
    _lastPollActivityAt = null;
    _inFlightCompleter = null;
    _pollNowAfterResponse = false;
    _pollAttempt = 0;
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
      await _syncGithubTokenToRust(token);

      // 尝试读取用户信息
      final userInfoJson = await _secureStorage.read(key: _userInfoKey);
      if (userInfoJson != null && userInfoJson.isNotEmpty) {
        try {
          _setUserInfo(UserInfo.fromJsonString(userInfoJson));
          appLog.info('UserManager: 已加载用户信息 - ${userInfo.login}');
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
        _setUserInfo(user);
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
    _pollNowAfterResponse = false;
  }

  /// 轮询尝试次数（每次 startLoginOfTimer 重置；登录说明页用于展示进度日志）。
  int _pollAttempt = 0;

  /// 当前登录轮询参数（用于后台回到前台时恢复轮询）。
  String? _loginDeviceCode;
  int _loginInterval = 5;
  int? _loginExpiresIn;

  /// 当前轮询链的完成器 / 取消令牌 / 截止时间。
  ///
  /// 回前台时若轮询定时器仍在等待但已超期，可直接复用该链（同一 completer、
  /// 同一取消令牌）立即补发一次请求，结果仍由原来的 future 返回。
  Completer<UserInfo?>? _loginCompleter;
  CancelToken? _loginCancelToken;
  DateTime? _loginDeadline;

  /// 上次轮询活动时间（发起请求或启动轮询链）。
  ///
  /// 用于后台回到前台时判断：距上次轮询是否已超过一个轮询间隔——超过则立即
  /// 补发一次请求，而不是再空等一个间隔。
  DateTime? _lastPollActivityAt;

  /// 正在途中的请求所属轮询链（用于回前台时判断「是否有请求在飞」）。
  Completer<UserInfo?>? _inFlightCompleter;

  /// 回前台时若已有请求在途，登记「该请求返回后立即补发一次」。
  bool _pollNowAfterResponse = false;

  /// 轮询是否进行中（登录说明页用于判断是否需要恢复轮询）。
  bool get isPolling => _loginRequestTimer?.isActive ?? false;

  /// 是否有登录轮询请求正在途中。
  ///
  /// 请求在途期间定时器是停着的（触发请求时先取消定时器），所以不能用
  /// [isPolling] 判断。回前台时若只看定时器，会把「请求在途」误判为
  /// 「轮询已停」而另起一条链，导致同一设备码被并发轮询、先到的成功结果
  /// 又被当成过期结果丢弃（表现为「请求成功了却要再轮询一次才显示登录」）。
  bool get hasPendingPollRequest {
    final completer = _inFlightCompleter;
    return completer != null && !completer.isCompleted;
  }

  /// 回前台时若已有请求在途：沿用当前轮询链，登记它返回后立即补发一次
  /// （不新建链，避免两条链并发）。返回是否登记成功。
  bool resumeAfterPendingRequest() {
    if (!hasPendingPollRequest) return false;
    _pollNowAfterResponse = true;
    return true;
  }

  /// 是否已持有可恢复轮询的设备码（登录页回前台自动重试时判断）。
  bool get canResumePolling => _loginDeviceCode != null;

  /// 距上次轮询活动是否已超过一个轮询间隔。
  ///
  /// 后台（如跳到系统浏览器登录 GitHub）期间定时器可能被挂起或网络请求失败，
  /// 回到前台时用该值判断是否需要立即补发一次请求。
  bool get isPollOverdue => _remainingPollDelay == Duration.zero;

  /// 距离下一次轮询应等待的时长（已超过间隔则为 [Duration.zero]）。
  Duration get _remainingPollDelay {
    final last = _lastPollActivityAt;
    final interval = Duration(seconds: _loginInterval);
    if (last == null) return interval;
    final elapsed = DateTime.now().difference(last);
    return elapsed >= interval ? Duration.zero : interval - elapsed;
  }

  /// 后台回到前台时恢复轮询（无设备码或已轮询时不动作）。
  ///
  /// 返回本次轮询的结果（与 [startLoginOfTimer] 一致），供调用方统一处理
  /// 成功/失败；无法恢复时返回 null。
  ///
  /// [immediate] 为 true 时立即发起首次请求；否则按「距上次轮询还剩多久」等待
  /// ——若已超过一个轮询间隔，剩余为 0，同样立即发起。
  ///
  /// 注意：调用前应先确认没有请求在途（[resumeAfterPendingRequest]），否则会
  /// 与在途请求并发成两条链。
  Future<UserInfo?> resumePolling(
    CancelToken cancelToken, {
    bool immediate = false,
  }) async {
    if (isPolling) return null;
    final deviceCode = _loginDeviceCode;
    if (deviceCode == null) return null;
    return startLoginOfTimer(
      deviceCode,
      _loginInterval,
      cancelToken,
      expiresIn: _loginExpiresIn,
      initialDelay: immediate ? Duration.zero : _remainingPollDelay,
    );
  }

  /// 立即补发一次轮询请求（复用当前轮询链，结果仍由原 future 返回）。
  ///
  /// 仅在轮询定时器仍在等待（[isPolling]）时有效：取消当前定时器并立刻执行
  /// 一次 [_login]。返回是否已发起；定时器已停止时返回 false——此时应改用
  /// [resumePolling] 重新拉起轮询链。
  bool pollNow() {
    if (!isPolling) return false;
    final deviceCode = _loginDeviceCode;
    final completer = _loginCompleter;
    final cancelToken = _loginCancelToken;
    if (deviceCode == null ||
        completer == null ||
        completer.isCompleted ||
        cancelToken == null ||
        cancelToken.isCancelled) {
      return false;
    }
    _loginRequestTimer?.cancel();
    _runLogin(deviceCode, completer, cancelToken, _loginDeadline);
    return true;
  }

  /// 发起一次请求并标记「在途」，请求结束后清除在途标记。
  ///
  /// 在途标记按「链」区分：只清除自己那条链的标记，被新链取代的旧链不会污染
  /// 新链的在途状态。
  void _runLogin(
    String deviceCode,
    Completer<UserInfo?> completer,
    CancelToken cancelToken,
    DateTime? deadline,
  ) {
    _inFlightCompleter = completer;
    unawaited(
      _login(deviceCode, completer, cancelToken, deadline).whenComplete(() {
        if (identical(_inFlightCompleter, completer)) {
          _inFlightCompleter = null;
        }
      }),
    );
  }

  /// 轮询日志流——登录说明页用于展示每次轮询的进度。
  final StreamController<String> _pollLogController =
      StreamController<String>.broadcast();

  /// 轮询日志流（用户可在登录说明页查看轮询进度）。
  Stream<String> get pollLogStream => _pollLogController.stream;

  /// 向轮询日志流追加一条消息（后台无监听时静默丢弃，不影响轮询）。
  void _emitPollLog(String message) {
    try {
      _pollLogController.add(message);
    } catch (_) {}
  }

  /// 开始登录轮询
  /// [expiresIn] 设备码有效期（秒，GitHub device/code 返回）；到期后终止轮询，
  /// 避免无效轮询空转（否则需等 GitHub 返回 expired_token 才停止）。
  /// [initialDelay] 首次请求前的等待时长（默认一个 [interval]；回到前台恢复
  /// 轮询时可传 [Duration.zero] 立即补发）。
  Future<UserInfo?> startLoginOfTimer(
    String deviceCode,
    int interval,
    CancelToken cancelToken, {
    int? expiresIn,
    Duration? initialDelay,
  }) {
    // 记录登录轮询参数，用于后台回到前台时恢复轮询（如从 GitHub 浏览器返回）。
    _loginDeviceCode = deviceCode;
    _loginInterval = interval;
    _loginExpiresIn = expiresIn;
    _pollAttempt = 0;
    _lastPollActivityAt = DateTime.now();
    _pollNowAfterResponse = false;
    // 新链开始：旧的（可能仍被放弃的）在途标记不再代表当前链。
    _inFlightCompleter = null;
    final completer = Completer<UserInfo?>();
    _loginCompleter = completer;
    _loginCancelToken = cancelToken;
    final deadline = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null;
    _loginDeadline = deadline;
    _nextTimer(deviceCode, interval, completer, cancelToken, deadline,
        initialDelay: initialDelay);
    return completer.future;
  }

  /// 安排下一次轮询
  void _nextTimer(
    String deviceCode,
    int interval,
    Completer<UserInfo?> completer,
    CancelToken cancelToken,
    DateTime? deadline, {
    Duration? initialDelay,
  }) {
    // 链归属校验：已被新链取代的旧链不得再调度，否则会取消/覆盖当前链的定时器。
    if (!identical(completer, _loginCompleter)) return;
    if (_loginRequestTimer?.isActive ?? false) {
      _loginRequestTimer?.cancel();
    }
    _loginInterval = interval;
    _lastPollActivityAt = DateTime.now();
    // 单次定时器：到点后执行一次请求，再由 [_login] 按返回的 interval 安排下一次。
    // 不做周期定时任务，避免「上一次请求还没回来就按固定节拍再发」。
    _loginRequestTimer = Timer(initialDelay ?? Duration(seconds: interval), () {
      if (_loginRequestTimer?.isActive ?? false) {
        _loginRequestTimer?.cancel();
      }
      _runLogin(deviceCode, completer, cancelToken, deadline);
    });
  }

  /// 执行登录请求
  Future<void> _login(
    String deviceCode,
    Completer<UserInfo?> completer,
    CancelToken cancelToken,
    DateTime? deadline,
  ) async {
    // 旧链已被新链取代（手动重新认证等）：不再发请求，直接结束这条链。
    if (!identical(completer, _loginCompleter)) {
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    // 设备码已过期：终止轮询，提示重新获取（不再发起无效的 access_token 请求）
    if (deadline != null && !DateTime.now().isBefore(deadline)) {
      _loginRequestTimer?.cancel();
      appLog.error('UserManager: 设备码已过期，终止轮询');
      _emitPollLog('设备码已过期，停止轮询');
      completer.completeError(
        DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: '设备码已过期',
        ),
      );
      return;
    }

    try {
      // 检查是否已取消
      if (cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: '登录请求已取消',
        );
      }

      _pollAttempt++;
      _lastPollActivityAt = DateTime.now();
      _emitPollLog('第 $_pollAttempt 次轮询：请求 access_token…');

      // 调用 GitHub OAuth API
      final auth = await _authApi.login(
        AppConfig.githubClientId,
        deviceCode,
      );

      // 检查 access_token
      if (auth.accessToken?.isEmpty ?? true) {
        // token 还没准备好，继续轮询
        _emitPollLog('未获取到 access_token，继续轮询…');
        if (cancelToken.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: '登录请求已取消',
          );
        }
        // 回前台时登记过「在途请求返回后立即补发」：这次 pending 已经等过了，
        // 不必再等满一个 interval；但仍遵守 GitHub 的最小轮询间隔（用请求耗时
        // 抵扣，若这次请求本身在后台耗掉了整个间隔则剩余为 0，立即发下一次）。
        final immediate = _pollNowAfterResponse;
        _pollNowAfterResponse = false;
        _nextTimer(
          deviceCode,
          auth.interval ?? _loginInterval,
          completer,
          cancelToken,
          deadline,
          initialDelay: immediate ? _remainingPollDelay : null,
        );
        return;
      }

      // 登录成功，保存 token 和用户信息
      if (auth.accessToken?.isNotEmpty ?? false) {
        // 先设置全局授权头（内存态，供 user() 校验携带 token）
        DioClient.instance.authorization = auth.accessToken;
        _emitPollLog('获取到 access_token，请求用户信息…');

        // 先验证用户信息：拉取成功才持久化 token（避免"token 已落库但用户拉取失败"
        // 的半登录态——下次启动会误判已登录）；失败则清除内存授权头，不残留。
        final user = await _githubApi.user();
        if (user != null) {
          _emitPollLog('登录成功：${user.login}');
          LoginNotificationService.instance.cancel();
          await saveToken(auth.accessToken!);
          _setUserInfo(user);
          await _secureStorage.write(key: _userInfoKey, value: user.toJson());
          await _syncGithubTokenToRust(auth.accessToken);
          completer.complete(user);
        } else {
          _emitPollLog('用户信息为空，登录失败');
          LoginNotificationService.instance.cancel();
          DioClient.instance.authorization = null;
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
        _emitPollLog('认证失败（请重新获取验证码）');
        // 401/403：设备码过期/无效/授权被拒（不再弹 snackbar——失败态由页面「再次轮试」按钮兜底）
        completer.completeError(e);
      } else if (_pollNowAfterResponse) {
        // 回前台时登记过「在途请求返回后立即补发」：后台发出的这次请求网络失败，
        // 现在已回到前台，立刻重试一次（只重试一次，避免前台断网时无限重试）。
        _pollNowAfterResponse = false;
        appLog.error('UserManager: 登录请求失败（回前台重试一次）- $e');
        _emitPollLog('网络错误，立即重试一次…');
        _nextTimer(
          deviceCode,
          _loginInterval,
          completer,
          cancelToken,
          deadline,
          initialDelay: _remainingPollDelay,
        );
      } else {
        appLog.error('UserManager: 登录请求失败 - $e');
        _emitPollLog('网络错误，轮询停止');
        completer.completeError(e);
      }
    } catch (e) {
      // 其他错误处理
      appLog.error('UserManager: 登录异常 - $e');
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

  Future<void> _syncGithubTokenToRust(String? token) async {
    try {
      await RustChannelFacade.instance.setGithubToken(token: token);
    } catch (e) {
      appLog.error('UserManager: 同步 GitHub Token 到 Rust 失败 - $e');
    }
  }

  /// 保存 token（同时使用 FlutterSecureStorage 和 SharedPreferences）
  Future<bool> saveToken(String token) async {
    try {
      debugPrint('UserManager: 开始保存 Token...');
      debugPrint('  - Token 长度: ${token.length}');
      // 仅打印前缀前 10 字符（token 短于 10 时原样打印，避免 substring 越界
      // 被 catch 吞掉导致 token 保存静默失败）
      debugPrint('  - Token 前缀: ${token.substring(0, token.length < 10 ? token.length : 10)}...');

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
        _setUserInfo(user);
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
    return userInfo.avatarUrl?.isNotEmpty ?? false;
  }

  /// 退出登录
  Future<void> logout() async {
    try {
      appLog.info('UserManager: ⚠️⚠️⚠️ 开始退出登录，清除 Token ⚠️⚠️⚠️');
      debugPrint('  - 调用堆栈: ${StackTrace.current}');

      // 清除内存中的用户信息
      _setUserInfo(const UserInfo());

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
      await _syncGithubTokenToRust(null);

      // 取消任何进行中的登录
      cancelLogin();

      appLog.info('UserManager: ✅ 已退出登录，Token 已清除');
    } catch (e) {
      appLog.error('UserManager: 退出登录失败 - $e');
    }
  }
}
