import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_image_loader.dart';
import 'image_type_detector.dart';

/// 判断 [url] 是否为 shields.io 徽章 URL（大小写不敏感）。
bool isBadgeUrl(String url) => url.toLowerCase().contains('img.shields.io');

/// 解析图片的显示尺寸。
///
/// shields.io 徽章（SVG）高度钳制为 [badgeHeight]（默认 30），
/// 其余场景原样返回 [width] x [height]。
Size resolveImageDisplaySize({
  required String url,
  required ImageFormat format,
  required double width,
  required double height,
  double? badgeHeight,
}) {
  if (format == ImageFormat.svg && isBadgeUrl(url)) {
    return Size(width, badgeHeight ?? 30);
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

  /// shields.io 徽章的高度钳制值（为 null 时默认 30）。
  final double? badgeHeight;

  /// 加载器（测试注入），默认 [AppImageLoader.instance]。
  final AppImageLoader? loader;

  @override
  State<AppImage> createState() => _AppImageState();
}

class _AppImageState extends State<AppImage> {
  LoadedImage? _result;
  Object? _error;

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
      final result =
          await (widget.loader ?? AppImageLoader.instance).load(widget.url);
      if (!mounted) return;
      setState(() => _result = result);
      widget.onSuccess?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      widget.onError?.call(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.errorWidget,
      );
    }

    final result = _result;
    if (result == null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.placeholder,
      );
    }

    final format = result.format;
    final isBadge = format == ImageFormat.svg && isBadgeUrl(widget.url);
    // HTML 显式尺寸优先；未给时用 maxWidth/maxHeight 兜底，
    // badge SVG 未给高度时钳制到 badgeHeight（默认 30，保留现状）。
    final double effectiveWidth = widget.width ?? widget.maxWidth;
    final double effectiveHeight = widget.height ??
        (isBadge ? (widget.badgeHeight ?? 30) : widget.maxHeight);
    final size = resolveImageDisplaySize(
      url: widget.url,
      format: format,
      width: effectiveWidth,
      height: effectiveHeight,
      badgeHeight: widget.badgeHeight,
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

    // 解析后尺寸完全确定（如 HTML 显式宽高、badge 钳制）→ tight；
    // 否则 → loose 上限约束，SVG/位图按固有尺寸显示、超限等比 clamp。
    if (size.width.isFinite && size.height.isFinite) {
      return SizedBox.fromSize(size: size, child: child);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: effectiveWidth,
        maxHeight: effectiveHeight,
      ),
      child: child,
    );
  }

  /// 解码失败统一处理：首次触发时上报 [AppImage.onError]，并返回错误占位。
  void _reportDecodeError(Object error) {
    if (!_decodeErrorFired) {
      _decodeErrorFired = true;
      widget.onError?.call(error);
    }
  }
}
