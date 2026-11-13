import 'dart:typed_data';

class ByteLruCache {
  ByteLruCache({required int limit}) : _limit = limit {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
  }

  final Map<String, Uint8List> _items = {};
  int _size = 0;
  int _limit;

  int get size => _size;
  int get limit => _limit;

  set limit(int value) {
    if (value < 0) throw ArgumentError.value(value, 'limit');
    _limit = value;
    _trim();
  }

  Uint8List? take(String key) {
    final value = _items.remove(key);
    if (value != null) _size -= value.length;
    return value;
  }

  Uint8List? get(String key) {
    final value = _items.remove(key);
    if (value != null) _items[key] = value;
    return value;
  }

  Uint8List? peek(String key) => _items[key];

  void put(String key, Uint8List value) {
    final previous = _items.remove(key);
    if (previous != null) _size -= previous.length;
    if (value.length > _limit) return;
    _items[key] = value;
    _size += value.length;
    _trim();
  }

  bool remove(String key, {Uint8List? onlyIfIdentical}) {
    final value = _items[key];
    if (value == null ||
        (onlyIfIdentical != null && !identical(value, onlyIfIdentical))) {
      return false;
    }
    _items.remove(key);
    _size -= value.length;
    return true;
  }

  void clear() {
    _items.clear();
    _size = 0;
  }

  void _trim() {
    while (_size > _limit && _items.isNotEmpty) {
      final firstKey = _items.keys.first;
      _size -= _items.remove(firstKey)!.length;
    }
  }
}
