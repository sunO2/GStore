import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_zip_index.dart';

/// 用 archive 包生成一个合成 APK（zip），用于验证中央目录索引与兜底解析
File _buildApk(String tag, Map<String, List<int>> entries) {
  final dir = Directory.systemTemp.createTempSync('apk_zip_index_$tag');
  final file = File('${dir.path}/app.apk');
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final zip = ZipEncoder().encode(archive);
  if (zip == null) throw StateError('zip encode failed');
  file.writeAsBytesSync(zip);
  return file;
}

void main() {
  group('ApkZipIndex：只读中央目录', () {
    test('条目名/大小/压缩方式可从中央目录直接得到', () {
      final apk = _buildApk('basic', {
        'lib/arm64-v8a/liba.so': List.filled(100, 1),
        'lib/armeabi-v7a/liba.so': List.filled(200, 2),
        'assets/payload.so': List.filled(50, 3),
        'classes.dex': List.filled(10, 4),
        'classes2.dex': List.filled(20, 5),
        'AndroidManifest.xml': List.filled(8, 6),
      });

      final index = ApkZipIndex.read(apk.path);
      expect(index, isNotNull);
      expect(index!.fileSize, apk.lengthSync());
      expect(index.entries, hasLength(6));

      final liba = index.entryNamed('lib/arm64-v8a/liba.so');
      expect(liba, isNotNull);
      expect(liba!.size, 100);

      // 中央目录阶段不产生内容
      expect(index.files.every((e) => !e.name.endsWith('/')), isTrue);
    });

    test('按需解压单个条目（DEFLATED 走 raw inflate）', () {
      final payload = utf8.encode('{"buildSystem":"Gradle","buildSystemVersion":"8.7"}');
      final apk = _buildApk('read', {
        'kotlin-tooling-metadata.json': payload,
        'lib/arm64-v8a/liba.so': List.filled(64, 9),
      });

      final index = ApkZipIndex.read(apk.path)!;
      final bytes = index.readEntryBytes('kotlin-tooling-metadata.json');
      expect(bytes, isNotNull);
      expect(utf8.decode(bytes!), contains('"buildSystemVersion":"8.7"'));

      expect(index.readEntryBytes('not/exist.txt'), isNull);
    });

    test('非 zip 文件返回 null（调用方降级）', () {
      final dir = Directory.systemTemp.createTempSync('apk_zip_index_bad');
      final bad = File('${dir.path}/bad.apk')..writeAsBytesSync(List.filled(64, 0));
      expect(ApkZipIndex.read(bad.path), isNull);
      expect(ApkZipIndex.read('${dir.path}/missing.apk'), isNull);
    });
  });

  group('构建版本兜底路径（模块不可用时的 Dart 实现）', () {
    test('kotlin-tooling-metadata.json 主路径', () async {
      final apk = _buildApk('buildver', {
        'kotlin-tooling-metadata.json': utf8.encode(jsonEncode({
          'buildSystem': 'Gradle',
          'buildSystemVersion': '8.7',
          'buildPlugin':
              'org.jetbrains.kotlin.gradle.plugin.KotlinAndroidPluginWrapper',
          'buildPluginVersion': '2.0.21',
          'projectTargets': [
            {
              'target':
                  'org.jetbrains.kotlin.gradle.plugin.mpp.KotlinAndroidTarget',
              'extras': {
                'android': {'sourceCompatibility': '17'},
              },
            },
          ],
        })),
        'META-INF/androidx.compose.ui_ui.version': utf8.encode('1.7.5'),
        'META-INF/com.android.build.gradle_app-metadata.properties':
            utf8.encode('androidGradlePluginVersion=8.5.2\nother=1\n'),
      });

      final info = await ApkLibraryAnalyzer.instance.detectBuildVersions(apk.path);
      expect(info.kotlinVersion, '2.0.21');
      expect(info.gradleVersion, '8.7');
      expect(info.javaVersion, '17');
      expect(info.composeVersion, '1.7.5');
      expect(info.agpVersion, '8.5.2');
    });

    test('MANIFEST.MF 的 Created-By 作为 AGP 兜底', () async {
      final apk = _buildApk('agpfallback', {
        'META-INF/MANIFEST.MF':
            utf8.encode('Manifest-Version: 1.0\nCreated-By: Android Gradle 8.1.0\n'),
      });
      final info = await ApkLibraryAnalyzer.instance.detectBuildVersions(apk.path);
      expect(info.agpVersion, '8.1.0');
    });

    test('kotlin-tooling-metadata.json 非 Gradle 构建 → 不误报', () async {
      final apk = _buildApk('maven', {
        'kotlin-tooling-metadata.json': utf8.encode(jsonEncode({
          'buildSystem': 'Maven',
          'buildSystemVersion': '3.9',
          'buildPlugin': 'other.plugin',
          'buildPluginVersion': '1.2.3',
        })),
      });
      final info = await ApkLibraryAnalyzer.instance.detectBuildVersions(apk.path);
      expect(info.kotlinVersion, '');
      expect(info.gradleVersion, '');
    });

    test('*.kotlin_module 二进制版本降级推断（大端、恰好一种才采用）', () async {
      final module = BytesBuilder()
        ..add(_beInt32(3))
        ..add(_beInt32(1))
        ..add(_beInt32(9))
        ..add(_beInt32(0));
      final apk = _buildApk('kotlinmodule', {
        'META-INF/main.kotlin_module': module.takeBytes(),
      });
      final info = await ApkLibraryAnalyzer.instance.detectBuildVersions(apk.path);
      expect(info.kotlinVersion, '1.9.x');
    });

    test('兜底路径下原生库/ABI/DEX 清单仍可枚举（不解压整包）', () async {
      final apk = _buildApk('lists', {
        'lib/arm64-v8a/liba.so': List.filled(10, 1),
        'lib/x86_64/libb.so': List.filled(20, 2),
        'assets/x.so': List.filled(30, 3),
        'classes.dex': List.filled(40, 4),
        'classes2.dex': List.filled(50, 5),
      });

      final abis = await ApkLibraryAnalyzer.instance.listNativeAbis(apk.path);
      expect(abis, ['arm64-v8a', 'x86_64']);

      final libs = await ApkLibraryAnalyzer.instance
          .analyzeNativeLibsFull(apk.path);
      expect(libs.map((g) => g.abi).toList(), ['arm64-v8a', 'x86_64']);
      expect(libs.first.soFiles.single.name, 'liba.so');
      expect(libs.first.soFiles.single.size, 10);

      final dex = await ApkLibraryAnalyzer.instance.analyzeDexFilesFull(apk.path);
      expect(dex.map((d) => d.name).toList(), ['classes.dex', 'classes2.dex']);
      expect(dex.first.size, 40);
    });
  });
}

Uint8List _beInt32(int v) =>
    Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.big);
