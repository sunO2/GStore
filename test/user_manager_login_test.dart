import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// login 调用次数（P4 断言不再调用）
  int loginCallCount = 0;

  @override
  Future<AuthLoginResponse> login(
    String clientId,
    String deviceCode, {
    String gratType = 'urn:ietf:params:oauth:grant-type:device_code',
  }) async {
    loginCallCount++;
    if (throwOnLogin != null) throw throwOnLogin!;
    if (responses.isNotEmpty) return responses.removeAt(0);
    return AuthLoginResponse(null, 5); // pending：继续轮询
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAuthApi authApi;
  late _FakeRestClient restClient;
  late UserManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // 凭据安全存储走 mock 平台（可变 map——write 需写入；const {} 会抛
    // "Cannot modify unmodifiable map"）
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});

    authApi = _FakeAuthApi();
    restClient = _FakeRestClient();

    // 注入依赖：UserManager.initialize() 经 ModuleManager 取 authApi / restClient
    ModuleManager.instance.bind<GithubAuthApi>(authApi);
    ModuleManager.instance.bind<GithubRestClient>(restClient);
    manager = UserManager.instance;
    // 单例跨测试重置：强制重新绑定本轮 fake（否则残留上一用例的 _authApi）
    manager.resetForTest();
    await manager.initialize();
  });

  tearDown(() async {
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
}