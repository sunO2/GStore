import 'dart:convert';
import 'dart:typed_data';

/// 图片格式。
enum ImageFormat {
  /// PNG（便携式网络图形）。
  png,

  /// JPEG（联合图像专家组）。
  jpeg,

  /// GIF（图形交换格式）。
  gif,

  /// WebP。
  webp,

  /// SVG（可缩放矢量图形）。
  svg,

  /// BMP（位图）。
  bmp,

  /// 未知格式。
  unknown,
}

/// 各格式的二进制魔数。
const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const List<int> _jpegMagic = [0xFF, 0xD8, 0xFF];
const List<int> _gifMagic = [0x47, 0x49, 0x46, 0x38]; // "GIF8"
const List<int> _riffMagic = [0x52, 0x49, 0x46, 0x46]; // "RIFF"
const List<int> _webpMagic = [0x57, 0x45, 0x42, 0x50]; // "WEBP"
const List<int> _bmpMagic = [0x42, 0x4D]; // "BM"

/// SVG 文本嗅探的字节数上限。
const int _svgPrefixLimit = 2048;

/// 检测图片格式。
///
/// 规则：
/// - [contentType] 非空且可识别时优先采用（解析分号前的纯类型，大小写不敏感）；
/// - 缺失或未知时回退到 magic bytes 嗅探；
/// - 空 bytes 或 bytes 长度不足一律返回 [ImageFormat.unknown]。
ImageFormat detectImageType({String? contentType, required Uint8List bytes}) {
  if (bytes.isEmpty) return ImageFormat.unknown;

  final format = switch (_normalizeContentType(contentType)) {
    'image/png' => ImageFormat.png,
    'image/jpeg' => ImageFormat.jpeg,
    'image/gif' => ImageFormat.gif,
    'image/webp' => ImageFormat.webp,
    'image/svg+xml' => ImageFormat.svg,
    'image/bmp' => ImageFormat.bmp,
    _ => null,
  };
  if (format != null) return format;

  return _detectByMagicBytes(bytes);
}

/// 归一化 Content-Type：取分号前的纯类型并转小写；无法解析时返回 null。
String? _normalizeContentType(String? contentType) {
  if (contentType == null) return null;
  final semi = contentType.indexOf(';');
  final type = semi == -1 ? contentType : contentType.substring(0, semi);
  return type.trim().toLowerCase();
}

/// 通过 magic bytes 嗅探格式，均不匹配时返回 [ImageFormat.unknown]。
ImageFormat _detectByMagicBytes(Uint8List bytes) {
  if (_startsWith(bytes, _pngMagic)) return ImageFormat.png;
  if (_startsWith(bytes, _jpegMagic)) return ImageFormat.jpeg;
  if (_startsWith(bytes, _gifMagic)) return ImageFormat.gif;
  if (bytes.length >= 12 &&
      _startsWith(bytes, _riffMagic) &&
      _startsWith(bytes.sublist(8), _webpMagic)) {
    return ImageFormat.webp;
  }
  if (_startsWith(bytes, _bmpMagic)) return ImageFormat.bmp;
  if (_looksLikeSvg(bytes)) return ImageFormat.svg;
  return ImageFormat.unknown;
}

/// [bytes] 是否以 [magic] 开头（长度不足时返回 false）。
bool _startsWith(Uint8List bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

/// 文本嗅探：去掉 UTF-8 BOM 与前导空白后，以 `<svg` 开头，
/// 或以 `<?xml` 开头且内容包含 `<svg` / `<!DOCTYPE svg` 视为 SVG。
bool _looksLikeSvg(Uint8List bytes) {
  var start = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    start = 3;
  }
  if (start >= bytes.length) return false;

  final end = start + _svgPrefixLimit < bytes.length
      ? start + _svgPrefixLimit
      : bytes.length;
  final prefix = latin1.decode(bytes.sublist(start, end));
  final trimmed = prefix.trimLeft();
  if (trimmed.startsWith('<svg')) return true;
  if (trimmed.startsWith('<?xml')) {
    return prefix.contains('<svg') || prefix.contains('<!DOCTYPE svg');
  }
  return false;
}
