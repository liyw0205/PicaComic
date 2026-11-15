import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/state_controller.dart';
import 'package:pica_comic/pages/image_favorites.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pica_image_favorites_');
    path = '${directory.path}/history.db';
    final manager = HistoryManager.create();
    await manager.init(databasePath: path, importLegacy: false);
    manager.close();
  });

  tearDown(() async {
    HistoryManager().close();
    await directory.delete(recursive: true);
  });

  void insertRows(Iterable<(String, String)> rows) {
    final db = sqlite3.open(path);
    try {
      for (final row in rows) {
        db.execute(
            'insert into image_favorites(id,title,cover,ep,page,other) '
            'values(?, ?, ?, ?, ?, ?);',
            [row.$1, row.$2, '', 1, 1, '{}']);
      }
    } finally {
      db.dispose();
    }
  }

  test('falls back when the optional title index is not an FTS table',
      () async {
    HistoryManager().close();
    await File(path).delete();
    final db = sqlite3.open(path);
    db.execute('''
      create table history(
        target text primary key, title text, subtitle text, cover text,
        time int, type int, ep int, page int, readEpisode text, max_page int
      );
      create table image_favorites(
        id text, title text not null, cover text not null, ep int not null,
        page int not null, other text not null, primary key(id, ep, page)
      );
      create table image_favorites_title_fts(rowid integer, title text);
      insert into image_favorites values
        ('fallback', 'Fallback title', '', 1, 1, '{}');
    ''');
    db.dispose();

    await HistoryManager().init(databasePath: path, importLegacy: false);
    expect(ImageFavoriteManager.getPage(keyword: 'title').items.single.id,
        'fallback');
    expect(ImageFavoriteManager.count(keyword: 'title'), 1);
  });

  test('keyset pages remain stable across deletes and inserts', () async {
    insertRows([
      ('image-0', 'Title 0'),
      ('image-1', 'Title 1'),
      ('image-2', 'Title 2'),
      ('image-3', 'Title 3'),
      ('image-4', 'Title 4'),
    ]);
    await HistoryManager().init(databasePath: path, importLegacy: false);

    final first = ImageFavoriteManager.getPage(limit: 2);
    expect(first.items.map((item) => item.id), ['image-4', 'image-3']);
    expect(first.nextCursor, isNotNull);

    HistoryManager().close();
    final db = sqlite3.open(path);
    db.execute('delete from image_favorites where id = ?;', ['image-4']);
    db.dispose();
    insertRows([('image-new', 'Title new')]);
    await HistoryManager().init(databasePath: path, importLegacy: false);

    final second = ImageFavoriteManager.getPage(
      limit: 2,
      afterRowId: first.nextCursor,
    );
    expect(second.items.map((item) => item.id), ['image-2', 'image-1']);
    expect(ImageFavoriteManager.count(keyword: 'TITLE 2'), 1);
    expect(ImageFavoriteManager.getPage(keyword: 'title 2').items.single.id,
        'image-2');
  });

  test('title searches keep short-term semantics and use trigram FTS',
      () async {
    insertRows([
      ('image-0', 'A title for search'),
      ('image-1', 'Another title'),
      ('image-2', 'No match'),
    ]);
    await HistoryManager().init(databasePath: path, importLegacy: false);

    expect(
        ImageFavoriteManager.getPage(keyword: 'title')
            .items
            .map((item) => item.id),
        ['image-1', 'image-0']);
    final firstTitlePage =
        ImageFavoriteManager.getPage(keyword: 'title', limit: 1);
    expect(
        ImageFavoriteManager.getPage(
                keyword: 'title',
                limit: 1,
                afterRowId: firstTitlePage.nextCursor)
            .items
            .single
            .id,
        'image-0');
    // Two-character terms are deliberately kept on the old contains path;
    // the trigram tokenizer only guarantees matches for three code points.
    expect(ImageFavoriteManager.count(keyword: 'le'), 2);

    final fixture = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final plan = fixture.select('''
        explain query plan
        select i.rowid, i.*
        from image_favorites i
        join image_favorites_title_fts f on f.rowid = i.rowid
        where f.image_favorites_title_fts match ?
        order by i.rowid desc limit ?;
      ''', ['"title"', 60]).map((row) => row['detail'] as String).join(' ');
      expect(plan, contains('VIRTUAL TABLE INDEX'));
      expect(plan, isNot(contains('SCAN image_favorites')));
    } finally {
      fixture.dispose();
    }

    // Triggers keep the auxiliary index in sync for writes made after init.
    insertRows([('image-late', 'Late title')]);
    expect(ImageFavoriteManager.getPage(keyword: 'late').items.single.id,
        'image-late');
    final db = sqlite3.open(path);
    db.execute('delete from image_favorites where id = ?;', ['image-late']);
    db.dispose();
    expect(ImageFavoriteManager.count(keyword: 'late'), 0);
  });

  test('incremental head refresh reaches every new row in bounded batches',
      () async {
    insertRows([
      ('image-0', 'Title 0'),
      ('image-1', 'Title 1'),
      ('image-2', 'Title 2'),
    ]);
    await HistoryManager().init(databasePath: path, importLegacy: false);

    final first = ImageFavoriteManager.getPage(limit: 2);
    expect(first.items.map((item) => item.id), ['image-2', 'image-1']);
    final watermark = first.firstRowId;
    expect(watermark, isNotNull);

    // Delete the highest rowid so the first new insert reuses the watermark;
    // the following inserts also force the refresh to cross a page boundary.
    HistoryManager().close();
    final db = sqlite3.open(path);
    db.execute('delete from image_favorites where id = ?;', ['image-2']);
    db.dispose();
    insertRows([
      ('image-new-0', 'New 0'),
      ('image-new-1', 'New 1'),
      ('image-new-2', 'New 2'),
    ]);
    await HistoryManager().init(databasePath: path, importLegacy: false);

    final refreshed = <ImageFavorite>[];
    int? cursor;
    while (true) {
      final page = ImageFavoriteManager.getPage(
        limit: 2,
        afterRowId: cursor,
        newerThanOrEqualRowId: watermark,
      );
      refreshed.addAll(page.items);
      if (!page.hasMore) break;
      cursor = page.nextCursor;
      expect(cursor, isNotNull);
    }

    expect(refreshed.map((item) => item.id),
        ['image-new-2', 'image-new-1', 'image-new-0']);
  });

  testWidgets('refresh reloads after all rows are deleted and rowids reset',
      (tester) async {
    final imagePath = '${directory.path}/pixel.png';
    // Keep the fixture independent of platform encoders while exercising the
    // same image-provider path as a real local thumbnail.
    await File(imagePath).writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
    final db = sqlite3.open(path);
    try {
      db.execute('insert into image_favorites values(?, ?, ?, ?, ?, ?);',
          ['old-0', 'Old 0', imagePath, 1, 1, '{}']);
      db.execute('insert into image_favorites values(?, ?, ?, ?, ?, ?);',
          ['old-1', 'Old 1', imagePath, 1, 2, '{}']);
    } finally {
      db.dispose();
    }
    await HistoryManager().init(databasePath: path, importLegacy: false);

    await tester.pumpWidget(const MaterialApp(home: ImageFavoritesPage()));
    await tester.pump();
    expect(find.text('Old 1'), findsOneWidget);

    HistoryManager().close();
    final emptied = sqlite3.open(path);
    emptied.execute('delete from image_favorites;');
    emptied.dispose();
    final replacement = sqlite3.open(path);
    replacement.execute('insert into image_favorites values(?, ?, ?, ?, ?, ?);',
        ['new', 'New image', imagePath, 1, 1, '{}']);
    replacement.dispose();
    await HistoryManager().init(databasePath: path, importLegacy: false);

    StateController.findOrNull(tag: 'image_favorites_page')?.refresh();
    await tester.pump();
    expect(find.text('New image'), findsOneWidget);
  });

  test('existing key lookup preserves identity and handles missing rows',
      () async {
    insertRows([
      ('image-0', 'Title 0'),
      ('image-1', 'Title 1'),
    ]);
    await HistoryManager().init(databasePath: path, importLegacy: false);

    final existing = ImageFavoriteManager.existingKeys([
      const ImageFavorite('image-0', '', 'Title 0', 1, 1, {}),
      const ImageFavorite('image-1', '', 'Title 1', 1, 1, {}),
      const ImageFavorite('missing', '', 'Missing', 1, 1, {}),
    ]);

    expect(existing, {
      'image-0\u00001\u00001',
      'image-1\u00001\u00001',
    });
  });

  test('repeated deletes publish only the first actual mutation', () async {
    await HistoryManager().init(databasePath: path, importLegacy: false);
    const image = ImageFavorite('image-0', '', 'Title 0', 1, 1, {});

    await DataMaintenance.run(() async {
      await ImageFavoriteManager.add(image);
      await ImageFavoriteManager.delete(image);
      await ImageFavoriteManager.delete(image);
    }, suppressSync: true, operationName: 'image-favorites-delete');

    expect(DataMaintenance.lastStats?.syncRequests, 2);
    expect(DataMaintenance.lastStats?.suppressedSyncRequests, 2);
    expect(ImageFavoriteManager.exist(image.id, image.ep, image.page), isFalse);
  });

  test('favorite image keys preserve composite field boundaries', () {
    const first = ImageFavorite('comic-1', '', 'Title 1', 2, 34, {});
    const second = ImageFavorite('comic-12', '', 'Title 2', 3, 4, {});

    expect(first.key, 'comic-1\u00002\u000034');
    expect(second.key, 'comic-12\u00003\u00004');
    expect(first.key, isNot(second.key));
  });

  test('consecutive writes coalesce page refresh notifications', () async {
    await HistoryManager().init(databasePath: path, importLegacy: false);
    var meUpdates = 0;
    var imagePageRefreshes = 0;
    final mePage = StateController.putSimpleController(
      () => meUpdates++,
      'me_page',
    );
    final imagePage = StateController.putSimpleController(
      () {},
      'image_favorites_page',
      refresh: () => imagePageRefreshes++,
    );
    addTearDown(mePage.dispose);
    addTearDown(imagePage.dispose);

    await DataMaintenance.run(() async {
      await ImageFavoriteManager.add(
          const ImageFavorite('image-0', '', 'Title 0', 1, 1, {}));
      await ImageFavoriteManager.add(
          const ImageFavorite('image-1', '', 'Title 1', 1, 1, {}));
    }, suppressSync: true);
    await Future<void>.delayed(Duration.zero);

    expect(meUpdates, 1);
    expect(imagePageRefreshes, 1);
  });

  test('history image merge refreshes an open image favorites page once',
      () async {
    final sourcePath = '${directory.path}/history-source.db';
    final source = HistoryManager.create();
    await source.init(databasePath: sourcePath, importLegacy: false);
    source.close();
    final sourceDb = sqlite3.open(sourcePath);
    sourceDb.execute(
        "insert into image_favorites values('merged-image','Merged','',1,1,'{}');");
    sourceDb.dispose();

    final destination = HistoryManager();
    await destination.init(databasePath: path, importLegacy: false);
    var meUpdates = 0;
    var imagePageRefreshes = 0;
    final mePage = StateController.putSimpleController(
      () => meUpdates++,
      'me_page',
    );
    final imagePage = StateController.putSimpleController(
      () {},
      'image_favorites_page',
      refresh: () => imagePageRefreshes++,
    );
    addTearDown(mePage.dispose);
    addTearDown(imagePage.dispose);

    await destination.mergeFrom(sourcePath);
    await Future<void>.delayed(Duration.zero);
    final destinationDb = sqlite3.open(path);
    expect(destinationDb.select('select id from image_favorites;').single['id'],
        'merged-image');
    destinationDb.dispose();
    expect(meUpdates, 1);
    expect(imagePageRefreshes, 1);

    await destination.mergeFrom(sourcePath);
    await Future<void>.delayed(Duration.zero);
    expect(meUpdates, 1);
    expect(imagePageRefreshes, 1);
  });
}
