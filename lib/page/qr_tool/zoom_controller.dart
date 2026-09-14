import 'dart:math' as math;

/// 单帧变焦观测（几何 + 解码证据），控制器决策的唯一输入。
class ZoomObservation {
  const ZoomObservation({
    required this.ratio,
    required this.zoom,
    required this.detected,
    required this.checksumError,
    required this.sharpness,
  });

  /// 符号四角包围盒占 ROI 面积比；<=0 表示本帧没有可用几何。
  final double ratio;

  /// 本帧生效的变焦倍率。
  final double zoom;

  /// 是否定位到符号（含不可读候选）。
  final bool detected;

  /// 是否「定位到但校验失败」——几何可信、像素质量不足。
  final bool checksumError;

  /// ROI 清晰度（相邻梯度均值）。
  final double sharpness;
}

/// 变焦动作。
enum ZoomAction {
  /// 保持当前焦段（含数据不足、未达共识、观察期内）。
  none,

  /// 放大（码太小）。
  zoomIn,

  /// 缩小（码太大）。
  zoomOut,

  /// 已到放大上限仍偏小：提示用户靠近。
  tooFar,

  /// 已到缩小下限仍偏大：提示用户拿远。
  tooClose,
}

/// 变焦决策结果。
class ZoomDecision {
  const ZoomDecision(this.action, [this.targetZoom]);

  final ZoomAction action;

  /// [ZoomAction.zoomIn] / [ZoomAction.zoomOut] 时的目标倍率。
  final double? targetZoom;

  static const ZoomDecision hold = ZoomDecision(ZoomAction.none);

  @override
  String toString() => targetZoom == null
      ? 'ZoomDecision(${action.name})'
      : 'ZoomDecision(${action.name}, target=${targetZoom!.toStringAsFixed(2)})';
}

/// 单个变焦档位的实测统计——「哪些焦段真的能解出码」的原始数据。
///
/// 这是调参依据：`decoded > 0` 的档位是已验证可用焦段；`checksumErrors` 高而
/// `decoded` 为 0 的档位说明「能定位但解析不出」，是像质（而非距离）受限。
class ZoomBucketStats {
  int frames = 0;
  int detected = 0;
  int decoded = 0;
  int checksumErrors = 0;
  double ratioSum = 0;
  double sharpnessSum = 0;

  /// 检测到符号但占比不可用（四角退化/重合）的帧数。
  /// 真机日志里高倍率档大量出现 detected=true 而 ratio≈0，需能量化这种「几何信号失效」。
  int degenerate = 0;

  /// 成功帧不计入 [frames]（命中即停止扫描，不再走逐帧观测），故分母要把它们补回来，
  /// 否则这个比值的分母只含失败帧，读起来偏高、语义也混。
  double get decodeRate {
    final total = frames + decoded;
    return total == 0 ? 0 : decoded / total;
  }

  double get detectRate => frames == 0 ? 0 : detected / frames;

  /// 有效几何帧数（检测到且占比可用）
  int get validGeomFrames => detected - degenerate;

  /// 均值只统计有效几何帧：退化帧的 ratio 记 0 会把均值稀释掉，看不出真实尺寸
  double get meanRatio =>
      validGeomFrames <= 0 ? 0 : ratioSum / validGeomFrames;

  double get meanSharpness => frames == 0 ? 0 : sharpnessSum / frames;

  Map<String, Object?> toJson() => {
        'frames': frames,
        'detected': detected,
        'decoded': decoded,
        'checksumErrors': checksumErrors,
        'degenerate': degenerate,
        'decodeRate': double.parse(decodeRate.toStringAsFixed(3)),
        'meanRatio': double.parse(meanRatio.toStringAsFixed(3)),
        'meanSharpness': double.parse(meanSharpness.toStringAsFixed(2)),
      };
}

