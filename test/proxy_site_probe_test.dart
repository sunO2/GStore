import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/proxy/proxy_site_probe.dart';

/// 脚本化假发送器：按调用序号返回响应 / 抛错，并记录并发峰值。
class _ScriptedSender implements SiteProbeSender {
  _ScriptedSender(this.handler);

  final Future<ProbeHttpResponse> Function(
    SiteProbeTarget target,
    int call,
    Duration timeout,
  ) handler;

  final List<SiteProbeTarget> calls = <SiteProbeTarget>[];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<ProbeHttpResponse> send(
    SiteProbeTarget target,
    Duration timeout,
  ) async {
    final int call = calls.length;
    calls.add(target);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      return await handler(target, call, timeout);
    } finally {
      inFlight--;
    }
  }
}

const List<SiteProbeTarget> _oneTarget = <SiteProbeTarget>[
  SiteProbeTarget(label: 'X', url: 'https://example.com/robots.txt', method: 'GET'),
];

Future<SiteProbeResult> _probeStatus(int status) async {
  final sender = _ScriptedSender(
    (target, call, timeout) async =>
        ProbeHttpResponse(statusCode: status, latencyMs: 100),
  );
  final probe = SiteProbe(
    sender: sender,
    targets: _oneTarget,
    sampleCount: 1,
    warmupCount: 0,
  );
  return (await probe.probeAll()).single;
}

