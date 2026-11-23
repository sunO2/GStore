import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_image_loader.dart';
import 'bitmap_size_reader.dart';
import 'image_type_detector.dart';
import 'svg_intrinsic_size.dart';
import 'svg_text_scale_fix.dart';

/// 常见徽章服务域名/路径（大小写不敏感）。
///
/// 除 shields.io 外，README 里还常见 fury/badgen/codecov/travis/github workflow
/// 等 SVG 徽章；它们同样是"固定小尺寸、应等比缩放"的图。
const List<String> _badgeHosts = [
  'img.shields.io',
  'badge.fury.io',
  'badgen.net',
  'flat.badgen.net',
  'img.badgesize.io',
  'badge.buildkite.com',
  'codecov.io/',
  'coveralls.io/',
  'api.codacy.com/project/badge',
  'travis-ci.org/',
  'travis-ci.com/',
  'ci.appveyor.com/api/projects/status',
  'github.com/',
  'gitlab.com/',
];

/// 徽章默认显示高度（逻辑像素）。
///
/// shields 徽章固有高度 20；30 在手机上偏大，18（约 3/5）阅读更紧凑，
/// 仍能看清文字。调用方可用 `badgeHeight` 覆盖。
const double kDefaultBadgeHeight = 18;

/// 判断 [url] 是否为徽章 URL（大小写不敏感）。
///
/// `github.com/` 仅匹配 `/badge.svg` / `/workflows/.../badge.svg` 这类路径，
/// 避免把普通仓库图片当徽章。
bool isBadgeUrl(String url) {
  final lower = url.toLowerCase();
  for (final host in _badgeHosts) {
    if (!lower.contains(host)) continue;
    if (host == 'github.com/' || host == 'gitlab.com/') {
      return lower.contains('/badge.svg') ||
          lower.contains('/badges/') ||
          lower.contains('/workflows/');
    }
    return true;
  }
  return false;
}

/// 解析图片的显示尺寸。
///
/// shields.io 徽章（SVG）高度钳制为 [badgeHeight]（默认 [kDefaultBadgeHeight] = 18），
/// 其余场景原样返回 [width] x [height]。
Size resolveImageDisplaySize({
  required String url,
  required ImageFormat format,
  required double width,
  required double height,
  double? badgeHeight,
}) {
  if (format == ImageFormat.svg && isBadgeUrl(url)) {
    return Size(width, badgeHeight ?? kDefaultBadgeHeight);
  }
  return Size(width, height);
}

/// 通用图片组件：经 [AppImageLoader] 下载/缓存字节后按格式渲染。
///
/// - SVG → [SvgPicture]（[SvgBytesLoader]）；
/// - 其他格式（含 unknown）→ [Image]（[MemoryImage]），解码失败走 errorBuilder；
/// - 加载中显示 [placeholder]，加载失败显示 [errorWidget]。
class AppImage extends StatefulWidget {
  const AppImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.maxWidth = double.infinity,
    this.maxHeight = double.infinity,
    this.placeholder,
    this.errorWidget,
    this.onSuccess,
    this.onError,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.allowDrawingOutsideViewBox = false,
    this.badgeHeight,
    this.loader,
    this.hideOnLoading = false,
    this.hideOnError = false,
  });

  /// 已代理的最终下载 URL。
  final String url;

  /// HTML 指定宽度（可选）；为 null 时由 [maxWidth] 兜底。
  final double? width;

  /// HTML 指定高度（可选）；为 null 时由 [maxHeight] 兜底（badge SVG 则钳制 [badgeHeight]）。
  final double? height;

  /// 无显式宽度时的宽度上限。
  final double maxWidth;

  /// 无显式高度时的高度上限。
  final double maxHeight;

  /// 加载完成前显示的占位组件。
  final Widget? placeholder;

  /// 加载失败（下载/解码失败）时显示的组件。
  final Widget? errorWidget;

  /// 加载成功回调（触发一次）。
  final VoidCallback? onSuccess;

  /// 加载失败回调（触发一次），参数为异常对象。
  final void Function(Object error)? onError;

  /// 图片适应方式。
  final BoxFit fit;

  /// 图片对齐方式。
  final Alignment alignment;

  /// SVG 是否允许绘制超出 viewBox。
  final bool allowDrawingOutsideViewBox;

  /// shields.io 徽章的高度钳制值（为 null 时用 [kDefaultBadgeHeight] = 18）。
  final double? badgeHeight;

  /// 加载器（测试注入），默认 [AppImageLoader.instance]。
  final AppImageLoader? loader;

  /// 加载中是否隐藏占位（渲染 [SizedBox.shrink]，默认 false 显示 [placeholder]）。
  final bool hideOnLoading;

  /// 加载失败是否隐藏错误占位（渲染 [SizedBox.shrink]，
  /// 默认 false 显示 [errorWidget]；[onError] 回调不受影响）。
  final bool hideOnError;

  @override
  State<AppImage> createState() => _AppImageState();
}

