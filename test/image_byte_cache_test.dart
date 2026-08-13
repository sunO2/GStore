import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/image/image_byte_cache.dart';

void main() {
  group('ImageByteCache', () {
    Uint8List bytesOf(int seed) => Uint8List.fromList([seed, seed + 1, seed + 2]);

    test('put then get returns the same bytes', () {
      final cache = ImageByteCache();
      final bytes = bytesOf(1);
      cache.put('a', bytes);
      expect(cache.get('a'), same(bytes));
    });

    test('get on missing key returns null', () {
      final cache = ImageByteCache();
      expect(cache.get('nope'), isNull);
    });

    test('get refreshes LRU order (MRU semantics)', () {
      final cache = ImageByteCache(maximumEntries: 3);
      cache.put('A', bytesOf(1));
      cache.put('B', bytesOf(2));
      cache.put('C', bytesOf(3));
      // A is now most recently used.
      expect(cache.get('A'), isNotNull);
      // Adding D must evict B (least recently used), not A.
      cache.put('D', bytesOf(4));
      expect(cache.get('A'), isNotNull, reason: 'A was touched, must survive');
      expect(cache.get('B'), isNull, reason: 'B was least recently used');
      expect(cache.get('C'), isNotNull);
      expect(cache.get('D'), isNotNull);
    });

    test('put overflow evicts the least recently used entry', () {
      final cache = ImageByteCache(maximumEntries: 2);
      cache.put('A', bytesOf(1));
      cache.put('B', bytesOf(2));
      cache.put('C', bytesOf(3));
      expect(cache.length, 2);
      expect(cache.get('A'), isNull);
      expect(cache.get('B'), isNotNull);
      expect(cache.get('C'), isNotNull);
    });

    test('put existing key updates bytes and moves to MRU', () {
      final cache = ImageByteCache(maximumEntries: 2);
      cache.put('A', bytesOf(1));
      cache.put('B', bytesOf(2));
      // Update A: makes it MRU so C evicts B.
      final newA = bytesOf(9);
      cache.put('A', newA);
      cache.put('C', bytesOf(3));
      expect(cache.get('A'), same(newA));
      expect(cache.get('B'), isNull);
      expect(cache.get('C'), isNotNull);
    });

    test('remove returns true for existing key and removes it', () {
      final cache = ImageByteCache();
      cache.put('A', bytesOf(1));
      expect(cache.remove('A'), isTrue);
      expect(cache.get('A'), isNull);
      expect(cache.length, 0);
    });

    test('remove returns false for missing key', () {
      final cache = ImageByteCache();
      expect(cache.remove('missing'), isFalse);
    });

    test('clear empties the cache', () {
      final cache = ImageByteCache();
      cache.put('A', bytesOf(1));
      cache.put('B', bytesOf(2));
      cache.clear();
      expect(cache.length, 0);
      expect(cache.keys, isEmpty);
      expect(cache.get('A'), isNull);
      expect(cache.get('B'), isNull);
    });

    test('length and keys reflect current contents', () {
      final cache = ImageByteCache(maximumEntries: 3);
      expect(cache.length, 0);
      cache.put('A', bytesOf(1));
      cache.put('B', bytesOf(2));
      expect(cache.length, 2);
      expect(cache.keys.toSet(), {'A', 'B'});
    });

    test('maximumEntries=0 keeps no entries (length always 0)', () {
      final cache = ImageByteCache(maximumEntries: 0);
      cache.put('A', bytesOf(1));
      expect(cache.length, 0);
      expect(cache.get('A'), isNull);
      expect(cache.keys, isEmpty);
    });

    test('maximumEntries<0 keeps no entries (length always 0)', () {
      final cache = ImageByteCache(maximumEntries: -1);
      cache.put('A', bytesOf(1));
      expect(cache.length, 0);
      expect(cache.get('A'), isNull);
    });
  });
}
