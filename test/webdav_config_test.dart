import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';

void main() {
  group('WebDavConfig', () {
    test('默认 backupPath 为 /GStore', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
      );
      expect(config.backupPath, '/GStore');
      expect(config.enableHttps, true);
    });

    test('isValid：完整配置有效', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
      );
      expect(config.isValid, true);
    });

    test('isValid：缺密码无效', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: '',
      );
      expect(config.isValid, false);
    });

    test('isValid：缺用户名无效', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: '',
        password: 'pass',
      );
      expect(config.isValid, false);
    });

    test('baseUrl：无协议时默认 https', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        enableHttps: true,
      );
      expect(config.baseUrl, 'https://dav.example.com');
    });

    test('baseUrl：enableHttps=false 时用 http', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        enableHttps: false,
      );
      expect(config.baseUrl, 'http://dav.example.com');
    });

    test('baseUrl：已带协议不重复添加', () {
      final config = WebDavConfig(
        url: 'https://dav.example.com/dav',
        username: 'user',
        password: 'pass',
      );
      expect(config.baseUrl, 'https://dav.example.com/dav');
    });

    test('baseUrl：带协议时移除末尾斜杠', () {
      final config = WebDavConfig(
        url: 'https://dav.example.com/',
        username: 'user',
        password: 'pass',
      );
      expect(config.baseUrl, 'https://dav.example.com');
    });

    test('baseUrl：无协议时保留路径原样拼接', () {
      final config = WebDavConfig(
        url: 'dav.example.com/',
        username: 'user',
        password: 'pass',
      );
      expect(config.baseUrl, 'https://dav.example.com/');
    });

    test('fromJson / toJson 往返', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        backupPath: '/MyBackup',
        enableHttps: false,
      );
      final json = config.toJson();
      expect(json['url'], 'dav.example.com');
      expect(json['username'], 'user');
      expect(json['password'], 'pass');
      expect(json['backupPath'], '/MyBackup');
      expect(json['enableHttps'], false);

      final restored = WebDavConfig.fromJson(json);
      expect(restored.url, config.url);
      expect(restored.username, config.username);
      expect(restored.password, config.password);
      expect(restored.backupPath, config.backupPath);
      expect(restored.enableHttps, config.enableHttps);
    });

    test('fromJson：缺省字段使用默认值', () {
      final config = WebDavConfig.fromJson({
        'url': 'dav.example.com',
        'username': 'user',
        'password': 'pass',
      });
      expect(config.backupPath, '/GStore');
      expect(config.enableHttps, true);
    });

    test('copyWith：只改部分字段', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        backupPath: '/A',
        enableHttps: true,
      );
      final updated = config.copyWith(backupPath: '/B');
      expect(updated.url, 'dav.example.com');
      expect(updated.username, 'user');
      expect(updated.password, 'pass');
      expect(updated.backupPath, '/B');
      expect(updated.enableHttps, true);
    });

    test('toString 不含密码', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'secret',
      );
      expect(config.toString(), isNot(contains('secret')));
      expect(config.toString(), contains('dav.example.com'));
    });
  });

  group('WebDavFile.formattedSize', () {
    test('B 单位', () {
      expect(WebDavFile(name: 'a', path: '/a', size: 512, modified: DateTime.now(), isDirectory: false).formattedSize, '512 B');
    });

    test('KB 单位', () {
      expect(WebDavFile(name: 'a', path: '/a', size: 2048, modified: DateTime.now(), isDirectory: false).formattedSize, '2.0 KB');
    });

    test('MB 单位', () {
      expect(WebDavFile(name: 'a', path: '/a', size: 5 * 1024 * 1024, modified: DateTime.now(), isDirectory: false).formattedSize, '5.0 MB');
    });

    test('边界：1024 显示 1.0 KB', () {
      expect(WebDavFile(name: 'a', path: '/a', size: 1024, modified: DateTime.now(), isDirectory: false).formattedSize, '1.0 KB');
    });
  });
}
