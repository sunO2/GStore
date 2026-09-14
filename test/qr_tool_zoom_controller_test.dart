import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/qr_tool/zoom_controller.dart';

/// 变焦控制器单元测试。
///
/// 这块此前零覆盖，而历史上已被反复打补丁（变焦跳变 / 单码眼死循环放大 / 对焦变焦耦合）。
/// 用单测把「什么样的输入流不该触发动作」「什么时候才该动」「动多大」钉死，
/// 避免后续再引入极限环。
///
/// 注意：逻辑测试**显式传入阈值**，不用默认值——默认值会随真机实测标定而变化，
/// 不该把「平滑/共识/静默」这类逻辑语义带偏。默认值本身另有一组测试盯住。
void main() {
  /// 逻辑测试用控制器：阈值固定在旧的一档，保证断言不受标定变化影响
  QrZoomController ctrl({
    double minZoom = 1,
    double maxZoom = 8,
    double digitalCap = 4.0,
    double emaAlpha = 0.35,
    int consensusFrames = 3,
    int settleFrames = 3,
    double zoomInRatio = 0.35,
    double zoomOutRatio = 0.80,
    double targetRatio = 0.55,
    double successMargin = 3.0,
  }) {
    return QrZoomController(
      minZoom: minZoom,
      maxZoom: maxZoom,
      digitalCap: digitalCap,
      emaAlpha: emaAlpha,
      consensusFrames: consensusFrames,
      settleFrames: settleFrames,
      zoomInRatio: zoomInRatio,
      zoomOutRatio: zoomOutRatio,
      targetRatio: targetRatio,
      successMargin: successMargin,
    );
  }

  ZoomDecision feed(
    QrZoomController c, {
    required double ratio,
    double zoom = 1,
    bool detected = true,
    bool checksumError = false,
    double sharpness = 12,
  }) {
    return c.update(ZoomObservation(
      ratio: ratio,
      zoom: zoom,
      detected: detected,
      checksumError: checksumError,
      sharpness: sharpness,
    ));
  }

  group('时序平滑（EMA）', () {
    test('交替噪声不在滞回带内来回触发动作', () {
      final zc = ctrl();
      // 0.30（偏小）/ 0.85（偏大）交替：单帧判据会反复翻向，EMA 应把它稳在中带
      for (var i = 0; i < 20; i++) {
        final d = feed(zc, ratio: i.isEven ? 0.30 : 0.85);
        expect(d.action, ZoomAction.none,
            reason: '第 $i 帧不应因单帧噪声触发变焦');
      }
      expect(zc.smoothedRatio, greaterThan(0.35));
      expect(zc.smoothedRatio, lessThan(0.80));
    });

    test('平滑值是滑动平均而非直接取值', () {
      final zc = ctrl(emaAlpha: 0.35);
      feed(zc, ratio: 0.10);
      expect(zc.smoothedRatio, closeTo(0.10, 1e-9));
      feed(zc, ratio: 0.90);
      // 0.10*0.65 + 0.90*0.35 = 0.38
      expect(zc.smoothedRatio, closeTo(0.38, 1e-9));
    });
  });

  group('共识门控', () {
    test('未达连续帧数不动作，达到才动作', () {
      final zc = ctrl(consensusFrames: 3, settleFrames: 0);
      expect(feed(zc, ratio: 0.20).action, ZoomAction.none);
      expect(feed(zc, ratio: 0.20).action, ZoomAction.none);
      expect(feed(zc, ratio: 0.20).action, ZoomAction.zoomIn);
    });

    test('方向翻转会重置共识计数', () {
      final zc = ctrl(consensusFrames: 3, settleFrames: 0);
      feed(zc, ratio: 0.20);
      feed(zc, ratio: 0.20);
      // 第三帧方向相反 → 计数从 1 重来，而不是累计到 3
      expect(feed(zc, ratio: 0.95).action, ZoomAction.none);
      expect(zc.smoothedRatio, lessThan(0.80));
    });

    test('无检测帧不动作，并清空共识', () {
      final zc = ctrl(consensusFrames: 2, settleFrames: 0);
      feed(zc, ratio: 0.20);
      expect(feed(zc, ratio: 0, detected: false).action, ZoomAction.none);
      // 共识被清空：单帧不再触发
      expect(feed(zc, ratio: 0.20).action, ZoomAction.none);
      expect(feed(zc, ratio: 0.20).action, ZoomAction.zoomIn);
    });
  });

  group('动作后静默期', () {
    test('变焦后丢弃若干帧样本再评估', () {
      final zc = ctrl(consensusFrames: 1, settleFrames: 3);
      expect(feed(zc, ratio: 0.20).action, ZoomAction.zoomIn);
      // 静默期内即使占比仍然超界也不动作
      expect(feed(zc, ratio: 0.20, zoom: 1.3).action, ZoomAction.none);
      expect(feed(zc, ratio: 0.20, zoom: 1.3).action, ZoomAction.none);
      expect(feed(zc, ratio: 0.20, zoom: 1.3).action, ZoomAction.none);
      // 静默期结束：重新积累后允许动作
      expect(feed(zc, ratio: 0.20, zoom: 1.3).action, ZoomAction.zoomIn);
    });
  });

  group('步长阻尼', () {
    test('放大单步不超过上限倍率', () {
      final zc = ctrl(consensusFrames: 1, settleFrames: 0);
      // 理论需求 sqrt(0.55/0.10)≈2.35，被 clamp 到 1.3
      final d = feed(zc, ratio: 0.10);
      expect(d.action, ZoomAction.zoomIn);
      expect(d.targetZoom, closeTo(1.3, 1e-9));
    });

    test('缩小单步不低于下限倍率', () {
      final zc = ctrl(consensusFrames: 1, settleFrames: 0);
      // 理论需求 sqrt(0.55/0.95)≈0.76，被 clamp 到 0.8
      final d = feed(zc, ratio: 0.95, zoom: 4);
      expect(d.action, ZoomAction.zoomOut);
      expect(d.targetZoom, closeTo(3.2, 1e-9));
    });

    test('目标倍率被 clamp 在数字变焦上限内', () {
      final zc = ctrl(maxZoom: 8, digitalCap: 4);
      expect(zc.effectiveMaxZoom, 4);
    });
  });

  group('边界引导', () {
    test('已到放大上限仍偏小 → 提示靠近', () {
      final zc = ctrl(digitalCap: 2, consensusFrames: 1);
      expect(feed(zc, ratio: 0.20, zoom: 2).action, ZoomAction.tooFar);
    });

    test('已在最小倍率仍偏大 → 提示拿远', () {
      final zc = ctrl(consensusFrames: 1);
      expect(feed(zc, ratio: 0.95, zoom: 1).action, ZoomAction.tooClose);
    });
  });

  group('反冲验证（用数据判断变焦是否真的生效）', () {
    test('连续两次占比未按预期变化 → 判定变焦无效并停止放大', () {
      final zc = ctrl(consensusFrames: 1, settleFrames: 1);

      // 第一次动作
      expect(feed(zc, ratio: 0.20).action, ZoomAction.zoomIn);
      feed(zc, ratio: 0.20, zoom: 1.3); // 静默期
      // 动作后占比完全没变（放大未生效）
      expect(feed(zc, ratio: 0.20, zoom: 1.3).action, ZoomAction.zoomIn);
      expect(zc.zoomIneffective, isFalse);

      feed(zc, ratio: 0.20, zoom: 1.6); // 静默期
      // 第二次仍未变化 → 判定无效，改为引导用户靠近而非继续放大
      final d = feed(zc, ratio: 0.20, zoom: 1.6);
      expect(zc.zoomIneffective, isTrue);
      expect(d.action, ZoomAction.tooFar);
    });

    test('占比按预期变化则维持可用状态', () {
      final zc = ctrl(consensusFrames: 1, settleFrames: 1);
      feed(zc, ratio: 0.20);
      feed(zc, ratio: 0.20, zoom: 1.3); // 静默期
      // 放大后占比确实变大 → 变焦有效
      feed(zc, ratio: 0.34, zoom: 1.3);
      expect(zc.zoomIneffective, isFalse);
    });
  });

  group('分档实测统计', () {
    test('按焦段累计检测/解码/校验失败/清晰度', () {
      final zc = ctrl();
      feed(zc, ratio: 0.50, zoom: 2, sharpness: 8);
      feed(zc, ratio: 0.50, zoom: 2, checksumError: true, sharpness: 12);
      zc.onDecoded(2, 0.50);

      final b = zc.buckets[QrZoomController.bucketKey(2)]!;
      expect(b.frames, 2);
      expect(b.detected, 2);
      expect(b.checksumErrors, 1);
      expect(b.decoded, 1);
      expect(b.meanRatio, closeTo(0.50, 1e-9));
      expect(b.meanSharpness, closeTo(10, 1e-9));
      // 成功帧不在 frames 里，分母补上：1/(2+1)
      expect(b.decodeRate, closeTo(1 / 3, 1e-9));
    });

    test('检测到但占比不可用 → 记 degenerate（几何信号失效）', () {
      final zc = ctrl();
      feed(zc, ratio: 0.50, zoom: 2);
      feed(zc, ratio: 0, zoom: 2);
      final b = zc.buckets[QrZoomController.bucketKey(2)]!;
      expect(b.detected, 2);
      expect(b.degenerate, 1);
      expect(b.meanRatio, closeTo(0.50, 1e-9), reason: '退化帧不参与占比均值');
    });

    test('不同焦段分别归档', () {
      final zc = ctrl();
      feed(zc, ratio: 0.30, zoom: 1);
      feed(zc, ratio: 0.60, zoom: 2);
      expect(zc.buckets[QrZoomController.bucketKey(1)]!.frames, 1);
      expect(zc.buckets[QrZoomController.bucketKey(2)]!.frames, 1);
    });

    test('resetTransient 清瞬态但保留统计（跨轮调参要用）', () {
      final zc = ctrl(consensusFrames: 1, settleFrames: 0);
      feed(zc, ratio: 0.20);
      zc.onDecoded(1, 0.20);
      expect(zc.buckets[QrZoomController.bucketKey(1)]!.decoded, 1);

      zc.resetTransient();
      expect(zc.smoothedRatio, 0);
      expect(zc.emaSamples, 0);
      expect(zc.zoomIneffective, isFalse);
      expect(zc.buckets[QrZoomController.bucketKey(1)]!.decoded, 1,
          reason: '分档统计应跨轮保留');
    });
  });

  group('滞回带判定', () {
    test('isOutOfBand 只对有效占比判定', () {
      final zc = ctrl();
      expect(zc.isOutOfBand(0.20), isTrue);
      expect(zc.isOutOfBand(0.95), isTrue);
      expect(zc.isOutOfBand(0.50), isFalse);
      expect(zc.isOutOfBand(0), isFalse);
    });
  });

  group('实测标定（真机数据驱动）', () {
    // 真机日志：成功解码发生在占比 0.013~0.069；原先验 0.35 高了 5~25 倍，
    // 导致「明明已经能解」还在往上爬。默认值据此下调。
    test('默认放大阈值与目标占比已按实测下调', () {
      final zc = QrZoomController(minZoom: 0.67, maxZoom: 4);
      expect(zc.zoomInRatio, 0.05);
      expect(zc.targetRatio, 0.12);
      // 缩小侧没有实测数据，不擅自改动
      expect(zc.zoomOutRatio, 0.80);
    });

    test('无实测记录时，占比 0.04 仍会放大（先验生效）', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      expect(feed(zc, ratio: 0.04, zoom: 0.87).action, ZoomAction.zoomIn);
    });

    test('一旦实测在 0.01 解出过码，占比 0.04 就不再追高', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      zc.onDecoded(0.87, 0.01);
      // 停手线 = 实测可解占比 × margin(0.8) = 0.008
      expect(zc.stopZoomInRatio, closeTo(0.008, 1e-9));
      expect(feed(zc, ratio: 0.04, zoom: 0.87).action, ZoomAction.none,
          reason: '这个尺寸已经能解出码，不该继续爬向拍脑袋的目标');
    });

    test('实测占比取中位数，不被单次极小尺寸带偏', () {
      final zc = QrZoomController(minZoom: 1, maxZoom: 8);
      zc.onDecoded(2, 0.05);
      zc.onDecoded(2, 0.05);
      zc.onDecoded(2, 0.05);
      expect(zc.calibratedRatio, closeTo(0.05, 1e-9));
      // 一次「极小尺寸侥幸解出」不应把停手线一路压到底（取最小值时会压到 0.009）
      zc.onDecoded(1.5, 0.003);
      expect(zc.calibratedRatio, closeTo(0.05, 1e-9));
      expect(zc.stopZoomInRatio, closeTo(0.04, 1e-9));
    });

    test('成功占比样本有上限，早期样本不会永远压着当前状态', () {
      final zc = QrZoomController(minZoom: 1, maxZoom: 8);
      for (var i = 0; i < QrZoomLearning.maxSuccessSamples + 5; i++) {
        zc.onDecoded(2, 0.02);
      }
      expect(zc.successfulRatios.length, QrZoomLearning.maxSuccessSamples);
    });

    test('margin<1：刚成功过的尺寸不会再被判定为「太小」而继续放大', () {
      // 真机回归：1.69 档成功两次（占比 0.012/0.013），当时停手线被算成 0.013×3=0.039，
      // 于是算法认为 0.012「还太小」，径直爬到数字变焦上限 4.0 卡死（decodeRate 仅 2%）。
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      zc.onDecoded(1.69, 0.012);
      zc.onDecoded(1.69, 0.013);
      expect(zc.stopZoomInRatio, lessThan(0.013),
          reason: '停手线必须落在已验证尺寸之下，否则等于逼它继续爬');
      expect(feed(zc, ratio: 0.012, zoom: 1.69).action, ZoomAction.none,
          reason: '这个尺寸已经解出过码，不该再触发放大');
    });

    test('本档已被实测证明够用 → 不被瞬时占比抖动带离（真机回归）', () {
      // 真机：1.69 档已有 5 次成功（decodeRate 0.227），占比从 0.017 抖到 0.010 时
      // 仍被判「太小」而继续放大到 2.2/2.86，白扔一个已验证可用的档位。
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      for (var i = 0; i < 15; i++) {
        expect(feed(zc, ratio: 0.06, zoom: 1.69).action, ZoomAction.none);
      }
      for (var i = 0; i < 5; i++) {
        zc.onDecoded(1.69, 0.017);
      }
      expect(zc.currentLevelProvenGood, isTrue);
      // 停手线 0.017×0.8=0.0136，占比 0.004 本会触发放大 —— 由实测证据拦下
      expect(feed(zc, ratio: 0.004, zoom: 1.69).action, ZoomAction.none);
    });

    test('档位实测不达标时仍会继续放大（把关没有过头）', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      // 占比小幅波动：让「反冲验证」看到变焦确实生效，否则会被判变焦无效转 tooFar
      for (var i = 0; i < 20; i++) {
        feed(zc, ratio: i.isEven ? 0.004 : 0.006, zoom: 1.69);
      }
      zc.onDecoded(1.69, 0.017); // 1/(20+1)=0.048，远不到 0.15
      expect(zc.currentLevelProvenGood, isFalse);
      expect(zc.zoomIneffective, isFalse);
      expect(feed(zc, ratio: 0.004, zoom: 1.69).action, ZoomAction.zoomIn);
    });

    test('档位变差时把关自动放开（不需要额外复位）', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      for (var i = 0; i < 15; i++) {
        feed(zc, ratio: 0.06, zoom: 1.69);
      }
      for (var i = 0; i < 5; i++) {
        zc.onDecoded(1.69, 0.017);
      }
      expect(zc.currentLevelProvenGood, isTrue);
      // 之后一直解不出：5/(20+20)=0.125 < 0.15 → 放行
      for (var i = 0; i < 20; i++) {
        feed(zc, ratio: i.isEven ? 0.004 : 0.006, zoom: 1.69);
      }
      expect(zc.currentLevelProvenGood, isFalse);
      expect(feed(zc, ratio: 0.004, zoom: 1.69).action, ZoomAction.zoomIn);
    });

    test('换档位会重置本次驻留统计（不同档位的证据不混用）', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      for (var i = 0; i < 4; i++) {
        feed(zc, ratio: 0.06, zoom: 1.69);
      }
      zc.onDecoded(1.69, 0.017);
      expect(zc.currentLevelProvenGood, isTrue,
          reason: '4 帧失败 + 1 次成功 = 样本 5、成功率 0.2 ≥ 0.15，判定够用');
      // 换到 2.2 档：前面的证据不能算在它头上
      feed(zc, ratio: 0.004, zoom: 2.2);
      expect(zc.currentLevelProvenGood, isFalse);
    });

    test('学习结果跨控制器实例共享（切模式/重进页面不丢）', () {
      final shared = QrZoomLearning();
      final first = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0,
          learning: shared);
      first.onDecoded(2.86, 0.023);

      final second = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0,
          learning: shared);
      expect(second.lastSuccessfulZoom, 2.86);
      expect(second.preferredStartZoom, closeTo(2.86, 1e-9));
      expect(second.calibratedRatio, 0.023);
      expect(second.buckets[QrZoomController.bucketKey(2.86)]!.decoded, 1);
    });

    test('QrZoomLearning.of 按相机名复用同一份学习结果', () {
      QrZoomLearning.clearAll();
      addTearDown(QrZoomLearning.clearAll);
      expect(QrZoomLearning.of('cam-a'), same(QrZoomLearning.of('cam-a')));
      expect(QrZoomLearning.of('cam-a'), isNot(same(QrZoomLearning.of('cam-b'))));
    });

    test('updateZoomRange 刷新范围但保留学习结果', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      zc.onDecoded(2.86, 0.023);
      zc.updateZoomRange(1.0, 8.0);
      expect(zc.minZoom, 1.0);
      expect(zc.maxZoom, 8.0);
      expect(zc.lastSuccessfulZoom, 2.86);
    });

    test('起始倍率：无记录用 1.0，不用可能 <1 的超广角最小倍率', () {
      final zc = QrZoomController(minZoom: 0.67, maxZoom: 4);
      expect(zc.preferredStartZoom, 1.0);
    });

    test('起始倍率：有成功记录则回到该倍率，并夹在有效范围内', () {
      final zc = QrZoomController(minZoom: 0.67, maxZoom: 4);
      zc.onDecoded(1.13, 0.02);
      expect(zc.preferredStartZoom, closeTo(1.13, 1e-9));
      zc.onDecoded(0.5, 0.02); // 低于 minZoom
      expect(zc.preferredStartZoom, 0.67);
      zc.onDecoded(9, 0.02); // 高于 maxZoom
      expect(zc.preferredStartZoom, 4);
    });

    test('resetTransient 不清除实测学习结果（跨轮复用）', () {
      final zc = QrZoomController(
          minZoom: 0.67, maxZoom: 4, consensusFrames: 1, settleFrames: 0);
      zc.onDecoded(1.13, 0.02);
      zc.resetTransient();
      expect(zc.calibratedRatio, 0.02);
      expect(zc.lastSuccessfulZoom, 1.13);
      expect(zc.preferredStartZoom, closeTo(1.13, 1e-9));
    });
  });
}
