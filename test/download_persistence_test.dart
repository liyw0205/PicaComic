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
    await getQueueFile('.tmp').writeAsString(jsonEncode(committedQueue([
      {
        'type': 7,
        'id': 'fixture',
        '_downloadedNum': 0,
        '_downloadingEp': 0,
        'index': 0,
        'links': null,
        'directory': 'fixture',
        'finishedTasks': <String>[],
        'comic': {
          'name': 'fixture',
          'author': '',
          'type': 0,
          'tags': <String>[],
          'target': 'fixture',
          'coverPath': '',
          'time': '2026-01-01 00:00:00',
        },
      }
    ])));

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
          .where((file) => file.path.contains('newDownload.json.corrupt.')),
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

  test('download sorting accepts only mapped columns and directions', () async {
    final db = sqlite3.open('${directory.path}/download.db');
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
    for (final row in <(String, String, int)>[
      ('source-b', 'Beta', 20),
      ('source-a', 'Alpha', 10),
    ]) {
      final id = row.$1;
      db.execute(
        'insert into download values (?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          row.$2,
          'author',
          row.$3,
          id,
          row.$3,
          jsonEncode({
            'comicSize': row.$3.toDouble(),
            'downloadedEps': <int>[],
            'chapters': <String, String>{},
            'id': id,
            'name': row.$2,
            'subTitle': 'author',
            'tags': <String>[],
            'sourceKey': 'fixture',
            'sourceName': 'Fixture',
            'cover': '',
            'comicId': id,
          }),
        ],
      );
    }
    db.dispose();

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
