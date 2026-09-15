import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';

SnapshotPayload _payload({
  String versionName = '1.0.0',
  String apkSize = '1000',
  List<SnapshotNativeLib> nativeLibs = const [],
  List<SnapshotNativeLib> Function()? libsFn,
  List<SnapshotPermission> permissions = const [],
  List<SnapshotComponent> components = const [],
  List<SnapshotDexFile> dexFiles = const [],
  List<SnapshotCertificate> certificates = const [],
  List<SnapshotMetaData> metaData = const [],
  List<SnapshotAsset> assets = const [],
  List<SnapshotElfInfo> elfFiles = const [],
  SnapshotArscInfo arsc = const SnapshotArscInfo(),
  SnapshotStructureInfo structure = const SnapshotStructureInfo(),
  List<SnapshotRuleHit> nativeHits = const [],
  List<SnapshotRuleHit> dexHits = const [],
  SnapshotFeatures features = const SnapshotFeatures(),
  SnapshotBuildVersions buildVersions = const SnapshotBuildVersions(),
  int payloadVersion = kSnapshotPayloadVersion,
}) {
  final libs = libsFn?.call() ?? nativeLibs;
  return SnapshotPayload(
    payloadVersion: payloadVersion,
    app: SnapshotAppInfo(
      packageName: 'com.demo.app',
      label: 'Demo',
      versionName: versionName,
      versionCode: '1',
      apkSize: int.parse(apkSize),
      abis: const ['arm64-v8a'],
    ),
    signature: SnapshotSignatureInfo(certificates: certificates),
    permissions: permissions,
    components: components,
    nativeLibs: libs,
    dexFiles: dexFiles,
    nativeHits: nativeHits,
    dexHits: dexHits,
    features: features,
    buildVersions: buildVersions,
    metaData: metaData,
    elfFiles: elfFiles,
    assets: assets,
    arsc: arsc,
    structure: structure,
  );
}

SnapshotRecord _record(
  SnapshotPayload payload, {
  int id = 1,
  int createdAt = 1000,
  String versionName = '1.0.0',
}) =>
    SnapshotRecord(
      id: id,
      packageName: payload.app.packageName,
      appLabel: payload.app.label,
      versionName: versionName,
      versionCode: '1',
      createdAt: createdAt,
      payloadVersion: payload.payloadVersion,
      summary: payload.summary,
      payload: payload,
    );

SnapshotDiffSection _section(SnapshotDiff diff, String title) =>
    diff.sections.firstWhere((s) => s.title == title);