/// 变焦学习结果的**跨实例存储**。
///
/// 控制器会随相机重建（切「生成/识别」、重进页面都会走 `_initCamera`），但
/// 「哪个焦段能解出码」是设备属性，不该跟着丢。真机日志里每轮重建都要从最小倍率
/// 重爬 ~5 步，甚至在同一个坏档位反复成功而看不到更好的档位。
///
/// 按相机名缓存，进程内共享；不落盘（换机/重启重新学习成本可接受）。
class QrZoomLearning {
  QrZoomLearning();

  /// 最近一次成功解码的倍率（重新扫描的起点）
  double? lastSuccessfulZoom;

  /// 成功解码时的占比样本（稳健统计用）
  final List<double> successfulRatios = [];

  /// 分档实测统计
  final Map<int, ZoomBucketStats> buckets = {};

  static const int maxSuccessSamples = 16;

  static final Map<String, QrZoomLearning> _byCamera = {};

  /// 取某相机的学习结果（无则新建）
  static QrZoomLearning of(String cameraKey) =>
      _byCamera.putIfAbsent(cameraKey, QrZoomLearning.new);

  /// 清空全部缓存（测试用）
  static void clearAll() => _byCamera.clear();
}

/// 数据驱动的扫码变焦控制器。
///
/// 旧实现每帧用当帧四角包围盒去比对一组固定阈值、只做 2 帧去抖，且从不检验
/// 「变焦是否真的生效、是否真的有用」。三个失效来源都会造成极限环（放大↔缩小来回跳）：
/// - 手机倾斜时四角包围盒面积骤变，单帧判据噪声直接进决策；
/// - 数字变焦/F 值收敛滞后，动作后立刻用未稳定的帧评估 → 马上反向；
/// - 步长上限 2×，一步过冲后必被反向拉回。
///
/// 本控制器把决策落在**可观测数据**上：
/// 1. 时序平滑：占比用 EMA，单帧噪声不直接触发动作；
/// 2. 共识门控：连续 [consensusFrames] 帧同向才动作，且只在检测到符号时评估；
/// 3. 静默期：动作后丢弃 [settleFrames] 帧样本，等变焦真正反映到图像；
/// 4. 步长阻尼 + 反冲验证：单步 ≤[stepMaxFactor]；动作后校验占比是否按预期变化，
///    连续两次不符即判定「变焦无效」停止放大，避免无休止空转；
/// 5. 分档统计：[buckets] 累计每个焦段的检测/解码/校验失败/清晰度，可导出调参。
class QrZoomController {
  QrZoomController({
    required double minZoom,
    required double maxZoom,
    this.digitalCap = 4.0,
    this.emaAlpha = 0.35,
    this.consensusFrames = 3,
    this.settleFrames = 3,
    this.zoomInRatio = 0.05,
    this.zoomOutRatio = 0.80,
    this.successMargin = 0.8,
    this.targetRatio = 0.12,
    this.stepMinFactor = 0.8,
    this.stepMaxFactor = 1.3,
    this.minStepDelta = 0.1,
    this.zoomGoodMinSamples = 5,
    this.zoomGoodRate = 0.15,
    QrZoomLearning? learning,
  })  : _minZoom = minZoom,
        _maxZoom = maxZoom,
        learning = learning ?? QrZoomLearning(),
        assert(consensusFrames >= 1),
        assert(settleFrames >= 0),
        assert(emaAlpha > 0 && emaAlpha <= 1),
        assert(stepMinFactor > 0 && stepMinFactor <= 1),
        assert(stepMaxFactor >= 1);

  double _minZoom;
  double _maxZoom;

  /// 平台最小倍率
  double get minZoom => _minZoom;

  /// 平台最大倍率
  double get maxZoom => _maxZoom;

  /// 按相机共享的学习结果（跨控制器实例存活）
  final QrZoomLearning learning;

  /// 相机重开时刷新变焦范围——**不重建控制器**，学习结果得以保留
  void updateZoomRange(double min, double max) {
    _minZoom = min;
    _maxZoom = max;
  }

  /// 数字变焦有效上限（CameraX 放大是裁剪+上采样，过大只会糊且无解码收益）
  final double digitalCap;

  /// 占比 EMA 平滑系数（越大越信当帧）
  final double emaAlpha;

