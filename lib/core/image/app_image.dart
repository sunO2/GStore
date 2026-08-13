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
    required this.width,
    required this.height,
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

  /// 期望显示宽度。
  final double width;

  /// 期望显示高度。
  final double height;

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

    final size = resolveImageDisplaySize(
      url: widget.url,
      format: result.format,
      width: widget.width,
      height: widget.height,
      badgeHeight: widget.badgeHeight,
    );

    final Widget child = result.format == ImageFormat.svg
        ? SvgPicture(
            SvgBytesLoader(result.bytes),
            fit: widget.fit,
            alignment: widget.alignment,
            allowDrawingOutsideViewBox: widget.allowDrawingOutsideViewBox,
            errorBuilder: (c, e, s) =>
                widget.errorWidget ?? const SizedBox.shrink(),
          )
        : Image(
            image: MemoryImage(result.bytes),
            fit: widget.fit,
            alignment: widget.alignment,
            errorBuilder: (c, e, s) =>
                widget.errorWidget ?? const SizedBox.shrink(),
          );

    return SizedBox.fromSize(size: size, child: child);
  }
}