class _AppImageState extends State<AppImage> {
  LoadedImage? _result;
  Object? _error;

  /// 图片固有尺寸（SVG 根标签 width/height/viewBox 或位图 ImageDescriptor），
  /// 仅在 HTML 未给出显式宽高时提取，用于等比补维 / tight clamp 显示。
  double? _intrinsicW;
  double? _intrinsicH;

  /// 解码失败是否已上报（errorBuilder 可能在多次 build 中重复触发，
  /// 守卫保证 onError 只触发一次；与 _load 下载失败路径互不干扰）。
  bool _decodeErrorFired = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var result =
          await (widget.loader ?? AppImageLoader.instance).load(widget.url);
      if (!mounted) return;
      // vector_graphics 对「文本 + 等比缩放组」会丢字号缩放（徽章文字巨大）：
      // 渲染前做一次字符串级修正，坐标仍由编译器折算。
      if (result.format == ImageFormat.svg) {
        final fixed = fixSvgTextScaleBytes(result.bytes);
        if (!identical(fixed, result.bytes)) {
          result = LoadedImage(
            url: result.url,
            bytes: fixed,
            format: result.format,
          );
        }
      }
      setState(() => _result = result);
      widget.onSuccess?.call();
      // 无 HTML 显式宽高 → 提取固有尺寸（SVG 同步文本解析，位图异步 ImageDescriptor）。
      // 先渲染（loose）后收紧（tight），位图固有尺寸读取失败/慢时不影响展示。
      if (widget.width == null || widget.height == null) {
        final intrinsic = await _readIntrinsicSize(result);
        if (!mounted || intrinsic == null) return;
        setState(() {
          _intrinsicW = intrinsic.width;
          _intrinsicH = intrinsic.height;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      widget.onError?.call(e);
    }
  }

  /// 按格式读取固有尺寸：SVG → 文本解析；其他 → 位图 ImageDescriptor。
  Future<({double width, double height})?> _readIntrinsicSize(
      LoadedImage result) async {
    if (result.format == ImageFormat.svg) {
      return parseSvgIntrinsicSize(result.bytes);
    }
    return readBitmapSize(result.bytes);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      if (widget.hideOnError) return const SizedBox.shrink();
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.errorWidget,
      );
    }

