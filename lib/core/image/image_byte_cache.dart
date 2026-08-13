import 'dart:collection';
import 'dart:typed_data';

/// 图片字节 LRU 内存缓存。
///
/// 基于 [LinkedHashMap]（插入序）手写 LRU：读取/更新命中项时会先移除再重新
/// 插入，使其移动到 MRU 位置；超出 [maximumEntries] 时淘汰最久未使用（最旧）项。
///
/// [maximumEntries] <= 0 时，缓存不持有任何条目（[length] 恒为 0，
/// [get] 永远返回 null），即视为禁用缓存。
class ImageByteCache {
  ImageByteCache({this.maximumEntries = 100});

  /// 最大缓存条目数。<= 0 表示禁用缓存（不持有任何条目）。
  final int maximumEntries;

  final LinkedHashMap<String, Uint8List> _map = LinkedHashMap<String, Uint8List>();

  /// 当前缓存条目数。
  int get length => _map.length;

  /// 当前缓存中的所有 key（按最近使用到最久未使用排序）。
  Iterable<String> get keys => _map.keys;

  /// 读取 [key] 对应的字节；命中时移动到 MRU，未命中返回 null。
  Uint8List? get(String key) {
    final bytes = _map.remove(key);
    if (bytes == null) return null;
    _map[key] = bytes;
    return bytes;
  }

  /// 写入/更新 [key] 对应字节并移动到 MRU；超出 [maximumEntries] 时淘汰最久未用。
  ///
  /// [maximumEntries] <= 0 时不做任何持有。
  void put(String key, Uint8List bytes) {
    if (maximumEntries <= 0) return;
    _map.remove(key);
    _map[key] = bytes;
    while (_map.length > maximumEntries) {
      _map.remove(_map.keys.first);
    }
  }

  /// 移除 [key]，返回是否存在。
  bool remove(String key) => _map.remove(key) != null;

  /// 清空缓存。
  void clear() => _map.clear();
}
