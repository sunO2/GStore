
import 'package:dio/dio.dart' as dio;
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_api_seam.dart';

/// 登录流程修复单测（P2/P3/P4）
///
/// 覆盖：
/// - P2：token 拉取成功但 user() 返回 null → 不持久化 token（半登录态残留）
/// - P2(成功)：token + user 均就绪 → 持久化 token
/// - P3：401/403 认证失败 → future completeError，不留 token
/// - P4：expiresIn 到期 → 不再调用 login API，future 以错误终止
///
/// 采用手写 Fake（与项目既有测试风格一致，避免 mockito any 泛型推断问题）。

/// 可控 Fake 认证 API：按脚本返回 AuthLoginResponse 或抛异常
class _FakeAuthApi implements GithubAuthApi {
  /// 每次 login 调用的结果队列；为空 → 返回 pending（null accessToken）
  final List<AuthLoginResponse> responses = [];

  /// 每次 login 调用抛出的异常（非空时优先抛）
  Object? throwOnLogin;

  /// 仅下一次 login 调用抛出的异常（用于「第一次失败、重试成功」场景）
  Object? throwOnLoginOnce;

  /// login 调用次数（P4 断言不再调用）
  int loginCallCount = 0;

  /// 返回 pending（无 accessToken）时携带的 interval（秒）。
  int pendingInterval = 5;

  /// 非空时 [login] 会先等待它（用于模拟慢请求 / 请求在途）。
  Future<void>? loginGate;

  @override
  Future<AuthLoginResponse> login(
    String clientId,
    String deviceCode, {
    String gratType = 'urn:ietf:params:oauth:grant-type:device_code',
  }) async {
    loginCallCount++;
    final gate = loginGate;
    if (gate != null) await gate;
    if (throwOnLogin != null) throw throwOnLogin!;
    if (throwOnLoginOnce != null) {
      final error = throwOnLoginOnce!;
      throwOnLoginOnce = null;
      throw error;
    }
    if (responses.isNotEmpty) return responses.removeAt(0);
    return AuthLoginResponse(null, pendingInterval); // pending：继续轮询
  }

  @override
  Future<AuthDeviceResponse> device(
    String clientId, {
    String scope = 'repo',
  }) async =>
      AuthDeviceResponse();
}

/// 可控 Fake GitHub 客户端：user() 返回预设值
class _FakeRestClient implements GithubRestClient {
  UserInfo? userToReturn;
  Object? throwOnUser;
  int userCallCount = 0;

  @override
  Future<UserInfo?> user() async {
    userCallCount++;
    if (throwOnUser != null) throw throwOnUser!;
    return userToReturn;
  }

  // 其余方法未在登录流程使用，标注 UnimplementedError 防止误用
  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '登录测试未使用: ${invocation.memberName}');
}

