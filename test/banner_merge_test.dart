// 顶部横幅纯逻辑层（`banner_merge.dart`）的单元测试：
// 双来源优先级、仓库安装→索引同步的连续性、多来源聚合去重、QR 单卡、
// 终态隐藏、以及 `formatBytes` 边界。全部为纯 Dart 断言，不挂载任何 widget。
//
// ignore_for_file: file_names

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/compent/banner_merge.dart';
import 'package:gstore/core/progress/task_progress.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';

ModuleBootstrapState _module(
  String module,
  ModuleBootstrapPhase phase, {
  double? progress,
  int? sizeBytes,
  Object? error,
}) =>
    ModuleBootstrapState(
      module: module,
      phase: phase,
      progress: progress,
      sizeBytes: sizeBytes,
      error: error,
    );

TaskProgressState _task({
  String id = 'fdroid-sync',
  String cardKey = 'module:repo',
  TaskPhase phase = TaskPhase.running,
  String label = 'F-Droid 仓库',
  String? stage,
  String? detail,
  double? progress,
  int? sizeBytes,
  Object? error,
  int generation = 1,
}) =>
    TaskProgressState(
      id: id,
      cardKey: cardKey,
      phase: phase,
      label: label,
      stage: stage,
      detail: detail,
      progress: progress,
      sizeBytes: sizeBytes,
      error: error,
      generation: generation,
    );

