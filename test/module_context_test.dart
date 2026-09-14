import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleContext.dart';

void main() {
  group('ModuleContext：宿主 → 模块 create 的标准上下文', () {
    test('toJson 使用与 Rust 侧一致的键名', () {
      const ctx = ModuleContext(
        dataDir: '/data/x',
        cacheDir: '/cache/x',
        dbPath: '/data/x/repo.db',
        abi: 'arm64-v8a',
      );
      expect(ctx.toJson(), {
        'data_dir': '/data/x',
        'cache_dir': '/cache/x',
        'db_path': '/data/x/repo.db',
        'abi': 'arm64-v8a',
      });
    });

    test('空字段不序列化（保持紧凑，且不覆盖模块侧默认值）', () {
      const ctx = ModuleContext(abi: 'x86_64');
      expect(ctx.toJson(), {'abi': 'x86_64'});
    });

    test('encode 产出的字节可被 json 解析且含 extras', () {
      const ctx = ModuleContext(
        dataDir: '/d',
        extras: {'feature': 'on'},
      );
      final decoded = jsonDecode(utf8.decode(ctx.encode())) as Map<String, dynamic>;
      expect(decoded['data_dir'], '/d');
      expect(decoded['extras'], {'feature': 'on'});
      // 未设置的字段不应出现（模块侧解析后保持默认）
      expect(decoded.containsKey('db_path'), isFalse);
    });

    test('全空上下文编码为 {}', () {
      expect(utf8.decode(const ModuleContext().encode()), '{}');
    });
  });
}
