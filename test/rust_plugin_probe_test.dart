import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probe 在 Rust/平台不可用时安全降级（不抛异常）', () async {
    final status = await RustModuleLoader.instance.probe('qr');
    expect(status.name, 'qr');
    expect(status.loaded, isFalse, reason: '测试环境 Rust 未初始化 → 视为未加载');
    // 内置清单（assets/app/modules_builtin.json）声明 qr → 视为 builtin；
    // 测试环境资源不可读时退化为 none/remote。均不得抛异常。
    expect(status.source, anyOf('none', 'remote', 'builtin'));
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
