import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/rust/Contract.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';

void main() {
  group('decodeElfScanResult：ELF 元数据与 16KB 判定', () {
    test('解析页对齐 + zip 对齐 + ELF 元数据', () {
      final json = jsonDecode('''
      {"so_files": [
        {"abi": "arm64-v8a", "so_name": "libfoo.so", "path": "lib/arm64-v8a/libfoo.so",
         "size": 1234, "min_page_size": 16384, "zip_alignment": 4096,
         "aligned_16kb": false, "elf_type": 3,
         "needed": ["libc.so", "liblog.so"],
         "jni_entry_points": ["Java_com_a_B_c"],
         "stripped": true}
      ]}''');

      final result = decodeElfScanResult(json)!;
      expect(result.soFiles, hasLength(1));
      final so = result.soFiles.single;
      expect(so.abi, 'arm64-v8a');
      expect(so.path, 'lib/arm64-v8a/libfoo.so');
      expect(so.size, 1234);
      expect(so.minPageSize, 16384);
      expect(so.zipAlignment, 4096);
      // 页对齐达标但 zip 对齐不达标 → 整体不通过（LibChecker 双条件语义）
      expect(so.aligned16Kb, isFalse);
      expect(so.elfType, 3);
      expect(so.needed, ['libc.so', 'liblog.so']);
      expect(so.jniEntryPoints, ['Java_com_a_B_c']);
      expect(so.stripped, isTrue);
    });

    test('字段缺失时用安全默认值（兼容旧版模块）', () {
      final result = decodeElfScanResult(jsonDecode('''
      {"so_files": [{"abi": "x86", "so_name": "libx.so", "min_page_size": -1,
                     "aligned_16kb": false}]}'''))!;
      final so = result.soFiles.single;
      expect(so.path, '');
      expect(so.zipAlignment, 0);
      expect(so.elfType, -1);
      expect(so.needed, isEmpty);
      expect(so.stripped, isFalse);
    });
  });

  group('decodeApkManifestInfo：manifest 深挖', () {
    test('权限 maxSdkVersion / 组件 action / meta-data / 静态库', () {
      final info = decodeApkManifestInfo(jsonDecode('''
      {"package_name": "com.a.b", "version_name": "1.2", "version_code": "3",
       "min_sdk": "21", "target_sdk": "34", "compile_sdk": "35",
       "shared_user_id": "android.uid.shared", "main_activity": "com.a.b.Main",
       "permissions": [
         {"name": "android.permission.INTERNET"},
         {"name": "android.permission.READ_PHONE_STATE", "max_sdk_version": "29"}
       ],
       "components": [
         {"kind": "service", "name": "com.a.b.S", "exported": "true",
          "process": ":push", "actions": ["com.a.b.PUSH", "com.a.b.SYNC"]}
       ],
       "meta_data": [{"name": "xposedmodule", "value": "true"}],
       "static_libraries": [{"name": "com.x.lib", "version": "1.0",
                             "cert_digest": "AA:BB"}]}'''))!;

      expect(info.packageName, 'com.a.b');
      expect(info.compileSdk, '35');
      expect(info.sharedUserId, 'android.uid.shared');
      expect(info.mainActivity, 'com.a.b.Main');
      expect(info.permissions, hasLength(2));
      expect(info.permissions[1].maxSdkVersion, '29');
      expect(info.components.single.kind, 'service');
      expect(info.components.single.process, ':push');
      expect(info.allActions, ['com.a.b.PUSH', 'com.a.b.SYNC']);
      expect(info.metaData.single.name, 'xposedmodule');
      expect(info.staticLibraries.single.name, 'com.x.lib');
      expect(info.staticLibraries.single.certDigest, 'AA:BB');
    });

    test('解析 intent-filter 的深链 data（scheme/host/path/autoVerify）', () {
      final info = decodeApkManifestInfo(jsonDecode('''
      {"package_name": "com.a.b",
       "components": [
         {"kind": "activity", "name": "com.a.b.Deep",
          "intent_filters": [
            {"actions": ["android.intent.action.VIEW"],
             "categories": ["android.intent.category.BROWSABLE"],
             "auto_verify": true,
             "data": [
               {"scheme": "https", "host": "www.a.com",
                "path_pattern": "/p/[0-9]+"},
               {"scheme": "myapp", "host": "open",
                "path_prefix": "/detail", "mime_type": ""}
             ]}
          ]}
       ]}'''))!;

      final filters = info.components.single.intentFilters;
      expect(filters, hasLength(1));
      expect(filters.single.autoVerify, isTrue);
      expect(filters.single.categories, ['android.intent.category.BROWSABLE']);
      expect(filters.single.data, hasLength(2), reason: '同一 filter 下可有并列多条 data');
      expect(filters.single.data.first.scheme, 'https');
      expect(filters.single.data.first.pathPattern, '/p/[0-9]+');
      expect(filters.single.data[1].pathPrefix, '/detail');
    });

    test('无 intent_filters 字段时降级为空（兼容旧版模块）', () {
      final info = decodeApkManifestInfo(jsonDecode('''
      {"package_name": "com.a.b",
       "components": [{"kind": "service", "name": "com.a.b.S"}]}'''))!;
      expect(info.components.single.intentFilters, isEmpty);
      expect(info.components.single.actions, isEmpty);
    });
  });

  group('decodeApkDexStats：每文件类数量', () {
    test('解析类数量与总量', () {
      final stats = decodeApkDexStats(jsonDecode('''
      {"dex_files": [
        {"name": "classes.dex", "size": 100, "compressed_size": 60,
         "crc32": 42, "class_count": 500},
        {"name": "classes2.dex", "size": 200, "compressed_size": 120,
         "crc32": 43, "class_count": -1}
      ], "total_class_count": 500}'''))!;
      expect(stats.dexFiles, hasLength(2));
      expect(stats.dexFiles.first.classCount, 500);
      expect(stats.dexFiles.first.crc32, 42);
      expect(stats.dexFiles[1].classCount, -1);
      expect(stats.totalClassCount, 500);
    });
  });

  group('decodeSignatureSchemes：签名方案', () {
    test('解析 V1–V4 与签名块 ID', () {
      final s = decodeSignatureSchemes(jsonDecode('''
      {"has_v1": true, "has_v2": true, "has_v3": false, "has_v31": false,
       "has_v32": false, "has_v4": true, "schemes": ["V1", "V2", "V4"],
       "signing_block_ids": [1896441226]}'''))!;
      expect(s.hasV1, isTrue);
      expect(s.hasV2, isTrue);
      expect(s.hasV4, isTrue);
      expect(s.schemes, ['V1', 'V2', 'V4']);
      expect(s.signingBlockIds, [1896441226]);
    });
  });

  group('decodeApkFeatures：特征识别', () {
    test('解析布尔特征与展示标签', () {
      final f = decodeApkFeatures(jsonDecode('''
      {"kotlin_used": true, "jetpack_compose": true, "kmp": false,
       "xposed_module": false, "play_signing": true, "pwa": false,
       "live_update_notification": false, "agp_version": "8.7.2",
       "evidence": ["kotlin-tooling-metadata.json"]}'''))!;
      expect(f.kotlinUsed, isTrue);
      expect(f.jetpackCompose, isTrue);
      expect(f.agpVersion, '8.7.2');
      expect(f.evidence, ['kotlin-tooling-metadata.json']);
      expect(f.labels, ['Kotlin', 'Jetpack Compose', 'Play 签名']);
    });
  });

  group('decodeRuleMatchResult：规则命中与分类', () {
    RuleMatchResult sample() =>
        decodeRuleMatchResult(jsonDecode('''
      {"hits": [
        {"rule_name": "libAMapSDK_MAP_v(.*)\\\\.so", "label": "高德地图",
         "kind": "native", "matched": "libAMapSDK_MAP_v11.so", "is_regex": true,
         "component_type": 0},
        {"rule_name": "androidx.lifecycle", "label": "Lifecycle",
         "kind": "dex", "matched": "androidx.lifecycle.LiveData",
         "is_regex": false, "component_type": 0},
        {"rule_name": "com.x.S", "label": "推送",
         "kind": "component", "matched": "com.x.S", "is_regex": false,
         "component_type": 1},
        {"rule_name": "com.google.android.trichromelibrary",
         "label": "Trichrome", "kind": "static",
         "matched": "com.google.android.trichromelibrary", "is_regex": false,
         "component_type": 0},
        {"rule_name": "androidx.profileinstaller.action.INSTALL_PROFILE",
         "label": "Jetpack ProfileInstaller", "kind": "action",
         "matched": "androidx.profileinstaller.action.INSTALL_PROFILE",
         "is_regex": false, "component_type": 0}
      ], "skipped_regex": 2, "dex_class_count": 12345}'''))!;

    test('解析全部字段', () {
      final r = sample();
      expect(r.hits, hasLength(5));
      expect(r.skippedRegex, 2);
      expect(r.dexClassCount, 12345);
      expect(r.hits.first.isRegex, isTrue);
      expect(r.hits[2].componentType, 1);
    });

    test('static(6) / action(9) 是此前宿主未覆盖的两类，现可按类别取回', () {
      final r = sample();
      final statics = ApkLibraryAnalyzer.staticLibraryHitsOf(r);
      final actions = ApkLibraryAnalyzer.actionHitsOf(r);
      expect(statics.map((h) => h.label), ['Trichrome']);
      expect(actions.map((h) => h.label), ['Jetpack ProfileInstaller']);
      // 其余类别不应混入
      expect(statics.single.kind, 'static');
      expect(actions.single.kind, 'action');
    });
  });

  group('decodeApkStructure：assets 清单 / arsc 指纹 / 包结构总量', () {
    test('解析 assets 全量清单与 resources.arsc 内容指纹', () {
      final json = jsonDecode('''
      {"file_size": 1000, "entry_count": 42, "total_uncompressed": 2048,
       "stored_entry_count": 3,
       "abis": [], "assets_so": [],
       "assets": [
         {"path": "assets/models/a.tflite", "name": "models/a.tflite",
          "size": 128, "compressed_size": 64, "crc32": 305419896, "stored": false},
         {"path": "assets/raw/b.bin", "name": "raw/b.bin",
          "size": 9, "compressed_size": 9, "crc32": 7, "stored": true}
       ],
       "dex_files": [],
       "resources_arsc_size": 911, "resources_arsc_crc32": 4242,
       "resources_arsc_stored": true, "has_manifest": true}''');
      final st = decodeApkStructure(json)!;
      expect(st.entryCount, 42);
      expect(st.totalUncompressed, 2048);
      expect(st.storedEntryCount, 3);
      expect(st.assets.length, 2);
      expect(st.assets.first.name, 'models/a.tflite');
      expect(st.assets.first.crc32, 305419896);
      expect(st.assets.last.stored, isTrue);
      expect(st.resourcesArscSize, 911);
      expect(st.resourcesArscCrc32, 4242);
      expect(st.resourcesArscStored, isTrue);
    });

    test('旧模块输出缺字段时安全降级（不抛异常、计数为 0）', () {
      final st = decodeApkStructure(jsonDecode('''
      {"file_size": 1, "entry_count": 1, "total_uncompressed": 1,
       "abis": [], "assets_so": [], "dex_files": [],
       "resources_arsc_size": 0, "has_manifest": false}'''))!;
      expect(st.assets, isEmpty);
      expect(st.storedEntryCount, 0);
      expect(st.resourcesArscCrc32, 0);
      expect(st.resourcesArscStored, isFalse);
    });
  });

  group('decodeApkDexStats：DEX 头指纹与各类 id 数量', () {
    test('解析 checksum / 头 SHA-1 / 方法·字段·字符串数', () {
      final json = jsonDecode('''
      {"total_class_count": 10, "dex_files": [
        {"name": "classes.dex", "size": 100, "compressed_size": 50,
         "crc32": 123, "class_count": 10, "checksum": 99,
         "header_sha1": "000102030405060708090a0b0c0d0e0f10111213",
         "header_file_size": 100, "string_ids": 11, "type_ids": 12,
         "proto_ids": 13, "field_ids": 14, "method_ids": 15, "data_size": 16}
      ]}''');
      final stats = decodeApkDexStats(json)!;
      final dex = stats.dexFiles.single;
      expect(dex.checksum, 99);
      expect(dex.headerSha1, '000102030405060708090a0b0c0d0e0f10111213');
      expect(dex.hasHeaderFingerprint, isTrue);
      expect(dex.methodIds, 15);
      expect(dex.fieldIds, 14);
      expect(dex.stringIds, 11);
    });

    test('旧模块输出缺头字段时 hasHeaderFingerprint=false', () {
      final stats = decodeApkDexStats(jsonDecode('''
      {"total_class_count": 1, "dex_files": [
        {"name": "classes.dex", "size": 1, "compressed_size": 1,
         "crc32": 1, "class_count": 1}]}'''))!;
      expect(stats.dexFiles.single.hasHeaderFingerprint, isFalse);
      expect(stats.dexFiles.single.methodIds, 0);
    });
  });
}