    final result = _result;
    if (result == null) {
      if (widget.hideOnLoading) return const SizedBox.shrink();
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.placeholder,
      );
    }

    final format = result.format;
    final isBadge = format == ImageFormat.svg && isBadgeUrl(widget.url);
    // HTML 显式尺寸 / badge 钳制 / 固有尺寸等比 clamp → tight；
    // 否则 → loose 上限约束，SVG/位图按固有尺寸显示、超限等比 clamp。
    final size = _computeDisplaySize(
      result,
      maxWidth: widget.maxWidth,
      maxHeight: widget.maxHeight,
    );

    final Widget child = format == ImageFormat.svg
        ? SvgPicture(
            SvgBytesLoader(result.bytes),
            fit: widget.fit,
            alignment: widget.alignment,
            allowDrawingOutsideViewBox: widget.allowDrawingOutsideViewBox,
            errorBuilder: (c, e, s) {
              _reportDecodeError(e);
              return widget.errorWidget ?? const SizedBox.shrink();
            },
          )
        : Image(
            image: MemoryImage(result.bytes),
            fit: widget.fit,
            alignment: widget.alignment,
            errorBuilder: (c, e, s) {
              _reportDecodeError(e);
              return widget.errorWidget ?? const SizedBox.shrink();
            },
          );

    debugPrint('AppImage: url=${widget.url} format=$format badge=$isBadge '
        'intrinsic=${_intrinsicW}x$_intrinsicH -> size=$size '
        '(box=${widget.maxWidth}x${widget.maxHeight})');
    // 解析后尺寸完全确定（如 HTML 显式宽高、badge 钳制、固有尺寸 clamp）→ tight；
    // 否则 → loose 上限约束（现有 fallback）。
    if (size != null && size.width.isFinite && size.height.isFinite) {
      return SizedBox.fromSize(size: size, child: child);
    }
    // loose 兜底：badge SVG 未给高度时钳制到 badgeHeight（默认 18）。
    final double effectiveWidth = widget.width ?? widget.maxWidth;
    final double effectiveHeight = widget.height ??
        (isBadge ? (widget.badgeHeight ?? kDefaultBadgeHeight) : widget.maxHeight);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: effectiveWidth,
        maxHeight: effectiveHeight,
      ),
      child: child,
    );
  }

  /// 计算显示尺寸（null 表示无法确定，走 loose 兜底）。
  ///
  /// 优先级：
  /// 1. HTML width&&height → [resolveImageDisplaySize]（badge 钳制保留，intrinsic 不参与）；
  /// 2. 仅 width → intrinsic 等比补高（clamp ≤ maxHeight）；无 intrinsic → maxHeight 兜底；
  /// 3. 仅 height → 对称补宽；
  /// 4. 都无 + intrinsic → tight clamp 不放大：scale=min(1, maxW/iw, maxH/ih)；
  /// 5. 都无 + 无 intrinsic → null（loose fallback）。
  /// badge SVG 一律保持现状（高度钳制 badgeHeight，intrinsic 不参与）。
  Size? _computeDisplaySize(
    LoadedImage result, {
    required double maxWidth,
    required double maxHeight,
  }) {
    final width = widget.width;
    final height = widget.height;
    final format = result.format;
    final isBadge = format == ImageFormat.svg && isBadgeUrl(widget.url);
    final intrinsicW = _intrinsicW;
    final intrinsicH = _intrinsicH;
    final hasIntrinsic = intrinsicW != null &&
        intrinsicH != null &&
        intrinsicW > 0 &&
        intrinsicH > 0;

    // 1) HTML 显式宽高 → 保留既有 badge 钳制，但**必须收敛到显示区**；
    //    否则超宽盒子会被父级裁剪，看起来像"放大后只露出一块"。
    if (width != null && height != null) {
      final resolved = resolveImageDisplaySize(
        url: widget.url,
        format: format,
        width: width,
        height: height,
        badgeHeight: widget.badgeHeight,
      );
      var w = resolved.width;
      var h = resolved.height;
      if (isBadge) {
        // 徽章：高度钳制优先（宽度保留但收敛）
        w = math.min(w, maxWidth);
        h = math.min(h, maxHeight);
      } else {
        // 普通图片：超限时等比缩放，避免"超宽盒子被父级裁掉一块"
        final scale = math.min(
          1.0,
          math.min(maxWidth / w, maxHeight / h),
        );
        w = w * scale;
        h = h * scale;
      }
      if (w > 0 && h > 0) return Size(w, h);
    }

    // 2) badge：高度一律钳制（显式 width 保留，但收敛到 maxWidth）；
    //    没有显式宽度时按固有宽高比算宽（不再铺满整行），超宽再等比缩。
    //    这样徽章会自然并排，不会被父级裁剪成"一块"。
    if (isBadge) {
      final h = math.min(widget.badgeHeight ?? kDefaultBadgeHeight, maxHeight);
      double? w;
      if (width != null && width > 0) {
        w = math.min(width, maxWidth);
      } else if (hasIntrinsic) {
        w = intrinsicW * h / intrinsicH;
        if (w > maxWidth) {
          w = maxWidth;
        }
      } else {
        w = math.min(maxWidth, 200);
      }
      final hh = (hasIntrinsic && width == null)
          ? math.min(h, w * intrinsicH / intrinsicW)
          : h;
      if (w > 0 && hh > 0) return Size(w, hh);
      return Size(math.min(maxWidth, 200), h);
    }

    // 3) 仅 width → intrinsic 等比补高（clamp ≤ maxHeight）。
    if (width != null) {
      final w = math.min(width, maxWidth);
      final h = hasIntrinsic
          ? math.min(w * intrinsicH / intrinsicW, maxHeight)
          : maxHeight;
      return Size(w, h);
    }

    // 4) 仅 height → 对称补宽。
    if (height != null) {
      final h = math.min(height, maxHeight);
      final w = hasIntrinsic
          ? math.min(h * intrinsicW / intrinsicH, maxWidth)
          : maxWidth;
      return Size(w, h);
    }

    // 5) 都无 + intrinsic → tight clamp 不放大。
    if (hasIntrinsic) {
      final scale = math.min(
        1.0,
        math.min(maxWidth / intrinsicW, maxHeight / intrinsicH),
      );
      return Size(intrinsicW * scale, intrinsicH * scale);
    }

    // 6) 都无 + 无 intrinsic → null（loose fallback）。
    return null;
  }

  /// 解码失败统一处理：首次触发时上报 [AppImage.onError]，并返回错误占位。
  void _reportDecodeError(Object error) {
    if (!_decodeErrorFired) {
      _decodeErrorFired = true;
      widget.onError?.call(error);
    }
  }
}
