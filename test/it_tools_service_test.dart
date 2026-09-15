import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gstore/core/service/it_tools_service.dart';

/// ItToolsService 的解压与清理测试。
///
/// [ItToolsService.extractTo] 是纯 Dart，直接覆盖；
/// `ensureExtracted` / `clearExtracted` 通过 [ItToolsService.debugDocsDir]
/// 注入临时文档目录后也可覆盖（rootBundle 读的是 pubspec 里声明的真实资产）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ItToolsService.extractTo', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('it_tools_test_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    Uint8List buildZip(Map<String, String> files) {
      final archive = Archive();
      for (final entry in files.entries) {
        final data = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, data.length, data));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive)!);
    }

    test('解压根级与嵌套文件，内容一致', () async {
      final bytes = buildZip({
        'index.html': '<html>ok</html>',
        'assets/app.js': 'console.log(1)',
        'assets/deep/nested/x.txt': 'deep',
      });

      await ItToolsService.extractTo(bytes, dir.path);

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        '<html>ok</html>',
      );
      expect(
        await File(p.join(dir.path, 'assets', 'app.js')).readAsString(),
        'console.log(1)',
      );
      expect(
        await File(p.join(dir.path, 'assets', 'deep', 'nested', 'x.txt'))
            .readAsString(),
        'deep',
      );
    });

    test('拒绝跳出目标目录的条目（zip-slip）', () async {
      final bytes = buildZip({
        'ok.txt': 'ok',
        '../escaped.txt': 'pwn',
        'assets/../../escaped2.txt': 'pwn',
        '/tmp/absolute_escape.txt': 'pwn',
      });

      await ItToolsService.extractTo(bytes, dir.path);

      // 正常条目照常写入
      expect(await File(p.join(dir.path, 'ok.txt')).exists(), isTrue);
      // 越界条目一个都不该落盘
      expect(await File(p.join(dir.parent.path, 'escaped.txt')).exists(), isFalse);
      expect(await File(p.join(dir.parent.path, 'escaped2.txt')).exists(), isFalse);
      expect(await File('/tmp/absolute_escape.txt').exists(), isFalse);
    });

    test('覆盖同名文件时内容为新值', () async {
      await File(p.join(dir.path, 'index.html')).writeAsString('old');

      await ItToolsService.extractTo(buildZip({'index.html': 'new'}), dir.path);

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        'new',
      );
    });
  });

  group('ItToolsService 清理（「缓存管理」入口）', () {
    late Directory docs;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('it_tools_docs_');
      ItToolsService.debugDocsDir = docs;
    });

    tearDown(() async {
      ItToolsService.debugDocsDir = null;
      if (await docs.exists()) {
        await docs.delete(recursive: true);
      }
    });

    test('extractedDir 指向文档目录下的 it_tools', () async {
      final dir = await ItToolsService.extractedDir();
      expect(dir.path, p.join(docs.path, 'it_tools'));
    });

    test('目录不存在时清理返回 false', () async {
      expect(await ItToolsService.clearExtracted(), isFalse);
    });

    test(
      '清理会连版本标记一起删除 → 下次 ensureExtracted 必然重新解压',
      () async {
        // 首次：目录为空，应当解压真实资产
        final dir = await ItToolsService.ensureExtracted();
        expect(await File(p.join(dir.path, 'index.html')).exists(), isTrue);
        expect(
          await File(p.join(dir.path, '.extracted_version')).exists(),
          isTrue,
          reason: '解压后必须落版本标记，否则每次进入都会重复解压',
        );

        // 已解压且版本一致 → 不重复解压（埋一个哨兵文件，重解会被清掉）
        final sentinel = File(p.join(dir.path, 'sentinel.txt'));
        await sentinel.writeAsString('keep');
        await ItToolsService.ensureExtracted();
        expect(await sentinel.exists(), isTrue, reason: '版本一致时不应重新解压');

        // 清理后 → 标记没了 → 必然重新解压（哨兵文件随之消失）
        expect(await ItToolsService.clearExtracted(), isTrue);
        expect(await dir.exists(), isFalse);

        await ItToolsService.ensureExtracted();
        expect(await File(p.join(dir.path, 'index.html')).exists(), isTrue);
        expect(await sentinel.exists(), isFalse, reason: '清理后应重新解压出新目录');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