void main() {
  group('mergeBannerCards 优先级（模块 > 同键任务）', () {
    test('模块活动 + 同键任务运行 ⇒ 仅一张卡片，显示模块阶段', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('repo', ModuleBootstrapPhase.downloading, progress: 0.42),
        ],
        <TaskProgressState>[
          _task(stage: '解析入库…', progress: 0.9),
        ],
      );

      expect(cards, hasLength(1));
      expect(cards.single.cardKey, 'module:repo');
      expect(cards.single.fromModule, isTrue, reason: '模块条目胜出');
      expect(cards.single.label, 'F-Droid 仓库');
      expect(cards.single.stage, '正在下载模块 42%', reason: '显示模块阶段而非任务阶段');
      expect(cards.single.progress, 0.42);
    });

    test('仓库安装结束（ready）后同键任务接管，cardKey 不变（视觉连续）', () {
      final task = _task(stage: '解析入库…', progress: 0.9);

      // 第一步：模块仍在安装 → 模块卡片，键为 module:repo。
      final installing = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('repo', ModuleBootstrapPhase.downloading, progress: 0.5),
        ],
        <TaskProgressState>[task],
      );
      expect(installing, hasLength(1));
      expect(installing.single.cardKey, 'module:repo');
      expect(installing.single.fromModule, isTrue);
      expect(installing.single.stage, '正在下载模块 50%');

      // 第二步：模块就绪（不再活动）→ 同键任务以同一 cardKey 接管，卡片不消失。
      final syncing = mergeBannerCards(
        <ModuleBootstrapState>[_module('repo', ModuleBootstrapPhase.ready)],
        <TaskProgressState>[task],
      );
      expect(syncing, hasLength(1));
      expect(syncing.single.cardKey, installing.single.cardKey,
          reason: '同一张卡片的键必须保持不变，才能读作一个连续过程');
      expect(syncing.single.fromModule, isFalse);
      expect(syncing.single.stage, '解析入库…');
      expect(syncing.single.progress, 0.9);
    });

    test('模块失败后同键任务接管（失败不粘滞、不重复渲染）', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('repo', ModuleBootstrapPhase.failed, error: StateError('x')),
        ],
        <TaskProgressState>[_task(stage: '同步中')],
      );

      expect(cards, hasLength(1));
      expect(cards.single.cardKey, 'module:repo');
      expect(cards.single.fromModule, isFalse);
      expect(cards.single.stage, '同步中');
    });
  });

  group('mergeBannerCards 去重与顺序', () {
    test('无模块时任务渲染为独立卡片', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[
          _task(label: 'F-Droid 仓库', stage: '同步中', progress: 0.1),
        ],
      );

      expect(cards, hasLength(1));
      expect(cards.single.cardKey, 'module:repo');
      expect(cards.single.fromModule, isFalse);
      expect(cards.single.label, 'F-Droid 仓库');
      expect(cards.single.stage, '同步中');
    });

    test('多来源归并到同一 cardKey ⇒ 只渲染一张卡片（无风暴）', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[
          _task(id: 'fdroid-sync', stage: '同步中'),
          _task(id: 'fdroid-sync-2', stage: '同步中', generation: 2),
          _task(id: 'fdroid-sync-3', stage: '同步中', generation: 3),
        ],
      );

      expect(cards, hasLength(1));
      expect(cards.single.cardKey, 'module:repo');
    });

    test('qr 模块与其同键任务只渲染一张卡片（绝不双渲染）', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('qr', ModuleBootstrapPhase.downloading, progress: 0.3),
        ],
        <TaskProgressState>[
          _task(id: 'qr-task', cardKey: 'module:qr', label: '二维码解码'),
        ],
      );

      expect(cards, hasLength(1));
      expect(cards.single.cardKey, 'module:qr');
      expect(cards.single.fromModule, isTrue);
      expect(cards.single.stage, '正在下载模块 30%');
    });

    test('模块在前、任务在后，且各 cardKey 只出现一次', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('qr', ModuleBootstrapPhase.downloading, progress: 0.1),
        ],
        <TaskProgressState>[
          _task(id: 'fdroid-sync', cardKey: 'module:repo', stage: '同步中'),
          _task(id: 'db-sync', cardKey: 'task:db', label: '数据库更新',
              stage: '下载中'),
        ],
      );

      expect(
        cards.map((BannerCard card) => card.cardKey).toList(),
        <String>['module:qr', 'module:repo', 'task:db'],
      );
    });
  });

  group('mergeBannerCards 终态隐藏（failed/ready/absent 不产生卡片）', () {
    test('仅失败的模块不产生卡片', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('qr', ModuleBootstrapPhase.failed, error: StateError('boom')),
        ],
        const <TaskProgressState>[],
      );
      expect(cards, isEmpty);
    });

    test('仅失败的任务不产生卡片', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[
          _task(phase: TaskPhase.failed, error: StateError('boom')),
        ],
      );
      expect(cards, isEmpty);
    });

    test('ready 模块与 ready 任务均不产生卡片', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('qr', ModuleBootstrapPhase.ready, progress: 1),
          _module('llm', ModuleBootstrapPhase.absent),
        ],
        <TaskProgressState>[_task(phase: TaskPhase.ready, progress: 1)],
      );
      expect(cards, isEmpty);
    });
  });

  group('formatBytes', () {
    test('null / 0 / 负数 → null（省略体积行）', () {
      expect(formatBytes(null), isNull);
      expect(formatBytes(0), isNull);
      expect(formatBytes(-1), isNull);
    });

    test('不足 1 KiB → 整数 B', () {
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1), '1 B');
    });

    test('1024 → 1.0 KB（保留 1 位小数）', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
    });

    test('1.5 MB / GB 边界', () {
      expect(formatBytes(1572864), '1.5 MB');
      expect(formatBytes(1073741824), '1.0 GB');
      expect(formatBytes(1610612736), '1.5 GB');
    });
  });

  group('详情文案（用途 + 体积）', () {
    test('模块有体积 ⇒ 用途 · 约 X MB · 仅需一次', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('repo', ModuleBootstrapPhase.downloading,
              progress: 0.4, sizeBytes: 12897485),
        ],
        const <TaskProgressState>[],
      );

      expect(
        cards.single.detail,
        '首次使用需下载，用于 F-Droid 仓库搜索 · 约 12.3 MB · 仅需一次',
      );
      expect(cards.single.sizeBytes, 12897485);
    });

    test('模块无体积 ⇒ 仅用途说明', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('qr', ModuleBootstrapPhase.downloading, progress: 0.2),
        ],
        const <TaskProgressState>[],
      );
      expect(cards.single.detail, '首次使用需下载，用于扫描识别二维码');
    });

    test('未知模块 ⇒ 无用途也无体积时为 null（优雅降级）', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('mystery', ModuleBootstrapPhase.downloading, progress: 0.2),
        ],
        const <TaskProgressState>[],
      );
      expect(cards.single.label, 'mystery');
      expect(cards.single.detail, isNull);
    });

    test('任务详情原样透传', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[
          _task(detail: '约 15.0 MB · 仅需一次', stage: '解析入库…'),
        ],
      );
      expect(cards.single.detail, '约 15.0 MB · 仅需一次');
    });

    test('模块初始化阶段 ⇒ 动作句「下载完成，正在准备使用」', () {
      final cards = mergeBannerCards(
        <ModuleBootstrapState>[
          _module('repo', ModuleBootstrapPhase.initializing),
        ],
        const <TaskProgressState>[],
      );

      expect(cards.single.stage, '下载完成，正在准备使用');
      expect(cards.single.detail, '首次使用需下载，用于 F-Droid 仓库搜索');
    });
  });

  group('任务阶段/详情兜底（生产者未上报时）', () {
    test('任务无 stage ⇒ 通用动作句兜底，而非留空', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[_task(progress: 0.4)],
      );

      expect(cards.single.stage, '正在后台处理…');
      expect(cards.single.progress, 0.4);
    });

    test('任务有 stage ⇒ 兜底不覆盖生产者文案', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[_task(stage: '正在下载仓库索引 42%')],
      );

      expect(cards.single.stage, '正在下载仓库索引 42%');
    });

    test('任务无 detail 但有体积 ⇒ 补「约 X MB · 仅需一次」', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[_task(sizeBytes: 1572864)],
      );

      expect(cards.single.detail, '约 1.5 MB · 仅需一次');
    });

    test('任务无 detail 且无体积 ⇒ 不臆造，detail 保持 null', () {
      final cards = mergeBannerCards(
        const <ModuleBootstrapState>[],
        <TaskProgressState>[_task()],
      );

      expect(cards.single.detail, isNull);
    });
  });
}