void main() {
  group('SnapshotPayload JSON 往返', () {
    test('全部节可往返且不丢字段', () {
      final payload = _payload(
        nativeLibs: const [
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'liba.so', size: 100),
        ],
        permissions: const [
          SnapshotPermission(
            name: 'android.permission.CAMERA',
            maxSdkVersion: '29',
            granted: true,
          ),
        ],
        components: const [
          SnapshotComponent(
            kind: 'activity',
            name: 'com.demo.MainActivity',
            exported: 'true',
            actions: ['android.intent.action.VIEW'],
            deepLinks: ['demo://open/home'],
          ),
        ],
        dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', size: 10, classCount: 42),
        ],
        certificates: const [
          SnapshotCertificate(
            subject: 'CN=Demo',
            sha256: 'abc',
            kind: 'current',
          ),
        ],
        metaData: const [SnapshotMetaData(name: 'k', value: 'v')],
        nativeHits: const [
          SnapshotRuleHit(label: 'OkHttp', ruleName: 'okhttp', matched: 'libokhttp.so'),
        ],
        features: const SnapshotFeatures(kotlinUsed: true, jetpackCompose: true),
      );

      final restored =
          SnapshotPayload.fromJson(jsonDecode(jsonEncode(payload.toJson())));

      expect(restored.app.packageName, 'com.demo.app');
      expect(restored.nativeLibs.single.name, 'liba.so');
      expect(restored.permissions.single.maxSdkVersion, '29');
      expect(restored.permissions.single.granted, isTrue);
      expect(restored.components.single.deepLinks, ['demo://open/home']);
      expect(restored.dexFiles.single.classCount, 42);
      expect(restored.signature.certificates.single.kind, 'current');
      expect(restored.metaData.single.value, 'v');
      expect(restored.nativeHits.single.label, 'OkHttp');
      expect(restored.features.kotlinUsed, isTrue);
      expect(restored.features.jetpackCompose, isTrue);
    });

    test('缺失字段按默认值解码（不抛异常）', () {
      final restored = SnapshotPayload.fromJson(const {'payload_version': 1});
      expect(restored.payloadVersion, 1);
      expect(restored.nativeLibs, isEmpty);
      expect(restored.features.kotlinUsed, isFalse);
    });
  });

  group('标量与集合差异', () {
    test('版本与大小变化识别为 changed，并给出 from→to', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(versionName: '1.0.0', apkSize: '1000')),
        _record(_payload(versionName: '2.0.0', apkSize: '2000'), createdAt: 2000),
      );
      final app = _section(diff, '应用信息');
      final version = app.entries.firstWhere((e) => e.key == '版本名');
      expect(version.kind, SnapshotDiffKind.changed);
      expect(version.oldValue, '1.0.0');
      expect(version.newValue, '2.0.0');
      expect(
        app.entries.any((e) => e.key == 'APK 大小' && e.oldValue != e.newValue),
        isTrue,
      );
    });

    test('原生库新增/移除/大小变化三类都能区分', () {
      final oldP = _payload(
        nativeLibs: const [
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libkeep.so', size: 100),
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgone.so', size: 200),
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgrow.so', size: 300),
        ],
      );
      final newP = _payload(
        nativeLibs: const [
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libkeep.so', size: 100),
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgrow.so', size: 500),
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libnew.so', size: 400),
        ],
      );
      final libs = _section(
        SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000)),
        '原生库文件',
      );
      expect(libs.added, 1);
      expect(libs.removed, 1);
      expect(libs.changed, 1);
      expect(
        libs.entries.firstWhere((e) => e.key.contains('libnew.so')).kind,
        SnapshotDiffKind.added,
      );
      final grow = libs.entries.firstWhere((e) => e.key.contains('libgrow.so'));
      expect(grow.fieldChanges.single.field, '大小');
      expect(grow.fieldChanges.single.from, formatBytes(300));
      expect(grow.fieldChanges.single.to, formatBytes(500));
    });

    test('新增/移除的原生库也带出自身字段（大小等），不是只有一个名字', () {
      final oldP = _payload(nativeLibs: const [
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgone.so', size: 200),
      ]);
      final newP = _payload(nativeLibs: const [
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libnew.so', size: 400),
      ]);
      final libs = _section(
        SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000)),
        '原生库文件',
      );

      final added =
          libs.entries.firstWhere((e) => e.kind == SnapshotDiffKind.added);
      final addedSize = added.fieldChanges.firstWhere((f) => f.field == '大小');
      expect(addedSize.from, '—');
      expect(addedSize.to, formatBytes(400));

      final removed =
          libs.entries.firstWhere((e) => e.kind == SnapshotDiffKind.removed);
      final removedSize =
          removed.fieldChanges.firstWhere((f) => f.field == '大小');
      expect(removedSize.from, formatBytes(200));
      expect(removedSize.to, '—');
    });

    test('权限 maxSdkVersion 变化产生字段级差异（不是整条误报新增）', () {
      final oldP = _payload(
        permissions: const [
          SnapshotPermission(name: 'android.permission.READ_PHONE_STATE', maxSdkVersion: '33'),
        ],
      );
      final newP = _payload(
        permissions: const [
          SnapshotPermission(name: 'android.permission.READ_PHONE_STATE', maxSdkVersion: '29'),
        ],
      );
      final section = _section(
        SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000)),
        '权限',
      );
      expect(section.added, 0);
      expect(section.removed, 0);
      expect(section.changed, 1);
      expect(section.entries.single.fieldChanges.single.field, 'maxSdkVersion');
    });

    test('组件 exported 变化与深链变化可分辨', () {
      final oldP = _payload(
        components: const [
          SnapshotComponent(
            kind: 'activity',
            name: 'com.demo.A',
            exported: 'false',
            deepLinks: ['demo://a'],
          ),
        ],
      );
      final newP = _payload(
        components: const [
          SnapshotComponent(
            kind: 'activity',
            name: 'com.demo.A',
            exported: 'true',
            deepLinks: ['demo://a', 'demo://b'],
          ),
        ],
      );
      final section = _section(
        SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000)),
        '组件',
      );
      final fields = section.entries.single.fieldChanges
          .map((f) => f.field)
          .toList();
      expect(fields, contains('exported'));
      expect(fields, contains('深链'));
    });

    test('相同快照没有差异', () {
      final p = _payload(
        nativeLibs: const [
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'liba.so', size: 1),
        ],
      );
      final diff = SnapshotDiffEngine.compare(_record(p), _record(p, createdAt: 2000));
      expect(diff.hasDiff, isFalse);
      expect(diff.total, 0);
    });
  });

  group('可比性守卫', () {
    test('载荷版本不同 → 带不确定标记且不丢差异', () {
      final oldP = _payload(payloadVersion: 1);
      final newP = _payload(payloadVersion: 2);
      final diff = SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000));
      expect(diff.payloadVersionMismatch, isTrue);
    });

    test('新增项在版本不同时标记为 uncertain', () {
      final oldP = _payload(payloadVersion: 1);
      final newP = _payload(
        payloadVersion: 2,
        nativeLibs: const [
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libnew.so', size: 1),
        ],
      );
      final diff = SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000));
      final libs = _section(diff, '原生库文件');
      expect(libs.entries.single.uncertain, isTrue);
    });

    test('旧快照缺整节 → 该节标记不可比，不误报', () {
      final oldP = _payload(payloadVersion: 1);
      final newP = _payload(payloadVersion: 2);
      final diff = SnapshotDiffEngine.compare(_record(oldP), _record(newP, createdAt: 2000));
      // 两端都空 → 该节无差异；不可比标记只用于「旧端缺、新端有」的节
      final libs = _section(diff, '原生库文件');
      expect(libs.entries, isEmpty);
    });
  });

  group('内容指纹：同名条目是否"同一个文件"', () {
    test('.so 同大小但 CRC32 不同 → 标记内容不同（sameContent=false）', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
            abi: 'arm64-v8a',
            name: 'liba.so',
            size: 100,
            crc32: 111,
          ),
        ])),
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
            abi: 'arm64-v8a',
            name: 'liba.so',
            size: 100,
            crc32: 222,
          ),
        ])),
      );
      final section = _section(diff, '原生库文件');
      expect(section.total, 1);
      final entry = section.entries.single;
      expect(entry.kind, SnapshotDiffKind.changed);
      expect(entry.sameContent, isFalse);
      // 指纹字段本身也会出现在字段级变化里（便于肉眼核对）
      expect(
        entry.fieldChanges.any((f) => f.field == '内容指纹'),
        isTrue,
      );
    });

    test('.so CRC32 相同 → 不算变化（同名即同一文件）', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'liba.so', size: 100, crc32: 111),
        ])),
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'liba.so', size: 100, crc32: 111),
        ])),
      );
      expect(_section(diff, '原生库文件').total, 0);
    });

    test('文件类条目：体积没变也列出大小（不靠"内容变化"触发）', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'liba.so', size: 100, crc32: 111),
        ])),
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'liba.so', size: 100, crc32: 222),
        ])),
      );
      final entry = _section(diff, '原生库文件').entries.single;
      expect(entry.kind, SnapshotDiffKind.changed);
      expect(entry.sameContent, isFalse);
      final size = entry.fieldChanges.firstWhere((f) => f.field == '大小');
      expect(size.from, formatBytes(100));
      expect(size.to, formatBytes(100));
    });

    test('dex 头 SHA-1 不同 → 同名 dex 内容已变；相同 → 无差异', () {
      final before = _record(_payload(dexFiles: const [
        SnapshotDexFile(
            name: 'classes.dex', size: 10, crc32: 1, headerSha1: 'aa'),
      ]));
      final after = _record(_payload(dexFiles: const [
        SnapshotDexFile(
            name: 'classes.dex', size: 10, crc32: 1, headerSha1: 'bb'),
      ]));
      final diff = SnapshotDiffEngine.compare(before, after);
      final entry = _section(diff, 'DEX 文件（明细）').entries.single;
      expect(entry.sameContent, isFalse);

      // 头指纹一致时不应报告差异
      final same = SnapshotDiffEngine.compare(
        after,
        _record(_payload(dexFiles: const [
          SnapshotDexFile(
              name: 'classes.dex', size: 10, crc32: 1, headerSha1: 'bb'),
        ])),
      );
      expect(_section(same, 'DEX 文件（明细）').total, 0);
    });

    test('ELF 动态依赖/JNI 入口按集合给出增删，而不是整串变化', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(elfFiles: const [
          SnapshotElfInfo(
            abi: 'arm64-v8a',
            soName: 'liba.so',
            needed: ['libc.so', 'libm.so'],
            jniEntryPoints: ['Java_a'],
          ),
        ])),
        _record(_payload(elfFiles: const [
          SnapshotElfInfo(
            abi: 'arm64-v8a',
            soName: 'liba.so',
            needed: ['libc.so', 'libz.so'],
            jniEntryPoints: ['Java_a', 'Java_b'],
          ),
        ])),
      );
      final entry = _section(diff, 'ELF 元数据').entries.single;
      final needed = entry.fieldChanges
          .firstWhere((f) => f.field == '动态依赖变化');
      expect(needed.from, '−libm.so');
      expect(needed.to, '+libz.so');
      final jni =
          entry.fieldChanges.firstWhere((f) => f.field == 'JNI 入口变化');
      expect(jni.from, '—');
      expect(jni.to, '+Java_b');
    });
  });

  group('P0 新分区：assets / resources.arsc / 包结构', () {
    test('assets 新增/移除/同名内容变化', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(assets: const [
          SnapshotAsset(name: 'models/a.tflite', size: 10, crc32: 1),
          SnapshotAsset(name: 'gone.bin', size: 5, crc32: 2),
        ])),
        _record(_payload(assets: const [
          SnapshotAsset(name: 'models/a.tflite', size: 10, crc32: 9),
          SnapshotAsset(name: 'new.json', size: 5, crc32: 3),
        ])),
      );
      final section = _section(diff, 'assets 文件');
      expect(section.added, 1);
      expect(section.removed, 1);
      expect(section.changed, 1);
      expect(
        section.entries
            .firstWhere((e) => e.key == 'models/a.tflite')
            .sameContent,
        isFalse,
      );
    });

    test('assets 新增条目也列出大小', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload()),
        _record(_payload(assets: const [
          SnapshotAsset(name: 'lib/arm64-v8a/libx.so', size: 1234, crc32: 5),
        ])),
      );
      final entry = _section(diff, 'assets 文件').entries.single;
      expect(entry.kind, SnapshotDiffKind.added);
      expect(
        entry.fieldChanges.firstWhere((f) => f.field == '大小').to,
        formatBytes(1234),
      );
    });

    test('resources.arsc 内容指纹变化会报告；两侧都缺失则不报', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(
            arsc: const SnapshotArscInfo(present: true, size: 100, crc32: 7))),
        _record(_payload(
            arsc: const SnapshotArscInfo(present: true, size: 100, crc32: 8))),
      );
      expect(_section(diff, 'resources.arsc').total, 1);

      final none = SnapshotDiffEngine.compare(
        _record(_payload()),
        _record(_payload()),
      );
      expect(_section(none, 'resources.arsc').total, 0);
    });

    test('包结构：条目数 / 解压总量 / STORED 数变化', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(
            structure: const SnapshotStructureInfo(
                entryCount: 10,
                totalUncompressed: 100,
                storedEntryCount: 1))),
        _record(_payload(
            structure: const SnapshotStructureInfo(
                entryCount: 11,
                totalUncompressed: 200,
                storedEntryCount: 3))),
      );
      final section = _section(diff, '包结构');
      expect(section.total, 3);
      expect(section.entries.map((e) => e.key), contains('STORED 条目数'));
    });

    test('旧快照（v1）不因缺少指纹字段而误报：该节标记不可比', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(payloadVersion: 1, assets: const [
          SnapshotAsset(name: 'a.bin', size: 1, crc32: 0),
        ])),
        _record(_payload(assets: const [
          SnapshotAsset(name: 'a.bin', size: 1, crc32: 42),
        ])),
      );
      expect(_section(diff, 'assets 文件').comparable, isFalse);
      expect(_section(diff, 'assets 文件').total, 0);
      expect(_section(diff, '包结构').comparable, isFalse);
      expect(_section(diff, 'resources.arsc').comparable, isFalse);
    });
  });

  group('变化结论摘要（变了什么）', () {
    test('签名变更优先给出"可能被重新签名"结论', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(
            certificates: const [
              SnapshotCertificate(subject: 'A', sha256: 'aa')
            ],
            nativeLibs: const [
              SnapshotNativeLib(
                  abi: 'arm64-v8a', name: 'liba.so', size: 1, crc32: 1)
            ])),
        _record(_payload(
            certificates: const [
              SnapshotCertificate(subject: 'B', sha256: 'bb')
            ],
            nativeLibs: const [
              SnapshotNativeLib(
                  abi: 'arm64-v8a', name: 'liba.so', size: 1, crc32: 1)
            ])),
      );
      expect(diff.verdict.signatureSame, isFalse);
      expect(diff.verdict.title, contains('重新签名'));
      expect(diff.verdict.labels, contains('签名变更'));
    });

    test('仅 assets 变化 → 结论为资源内容更新', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(assets: const [
          SnapshotAsset(name: 'a.bin', size: 1, crc32: 1),
        ])),
        _record(_payload(assets: const [
          SnapshotAsset(name: 'a.bin', size: 1, crc32: 2),
        ])),
      );
      expect(diff.verdict.assetsSame, isFalse);
      expect(diff.verdict.dexSame, isTrue);
      expect(diff.verdict.nativeSame, isTrue);
      // 单类变化给出更具体的结论
      expect(diff.verdict.title, contains('仅 assets 变化'));
    });

    test('DEX 与原生库同时变化 → 代码整体重新构建', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(
            dexFiles: const [
              SnapshotDexFile(name: 'classes.dex', crc32: 1, headerSha1: 'aa')
            ],
            nativeLibs: const [
              SnapshotNativeLib(
                  abi: 'arm64-v8a', name: 'liba.so', size: 1, crc32: 1)
            ])),
        _record(_payload(
            dexFiles: const [
              SnapshotDexFile(name: 'classes.dex', crc32: 2, headerSha1: 'bb')
            ],
            nativeLibs: const [
              SnapshotNativeLib(
                  abi: 'arm64-v8a', name: 'liba.so', size: 1, crc32: 2)
            ])),
      );
      expect(diff.verdict.title, contains('重新构建'));
    });

    test('完全相同 → 未检出内容变化', () {
      final p = _payload();
      final diff = SnapshotDiffEngine.compare(_record(p), _record(p, id: 2));
      expect(diff.verdict.hasChange, isFalse);
      expect(diff.verdict.title, contains('未检出'));
    });
  });

  group('改名/移动检测', () {
    test('内容指纹一致但名字不同 → 合并成"疑似改名/移动"而非删+增', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'libold.so', size: 10, crc32: 777),
        ])),
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'libnew.so', size: 10, crc32: 777),
        ])),
      );
      final section = _section(diff, '原生库文件');
      expect(section.added, 0);
      expect(section.removed, 0);
      final entry = section.entries.single;
      expect(entry.key, contains('疑似改名/移动'));
      expect(entry.sameContent, isTrue);
      expect(entry.fieldChanges.single.from, 'libold.so (arm64-v8a)');
      expect(entry.fieldChanges.single.to, 'libnew.so (arm64-v8a)');
    });

    test('内容不同则仍报删+增（不会误判成改名）', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'libold.so', size: 10, crc32: 1),
        ])),
        _record(_payload(nativeLibs: const [
          SnapshotNativeLib(
              abi: 'arm64-v8a', name: 'libnew.so', size: 10, crc32: 2),
        ])),
      );
      final section = _section(diff, '原生库文件');
      expect(section.added, 1);
      expect(section.removed, 1);
    });
  });

  group('resources.arsc 浅解析对比', () {
    test('语言集合与类型条目数变化可识别', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(
            arsc: const SnapshotArscInfo(
                present: true,
                size: 100,
                crc32: 7,
                parsed: true,
                packageNames: ['com.demo.app'],
                typeNames: ['string'],
                configs: ['默认', 'en']))),
        _record(_payload(
            arsc: const SnapshotArscInfo(
                present: true,
                size: 120,
                crc32: 8,
                parsed: true,
                packageNames: ['com.demo.app'],
                typeNames: ['string', 'drawable'],
                entryInstances: 5,
                configs: ['默认', 'en', 'zh-CN']))),
      );
      final keys = _section(diff, 'resources.arsc').entries.map((e) => e.key);
      expect(keys, contains('资源类型数'));
      expect(keys, contains('类型条目数'));
      expect(keys, contains('语言 zh-CN'));
    });
  });

  group('P2：DEX 类集合搬迁', () {
    test('同一份类集合从 classes.dex 挪到 classes3.dex → 判为搬迁', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', crc32: 1, classDigest: 'D1'),
          SnapshotDexFile(name: 'classes2.dex', crc32: 2, classDigest: 'D2'),
        ])),
        _record(_payload(dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', crc32: 1, classDigest: 'D1'),
          SnapshotDexFile(name: 'classes3.dex', crc32: 2, classDigest: 'D2'),
        ])),
      );
      final section = _section(diff, 'DEX 类集合搬迁');
      final moved = section.entries.single;
      expect(moved.key, contains('类集合搬迁'));
      expect(moved.oldValue, 'classes2.dex');
      expect(moved.newValue, 'classes3.dex');
      expect(moved.sameContent, isTrue, reason: '类内容没变，只是换了文件');
    });

    test('类集合新增/移除可识别', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', crc32: 1, classDigest: 'D1'),
        ])),
        _record(_payload(dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', crc32: 1, classDigest: 'D1'),
          SnapshotDexFile(name: 'classes2.dex', crc32: 2, classDigest: 'D9'),
        ])),
      );
      expect(_section(diff, 'DEX 类集合搬迁').added, 1);
    });

    test('无类指纹（旧快照）时该节不可比，不误报', () {
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(payloadVersion: 1, dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', crc32: 1),
        ])),
        _record(_payload(dexFiles: const [
          SnapshotDexFile(name: 'classes.dex', crc32: 2, classDigest: 'D1'),
        ])),
      );
      final section = _section(diff, 'DEX 类集合搬迁');
      expect(section.comparable, isFalse);
      expect(section.total, 0);
    });
  });

  group('P2：resources.arsc 资源级 diff', () {
    test('按资源 id 判定增/删，并给出资源名与值的字段级变化', () {
      const r = SnapshotArscResource(
          id: 0x7f010001, typeName: 'string', key: 'app_name', value: 'A');
      final diff = SnapshotDiffEngine.compare(
        _record(_payload(
            arsc: const SnapshotArscInfo(
                present: true,
                crc32: 1,
                parsed: true,
                resources: [
              r,
              SnapshotArscResource(
                  id: 0x7f020001,
                  typeName: 'drawable',
                  key: 'ic_launcher',
                  valueKind: 'reference',
                  value: '@0x7f030001'),
            ]))),
        _record(_payload(
            arsc: const SnapshotArscInfo(
                present: true,
                crc32: 2,
                parsed: true,
                resources: [
              SnapshotArscResource(
                  id: 0x7f010001,
                  typeName: 'string',
                  key: 'app_name',
                  value: 'B'),
              SnapshotArscResource(
                  id: 0x7f010002,
                  typeName: 'string',
                  key: 'new_key',
                  value: 'C'),
            ]))),
      );
      final section = _section(diff, 'resources.arsc 资源');
      expect(section.removed, 1, reason: 'ic_launcher 被删除');
      expect(section.added, 1, reason: 'new_key 新增');
      expect(section.changed, 1, reason: 'app_name 值变化');
      final changed = section.entries
          .firstWhere((e) => e.kind == SnapshotDiffKind.changed);
      expect(changed.key, contains('app_name'));
      expect(
        changed.fieldChanges.any((f) => f.field == '值' && f.to == 'B'),
        isTrue,
      );
    });
  });

  group('体积展示：formatBytes / tryParseBytes / formatBytesDelta', () {
    test('formatBytes 与 tryParseBytes 互为逆运算（含 B/KB/MB/GB）', () {
      for (final bytes in [0, 1, 512, 1024, 1536, 1048576, 1572864, 3221225472]) {
        final text = formatBytes(bytes);
        if (bytes <= 0) continue; // 0 显示为 "0 B"
        final back = tryParseBytes(text);
        expect(back, isNotNull, reason: '$bytes → $text 应可逆');
        // KB/MB 保留一位小数，允许舍入误差
        expect((back! - bytes).abs() <= 1024 + bytes * 0.001, isTrue,
            reason: '$bytes → $text → $back');
      }
    });

    test('不带单位的计数不会被误判成字节', () {
      expect(tryParseBytes('3'), isNull);
      expect(tryParseBytes('crc32:1a2b3c4d'), isNull);
      expect(tryParseBytes('—'), isNull);
    });

    test('体积差带符号；相等或不可解析时为 null', () {
      expect(formatBytesDelta('1.0 MB', '3.2 MB'), '+2.2 MB');
      expect(formatBytesDelta('2.0 MB', '1.0 MB'), '−1.0 MB');
      expect(formatBytesDelta('1.0 MB', '1.0 MB'), isNull);
      expect(formatBytesDelta('abc', 'def'), isNull);
    });
  });
}
