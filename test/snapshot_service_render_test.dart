import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/core/snapshot/snapshot_service.dart';

/// 构造一份最小可用载荷（只填对比/渲染关心的字段）
///
/// `summary` 由 payload 派生，保证记录页字段与载荷一致（与真实落库路径相同）。
SnapshotRecord _record({
  required int id,
  required String versionName,
  required int apkSize,
  required int soSize,
  required int soCrc,
  required int createdAt,
  List<String> permissions = const [],
  String note = '',
  String soName = 'libdemo.so',
}) {
  final payload = SnapshotPayload(
    app: SnapshotAppInfo(
      packageName: 'com.example.app',
      label: '示例应用',
      versionName: versionName,
      versionCode: '1',
      apkSize: apkSize,
      targetSdk: '34',
    ),
    permissions: [
      for (final p in permissions) SnapshotPermission(name: p),
    ],
    nativeLibs: [
      SnapshotNativeLib(
        abi: 'arm64-v8a',
        name: soName,
        size: soSize,
        crc32: soCrc,
      ),
    ],
    structure: const SnapshotStructureInfo(entryCount: 100),
  );
  return SnapshotRecord(
    id: id,
    packageName: 'com.example.app',
    appLabel: '示例应用',
    versionName: versionName,
    versionCode: '1',
    createdAt: createdAt,
    note: note,
    payloadVersion: kSnapshotPayloadVersion,
    summary: payload.summary,
    payload: payload,
  );
}

void main() {
  group('AppSnapshotService.renderDiff', () {
    final oldR = _record(
      id: 1,
      versionName: '1.0',
      apkSize: 1024 * 1024,
      soSize: 1024,
      soCrc: 111,
      createdAt: 1000,
      permissions: ['android.permission.CAMERA'],
      note: '更新前',
    );
    final newR = _record(
      id: 2,
      versionName: '2.0',
      apkSize: 3 * 1024 * 1024,
      soSize: 2048,
      soCrc: 222,
      createdAt: 2000,
      permissions: ['android.permission.CAMERA', 'android.permission.LOCATION'],
      note: '更新后',
    );
    final diff = SnapshotDiffEngine.compare(oldR, newR);
    final text = AppSnapshotService.instance.renderDiff(diff);

    test('包含新旧版本与采集时间', () {
      expect(text, contains('基准(旧)：id=1 v1.0'));
      expect(text, contains('目标(新)：id=2 v2.0'));
    });

    test('包含结论与指纹判定', () {
      expect(text, contains('【结论】'));
      expect(text, contains('原生库变更'));
      expect(text, contains('指纹判定：'));
    });

    test('体积差直接给出（无需用户相减）', () {
      expect(text, contains('APK 体积变化：+2.0 MB'));
    });

    test('字段级差异按「字段名 + −旧 + 新」多行给出', () {
      // .so 大小 1.0 KB → 2.0 KB
      expect(text, contains('大小'));
      expect(text, contains('− 1.0 KB'));
      expect(text, contains('+ 2.0 KB'));
    });

    test('内容指纹不同时给出"同名但内容已变"结论', () {
      expect(text, contains('内容指纹不同'));
    });

    test('新增权限以 + 条目列出', () {
      expect(text, contains('LOCATION'));
    });

    test('差异总计与分节统计存在', () {
      expect(text, contains('差异总计：新增'));
      expect(text, contains('=== 变化明细（按分节） ==='));
    });
  });

  group('AppSnapshotService.renderDiff 无差异', () {
    final r1 = _record(
      id: 1,
      versionName: '1.0',
      apkSize: 1024,
      soSize: 1024,
      soCrc: 111,
      createdAt: 1000,
    );
    final r2 = _record(
      id: 2,
      versionName: '1.0',
      apkSize: 1024,
      soSize: 1024,
      soCrc: 111,
      createdAt: 2000,
    );
    final text =
        AppSnapshotService.instance.renderDiff(SnapshotDiffEngine.compare(r1, r2));

    test('明确说明未检出内容差异', () {
      expect(text, contains('未检出任何内容差异'));
    });
  });

  group('AppSnapshotService.renderDiff 新增/移除条目', () {
    final oldR = _record(
      id: 1,
      versionName: '1.0',
      apkSize: 1024,
      soSize: 1024,
      soCrc: 111,
      createdAt: 1000,
      soName: 'libgone.so',
    );
    final newR = _record(
      id: 2,
      versionName: '2.0',
      apkSize: 1024,
      soSize: 4096,
      soCrc: 222,
      createdAt: 2000,
      soName: 'libnew.so',
    );
    final text =
        AppSnapshotService.instance.renderDiff(SnapshotDiffEngine.compare(oldR, newR));

    test('新增的 .so 也给出大小，而不是只有名字', () {
      expect(text, contains('libnew.so'));
      expect(text, contains('+ 4.0 KB'));
    });

    test('移除的 .so 也给出大小', () {
      expect(text, contains('libgone.so'));
      expect(text, contains('− 1.0 KB'));
    });
  });

  group('AppSnapshotService 列表/详情渲染', () {
    test('renderAppList 空态给出创建指引', () {
      final text = AppSnapshotService.instance.renderAppList(const []);
      expect(text, contains('暂无任何应用快照'));
      expect(text, contains('appSnapshot'));
    });

    test('renderRecordList 含 id 便于指定对比', () {
      final r = _record(
        id: 7,
        versionName: '3.1',
        apkSize: 2048,
        soSize: 512,
        soCrc: 9,
        createdAt: 5000,
        note: '更新后',
      );
      final text =
          AppSnapshotService.instance.renderRecordList('com.example.app', [r]);
      expect(text, contains('id=7'));
      expect(text, contains('v3.1'));
      expect(text, contains('更新后'));
      expect(text, contains('原生库 1'));
    });

    test('renderDetail 汇总关键字段与命中库', () {
      final r = _record(
        id: 9,
        versionName: '4.0',
        apkSize: 4096,
        soSize: 128,
        soCrc: 3,
        createdAt: 9000,
      );
      final text = AppSnapshotService.instance.renderDetail(r);
      expect(text, contains('快照 id=9'));
      expect(text, contains('版本：4.0(1)'));
      expect(text, contains('原生库 1 个'));
      expect(text, contains('载荷版本：v$kSnapshotPayloadVersion'));
    });
  });
}
