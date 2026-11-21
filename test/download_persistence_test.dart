import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DownloadManager manager;
  late Directory directory;
  late String oldDownloadPath;

  setUp(() async {
    manager = DownloadManager();
    await manager.dispose();
    manager.downloading.clear();
    directory =
        await Directory.systemTemp.createTemp('pica-download-persistence-');
    oldDownloadPath = appdata.settings[22];
    appdata.settings[22] = directory.path;
  });

  tearDown(() async {
    await manager.dispose();
    manager.path = null;
    appdata.settings[22] = oldDownloadPath;
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  File getQueueFile([String suffix = '']) =>
      File('${directory.path}/newDownload.json$suffix');

  Map<String, dynamic> committedQueue([
    List<Object?> tasks = const [],
    int generation = 1,
  ]) =>
      {
        'version': 1,
        'state': 'committed',
        'generation': generation,
        'downloading': tasks,
      };

  Map<String, dynamic> fixtureTask(String id) => {
        'type': 7,
        'id': id,
        '_downloadedNum': 0,
        '_downloadingEp': 0,
        'index': 0,
        'links': null,
        'directory': id,
        'finishedTasks': <String>[],
        'comic': {
          'name': id,
          'author': '',
          'type': 0,
          'tags': <String>[],
          'target': id,
          'coverPath': '',
          'time': '2026-01-01 00:00:00',
        },
      };

  void createDownloadDatabase(Directory root, Iterable<List<Object?>> rows) {
    final db = sqlite3.open('${root.path}/download.db');
    db.execute('''
      create table download (
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size int,
        json text
      )
    ''');
    for (final row in rows) {
      db.execute(
        'insert into download values (?, ?, ?, ?, ?, ?, ?)',
        row,
      );
    }
    db.dispose();
  }

  ComicItem picacgComic() => ComicItem(
        Profile('creator', '', '', 0, 0, 'author', '', false, null, null),
        'Fixture comic',
        '',
        '',
        'author',
        '',
        const [],
        const [],
        0,
        0,
        false,
        false,
        2,
        'abcdef1234567890abcdef12',
        0,
        '',
        const [],
        const [],
      );

  JmComicInfo jmComic(Map<int, String> series, List<String> epNames,
          {String id = '123'}) =>
      JmComicInfo(
        'Fixture JM',
        id,
        const ['author'],
        '',
        0,
        0,
        series,
        const [],
        const [],
        const [],
        const [],
        false,
        false,
        0,
        epNames,
      );

  test('NH downloaded tags survive JSON round trips and legacy records', () {
    final original = NhentaiDownloadedComic('nhentai123', 'Fixture', 1.5,
        'cover.jpg', ['tag one', 'tag & two', 'tag one']);
    var restored = original;
    for (var round = 0; round < 3; round++) {
      restored = NhentaiDownloadedComic.fromJson(
          jsonDecode(jsonEncode(restored.toJson())));
      expect(restored.tags, original.tags);
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.comicSize, original.comicSize);
      expect(restored.cover, original.cover);
    }
    for (final legacyTags in [
      <String, dynamic>{},
      {'tags': null},
      {'tags': []}
    ]) {
      final legacy = <String, dynamic>{
        'comicID': original.id,
        'title': original.name,
        'size': null,
        'cover': original.cover,
        ...legacyTags,
      };
      final item = NhentaiDownloadedComic.fromJson(legacy);
      expect(item.tags, isEmpty);
      expect(
          NhentaiDownloadedComic.fromJson(jsonDecode(jsonEncode(item.toJson())))
              .tags,
          isEmpty);
    }
  });

  test('NH tags survive database migration and reopening', () async {
    final fixtures = {
      'nhentai123': ['tag one', 'tag & two'],
      'nhentai456': <String>[],
    };
    for (final entry in fixtures.entries) {
      final comicDirectory = Directory('${directory.path}/${entry.key}');
      await comicDirectory.create();
      await File('${comicDirectory.path}/info.json').writeAsString(jsonEncode({
        'comicID': entry.key,
        'title': 'Fixture ${entry.key}',
        'size': 1.5,
        'cover': 'cover.jpg',
        if (entry.value.isNotEmpty) 'tags': entry.value,
      }));
    }

    // Legacy import uses the same database writer as download completion.
    await manager.init();
    await manager.dispose();
    await manager.init();

    expect(manager.total, fixtures.length);
    for (final entry in fixtures.entries) {
      final restored = await manager.getComicOrNull(entry.key);
      expect(restored, isA<NhentaiDownloadedComic>());
      expect(restored!.tags, entry.value);
      expect(restored.name, 'Fixture ${entry.key}');
      expect(restored.comicSize, 1.5);
      expect(manager.getAll().singleWhere((item) => item.id == entry.key).tags,
          entry.value);
    }
  });

  Gallery galleryFixture(String id, Map<String, List<String>> tags) => Gallery(
        'Gallery $id',
        'Manga',
        '2026-01-01 00:00:00',
        'Uploader',
        4.5,
        null,
        'cover.jpg',
        tags,
        [],
        null,
        false,
        'https://e-hentai.org/g/$id/fixture/',
        '15',
        20,
        [],
        'jpg',
        100,
        null,
      );

  test('EH gallery tag categories survive JSON round trips', () {
    for (final tags in [
      <String, List<String>>{
        'artist': ['Artist One', 'Artist & Two'],
        'language': ['chinese', 'translated'],
        'parody': ['Series: One', 'Series: One'],
        'other': [],
      },
      <String, List<String>>{},
      <String, List<String>>{
        'key': ['legacy unclassified tag']
      },
    ]) {
      final original = galleryFixture('123', tags);
      var restored = original;
      for (var round = 0; round < 3; round++) {
        restored = Gallery.fromJson(jsonDecode(jsonEncode(restored.toJson())));
        expect(restored.tags, tags);
        expect(restored.toBrief().tags, original.toBrief().tags);
        expect(restored.toJson(), original.toJson());
      }
    }
  });

  test('EH tags survive database migration and queue reopening', () async {
    final tags = <String, List<String>>{
      'artist': ['Artist One', 'Artist & Two'],
      'language': ['chinese'],
      'parody': ['Series One'],
    };
    final gallery = galleryFixture('123', tags);
    final comicDirectory = Directory('${directory.path}/123');
    await comicDirectory.create();
    await File('${comicDirectory.path}/info.json')
        .writeAsString(jsonEncode(DownloadedGallery(gallery, 1.5).toJson()));

    await manager.init();
    await manager.dispose();
    await getQueueFile().writeAsString(jsonEncode(committedQueue([
      {
        ...fixtureTask('456'),
        'type': 1,
        'gallery': galleryFixture('456', tags).toJson(),
        'downloadType': 0,
      },
    ])));
    await manager.init();

    final restored = await manager.getComicOrNull('123') as DownloadedGallery;
    expect(restored.gallery.tags, tags);
    expect(restored.gallery.toBrief().tags, gallery.toBrief().tags);
    expect(restored.tags, tags.values.expand((values) => values).toList());
    expect(restored.subTitle, 'Uploader');
    expect(restored.comicSize, 1.5);
    expect((manager.getAll().single as DownloadedGallery).gallery.tags, tags);
    final queued = manager.downloading.single as EhDownloadingItem;
    expect(queued.gallery.tags, tags);
    expect(queued.gallery.link, 'https://e-hentai.org/g/456/fixture/');
    expect(queued.toMap()['gallery']['tags'], tags);
  });

  test('legacy queue snapshots are upgraded with a committed marker', () async {
    await getQueueFile().writeAsString(jsonEncode({'downloading': []}));

    await manager.init();

    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['version'], 1);
    expect(snapshot['state'], 'committed');
    expect(snapshot['downloading'], isEmpty);
    expect(await getQueueFile('.tmp').exists(), isFalse);
    expect(await getQueueFile('.bak').exists(), isFalse);
    expect(await getQueueFile('.legacy-v1').exists(), isTrue);
  });

  test('a valid backup restores a truncated queue and preserves the bad file',
      () async {
    await getQueueFile().writeAsString('{"version":1');
    await getQueueFile('.bak').writeAsString(jsonEncode(committedQueue()));

    await manager.init();

    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['version'], 1);
    expect(snapshot['state'], 'committed');
    expect(await getQueueFile('.bak').exists(), isFalse);
    final preserved = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('newDownload.json.corrupt.'));
    expect(preserved, hasLength(1));
  });

  test('a backup symlink cannot import a queue from outside the root',
      () async {
    final externalDirectory =
        await Directory.systemTemp.createTemp('pica-download-external-');
    addTearDown(() async {
      if (await externalDirectory.exists()) {
        await externalDirectory.delete(recursive: true);
      }
    });
    final externalQueue = File('${externalDirectory.path}/queue.json');
    final externalContents = jsonEncode(
      committedQueue([fixtureTask('external')], 9),
    );
    await externalQueue.writeAsString(externalContents);
    await getQueueFile().writeAsString('{"version":1');
    final backupLink = Link(getQueueFile('.bak').path);
    await backupLink.create(externalQueue.path);

    await manager.init();

    expect(manager.downloading, isEmpty);
    expect(await externalQueue.readAsString(), externalContents);
    expect(await backupLink.exists(), isFalse);
    expect(
      directory
          .listSync()
          .whereType<FileSystemEntity>()
          .where((file) => file.path.contains('newDownload.json.bak.corrupt.')),
      hasLength(1),
    );
  });

  test('a complete temporary queue is promoted when the target is missing',
      () async {
    await getQueueFile('.tmp').writeAsString(jsonEncode(committedQueue()));

    await manager.init();

    expect(jsonDecode(await getQueueFile().readAsString())['version'], 1);
    expect(await getQueueFile('.tmp').exists(), isFalse);
  });

  test('a complete temporary queue wins over an older backup', () async {
    await getQueueFile().writeAsString('{"version":1');
    await getQueueFile('.bak')
        .writeAsString(jsonEncode(committedQueue(<Object?>[])));
    await getQueueFile('.tmp')
        .writeAsString(jsonEncode(committedQueue([fixtureTask('fixture')])));

    await manager.init();

    expect(await getQueueFile('.bak').exists(), isFalse);
    expect(await getQueueFile('.tmp').exists(), isFalse);
    expect(manager.downloading, hasLength(1));
  });

  test('a newer complete temporary snapshot supersedes a valid target',
      () async {
    await getQueueFile().writeAsString(jsonEncode(committedQueue([], 10)));
    await getQueueFile('.tmp').writeAsString(
      jsonEncode(committedQueue([fixtureTask('newer')], 11)),
    );

    await manager.init();

    expect(manager.downloading.single.id, 'newer');
    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['generation'], 11);
    expect(await getQueueFile('.tmp').exists(), isFalse);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.stale.')),
      hasLength(1),
    );
  });

  test('a newer backup supersedes an older temporary snapshot', () async {
    await getQueueFile().writeAsString('{"version":1');
    await getQueueFile('.tmp').writeAsString(
      jsonEncode(committedQueue([fixtureTask('temporary')], 20)),
    );
    await getQueueFile('.bak').writeAsString(
      jsonEncode(committedQueue([fixtureTask('backup')], 21)),
    );

    await manager.init();

    expect(manager.downloading.single.id, 'backup');
    expect(jsonDecode(await getQueueFile().readAsString())['generation'], 21);
    expect(await getQueueFile('.tmp').exists(), isFalse);
    expect(await getQueueFile('.bak').exists(), isFalse);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.corrupt.')),
      hasLength(1),
    );
  });

  test('a newer invalid task snapshot falls back to a valid backup', () async {
    await getQueueFile().writeAsString(
      jsonEncode(committedQueue([
        {'type': 999, 'id': 'invalid-newer'},
      ], 20)),
    );
    await getQueueFile('.bak').writeAsString(
      jsonEncode(committedQueue([fixtureTask('backup')], 19)),
    );

    await manager.init();

    expect(manager.downloading.single.id, 'backup');
    expect(jsonDecode(await getQueueFile().readAsString())['generation'], 19);
    expect(await getQueueFile('.bak').exists(), isFalse);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.corrupt.')),
      hasLength(1),
    );
  });

  test('a malformed temporary snapshot is preserved when target is valid',
      () async {
    await getQueueFile().writeAsString(jsonEncode(committedQueue([], 10)));
    await getQueueFile('.tmp').writeAsString('{"version":1');

    await manager.init();

    expect(manager.downloading, isEmpty);
    expect(jsonDecode(await getQueueFile().readAsString())['generation'], 10);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.tmp.corrupt.')),
      hasLength(1),
    );
  });

  test('invalid task records are rejected without deleting the source snapshot',
      () async {
    await getQueueFile().writeAsString(jsonEncode(committedQueue([
      {'type': 999, 'id': 'invalid'},
    ])));

    await manager.init();

    expect(manager.downloading, isEmpty);
    expect(jsonDecode(await getQueueFile().readAsString())['version'], 1);
    final preserved = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('newDownload.json.corrupt.'));
    expect(preserved, hasLength(1));
  });

  test('a legacy snapshot with an invalid generation falls back to backup',
      () async {
    await getQueueFile().writeAsString(jsonEncode({
      'generation': 'not-an-integer',
      'downloading': <Object?>[],
    }));
    await getQueueFile('.bak').writeAsString(
      jsonEncode(committedQueue([fixtureTask('backup')], 19)),
    );

    await manager.init();

    expect(manager.downloading.single.id, 'backup');
    expect(jsonDecode(await getQueueFile().readAsString())['generation'], 19);
    expect(await getQueueFile('.bak').exists(), isFalse);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.corrupt.')),
      hasLength(1),
    );
  });

  test('duplicate task ids are rejected to prevent duplicate downloads',
      () async {
    await getQueueFile().writeAsString(
      jsonEncode(committedQueue(
          [fixtureTask('duplicate'), fixtureTask('duplicate')], 2)),
    );

    await manager.init();

    expect(manager.downloading, isEmpty);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.corrupt.')),
      hasLength(1),
    );
  });

  test('task directories cannot escape the configured download root', () async {
    final task = fixtureTask('unsafe');
    task['directory'] = '../outside';
    await getQueueFile().writeAsString(
      jsonEncode(committedQueue([task], 3)),
    );

    await manager.init();

    expect(manager.downloading, isEmpty);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('newDownload.json.corrupt.')),
      hasLength(1),
    );
    expect(
        await Directory('${directory.parent.path}/outside').exists(), isFalse);
  });

  test('failed initialization can be retried after fixing the path', () async {
    final invalidPath = File('${directory.path}/not-a-directory');
    await invalidPath.writeAsString('occupied');
    appdata.settings[22] = invalidPath.path;

    await expectLater(manager.init(), throwsA(isA<FileSystemException>()));

    appdata.settings[22] = directory.path;
    await manager.init();

    expect(manager.path, directory.path);
    expect(manager.total, 0);
  });

  test('missing snapshot does not resurrect an in-memory queue', () async {
    manager.downloading.add(
      downloadingItemFromMap(
          fixtureTask('memory-only'), () {}, () {}, () async {}),
    );

    await manager.init();

    expect(manager.downloading, isEmpty);
    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['downloading'], isEmpty);
  });

  test('failing listeners cannot prevent a queue snapshot commit', () async {
    await manager.init();
    manager.downloading.add(
      downloadingItemFromMap(
          fixtureTask('listener-safe'), () {}, () {}, () async {}),
    );

    var healthyListenerCalled = false;
    void failingListener() {
      manager.removeListener(failingListener);
      throw StateError('stale download page listener');
    }

    void healthyListener() => healthyListenerCalled = true;

    manager
      ..addListener(failingListener)
      ..addListener(healthyListener);

    try {
      await manager.persistQueueForTesting();
    } finally {
      manager.removeListener(healthyListener);
    }

    expect(healthyListenerCalled, isTrue);
    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['state'], 'committed');
    expect((snapshot['downloading'] as List).single['id'], 'listener-safe');
  });

  test('disposing the manager persists the cleared queue snapshot', () async {
    await getQueueFile().writeAsString(
      jsonEncode(committedQueue([fixtureTask('disposed')], 4)),
    );

    await manager.init();
    expect(manager.downloading.single.id, 'disposed');

    await manager.dispose();

    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['state'], 'committed');
    expect(snapshot['downloading'], isEmpty);

    await manager.init();
    expect(manager.downloading, isEmpty);
  });

  test('failed dispose snapshot cannot resurrect stopped tasks', () async {
    await getQueueFile().writeAsString(
      jsonEncode(committedQueue([fixtureTask('dispose-failure')], 4)),
    );

    await manager.init();
    expect(manager.downloading.single.id, 'dispose-failure');

    // Force the atomic writer to fail before it can replace the old target.
    await Directory(getQueueFile('.tmp').path).create();
    await manager.dispose();

    expect(manager.downloading, isEmpty);
    expect(await getQueueFile().exists(), isFalse);
    expect(
      directory.listSync().whereType<FileSystemEntity>().where(
          (entity) => entity.path.contains('newDownload.json.disposed.')),
      isNotEmpty,
    );

    await manager.init();
    expect(manager.downloading, isEmpty);
    final snapshot =
        jsonDecode(await getQueueFile().readAsString()) as Map<String, dynamic>;
    expect(snapshot['downloading'], isEmpty);
  });

  test('deleting an already deleted comic is idempotent', () async {
    createDownloadDatabase(directory, [
      ['repeat-delete', 'title', '', 1, 'repeat-delete', 0, '{}'],
    ]);
    await Directory('${directory.path}/repeat-delete').create();

    await manager.init();
    final totals = <int>[];
    void listener() => totals.add(manager.total);
    manager.addListener(listener);
    addTearDown(() => manager.removeListener(listener));
    await manager.delete(['repeat-delete']);
    expect(
        await Directory('${directory.path}/repeat-delete').exists(), isFalse);
    expect(manager.total, 0);

    await expectLater(manager.delete(['repeat-delete']), completes);
    expect(manager.total, 0);
    expect(totals, [0]);
  });

  test('a partially failed delete publishes the committed download count',
      () async {
    createDownloadDatabase(directory, [
      ['removed', 'title', '', 1, 'removed', 0, '{}'],
      ['retained', 'title', '', 1, 'unsafe/path', 0, '{}'],
    ]);
    await manager.init();
    final totals = <int>[];
    void listener() => totals.add(manager.total);
    manager.addListener(listener);
    addTearDown(() => manager.removeListener(listener));

    await expectLater(
        manager.delete(['removed', 'retained']), throwsStateError);

    expect(manager.total, 1);
    expect(manager.isExists('removed'), isFalse);
    expect(manager.isExists('retained'), isTrue);
    expect(totals, [1]);
  });

  test('metadata updates preserve downloaded directory and original time',
      () async {
    const id = 'fixture-comic-1';
    final originalTime = DateTime(2026, 1, 1);
    createDownloadDatabase(directory, [
      [
        id,
        'Fixture comic',
        'Fixture author',
        originalTime.millisecondsSinceEpoch,
        'stable-directory',
        2,
        jsonEncode({
          'comicSize': 2.0,
          'downloadedEps': <int>[1],
          'chapters': <String, String>{
            'chapter-1': 'Chapter 1',
            'chapter-2': 'Chapter 2',
          },
          'id': id,
          'name': 'Fixture comic',
          'subTitle': 'Fixture author',
          'tags': <String>[],
          'sourceKey': 'fixture_source',
          'sourceName': 'Fixture source',
          'cover': 'https://fixture.test/cover.jpg',
          'comicId': 'comic-1',
        }),
      ],
    ]);

    await manager.init();
    final updated = CustomDownloadedItem(
      2,
      [1],
      const {
        'chapter-1': 'Chapter 1',
        'chapter-2': 'Chapter 2',
        'chapter-3': 'Chapter 3',
      },
      id,
      'Fixture comic',
      'Fixture author',
      const [],
      'fixture_source',
      'Fixture source',
      'https://fixture.test/cover.jpg',
      'comic-1',
    )
      ..directory = 'replacement-directory'
      ..time = DateTime(2030, 1, 1);

    manager.updateComic(id, (_) => updated);

    expect(updated.directory, 'stable-directory');
    expect(updated.time, originalTime);
    await manager.dispose();
    await manager.init();
    final restored = await manager.getComicOrNull(id) as CustomDownloadedItem;
    expect(restored.chapters, {
      'chapter-1': 'Chapter 1',
      'chapter-2': 'Chapter 2',
      'chapter-3': 'Chapter 3',
    });
    expect(restored.directory, 'stable-directory');
    expect(restored.time, originalTime);
  });

  test('PICACG chapter refresh accepts an append without moving downloads', () {
    final originalTime = DateTime(2025, 3, 4);
    final item = DownloadedComic(
      picacgComic(),
      ['Chapter 1', 'Chapter 2'],
      12,
      [0, 1],
    )
      ..directory = 'picacg-stable'
      ..time = originalTime;
    expect(refreshPicacgDownloadedChapters(item, item.chapters), same(item));

    final updated = refreshPicacgDownloadedChapters(
      item,
      ['Chapter 1', 'Chapter 2', 'Chapter 3'],
    );

    expect(updated.chapters, ['Chapter 1', 'Chapter 2', 'Chapter 3']);
    expect(updated.downloadedChapters, [0, 1]);
    expect(updated.directory, 'picacg-stable');
    expect(updated.time, originalTime);
    expect(item.chapters, ['Chapter 1', 'Chapter 2']);
  });

  test('custom chapter refresh rejects invalid downloaded positions and IDs',
      () {
    CustomDownloadedItem item(List<int> downloaded) => CustomDownloadedItem(
        2,
        downloaded,
        {'ep-1': 'First', 'ep-2': 'Second'},
        'fixture-1',
        'Fixture',
        '',
        [],
        'fixture',
        'Fixture',
        '',
        '1');
    for (final downloaded in [
      [-1],
      [2],
      [0, 0]
    ]) {
      expect(
          () => refreshCustomDownloadedChapters(
              item(downloaded), {'ep-1': 'First', 'ep-2': 'Second'}),
          throwsStateError);
    }
    expect(
        () => refreshCustomDownloadedChapters(
            item([0]), {'ep-1': 'First', '': 'Invalid'}),
        throwsStateError);
  });

  test('PICACG chapter refresh rejects changed downloaded positions', () {
    final item = DownloadedComic(
      picacgComic(),
      ['Chapter 1', 'Chapter 2'],
      12,
      [1],
    );

    for (final chapters in [
      ['New chapter', 'Chapter 1', 'Chapter 2'],
      ['Chapter 2', 'Chapter 1'],
      ['Chapter 1'],
      ['', 'Chapter 2'],
      <String>[],
    ]) {
      expect(
        () => refreshPicacgDownloadedChapters(item, chapters),
        throwsA(isA<StateError>()),
        reason: '$chapters must not change downloaded directory mappings',
      );
    }
    item.downloadedChapters = [-1];
    expect(() => refreshPicacgDownloadedChapters(item, item.chapters),
        throwsStateError);
    item.downloadedChapters = [2];
    expect(() => refreshPicacgDownloadedChapters(item, item.chapters),
        throwsStateError);
  });

  test('JM chapter refresh accepts appended IDs and preserves local identity',
      () {
    final originalTime = DateTime(2025, 4, 5);
    final item = DownloadedJmComic(
      jmComic({1: 'ep-1', 2: 'ep-2'}, ['Chapter 1', 'Chapter 2']),
      12,
      [1],
    )
      ..directory = 'jm-stable'
      ..time = originalTime;
    expect(refreshJmDownloadedChapters(item, item.comic), same(item));

    final updated = refreshJmDownloadedChapters(
      item,
      jmComic(
        {1: 'ep-1', 2: 'ep-2', 3: 'ep-3'},
        ['Renamed chapter 1', 'Chapter 2', 'Chapter 3'],
      ),
    );

    expect(updated.comic.series, {1: 'ep-1', 2: 'ep-2', 3: 'ep-3'});
    expect(updated.comic.epNames.first, 'Renamed chapter 1');
    expect(updated.downloadedChapters, [1]);
    expect(updated.directory, 'jm-stable');
    expect(updated.time, originalTime);
    expect(item.comic.series, {1: 'ep-1', 2: 'ep-2'});
  });

  test('JM chapter refresh rejects a changed downloaded chapter ID', () {
    final item = DownloadedJmComic(
      jmComic({1: 'ep-1', 2: 'ep-2'}, ['Chapter 1', 'Chapter 2']),
      12,
      [1],
    );

    for (final latest in [
      jmComic({1: 'ep-2', 2: 'ep-1'}, ['Chapter 2', 'Chapter 1']),
      jmComic({1: 'ep-1'}, ['Chapter 1']),
      jmComic({}, []),
      jmComic({1: 'ep-1', 3: 'ep-2'}, ['Chapter 1', 'Chapter 2']),
      jmComic({2: 'ep-2', 1: 'ep-1'}, ['Chapter 2', 'Chapter 1']),
      jmComic({1: 'ep-1', 2: ''}, ['Chapter 1', 'Chapter 2']),
      jmComic({1: 'ep-1', 2: 'ep-2', 3: 'ep-1'}, []),
      jmComic({1: 'ep-1', 2: 'ep-2'}, ['Only one name']),
      jmComic({1: 'ep-1', 2: 'ep-2'}, [], id: '456'),
    ]) {
      expect(
        () => refreshJmDownloadedChapters(item, latest),
        throwsA(isA<StateError>()),
        reason: '${latest.id}: ${latest.series} must preserve old downloads',
      );
    }
    item.downloadedChapters = [-1];
    expect(
        () => refreshJmDownloadedChapters(item, item.comic), throwsStateError);
    item.downloadedChapters = [2];
    expect(
        () => refreshJmDownloadedChapters(item, item.comic), throwsStateError);
  });

  test('JM single chapter refresh retains the original chapter identity', () {
    final item = DownloadedJmComic(jmComic({}, []), 1, [0]);
    final updated =
        refreshJmDownloadedChapters(item, jmComic({}, ['Single chapter']));
    expect(updated.comic.series, {1: item.comic.id});
    expect(updated.eps, ['Single chapter']);
    expect(updated.downloadedEps, [0]);
    expect(
      () => refreshJmDownloadedChapters(
          item, jmComic({1: 'different-chapter'}, ['Single chapter'])),
      throwsStateError,
    );
    final appended = refreshJmDownloadedChapters(item,
        jmComic({1: item.comic.id, 2: 'ep-2'}, ['Single chapter', 'New']));
    expect(appended.comic.series.values, [item.comic.id, 'ep-2']);
    expect(appended.downloadedEps, [0]);
  });

  for (final source in ['PICACG', 'JM']) {
    test('$source chapter refresh survives reopening without changing files',
        () async {
      final DownloadedItem original = source == 'PICACG'
          ? DownloadedComic(picacgComic(), ['Chapter 1', 'Chapter 2'], 12, [1])
          : DownloadedJmComic(
              jmComic({1: 'ep-1', 2: 'ep-2'}, ['Chapter 1', 'Chapter 2']),
              12,
              [1]);
      final originalTime = DateTime(2025, 6, 7);
      createDownloadDatabase(directory, [
        [
          original.id,
          original.name,
          original.subTitle,
          originalTime.millisecondsSinceEpoch,
          'stable-directory',
          12,
          jsonEncode(original.toJson()),
        ],
      ]);
      final image = File('${directory.path}/stable-directory/2/0.jpg');
      await image.create(recursive: true);
      await image.writeAsBytes([1, 2, 3]);
      await manager.init();
      final stored = (await manager.getComicOrNull(original.id))!;
      final updated = stored is DownloadedComic
          ? refreshPicacgDownloadedChapters(
              stored, ['Chapter 1', 'Chapter 2', 'Chapter 3'])
          : refreshJmDownloadedChapters(
              stored as DownloadedJmComic,
              jmComic({1: 'ep-1', 2: 'ep-2', 3: 'ep-3'},
                  ['Chapter 1', 'Chapter 2', 'Chapter 3']));
      manager.updateComic(original.id, (_) => updated);

      await manager.dispose();
      await manager.init();
      final restored = (await manager.getComicOrNull(original.id))!;
      expect(restored.eps, ['Chapter 1', 'Chapter 2', 'Chapter 3']);
      expect(restored.downloadedEps, [1]);
      expect(restored.comicSize, 12);
      expect(restored.directory, 'stable-directory');
      expect(restored.time, originalTime);
      expect(await image.readAsBytes(), [1, 2, 3]);
      expect(Directory('${directory.path}/stable-directory/3').existsSync(),
          isFalse);
    });
  }

  test('deleting an episode preserves the comic download timestamp', () async {
    const id = 'fixture-comic-2';
    final originalTime = DateTime(2024, 5, 6);
    createDownloadDatabase(directory, [
      [
        id,
        'Fixture comic',
        'Fixture author',
        originalTime.millisecondsSinceEpoch,
        'stable-directory',
        2,
        jsonEncode({
          'comicSize': 2.0,
          'downloadedEps': <int>[0, 1],
          'chapters': <String, String>{
            'chapter-1': 'Chapter 1',
            'chapter-2': 'Chapter 2',
          },
          'id': id,
          'name': 'Fixture comic',
          'subTitle': 'Fixture author',
          'tags': <String>[],
          'sourceKey': 'fixture_source',
          'sourceName': 'Fixture source',
          'cover': 'https://fixture.test/cover.jpg',
          'comicId': 'comic-2',
        }),
      ],
    ]);
    await Directory('${directory.path}/stable-directory/1')
        .create(recursive: true);
    await Directory('${directory.path}/stable-directory/2')
        .create(recursive: true);

    await manager.init();
    final comic = await manager.getComicOrNull(id);
    final db = sqlite3.open('${directory.path}/download.db');
    final data = comic!.toJson()
      ..['downloadedEps'] = [0, 1, 2]
      ..['chapters'] = {
        'chapter-1': 'Chapter 1',
        'chapter-2': 'Chapter 2',
        'chapter-3': 'Chapter 3',
      };
    db.execute(
        'update download set json = ? where id = ?', [jsonEncode(data), id]);
    db.dispose();
    final result = await manager.deleteEpisode(comic, 0);

    expect(result, isNull);
    await manager.dispose();
    await manager.init();
    final restored = await manager.getComicOrNull(id) as CustomDownloadedItem;
    expect(restored.downloadedEps, [1, 2]);
    expect(restored.eps, ['Chapter 1', 'Chapter 2', 'Chapter 3']);
    expect(restored.time, originalTime);
  });

  test('deleting a record without a directory removes the orphaned row',
      () async {
    createDownloadDatabase(directory, [
      ['orphaned-directory', 'title', '', 1, null, 0, '{}'],
    ]);

    await manager.init();
    expect(manager.total, 1);
    final totals = <int>[];
    void listener() => totals.add(manager.total);
    manager.addListener(listener);
    addTearDown(() => manager.removeListener(listener));

    await manager.delete(['orphaned-directory']);

    expect(manager.total, 0);
    await expectLater(manager.delete(['orphaned-directory']), completes);
    expect(manager.total, 0);
    expect(totals, [0]);
  });

  test('directory cache is scoped to the active download root', () async {
    const id = 'cache-root-switch';
    final secondDirectory =
        await Directory.systemTemp.createTemp('pica-download-persistence-');

    try {
      createDownloadDatabase(directory, [
        [id, 'title', '', 1, 'first-root', 0, '{}'],
      ]);
      await manager.init();
      expect(manager.getDirectory(id), 'first-root');

      await manager.dispose();
      appdata.settings[22] = secondDirectory.path;
      createDownloadDatabase(secondDirectory, [
        [id, 'title', '', 1, 'second-root', 0, '{}'],
      ]);
      await manager.init();

      expect(manager.getDirectory(id), 'second-root');
    } finally {
      await manager.dispose();
      manager.path = null;
      if (await secondDirectory.exists()) {
        await secondDirectory.delete(recursive: true);
      }
    }
  });

  test('unsafe database directories are rejected before deletion', () async {
    createDownloadDatabase(directory, [
      ['unsafe-directory', 'title', '', 1, 'owned/path', 0, '{}'],
    ]);

    // Sanitizing `owned/path` would resolve to `owned path` and could delete
    // an unrelated directory. The malformed row must remain retryable.
    final unrelated = Directory('${directory.path}/owned path');
    await unrelated.create();
    final marker = File('${unrelated.path}/keep.txt');
    await marker.writeAsString('keep');

    await manager.init();

    await expectLater(
      manager.delete(['unsafe-directory']),
      throwsA(isA<StateError>()),
    );
    expect(await marker.exists(), isTrue);
    expect(manager.total, 1);
  });

  test('download sorting accepts only mapped columns and directions', () async {
    createDownloadDatabase(directory, [
      for (final row in <(String, String, int)>[
        ('source-b', 'Beta', 20),
        ('source-a', 'Alpha', 10),
      ])
        [
          row.$1,
          row.$2,
          'author',
          row.$3,
          row.$1,
          row.$3,
          jsonEncode({
            'comicSize': row.$3.toDouble(),
            'downloadedEps': <int>[],
            'chapters': <String, String>{},
            'id': row.$1,
            'name': row.$2,
            'subTitle': 'author',
            'tags': <String>[],
            'sourceKey': 'fixture',
            'sourceName': 'Fixture',
            'cover': '',
            'comicId': row.$1,
          }),
        ],
    ]);

    await manager.init();

    expect(manager.getAll('title', 'asc').map((item) => item.name),
        ['Alpha', 'Beta']);
    expect(manager.getAll('size', 'DESC').map((item) => item.name),
        ['Beta', 'Alpha']);
    expect(
      () => manager.getAll('title desc, id', 'asc'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => manager.getAll('title', 'desc; drop table download'),
      throwsA(isA<ArgumentError>()),
    );
    expect(manager.total, 2);
  });

  test('malformed legacy row does not hide valid downloaded comics', () async {
    final valid = DownloadedGallery(galleryFixture('10001', const {}), 2);
    final timestamp = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    createDownloadDatabase(directory, [
      [
        valid.id,
        valid.name,
        valid.subTitle,
        timestamp,
        'valid-gallery',
        2,
        jsonEncode(valid.toJson()),
      ],
      [
        '10002',
        'Malformed legacy gallery',
        '',
        timestamp,
        'malformed-gallery',
        0,
        jsonEncode({'gallery': null, 'size': null}),
      ],
    ]);

    await manager.init();

    expect(manager.getAll().map((comic) => comic.id), [valid.id]);
    expect(manager.total, 2);
  });
}