void main() {
  group('catalog', () {
    test('固定清单：9 站点 + URL/方法精确', () {
      expect(kSiteProbeCatalog.length, 9);
      final Map<String, SiteProbeTarget> byLabel = <String, SiteProbeTarget>{
        for (final t in kSiteProbeCatalog) t.label: t,
      };
      expect(byLabel['Claude']!.url, 'https://claude.ai/robots.txt');
      expect(byLabel['Claude']!.method, 'GET');
      expect(byLabel['OpenAI']!.url, 'https://openai.com/robots.txt');
      expect(byLabel['OpenAI']!.method, 'GET');
      expect(byLabel['Google']!.url, 'https://www.gstatic.com/generate_204');
      expect(byLabel['Google']!.method, 'HEAD');
      expect(byLabel['YouTube']!.url, 'https://www.youtube.com/robots.txt');
      expect(byLabel['YouTube']!.method, 'GET');
      expect(byLabel['GitHub']!.url, 'https://github.com/robots.txt');
      expect(byLabel['GitHub']!.method, 'GET');
      expect(byLabel['Baidu']!.url, 'https://www.baidu.com/robots.txt');
      expect(byLabel['Baidu']!.method, 'GET');
      expect(byLabel['Cloudflare']!.url, 'https://cp.cloudflare.com/generate_204');
      expect(byLabel['Cloudflare']!.method, 'HEAD');
      expect(byLabel['Apple']!.url, 'http://captive.apple.com/hotspot-detect.html');
      expect(byLabel['Apple']!.method, 'GET');
      expect(byLabel['国内基线']!.url, 'http://connect.rom.miui.com/generate_204');
      expect(byLabel['国内基线']!.method, 'HEAD');
    });
  });

  group('verdict classification', () {
    test('2xx / 3xx -> ok', () async {
      for (final status in <int>[200, 204, 301, 302, 399]) {
        final result = await _probeStatus(status);
        expect(result.verdict, SiteProbeVerdict.ok, reason: 'status $status');
        expect(result.ok, isTrue);
        expect(result.statusCode, status);
      }
    });

    test('4xx -> restricted 且仍视为可达（403 不是死站）', () async {
      for (final status in <int>[400, 403, 404, 429, 499]) {
        final result = await _probeStatus(status);
        expect(
          result.verdict,
          SiteProbeVerdict.restricted,
          reason: 'status $status 必须可达但受限',
        );
        expect(result.reachable, isTrue);
        expect(result.statusCode, status);
      }
    });

    test('5xx -> unreachable', () async {
      for (final status in <int>[500, 502, 503]) {
        final result = await _probeStatus(status);
        expect(result.verdict, SiteProbeVerdict.unreachable, reason: '$status');
        expect(result.reachable, isFalse);
      }
    });

    test('超时 -> timeout', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async =>
            throw const ProbeTimeoutException('慢'),
      );
      final probe = SiteProbe(
        sender: sender,
        targets: _oneTarget,
        sampleCount: 1,
        warmupCount: 0,
      );
      final result = (await probe.probeAll()).single;
      expect(result.verdict, SiteProbeVerdict.timeout);
      expect(result.statusCode, isNull);
      expect(result.error, '慢');
    });

    test('传输错误 -> unreachable', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async => throw StateError('boom'),
      );
      final probe = SiteProbe(
        sender: sender,
        targets: _oneTarget,
        sampleCount: 1,
        warmupCount: 0,
      );
      final result = (await probe.probeAll()).single;
      expect(result.verdict, SiteProbeVerdict.unreachable);
      expect(result.error, contains('boom'));
    });
  });

  group('sampling + latency', () {
    test('丢弃 warmup、取测量样本中位 TTFB；默认 3+1 次发送', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async => ProbeHttpResponse(
          statusCode: 200,
          latencyMs: const <int>[999, 100, 300, 200][call],
        ),
      );
      // 默认 sampleCount=3 / warmupCount=1。
      final probe = SiteProbe(sender: sender, targets: _oneTarget);
      final result = (await probe.probeAll()).single;
      expect(sender.calls.length, 4, reason: '1 预热 + 3 测量');
      expect(result.latencyMs, 200, reason: '测量样本 [100,300,200] 的中位数');
      expect(result.verdict, SiteProbeVerdict.ok);
    });

    test('样本全失败时无延迟', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async => throw StateError('x'),
      );
      final probe = SiteProbe(sender: sender, targets: _oneTarget);
      final result = (await probe.probeAll()).single;
      expect(result.latencyMs, isNull);
      expect(sender.calls.length, 4);
    });

    test('medianOf：奇偶与空列表', () {
      expect(medianOf(const <int>[]), isNull);
      expect(medianOf(const <int>[5]), 5);
      expect(medianOf(const <int>[3, 1, 2]), 2);
      expect(medianOf(const <int>[100, 200, 300, 400]), 250);
    });
  });

  group('robustness', () {
    test('probeAll 绝不抛异常（发送器持续抛错）', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async => throw ArgumentError('nope'),
      );
      final probe = SiteProbe(sender: sender, targets: kSiteProbeCatalog);
      final results = await probe.probeAll();
      expect(results.length, kSiteProbeCatalog.length);
      expect(
        results.every((r) => r.verdict == SiteProbeVerdict.unreachable),
        isTrue,
      );
    });

    test('空清单直接返回空', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async =>
            const ProbeHttpResponse(statusCode: 200, latencyMs: 1),
      );
      final probe = SiteProbe(sender: sender, targets: const <SiteProbeTarget>[]);
      expect(await probe.probeAll(), isEmpty);
      expect(sender.calls, isEmpty);
    });

    test('并发限制：至多 3 个站点在飞', () async {
      final List<Completer<void>> gates = <Completer<void>>[];
      final sender = _ScriptedSender((target, call, timeout) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return const ProbeHttpResponse(statusCode: 200, latencyMs: 50);
      });
      final probe = SiteProbe(
        sender: sender,
        targets: kSiteProbeCatalog,
        sampleCount: 1,
        warmupCount: 0,
        maxConcurrency: 3,
      );
      final future = probe.probeAll();
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 3, reason: '首轮最多 3 个站点在飞');

      var completed = 0;
      var spins = 0;
      while (completed < kSiteProbeCatalog.length) {
        while (completed < gates.length) {
          gates[completed].complete();
          completed++;
        }
        await Future<void>.delayed(Duration.zero);
        spins++;
        if (spins > 1000) fail('并发闸门未推进');
      }
      final results = await future;
      expect(results.length, kSiteProbeCatalog.length);
      expect(sender.maxInFlight, lessThanOrEqualTo(3));
      expect(sender.maxInFlight, 3);
    });
  });

  group('probeAllStream', () {
    test('每站恰好一个事件，无遗漏/重复', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async =>
            const ProbeHttpResponse(statusCode: 200, latencyMs: 5),
      );
      final probe = SiteProbe(
        sender: sender,
        targets: kSiteProbeCatalog,
        sampleCount: 1,
        warmupCount: 0,
      );
      final results = await probe.probeAllStream().toList();
      expect(results.length, kSiteProbeCatalog.length);
      expect(
        results.map((r) => r.target.label).toSet(),
        kSiteProbeCatalog.map((t) => t.label).toSet(),
      );
    });

    test('逐站发射：首站完成即先到，不等其余（渐进）', () async {
      final gate = Completer<void>();
      final targets = <SiteProbeTarget>[
        const SiteProbeTarget(label: 'A', url: 'https://a.test/', method: 'GET'),
        const SiteProbeTarget(label: 'B', url: 'https://b.test/', method: 'GET'),
      ];
      final sender = _ScriptedSender((target, call, timeout) async {
        if (target.label == 'B') await gate.future;
        return const ProbeHttpResponse(statusCode: 200, latencyMs: 10);
      });
      final probe = SiteProbe(
        sender: sender,
        targets: targets,
        sampleCount: 1,
        warmupCount: 0,
        maxConcurrency: 2,
      );
      final List<SiteProbeResult> events = <SiteProbeResult>[];
      final first = Completer<void>();
      final done = Completer<void>();
      final sub = probe.probeAllStream().listen(
        (r) {
          events.add(r);
          if (!first.isCompleted) first.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await first.future;
      expect(events.map((e) => e.target.label).toList(), <String>['A']);
      expect(done.isCompleted, isFalse, reason: 'B 仍被门控，流不应关闭');
      expect(events.length, lessThan(targets.length));

      gate.complete();
      await done.future;
      expect(events.map((e) => e.target.label).toList(), <String>['A', 'B']);
      await sub.cancel();
    });

    test('按完成顺序发射而非清单顺序', () async {
      final gate = Completer<void>();
      final targets = <SiteProbeTarget>[
        const SiteProbeTarget(
            label: 'slow', url: 'https://slow.test/', method: 'GET'),
        const SiteProbeTarget(
            label: 'fast1', url: 'https://f1.test/', method: 'GET'),
        const SiteProbeTarget(
            label: 'fast2', url: 'https://f2.test/', method: 'GET'),
      ];
      final sender = _ScriptedSender((target, call, timeout) async {
        if (target.label == 'slow') await gate.future;
        return const ProbeHttpResponse(statusCode: 200, latencyMs: 10);
      });
      final probe = SiteProbe(
        sender: sender,
        targets: targets,
        sampleCount: 1,
        warmupCount: 0,
        maxConcurrency: 3,
      );
      final List<String> order = <String>[];
      final twoDone = Completer<void>();
      final done = Completer<void>();
      final sub = probe.probeAllStream().listen(
        (r) {
          order.add(r.target.label);
          if (order.length == 2 && !twoDone.isCompleted) twoDone.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await twoDone.future;
      expect(order, <String>['fast1', 'fast2'], reason: '慢站未完成，先发已完成的两站');
      expect(done.isCompleted, isFalse);

      gate.complete();
      await done.future;
      expect(order, <String>['fast1', 'fast2', 'slow']);
      await sub.cancel();
    });

    test('发送器持续抛错也不抛并正常关闭（逐站转判定）', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async => throw ArgumentError('nope'),
      );
      final probe = SiteProbe(sender: sender, targets: kSiteProbeCatalog);
      final results = await probe.probeAllStream().toList();
      expect(results.length, kSiteProbeCatalog.length);
      expect(
        results.every((r) => r.verdict == SiteProbeVerdict.unreachable),
        isTrue,
      );
    });

    test('空清单立即关闭为空流', () async {
      final sender = _ScriptedSender(
        (target, call, timeout) async =>
            const ProbeHttpResponse(statusCode: 200, latencyMs: 1),
      );
      final probe =
          SiteProbe(sender: sender, targets: const <SiteProbeTarget>[]);
      expect(await probe.probeAllStream().toList(), isEmpty);
      expect(sender.calls, isEmpty);
    });

    test('并发限制：至多 3 个站点在飞', () async {
      final List<Completer<void>> gates = <Completer<void>>[];
      final sender = _ScriptedSender((target, call, timeout) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return const ProbeHttpResponse(statusCode: 200, latencyMs: 50);
      });
      final probe = SiteProbe(
        sender: sender,
        targets: kSiteProbeCatalog,
        sampleCount: 1,
        warmupCount: 0,
        maxConcurrency: 3,
      );
      final List<SiteProbeResult> results = <SiteProbeResult>[];
      final done = Completer<void>();
      probe.probeAllStream().listen(
        results.add,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 3, reason: '首轮最多 3 个站点在飞');

      var completed = 0;
      var spins = 0;
      while (completed < kSiteProbeCatalog.length) {
        while (completed < gates.length) {
          gates[completed].complete();
          completed++;
        }
        await Future<void>.delayed(Duration.zero);
        spins++;
        if (spins > 1000) fail('并发闸门未推进');
      }
      await done.future;
      expect(results.length, kSiteProbeCatalog.length);
      expect(sender.maxInFlight, lessThanOrEqualTo(3));
      expect(sender.maxInFlight, 3);
    });

    test('取消订阅后不再发射且不抛错', () async {
      final gate = Completer<void>();
      final sender = _ScriptedSender((target, call, timeout) async {
        await gate.future;
        return const ProbeHttpResponse(statusCode: 200, latencyMs: 1);
      });
      final probe = SiteProbe(
        sender: sender,
        targets: kSiteProbeCatalog,
        sampleCount: 1,
        warmupCount: 0,
      );
      final List<SiteProbeResult> events = <SiteProbeResult>[];
      final sub = probe.probeAllStream().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });
  });

  group('defaults', () {
    test('默认参数', () {
      final probe = SiteProbe();
      expect(probe.sampleCount, 3);
      expect(probe.warmupCount, 1);
      expect(probe.timeout, const Duration(seconds: 8));
      expect(probe.maxConcurrency, 3);
      expect(probe.targets.length, kSiteProbeCatalog.length);
    });
  });
}
