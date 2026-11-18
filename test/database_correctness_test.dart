import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final runPerformance = Platform.environment['PICA_RUN_PERF_TESTS'] == '1';
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica_database_');
    App.dataPath = directory.path;
    await LocalFavoritesManager().init();
    await HistoryManager().init();
  });

  FavoriteItem favorite(String target, int type) => FavoriteItem(
        target: target,
        name: 'A title',
        coverPath: '',
        author: 'An author',
        type: FavoriteType(type),
        tags: [],
      );

  test('favorite identity includes source type', () async {
    final manager = LocalFavoritesManager();
    final folder = manager.createFolder('identity');
    await manager.addComic(folder, favorite('same-target', 0), null, false);
    await manager.addComic(folder, favorite('same-target', 1), null, false);
    await manager.addComic(folder, favorite('same-target', 1), null, false);
    expect(manager.count(folder), 2);
  });

  test('Hitomi favorites match and delete legacy URL variants', () async {
    final manager = LocalFavoritesManager.create();
    final path = '${directory.path}/hitomi-target-compat.db';
    await manager.init(databasePath: path, importLegacy: false);
    final folder = manager.createFolder('hitomi-targets');
    final legacy = favorite('https://hitomi.la/reader/42.html', 3);
    final canonical = favorite('https://hitomi.la/galleries/42.html', 3);
    await manager.addComic(folder, legacy, null, false);

    try {
      expect(await manager.findWithModel(canonical), [folder]);
      expect(manager.comicExists(folder, canonical.target, 3), isTrue);
      await manager.deleteComic(folder, canonical);
      expect(manager.comicExists(folder, legacy.target, 3), isFalse);
    } finally {
      manager.close();
    }
  });

  test('values round trip and tag updates retain source identity', () async {
    final manager = LocalFavoritesManager();
    final folder = manager.createFolder('values');
    await DataMaintenance.waitForIdle();
    final item = favorite("target's \"中文\"", 0)
      ..name = "name's \"quote\""
      ..author = "author's name"
      ..tags = ["tag's", '中文'];
    await manager.addComic(folder, item, null, false);
    await manager.addComic(folder, favorite(item.target, 1), null, false);
    expect(manager.getComic(folder, item.target, item.type).name, item.name);
    await manager.editTags(item.target, folder, ["edited's"], item.type);
    expect(manager.getComic(folder, item.target, item.type).tags, ["edited's"]);
    expect(manager.getComic(folder, item.target, const FavoriteType(1)).tags,
        isEmpty);
    manager.insertFolderSync(FolderSync(folder, "key's", '{"value":"a\'b"}'));
    await DataMaintenance.waitForIdle();
    expect(manager.folderSync.single.syncDataObj['value'], "a'b");
    await manager.deleteComicWithTarget(folder, item.target, item.type);
    expect(manager.comicExists(folder, item.target, 0), isFalse);
    expect(manager.comicExists(folder, item.target, 1), isTrue);
  });

  test('folder identifiers support quotes and punctuation', () async {
    final manager = LocalFavoritesManager();
    final folder = manager.createFolder('folder "quote"; 中文');
    expect(manager.count(folder), 0);
    await manager.deleteFolder(folder);
    expect(manager.folderNames, isNot(contains(folder)));
    final similarPrefix = manager.createFolder('sqliteXuser');
    expect(manager.folderNames, contains(similarPrefix));
    await manager.deleteFolder(similarPrefix);
  });

  test('folder deletion rolls back metadata when a later delete fails',
      () async {
    final manager = LocalFavoritesManager.create();
    final path = '${directory.path}/folder-delete-rollback.db';
    await manager.init(databasePath: path, importLegacy: false);
    final folder = manager.createFolder('kept');
    manager.insertFolderSync(FolderSync(folder, 'source', '{}'));
    manager.updateOrder({folder: 12});
    await manager.addComic(folder, favorite('kept-comic', 0), null, false);
    final fixture = sqlite3.open(path);
    fixture.execute('''
      create trigger reject_folder_delete before delete on folder_order
      when old.folder_name = 'kept'
      begin select raise(abort, 'injected metadata delete failure'); end;
    ''');
    fixture.dispose();

    try {
      await expectLater(
          manager.deleteFolder(folder), throwsA(isA<SqliteException>()));
      expect(manager.folderNames, contains(folder));
      expect(manager.comicExists(folder, 'kept-comic', 0), isTrue);
      expect(manager.folderSync.single.folderName, folder);
      final saved = sqlite3.open(path, mode: OpenMode.readOnly);
      expect(
          saved.select('select order_value from folder_order;').single[0], 12);
      saved.dispose();
    } finally {
      manager.close();
    }
  });

  test('folder deletion cannot remove metadata tables', () async {
    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/folder-delete-reserved.db',
        importLegacy: false);
    final folder = manager.createFolder('kept');
    await manager.addComic(folder, favorite('kept-comic', 0), null, false);
    try {
      for (final name in ['folder_sync', 'folder_order', 'missing']) {
        await expectLater(manager.deleteFolder(name), throwsStateError);
      }
      expect(manager.folderSync, isEmpty);
      expect(manager.comicExists(folder, 'kept-comic', 0), isTrue);
    } finally {
      manager.close();
    }
  });

  test('deleting a favorite retains a cover used by another identity',
      () async {
    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/shared-cover.db', importLegacy: false);
    final folder = manager.createFolder('shared-cover');
    final otherFolder = manager.createFolder('other-cover');
    const coverPath = 'https://example.invalid/shared-cover.jpg';
    final first = favorite('first', 0)..coverPath = coverPath;
    final second = favorite('second', 1)..coverPath = coverPath;
    await manager.addComic(folder, first, null, false);
    await manager.addComic(otherFolder, second, null, false);
    final hash = md5.convert(utf8.encode(coverPath));
    final cover = File('${directory.path}/favoritesCover/$hash.jpg');
    await cover.parent.create(recursive: true);
    await cover.writeAsBytes([1, 2, 3]);

    try {
      await manager.deleteComic(folder, first);
      expect(cover.existsSync(), isTrue);
      expect(manager.comicExists(otherFolder, second.target, second.type.key),
          isTrue);
      await manager.deleteComic(otherFolder, second);
      expect(cover.existsSync(), isFalse);
    } finally {
      manager.close();
    }
  });

  test('cover cleanup failure does not prevent publishing a deletion',
      () async {
    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/cover-delete-failure.db',
        importLegacy: false);
    final folder = manager.createFolder('cover-failure');
    final item = favorite('deleted', 0)
      ..coverPath = 'https://example.invalid/cannot-delete.jpg';
    await manager.addComic(folder, item, null, false);
    final hash = md5.convert(utf8.encode(item.coverPath));
    final cover = Directory('${directory.path}/favoritesCover/$hash.jpg');
    await cover.create(recursive: true);
    await File('${cover.path}/sentinel').writeAsBytes([1, 2, 3]);

    try {
      await DataMaintenance.run(() async {
        await manager.deleteComic(folder, item);
        expect(
            manager.comicExists(folder, item.target, item.type.key), isFalse);
        expect(DataMaintenance.currentStats?.syncRequests, 1);
        expect(DataMaintenance.currentStats?.suppressedSyncRequests, 1);
      }, suppressSync: true);
      expect(cover.existsSync(), isTrue);
    } finally {
      manager.close();
    }
  });

  test('history removal binds quote-bearing targets', () async {
    final manager = HistoryManager();
    const target = "comic's target";
    await manager.addHistory(History(
        HistoryType.picacg, DateTime.now(), 'Title', '', '', 0, 0, target));
    manager.remove(target);
    await DataMaintenance.waitForIdle();
    expect(manager.findSync(target), isNull);
  });

  test('lazy existence cache tracks absent, added, and removed targets',
      () async {
    final cacheDirectory =
        await Directory.systemTemp.createTemp('pica_history_cache_');
    final manager = HistoryManager.create();
    try {
      await manager.init(
        databasePath: '${cacheDirectory.path}/history.db',
        importLegacy: false,
      );
      const target = 'cache-target';
      expect(manager.findSync(target), isNull);

      await manager.addHistory(History(
        HistoryType.picacg,
        DateTime.now(),
        'Title',
        '',
        '',
        0,
        0,
        target,
      ));
      expect(manager.findSync(target), isNotNull);

      await manager.remove(target);
      await DataMaintenance.waitForIdle();
      expect(manager.findSync(target), isNull);

      await manager.addHistory(History(
        HistoryType.picacg,
        DateTime.now(),
        'Title again',
        '',
        '',
        0,
        0,
        target,
      ));
      expect(manager.findSync(target)?.title, 'Title again');
    } finally {
      manager.close();
      await cacheDirectory.delete(recursive: true);
    }
  });

  test('history deletions publish and keep the local cache coherent', () async {
    final manager = HistoryManager.create();
    await manager.init(
        databasePath: '${directory.path}/history-delete-sync.db',
        importLegacy: false);
    const target = 'delete-target';
    try {
      await manager.addHistory(History(
          HistoryType.picacg, DateTime.now(), 'Title', '', '', 0, 0, target));
      await DataMaintenance.run<void>(() => manager.remove(target),
          suppressSync: true);
      expect(manager.findSync(target), isNull);
      expect(DataMaintenance.lastStats?.syncRequests, 1);
      expect(DataMaintenance.lastStats?.suppressedSyncRequests, 1);
      expect(DataMaintenance.lastStats?.unsuppressedSyncRequests, 0);

      await manager.addHistory(History(HistoryType.picacg, DateTime.now(),
          'Title again', '', '', 0, 0, target));
      await DataMaintenance.run<void>(() => manager.clearHistory(),
          suppressSync: true);
      expect(manager.findSync(target), isNull);
      expect(DataMaintenance.lastStats?.syncRequests, 1);
      expect(DataMaintenance.lastStats?.suppressedSyncRequests, 1);
    } finally {
      manager.close();
    }
  });

  test('history pages use a stable time and target order', () async {
    final manager = HistoryManager.create();
    await manager.init(
        databasePath: '${directory.path}/pages.db', importLegacy: false);
    final time = DateTime.fromMillisecondsSinceEpoch(1000);
    for (final target in ['c', 'a', 'b', 'd']) {
      await manager.addHistory(History(HistoryType.picacg, time,
          'title $target', 'subtitle', '', 0, 0, target));
    }
    final first = manager.getPage(limit: 2);
    expect(first.map((row) => row.target), ['a', 'b']);
    manager.remove('a');
    await DataMaintenance.waitForIdle();
    await manager.addHistory(History(
        HistoryType.picacg, DateTime.now(), 'new title', '', '', 0, 0, 'new'));
    final second = manager.getPage(limit: 2, after: first.last);
    expect(second.map((row) => row.target), ['c', 'd']);
    expect(manager.getPage(keyword: 'TITLE C').single.target, 'c');
    expect(manager.count(keyword: ' title c '), 1);
    expect(manager.count(keyword: '   '), 4);
    expect(manager.getPage(keyword: '   ').map((row) => row.target),
        ['new', 'b', 'c', 'd']);
    expect(manager.findSync('new'), isNotNull);
    manager.clearHistory();
    await DataMaintenance.waitForIdle();
    expect(manager.findSync('new'), isNull);
    manager.close();
  });

  test('favorite search filters all terms before applying its global limit',
      () async {
    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/search.db', importLegacy: false);
    final first = manager.createFolder('first');
    final second = manager.createFolder('second');
    await DataMaintenance.waitForIdle();
    for (var i = 0; i < 205; i++) {
      await manager.addComic(
          first, favorite('$i', 0)..name = 'common', null, false);
    }
    await manager.addComic(
        second,
        favorite('wanted', 0)
          ..name = 'common'
          ..author = 'rare token',
        null,
        false);
    expect(manager.search('common').length, 200);
    expect(manager.search(' common   RARE ').single.comic.target, 'wanted');
    expect(manager.search('common', limit: 7).length, 7);
    expect(manager.search('%'), isEmpty);
    manager.close();
  });

  test('favorite folder ordering uses a composite ordering index', () async {
    final path = '${directory.path}/favorite-order-index.db';
    final manager = LocalFavoritesManager.create();
    await manager.init(databasePath: path, importLegacy: false);
    final folder = manager.createFolder('indexed');
    await DataMaintenance.waitForIdle();
    final fixture = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final plan = fixture.select('''
            explain query plan
            select * from "$folder"
            order by display_order, target, type
            limit 60;
          ''').map((row) => row['detail'] as String).join(' ');
      expect(
          plan, contains('pica_favorites_indexed_display_order_target_type'));
      expect(plan, isNot(contains('TEMP B-TREE')));
    } finally {
      fixture.dispose();
      manager.close();
    }
  });

  test('a failed schema migration rolls back every table', () async {
    final path = '${directory.path}/migration.db';
    final db = sqlite3.open(path);
    for (final name in ['good', 'bad']) {
      db.execute('''
        create table "$name"(target text, name text, author text, type int,
          tags text, cover_path text, time text, display_order int);
      ''');
    }
    db.execute("insert into good values('ok','title','',0,'','','',0);");
    db.execute("insert into bad values('duplicate','title','',0,'','','',0);");
    db.execute("insert into bad values('duplicate','title','',0,'','','',1);");
    db.dispose();
    final manager = LocalFavoritesManager.create();
    await expectLater(manager.init(databasePath: path, importLegacy: false),
        throwsA(isA<SqliteException>()));
    manager.close();
    final original = sqlite3.open(path);
    expect(original.select('select * from good;').length, 1);
    expect(original.select('select * from bad;').length, 2);
    expect(
        original
            .select('pragma table_info(good);')
            .every((row) => row['pk'] == 0),
        isTrue);
    expect(original.select('pragma user_version;').single.values.single, 0);
    original.dispose();
  });

  test('snapshot and merge do not change their source databases', () async {
    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/source.db', importLegacy: false);
    final folder = manager.createFolder('snapshot "folder"');
    await manager.addComic(folder, favorite('comic', 0), null, false);
    final snapshot = '${directory.path}/snapshot.db';
    await manager.snapshotTo(snapshot);
    final working = LocalFavoritesManager.create();
    await working.init(
        databasePath: '${directory.path}/working.db', importLegacy: false);
    await working.mergeFrom(snapshot);
    expect(working.getComic(folder, 'comic', const FavoriteType(0)).target,
        'comic');
    working.deleteComicWithTarget(folder, 'comic', const FavoriteType(0));
    expect(manager.count(folder), 1);
    final saved = sqlite3.open(snapshot, mode: OpenMode.readOnly);
    expect(saved.select('select * from "snapshot ""folder""";').length, 1);
    saved.dispose();
    manager.close();
    working.close();
  });

  test('legacy JSON merge retains existing data and failed inputs', () async {
    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/legacy.db', importLegacy: false);
    final folder = manager.createFolder('legacy');
    await manager.addComic(folder, favorite('existing', 0), null, false);
    final input = File('${directory.path}/legacy.json');
    await input.writeAsString(jsonEncode({
      folder: [favorite('imported', 1).toJson()]
    }));
    await manager.mergeLegacyJson(input.path);
    expect(manager.count(folder), 2);
    expect(input.existsSync(), isTrue);
    await input.writeAsString(jsonEncode({
      folder: [
        favorite('valid', 0).toJson(),
        {'invalid': true}
      ]
    }));
    await expectLater(manager.mergeLegacyJson(input.path), throwsA(anything));
    expect(input.existsSync(), isTrue);
    expect(manager.count(folder), 2);
    manager.close();
  });

  test('legacy import keeps source when cleanup cannot delete it', () async {
    if (Platform.isWindows) return;

    final manager = LocalFavoritesManager.create();
    await manager.init(
        databasePath: '${directory.path}/cleanup-failure.db',
        importLegacy: false);
    final input = File('${directory.path}/localFavorite');
    await input.writeAsString(jsonEncode({
      'cleanup': [favorite('imported', 0).toJson()]
    }));

    try {
      final chmod = await Process.run('chmod', ['0555', directory.path]);
      expect(chmod.exitCode, 0, reason: 'chmod failed: ${chmod.stderr}');
      await expectLater(manager.readData(), completes);
      expect(manager.count('cleanup'), 1);
      expect(input.existsSync(), isTrue);
    } finally {
      await Process.run('chmod', ['0755', directory.path]);
      if (input.existsSync()) await input.delete();
      manager.close();
    }
  });

  test('merge rolls back earlier writes when a later insert fails', () async {
    final manager = LocalFavoritesManager.create();
    final path = '${directory.path}/rollback.db';
    await manager.init(databasePath: path, importLegacy: false);
    final folder = manager.createFolder('items');
    final fixture = sqlite3.open(path);
    fixture.execute('''
      create trigger reject_bad before insert on items when new.target = 'bad'
      begin select raise(abort, 'injected insert failure'); end;
    ''');
    fixture.dispose();
    final input = File('${directory.path}/rollback.json');
    await input.writeAsString(jsonEncode({
      folder: [favorite('good', 0).toJson(), favorite('bad', 0).toJson()]
    }));
    await expectLater(
        manager.mergeLegacyJson(input.path), throwsA(isA<SqliteException>()));
    expect(manager.count(folder), 0);
    expect(input.existsSync(), isTrue);
    manager.close();
  });

  test('writes wait for maintenance and use the reopened connection', () async {
    final manager = LocalFavoritesManager.create();
    final path = '${directory.path}/maintenance.db';
    await manager.init(databasePath: path, importLegacy: false);
    final folder = manager.createFolder('items');
    final entered = Completer<void>();
    final release = Completer<void>();
    final maintenance = DataMaintenance.run(() async {
      entered.complete();
      await release.future;
      manager.close();
      await manager.init(databasePath: path, importLegacy: false);
    });
    await entered.future;
    final insertion =
        manager.addComic(folder, favorite('queued', 0), null, false);
    final tagging =
        manager.addTagTo(folder, 'queued', 'queued-tag', const FavoriteType(0));
    expect(manager.count(folder), 0);
    release.complete();
    await maintenance;
    await insertion;
    await tagging;
    expect(manager.getComic(folder, 'queued', const FavoriteType(0)).tags,
        ['queued-tag']);
    manager.close();
  });

  test('history and image favorites merge on an isolated manager', () async {
    final source = HistoryManager.create();
    final sourcePath = '${directory.path}/history-source.db';
    await source.init(databasePath: sourcePath, importLegacy: false);
    await source.addHistory(History(HistoryType.picacg, DateTime.now(), 'Title',
        '', '', 2, 7, 'history-source'));
    source.close();
    final fixture = sqlite3.open(sourcePath);
    fixture.execute(
        "insert into image_favorites values('image','Title','cover',1,2,'{}');");
    fixture.dispose();
    final destination = HistoryManager.create();
    final destinationPath = '${directory.path}/history-destination.db';
    await destination.init(databasePath: destinationPath, importLegacy: false);
    await destination.mergeFrom(sourcePath);
    expect(destination.findSync('history-source')?.page, 7);
    destination.close();
    final saved = sqlite3.open(destinationPath);
    expect(
        saved.select('select * from image_favorites;').single['id'], 'image');
    saved.dispose();
    expect(File(sourcePath).existsSync(), isTrue);
  });

  test('history import keeps source when cleanup cannot delete it', () async {
    if (Platform.isWindows) return;

    final manager = HistoryManager.create();
    final destinationPath = '${directory.path}/history-cleanup-failure.db';
    await manager.init(databasePath: destinationPath, importLegacy: false);
    final sourcePath = '${directory.path}/history_temp.db';
    final source = sqlite3.open(sourcePath);
    source.execute('''
      create table history(
        target text primary key,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int
      );
    ''');
    source.execute(
        "insert into history values('imported','Title','', '', 1000, 0, 0, 0, '', null);");
    source.dispose();

    try {
      final chmod = await Process.run('chmod', ['0555', directory.path]);
      expect(chmod.exitCode, 0, reason: 'chmod failed: ${chmod.stderr}');
      await expectLater(manager.tryUpdateDb(), completes);
      expect(manager.findSync('imported'), isNotNull);
      expect(File(sourcePath).existsSync(), isTrue);
    } finally {
      await Process.run('chmod', ['0755', directory.path]);
      if (File(sourcePath).existsSync()) await File(sourcePath).delete();
      manager.close();
    }
  });

  test('indexed history pages keep object allocation bounded at 50k rows',
      () async {
    final performanceDirectory =
        await Directory.systemTemp.createTemp('pica_database_perf_');
    try {
      for (final count in [1000, 10000, 50000]) {
        final path = '${performanceDirectory.path}/$count.db';
        final manager = HistoryManager.create();
        await manager.init(databasePath: path, importLegacy: false);
        manager.close();
        final fixture = sqlite3.open(path);
        final groups = List.generate(50, (i) => '($i)').join(',');
        const digits = '(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)';
        fixture.execute('''
          WITH groups(g) AS (VALUES $groups), digits(d) AS (VALUES $digits),
          sequence(n) AS (
            SELECT g * 1000 + a.d * 100 + b.d * 10 + c.d
            FROM groups CROSS JOIN digits a CROSS JOIN digits b CROSS JOIN digits c
          )
          INSERT INTO history(target,title,subtitle,cover,time,type,ep,page,readEpisode,max_page)
          SELECT 'target_' || n, 'Title', 'Author', '', 1700000000000 + n,
            0, 1, 1, '1', 10 FROM sequence WHERE n < $count;
        ''');
        final plan = fixture.select('''
          explain query plan select * from history
          order by time DESC, target ASC limit 60;
        ''').map((row) => row['detail']).join(' ');
        expect(plan, contains('history_time_target'));
        expect(plan, isNot(contains('TEMP B-TREE')));
        fixture.dispose();
        await manager.init(databasePath: path, importLegacy: false);
        manager.getPage();
        manager.getAll();
        final pageTimes = <int>[];
        final allTimes = <int>[];
        for (var sample = 0; sample < 5; sample++) {
          final stopwatch = Stopwatch()..start();
          final page = manager.getPage();
          pageTimes.add(stopwatch.elapsedMicroseconds);
          stopwatch.reset();
          final all = manager.getAll();
          allTimes.add(stopwatch.elapsedMicroseconds);
          stopwatch.stop();
          expect(page.length, 60);
          expect(all.length, count);
        }
        pageTimes.sort();
        allTimes.sort();
        // Synchronous isolate time includes SQL decoding and History allocation.
        stdout.writeln('history rows=$count page60 p50_us=${pageTimes[2]} '
            'p95_us=${pageTimes[4]} full p50_us=${allTimes[2]} '
            'p95_us=${allTimes[4]} plan=$plan');
        manager.close();
      }
    } finally {
      await performanceDirectory.delete(recursive: true);
    }
  },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: runPerformance ? false : 'opt-in performance benchmark');

  tearDownAll(() async {
    LocalFavoritesManager().close();
    HistoryManager().close();
    await directory.delete(recursive: true);
  });
}
