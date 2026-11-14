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
}