  /// 连续同向多少帧才动作
  final int consensusFrames;

  /// 动作后丢弃多少帧样本
  final int settleFrames;

  /// 占比低于此值 → 该放大。
  ///
  /// 这是**没有实测数据时的先验**。实测（zxing-cpp，720p high 档）成功解码集中在
  /// 占比 0.013~0.069，原值 0.35 是它的 5~25 倍，会导致「明明已能解还一路放大」。
  final double zoomInRatio;

  /// 占比高于此值 → 该缩小（两者之间为滞回带，不动）
  final double zoomOutRatio;

  /// 有成功记录后，允许停手的占比 = 实测可解占比 × [successMargin]。
  ///
  /// **必须 < 1**：含义是「已经知道这个尺寸能解出码，就不该再要求更大」。
  /// 早期取了 3.0（要求达到已验证尺寸的 3 倍才停手），结果算法在刚成功两次的档位上
  /// 仍判定「占比太小」而继续放大，一路爬到数字变焦上限 4.0 并卡在 `tooFar`：
  /// 真机日志里该档位刷了 283 帧、decodeRate 仅 2%，而最好的档位（1.69，decodeRate 33%）
  /// 被它径直越过。留一点余量（<1）只是为了容忍定位抖动，不是提高门槛。
  final double successMargin;

  /// 收敛目标占比（面积 ∝ 倍率²，故按 sqrt 求步长）
  final double targetRatio;

  /// 单步倍率变化下限/上限（相对当前倍率）
  final double stepMinFactor;
  final double stepMaxFactor;

  /// 低于此倍率变化不做动作（避免每帧微动）
  final double minStepDelta;

  /// 判定「本档位够用」所需的最少观测帧数
  final int zoomGoodMinSamples;

  /// 判定「本档位够用」的解码成功率门槛。
  ///
  /// 真机两轮数据：可用档位 decodeRate 0.21~0.33，不可用档位 0.0~0.034 —— 0.15 能干净分开。
  /// 这个把关的意义是：**已经用实测证明能解的档位，不该被瞬时占比抖动带离**。
  /// 真机上 1.69 档已有 5 次成功（decodeRate 0.227），却因为占比从 0.017 抖到 0.010
  /// 被判「太小」而继续放大，白扔掉一个已验证可用的档位。
  final double zoomGoodRate;

  double get effectiveMaxZoom => math.min(maxZoom, digitalCap);

  double _emaRatio = 0;
  int _emaSamples = 0;
  int _settleLeft = 0;
  int _consensusDir = 0;
  int _consensusCount = 0;

  /// 反冲验证：上次动作方向（+1 放大 / -1 缩小，0 = 无待验证动作）与动作前占比
  int _verifyDir = 0;
  double _verifyRatioBefore = 0;
  int _verifyFailures = 0;

  /// 变焦被判定为不生效（连续两次反冲验证失败）——不再尝试放大，避免空转抖动
  bool zoomIneffective = false;

  /// 当前档位本次驻留的实测结果（换档即重置）。
  /// 按**档位**作用域而非会话：一次成功就会停止扫描、用户点「重新扫描」会重进同一档位，
  /// 若按会话清零，就永远攒不够样本、也就永远无法判定「这一档其实够用」。
  double? _visitZoom;
  int _visitFails = 0;
  int _visitSuccesses = 0;

  /// 切换档位时重置本次驻留统计
  void _ensureVisit(double zoom) {
    final cur = _visitZoom;
    if (cur == null || (zoom - cur).abs() > 0.01) {
      _visitZoom = zoom;
      _visitFails = 0;
      _visitSuccesses = 0;
    }
  }

  /// 本档位是否已被实测证明「够用」：样本够 且 成功率达标
  bool get currentLevelProvenGood {
    final total = _visitFails + _visitSuccesses;
    if (total < zoomGoodMinSamples) return false;
    return _visitSuccesses / total >= zoomGoodRate;
  }

