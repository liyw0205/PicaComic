import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:pica_comic/foundation/app.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/open.dart';

import '../lib/foundation/cache_manager.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> verifyCacheManager() async {
  final prefix = Platform.environment['PREFIX'];
  if (Platform.isAndroid &&
      prefix != null &&
      File('$prefix/lib/libsqlite3.so').existsSync()) {
    open.overrideFor(OperatingSystem.android,
        () => DynamicLibrary.open('$prefix/lib/libsqlite3.so'));
  }
  final root = await Directory.systemTemp.createTemp('pica-cache-test-');
  App.cachePath = root.path;
  App.dataPath = root.path;
  final cacheDir = Directory('${root.path}/cache/0');
  await cacheDir.create(recursive: true);
  final orphan = File('${cacheDir.path}/orphan');
  await orphan.writeAsBytes(Uint8List(2 * 1024 * 1024));
  await File('${cacheDir.path}/valid').writeAsBytes(Uint8List(17));
  await File('${cacheDir.path}/expired').writeAsBytes(Uint8List(8));
  final db = sqlite3.open('${root.path}/cache.db');
  db.execute(
      'CREATE TABLE cache (key TEXT PRIMARY KEY, dir TEXT, name TEXT, expires INTEGER)');
  db.execute('INSERT INTO cache VALUES (?, ?, ?, ?)',
      ['valid', '0', 'valid', DateTime.now().millisecondsSinceEpoch + 60000]);
  db.execute(
      'INSERT INTO cache VALUES (?, ?, ?, ?)', ['expired', '0', 'expired', 0]);
  db.execute(
      'INSERT INTO cache VALUES (?, ?, ?, ?)', ['missing', '0', 'missing', 0]);
  db.dispose();
  final cache = CacheManager();
  try {
    _check(
        await cache.findCache('valid') != null, 'Legacy cache failed to load');
    _check(!await orphan.exists(), 'Orphan file survived startup');
    _check(await cache.findCache('expired') == null,
        'Expired entry survived startup');
    _check(cache.currentSize == 17,
        'Startup size includes missing or orphan files');

    await Future.wait([
      cache.writeCache('same', Uint8List(32)),
      cache.writeCache('same', Uint8List(64)),
    ]);
    final same = File((await cache.findCache('same'))!);
    _check(cache.currentSize == 17 + await same.length(),
        'Replacement size is wrong');
    final files = await Directory(CacheManager.cachePath)
        .list(recursive: true)
        .where((entry) => entry is File)
        .toList();
    _check(files.length == 2, 'Concurrent replacement leaked a file');

    cache.setType('same', 'png');
    await cache.writeCache('same', Uint8List(16));
    _check(cache.getType('same') == 'png', 'Replacement lost the image type');

    final writer = await cache.openWrite('active');
    await writer.writeBytes(Uint8List(2 * 1024 * 1024));
    await cache.checkCache().timeout(const Duration(seconds: 3));
    _check(await writer.file.exists(), 'Cleanup deleted an active write');
    cache.setLimitSize(1);
    await Future.wait([writer.close(), writer.close()]);
    _check(await writer.file.length() == 2 * 1024 * 1024,
        'Concurrent close duplicated data or deleted the new file');
    await cache.checkCache().timeout(const Duration(seconds: 3));
    _check(cache.currentSize <= cache.limitSize,
        'Eviction did not reach the limit');

    final duringClear = await cache.openWrite('during-clear');
    await duringClear.writeBytes(Uint8List(123));
    await cache.clear();
    await duringClear.close();
    _check(await duringClear.file.length() == 123,
        'Clear damaged an active write');
    _check(cache.currentSize == 123, 'Streamed writes were not counted');

    final lateOrphan = File('${cacheDir.path}/late-orphan');
    await lateOrphan.writeAsBytes(Uint8List(42));
    await cache.writeCache('incremental', Uint8List(23));
    _check(await lateOrphan.exists(),
        'A write unexpectedly rescanned the entire directory');
    await cache.checkCache();
    _check(!await lateOrphan.exists(),
        'Explicit cleanup did not remove an orphan');

    final userId = Platform.isWindows
        ? null
        : (await Process.run('id', ['-u'])).stdout.toString().trim();
    if (!Platform.isWindows && userId != '0') {
      final locked = Directory('${CacheManager.cachePath}/locked');
      await locked.create();
      await Process.run('chmod', ['000', locked.path]);
      try {
        bool failed = false;
        try {
          await cache.checkCache();
        } on FileSystemException {
          failed = true;
        }
        _check(failed, 'Permission failure was not surfaced');
      } finally {
        await Process.run('chmod', ['700', locked.path]);
      }
      await cache.checkCache().timeout(const Duration(seconds: 3));
    }
    await cache.clear();
    _check(cache.currentSize == 0, 'Clear did not reset size');
    stdout.writeln(
        'Cache: startup, TTL, replacement, streaming, eviction, lifecycle and recovery passed');
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> main() => verifyCacheManager();
