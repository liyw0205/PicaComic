import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/download.dart';
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
    await manager.delete(['repeat-delete']);
    expect(
        await Directory('${directory.path}/repeat-delete').exists(), isFalse);
    expect(manager.total, 0);

    await expectLater(manager.delete(['repeat-delete']), completes);
    expect(manager.total, 0);
  });

  test('deleting a record without a directory removes the orphaned row',
      () async {
    createDownloadDatabase(directory, [
      ['orphaned-directory', 'title', '', 1, null, 0, '{}'],
    ]);

    await manager.init();
    expect(manager.total, 1);

    await manager.delete(['orphaned-directory']);

    expect(manager.total, 0);
    await expectLater(manager.delete(['orphaned-directory']), completes);
    expect(manager.total, 0);
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
}
