import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probe 在 Rust/平台不可用时安全降级（不抛异常）', () async {
    final status = await RustModuleLoader.instance.probe('qr');
    expect(status.name, 'qr');
    expect(status.loaded, isFalse, reason: '测试环境 Rust 未初始化 → 视为未加载');
    // 测试环境无本地产物；来源为 none（未配置远端时不可能是 remote）
    expect(status.source, anyOf('none', 'remote'));
    expect(status.exists, status.source != 'none');
  });

  test('RustModuleStatus.sourceLabel 中文映射', () {
    expect(
      const RustModuleStatus(name: 'a', exists: true, source: 'builtin')
          .sourceLabel,
      '内置',
    );
    expect(
      const RustModuleStatus(name: 'a', exists: true, source: 'downloaded')
          .sourceLabel,
      '已下载',
    );
    expect(
      const RustModuleStatus(name: 'a', exists: true, source: 'remote')
          .sourceLabel,
      '可远程',
    );
    expect(
      const RustModuleStatus(name: 'a', exists: false, source: 'none')
          .sourceLabel,
      '缺失',
    );
  });
}
