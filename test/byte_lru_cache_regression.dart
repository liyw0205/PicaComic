import 'dart:typed_data';

import 'package:pica_comic/foundation/byte_lru_cache.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void verifyByteLruCache() {
  final cache = ByteLruCache(limit: 5);
  cache.put('same', Uint8List(3));
  cache.put('same', Uint8List(2));
  _check(cache.size == 2, 'Replacement did not adjust byte accounting');

  cache.put('older', Uint8List(2));
  cache.put('newer', Uint8List(2));
  _check(cache.peek('same') == null, 'Least-recent item was not evicted');
  _check(cache.size == 4, 'Eviction left incorrect byte accounting');

  final newer = cache.peek('newer')!;
  _check(!cache.remove('newer', onlyIfIdentical: Uint8List(2)),
      'A stale failure removed a replacement value');
  _check(identical(cache.peek('newer'), newer), 'Replacement value was lost');

  cache.put('too-large', Uint8List(6));
  _check(cache.peek('too-large') == null, 'Oversized item was cached');
  _check(cache.size == 4, 'Oversized item changed cache accounting');

  final recency = ByteLruCache(limit: 4);
  recency.put('old', Uint8List(2));
  recency.put('new', Uint8List(2));
  _check(recency.get('old') != null, 'Cached value was not returned');
  recency.put('next', Uint8List(2));
  _check(recency.peek('old') != null, 'Cache hit did not refresh LRU order');
  _check(recency.peek('new') == null, 'Least-recent value was not evicted');

  cache.limit = 1;
  _check(cache.size <= cache.limit, 'Reducing the limit did not evict items');
  cache.clear();
  _check(cache.size == 0, 'Clear did not reset cache accounting');
}

void main() => verifyByteLruCache();
