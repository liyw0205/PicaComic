import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/state_controller.dart';
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