  /// 成功占比样本（只读快照，供导出与单测）
  List<double> get successfulRatios =>
      List.unmodifiable(learning.successfulRatios);

  /// 最近一次成功解码时的倍率——作为重新扫描/下一轮的起始倍率。
  double? get lastSuccessfulZoom => learning.lastSuccessfulZoom;

  /// 分档统计：key = 量化后的倍率档（0.25 粒度）
  Map<int, ZoomBucketStats> get buckets => learning.buckets;

  /// 建议起始倍率：有实测成功记录就用它，否则用 1.0（原生视角），再夹到有效范围内。
  /// 最小倍率常 <1（超广角，实测该机为 0.67），从那里起步只会让码更小、白爬几步。
  double get preferredStartZoom =>
      (learning.lastSuccessfulZoom ?? 1.0).clamp(minZoom, effectiveMaxZoom);

  /// 实测能解出码的占比，取样本**中位数**。
  ///
  /// 为什么不用最小值：真机日志里同一轮出现过 1.0 档成功于占比 0.03、2.2 档成功于 0.003，
  /// 取最小值会被一次「极小尺寸侥幸解出」把停手线一路压到底（0.003×3=0.009），
  /// 整轮不再放大。中位数对离群值不敏感，且样本少时也比分位数稳定。
  double? get calibratedRatio {
    final samples = learning.successfulRatios;
    if (samples.isEmpty) return null;
    final sorted = [...samples]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// 当前允许停手的占比下限。
  /// 无成功记录时用先验 [zoomInRatio]；有记录时用「实测可解占比 × [successMargin]」
  /// ——数据比先验优先，且 margin < 1 保证不会越过已验证可解的尺寸继续放大。
  double get stopZoomInRatio {
    final proven = calibratedRatio;
    if (proven == null) return zoomInRatio;
    return proven * successMargin;
  }

  /// 平滑后的占比（样本不足时为 0）
  double get smoothedRatio => _emaRatio;
  int get emaSamples => _emaSamples;
  bool get hasPendingVerify => _verifyDir != 0;

  static int bucketKey(double zoom) => (zoom * 4).round();

  /// 当前占比是否落在滞回带之外（用于清/置边界引导）
  bool isOutOfBand(double ratio) =>
      ratio > 0 && (ratio < stopZoomInRatio || ratio > zoomOutRatio);

  /// 解码成功回调：记录该焦段确实解出过码，以及**成功时的占比**。
  /// 后者是控制器的标定基准之一——「实测能解的尺寸」比固定阈值可靠，但也需防离群值。
  void onDecoded(double zoom, double ratio) {
    _ensureVisit(zoom);
    _visitSuccesses++;
    buckets.putIfAbsent(bucketKey(zoom), ZoomBucketStats.new).decoded++;
    learning.lastSuccessfulZoom = zoom;
    if (ratio > 0) {
      final samples = learning.successfulRatios;
      if (samples.length >= QrZoomLearning.maxSuccessSamples) {
        samples.removeAt(0);
      }
      samples.add(ratio);
    }
    _verifyFailures = 0;
    _verifyDir = 0;
  }

  /// 单会话瞬态重置（重新扫描）：清平滑/共识/静默/反冲验证。
  /// 分档统计跨轮保留——本来就是用来跨轮调参的。
  void resetTransient() {
    _emaRatio = 0;
    _emaSamples = 0;
    _settleLeft = 0;
    _consensusDir = 0;
    _consensusCount = 0;
    _verifyDir = 0;
    _verifyRatioBefore = 0;
    _verifyFailures = 0;
    zoomIneffective = false;
  }

  /// 逐帧推进：先记录数据，再给出决策。
  ZoomDecision update(ZoomObservation o) {
    _record(o);

    // 静默期：变焦刚下发，镜头/裁剪尚未反映到图像，此间的占比无参考价值
    if (_settleLeft > 0) {
      _settleLeft--;
      return ZoomDecision.hold;
    }

    if (!o.detected || o.ratio <= 0) {
      // 无几何数据 → 不猜。清共识，避免拿过期判据动作
      _emaSamples = 0;
      _consensusDir = 0;
      _consensusCount = 0;
      return ZoomDecision.hold;
    }

    _verifyIfPending(o);
    _updateEma(o.ratio);

    final dir = _direction(_emaRatio);
    if (dir == 0) {
      _consensusDir = 0;
      _consensusCount = 0;
      return ZoomDecision.hold;
    }
    if (!_reachConsensus(dir)) return ZoomDecision.hold;

    // 本档已用实测证明够用（成功率达标）→ 不动。占比是瞬时量、噪声大，不能让它的
    // 一次抖动把我们从已验证可用的档位上赶走；若该档真的变差，失败帧会不断累积、
    // 成功率自然跌破门槛，这里就会自动放行（自校正，无需额外复位）。
    if (currentLevelProvenGood) return ZoomDecision.hold;

    return _planAction(dir, o.zoom);
  }

  void _record(ZoomObservation o) {
    _ensureVisit(o.zoom);
    _visitFails++;
    final b = buckets.putIfAbsent(bucketKey(o.zoom), ZoomBucketStats.new);
    b.frames++;
    b.sharpnessSum += o.sharpness;
    if (o.detected) {
      b.detected++;
      if (o.ratio > 0) {
        b.ratioSum += o.ratio;
      } else {
        b.degenerate++;
      }
    }
    if (o.checksumError) b.checksumErrors++;
  }

  void _updateEma(double ratio) {
    _emaRatio =
        _emaSamples == 0 ? ratio : _emaRatio * (1 - emaAlpha) + ratio * emaAlpha;
    _emaSamples++;
  }

  int _direction(double ratio) {
    // 放大侧用「实测标定后的下限」：既然这个尺寸已经解出过码，就不必再追高目标
    if (ratio < stopZoomInRatio) return 1;
    if (ratio > zoomOutRatio) return -1;
    return 0;
  }

  bool _reachConsensus(int dir) {
    if (dir == _consensusDir) {
      _consensusCount++;
    } else {
      _consensusDir = dir;
      _consensusCount = 1;
    }
    if (_consensusCount < consensusFrames) return false;
    _consensusCount = 0;
    return true;
  }

  /// 反冲验证：动作后的首个可信样本，检查占比是否按预期方向变化。
  /// 连续两次不变化 → 判定变焦不生效（平台不支持等），停止继续放大。
  void _verifyIfPending(ZoomObservation o) {
    if (_verifyDir == 0) return;
    final expected = _verifyRatioBefore;
    final moved = _verifyDir > 0
        ? o.ratio > expected * 1.1
        : o.ratio < expected * 0.9;
    _verifyFailures = moved ? 0 : _verifyFailures + 1;
    if (_verifyFailures >= 2) zoomIneffective = true;
    _verifyDir = 0;
  }

  ZoomDecision _planAction(int dir, double zoom) {
    final base = zoom > 0 ? zoom : minZoom;

    if (dir > 0) {
      // 已到上限（或变焦实测无效）：再放大没有收益，交给用户
      if (zoomIneffective || base >= effectiveMaxZoom - 0.01) {
        return const ZoomDecision(ZoomAction.tooFar);
      }
    } else if (base <= minZoom + 0.01) {
      return const ZoomDecision(ZoomAction.tooClose);
    }

    final factor = math
        .sqrt(targetRatio / _emaRatio.clamp(0.01, 1.0))
        .clamp(stepMinFactor, stepMaxFactor);
    final target = (base * factor).clamp(minZoom, effectiveMaxZoom);
    if ((target - base).abs() < minStepDelta) return ZoomDecision.hold;

    // 进入静默期并重新积累：旧样本对应的是旧倍率，已失效
    _settleLeft = settleFrames;
    _emaSamples = 0;
    _consensusDir = 0;
    _consensusCount = 0;
    _verifyDir = dir;
    _verifyRatioBefore = _emaRatio;

    return ZoomDecision(
      dir > 0 ? ZoomAction.zoomIn : ZoomAction.zoomOut,
      target,
    );
  }
}
