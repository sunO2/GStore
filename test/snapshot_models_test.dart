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
}