class _TokenSyncBackend extends FakeChannelApiBackend
    implements GithubTokenSyncBackend {
  _TokenSyncBackend() : super(FakeLibraryApi());

  String? token;
  int calls = 0;

  @override
  Future<void> setGithubToken({String? token}) async {
    this.token = token;
    calls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAuthApi authApi;
  late _FakeRestClient restClient;
  late UserManager manager;
  late _TokenSyncBackend tokenSync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // 凭据安全存储走 mock 平台（可变 map——write 需写入；const {} 会抛
    // "Cannot modify unmodifiable map"）
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});

    authApi = _FakeAuthApi();
    restClient = _FakeRestClient();
    tokenSync = _TokenSyncBackend();
    RustChannelFacade.installBackend(tokenSync);

    // 注入依赖：UserManager.initialize() 经 ModuleManager 取 authApi / restClient
    ModuleManager.instance.bind<GithubAuthApi>(authApi);
    ModuleManager.instance.bind<GithubRestClient>(restClient);
    manager = UserManager.instance;
    // 单例跨测试重置：强制重新绑定本轮 fake（否则残留上一用例的 _authApi）
    manager.resetForTest();
    await manager.initialize();
  });

  tearDown(() async {
    RustChannelFacade.resetBackend();
    DioClient.instance.authorization = null;
    await ModuleManager.instance.clear();
  });

  group('P2: user() 失败不残留 token', () {
    test('accessToken 就绪但 user() 返回 null → 不保存 token', () async {
      authApi.responses.add(AuthLoginResponse(null, 5, accessToken: 'longenough-token-12345'));
      restClient.userToReturn = null;

      final future = manager.startLoginOfTimer('device-code', 1, dio.CancelToken());
      final userInfo = await future.timeout(const Duration(seconds: 3));

      expect(userInfo, isNull, reason: 'user() 为 null → 登录视为失败');
      expect(await manager.getToken(), isNull,
          reason: 'P2: user() 失败后不应持久化 token（避免下次启动误判已登录）');

    });

    test('accessToken 就绪且 user() 成功 → 保存 token', () async {
      authApi.responses.add(AuthLoginResponse(null, 5, accessToken: 'longenough-token-12345'));
      restClient.userToReturn = const UserInfo(login: 'test-user', avatarUrl: 'a.png');

      final future = manager.startLoginOfTimer('device-code', 1, dio.CancelToken());
      final userInfo = await future.timeout(const Duration(seconds: 3));

      expect(userInfo?.login, 'test-user');
      expect(await manager.getToken(), 'longenough-token-12345');
      expect(tokenSync.token, 'longenough-token-12345',
          reason: '登录成功后必须把 token 同步给 Rust 渠道');
      expect(tokenSync.calls, 1);
    });

    test('logout 清空 Rust 侧 token', () async {
      authApi.responses.add(AuthLoginResponse(null, 5, accessToken: 'longenough-token-12345'));
      restClient.userToReturn = const UserInfo(login: 'test-user', avatarUrl: 'a.png');
      await manager
          .startLoginOfTimer('device-code', 1, dio.CancelToken())
          .timeout(const Duration(seconds: 3));

      await manager.logout();

      expect(tokenSync.token, isNull);
      expect(tokenSync.calls, 2);
    });
  });

  group('P3: 401/403 认证失败', () {
    test('login 抛认证异常 → future completeError，不留 token', () async {
      authApi.throwOnLogin = dio.DioException(
        requestOptions: dio.RequestOptions(path: '/oauth/access_token'),
        response: dio.Response(
          requestOptions: dio.RequestOptions(path: '/oauth/access_token'),
          statusCode: 401,
        ),
        type: dio.DioExceptionType.badResponse,
      );

      final future = manager.startLoginOfTimer('code', 1, dio.CancelToken());
      await expectLater(future, throwsA(isA<dio.DioException>()));
      expect(await manager.getToken(), isNull, reason: '401 不应残留 token');
    });
  });

  group('P4: expiresIn 到期终止轮询', () {
    test('expiresIn 已过 → 不再调用 login API，future 以错误终止', () async {
      final future = manager.startLoginOfTimer(
        'code',
        1,
        dio.CancelToken(),
        expiresIn: 0, // 立即过期：首轮触发前 deadline 已过
      );

      await expectLater(future, throwsA(isA<dio.DioException>()));
      expect(authApi.loginCallCount, 0,
          reason: 'P4: 到期后不应再发起 access_token 请求');
      expect(await manager.getToken(), isNull);
    });
  });

  group('回前台恢复轮询（超过间隔立即补发）', () {
    test('resumePolling：距上次轮询已超过间隔 → 立即发起请求', () async {
      authApi.pendingInterval = 1;
      final token = dio.CancelToken();
      manager.startLoginOfTimer('device-code', 1, token);

      // 等首次轮询执行，随后取消定时器模拟后台挂起
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final callsBeforePause = authApi.loginCallCount;
      expect(callsBeforePause, greaterThanOrEqualTo(1));
      manager.cancelLogin();
      expect(manager.isPolling, isFalse);

      // 模拟后台停留时间超过一个轮询间隔
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(manager.isPollOverdue, isTrue);

      manager.resumePolling(token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(authApi.loginCallCount, callsBeforePause + 1,
          reason: '回到前台超过轮询间隔应立即补发一次请求，而不是再等一个间隔');
      manager.cancelLogin();
    });

    test('resumePolling：未超过间隔 → 仍按剩余间隔等待', () async {
      authApi.pendingInterval = 1;
      final token = dio.CancelToken();
      manager.startLoginOfTimer('device-code', 1, token);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      manager.cancelLogin();
      final callsBeforeResume = authApi.loginCallCount;

      manager.resumePolling(token);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(authApi.loginCallCount, callsBeforeResume,
          reason: '未超过轮询间隔时应等待剩余时长，而不是立即重复请求');
      manager.cancelLogin();
    });

    test('pollNow：轮询定时器等待中可立即补发一次请求', () async {
      final token = dio.CancelToken();
      manager.startLoginOfTimer('device-code', 1, token);

      // 首次轮询完成，进入下一个等待窗口
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final callsBefore = authApi.loginCallCount;
      expect(callsBefore, 1);
      expect(manager.isPolling, isTrue);

      expect(manager.pollNow(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(authApi.loginCallCount, callsBefore + 1,
          reason: 'pollNow 应立即复用当前轮询链补发一次请求');
      manager.cancelLogin();
    });

    test('请求在途时回前台：不新建链，返回 pending 后立即补发', () async {
      authApi.pendingInterval = 1;
      final gate = Completer<void>();
      authApi.loginGate = gate.future;
      final token = dio.CancelToken();
      manager.startLoginOfTimer('device-code', 1, token);

      // 首次请求已在途（慢请求）
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(authApi.loginCallCount, 1);
      expect(manager.isPolling, isFalse, reason: '请求在途时定时器是停的');
      expect(manager.hasPendingPollRequest, isTrue);

      // 回前台：应只登记「返回后立即补发」，不能再发请求
      expect(manager.resumeAfterPendingRequest(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(authApi.loginCallCount, 1,
          reason: '在途期间不得另起一条链/并发请求');

      // 放行在途请求（此时已过了一整个间隔）：pending → 立即补发
      authApi.loginGate = null;
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(authApi.loginCallCount, 2,
          reason: '在途请求返回 pending 且已超过间隔 → 应立即补发一次');
      expect(manager.isPolling, isTrue);
      manager.cancelLogin();
    });

    test('在途请求很快返回 pending：仍遵守最小轮询间隔', () async {
      authApi.pendingInterval = 1;
      final gate = Completer<void>();
      authApi.loginGate = gate.future;
      manager.startLoginOfTimer('device-code', 1, dio.CancelToken());

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(authApi.loginCallCount, 1);
      expect(manager.resumeAfterPendingRequest(), isTrue);

      // 在途请求很快返回 pending（请求耗时 < 间隔）→ 只等剩余时长
      authApi.loginGate = null;
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(authApi.loginCallCount, 1,
          reason: '请求耗时不足一个间隔时，不应立刻再发（避免触发 GitHub 限频）');

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(authApi.loginCallCount, 2, reason: '剩余间隔到点后应继续轮询');
      manager.cancelLogin();
    });

    test('在途请求网络失败：回前台后立即重试一次，而不是结束轮询', () async {
      authApi.pendingInterval = 1;
      final gate = Completer<void>();
      authApi.loginGate = gate.future;
      manager.startLoginOfTimer('device-code', 1, dio.CancelToken());

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(authApi.loginCallCount, 1);
      expect(manager.resumeAfterPendingRequest(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      // 放行在途请求，但让它以网络错误失败
      authApi.loginGate = null;
      authApi.throwOnLoginOnce = dio.DioException(
        requestOptions: dio.RequestOptions(path: '/oauth/access_token'),
        type: dio.DioExceptionType.connectionError,
      );
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(authApi.loginCallCount, 2,
          reason: '后台请求网络失败、且已回到前台 → 立即重试一次，不直接终止轮询');
      expect(manager.isPolling, isTrue, reason: '重试请求 pending 后应继续轮询');
      manager.cancelLogin();
    });
  });
}