import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:sqlite3/sqlite3.dart';

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';
  static CacheManager? instance;
  factory CacheManager() => instance ??= CacheManager._create();

  late final Database _db;
  late final Future<void> _ready;
  Future<void> _mutations = Future.value();
  final _activeWrites = <String>{};
  int _currentSize = 0;
  int _limitSize = 2 * 1024 * 1024 * 1024;
  int dir = 0;

  int get currentSize => _currentSize;
  int get limitSize => _limitSize;

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL, dir TEXT NOT NULL, name TEXT NOT NULL,
        expires INTEGER NOT NULL, type TEXT
      )
    ''');
    if (!_db
        .select('PRAGMA table_info(cache)')
        .any((row) => row['name'] == 'type')) {
      _db.execute('ALTER TABLE cache ADD COLUMN type TEXT');
    }
    _ready = _reconcileFiles().then((_) => _clean());
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void setLimitSize(int size) {
    if (size < 1) throw ArgumentError.value(size, 'size');
    _limitSize = size * 1024 * 1024;
  }

  void setType(String key, String? type) {
    _db.execute('UPDATE cache SET type = ? WHERE key = ?', [type, key]);
  }

  String? getType(String key) {
    final rows = _db.select('SELECT type FROM cache WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['type'] as String?;
  }

  Future<void> writeCache(String key, Uint8List data,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    final writing = await openWrite(key);
    try {
      await writing.writeBytes(data);
      await writing.close(duration);
    } catch (_) {
      await writing.cancel();
      rethrow;
    }
  }

  Future<CachingFile> openWrite(String key) async {
    await _ready;
    dir = (dir + 1) % 100;
    final targetDir = dir.toString();
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    while (true) {
      final file = File('$cachePath/$targetDir/$name');
      if (_activeWrites.contains(file.path) ||
          await file.exists() ||
          !_activeWrites.add(file.path)) {
        name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
        continue;
      }
      try {
        await file.create(recursive: true);
        return CachingFile._(this, key, targetDir, name, file);
      } catch (_) {
        _activeWrites.remove(file.path);
        rethrow;
      }
    }
  }

  Future<String?> findCache(String key) async {
    await _ready;
    final rows = _db.select('SELECT * FROM cache WHERE key = ?', [key]);
    if (rows.isEmpty ||
        rows.first['expires'] < DateTime.now().millisecondsSinceEpoch) {
      return null;
    }
    final file = _rowFile(rows.first);
    return await file.exists() ? file.path : null;
  }

  File _rowFile(Row row) => File('$cachePath/${row['dir']}/${row['name']}');

  Future<void> _reconcileFiles() async {
    final rows = _db.select('SELECT * FROM cache');
    final indexed = {for (final row in rows) _rowFile(row).path: row};
    int size = 0;
    await for (final entry
        in Directory(cachePath).list(recursive: true, followLinks: false)) {
      if (entry is! File || _activeWrites.contains(entry.path)) continue;
      if (indexed.remove(entry.path) != null) {
        size += await entry.length();
      } else {
        await entry.delete();
      }
    }
    for (final row in indexed.values) {
      if (!_activeWrites.contains(_rowFile(row).path)) {
        _db.execute('DELETE FROM cache WHERE key = ?', [row['key']]);
      }
    }
    _currentSize = size;
  }

  Future<void> _removeRow(Row row) async {
    final file = _rowFile(row);
    if (await file.exists()) {
      final size = await file.length();
      await file.delete();
      _currentSize = max(0, _currentSize - size);
    }
    _db.execute('DELETE FROM cache WHERE key = ?', [row['key']]);
  }

  Future<void> _clean({String? protectedKey}) async {
    final expired = _db.select('SELECT * FROM cache WHERE expires < ?',
        [DateTime.now().millisecondsSinceEpoch]);
    for (final row in expired) {
      if (row['key'] != protectedKey) await _removeRow(row);
    }
    int count =
        _db.select('SELECT COUNT(*) AS count FROM cache').first['count'] as int;
    while (_currentSize > _limitSize || count > 2000) {
      final rows = protectedKey == null
          ? _db.select('SELECT * FROM cache ORDER BY expires ASC LIMIT 10')
          : _db.select(
              'SELECT * FROM cache WHERE key != ? ORDER BY expires ASC LIMIT 10',
              [protectedKey]);
      if (rows.isEmpty) break;
      for (final row in rows) {
        await _removeRow(row);
        count--;
        if (_currentSize <= _limitSize && count <= 2000) break;
      }
    }
  }

  Future<void> checkCache() async {
    await _ready;
    await _serialize(() async {
      await _reconcileFiles();
      await _clean();
    });
  }

  Future<void> _commit(CachingFile writing, int duration) =>
      _serialize(() async {
        try {
          final old =
              _db.select('SELECT * FROM cache WHERE key = ?', [writing.key]);
          final type = old.isEmpty ? null : old.first['type'];
          if (old.isNotEmpty) await _removeRow(old.first);
          final size = await writing.file.length();
          _db.execute('''
        INSERT INTO cache (key, dir, name, expires, type) VALUES (?, ?, ?, ?, ?)
      ''', [
            writing.key,
            writing.dir,
            writing.name,
            DateTime.now().millisecondsSinceEpoch + duration,
            type
          ]);
          _currentSize += size;
          // Keep the just-written file available until its caller can consume it.
          await _clean(protectedKey: writing.key);
        } finally {
          _activeWrites.remove(writing.file.path);
        }
      });

  Future<void> delete(String key) async {
    await _ready;
    await _serialize(() async {
      final rows = _db.select('SELECT * FROM cache WHERE key = ?', [key]);
      if (rows.isNotEmpty) await _removeRow(rows.first);
    });
  }

  Future<void> clear() async {
    await _ready;
    await _serialize(() async {
      for (final row in _db.select('SELECT * FROM cache')) {
        await _removeRow(row);
      }
      await _reconcileFiles();
    });
  }

  Future<void> deleteKeyword(String keyword) async {
    await _ready;
    await _serialize(() async {
      final rows =
          _db.select('SELECT * FROM cache WHERE key LIKE ?', ['%$keyword%']);
      for (final row in rows) {
        await _removeRow(row);
      }
    });
  }
}

class CachingFile {
  CachingFile._(this._manager, this.key, this.dir, this.name, this.file);

  final CacheManager _manager;
  final String key;
  final String dir;
  final String name;
  final File file;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _closed = false;
  Future<void>? _closing;

  Future<void> writeBytes(List<int> data) async {
    if (_closed) throw StateError('Cache writer is closed');
    _buffer.add(data);
    if (_buffer.length >= 1024 * 1024) {
      await file.writeAsBytes(_buffer.takeBytes(), mode: FileMode.append);
    }
  }

  Future<void> close([int duration = 7 * 24 * 60 * 60 * 1000]) {
    if (_closed) return Future.value();
    return _closing ??= _close(duration);
  }

  Future<void> _close(int duration) async {
    if (_buffer.isNotEmpty) {
      await file.writeAsBytes(_buffer.takeBytes(), mode: FileMode.append);
    }
    await _manager._commit(this, duration);
    _closed = true;
  }

  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    _buffer.clear();
    _manager._activeWrites.remove(file.path);
    if (await file.exists()) await file.delete();
  }

  void reset() {
    if (_closed) throw StateError('Cache writer is closed');
    _buffer.clear();
    _closing = null;
    if (file.existsSync()) file.deleteSync();
  }
}
