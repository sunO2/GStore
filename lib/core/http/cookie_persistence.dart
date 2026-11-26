import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cookie_sync.dart';

/// 统一 Cookie jar 的安全持久化实现。
///
/// Cookie 经常等价于登录凭证，因此整份 JSON 存入
/// `flutter_secure_storage`（Android 使用 EncryptedSharedPreferences），
/// 普通配置/文件不落明文。
class SecureCookiePersistence implements CookiePersistencePort {
  const SecureCookiePersistence({this.key = defaultKey});

  /// 安全存储键（与其它模块命名空间隔离）。
  static const String defaultKey = 'agent_cookie_jar_v1';

  final String key;

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: key);
    } catch (error) {
      debugPrint('SecureCookiePersistence: 读取失败 - $error');
      return null;
    }
  }

  @override
  Future<void> write(String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (error) {
      // 持久化失败不能影响本次请求；下次变更会重试。
      debugPrint('SecureCookiePersistence: 写入失败 - $error');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: key);
    } catch (error) {
      debugPrint('SecureCookiePersistence: 清除失败 - $error');
    }
  }
}
