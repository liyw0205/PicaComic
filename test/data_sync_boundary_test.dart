import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late HistoryManager manager;
  late LocalFavoritesManager favorites;
  late String favoritesFolder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pica-sync-boundary-');
    manager = HistoryManager.create();
    HistoryManager.cache = manager;
    await manager.init(
      databasePath: '${root.path}/history.db',
      importLegacy: false,
    );
    favorites = LocalFavoritesManager.create();
    await favorites.init(
      databasePath: '${root.path}/local_favorite.db',
      importLegacy: false,
    );
    favoritesFolder = favorites.createFolder('bulk');
  });

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    favorites.close();
    manager.close();
    if (identical(HistoryManager.cache, manager)) HistoryManager.cache = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  ImageFavorite favorite(String id) =>
      ImageFavorite(id, 'cover', 'title', 1, 2, const {});

  History history(String id) => History(
        HistoryType.picacg,
        DateTime.fromMillisecondsSinceEpoch(1000),
        'title',
        '',
        '',
        0,
        0,
        id,
      );

  FavoriteItem comic(String id) => FavoriteItem(
        target: id,
        name: 'title',
        coverPath: '',
        author: '',
        type: FavoriteType.picacg,
        tags: const [],
      );

  test('suppressed maintenance scope writes image favorites as one batch',
      () async {
    final image = favorite('batch');

    await DataMaintenance.run(() async {
      expect(DataMaintenance.syncSuppressed, isTrue);
      await ImageFavoriteManager.add(image);
      await ImageFavoriteManager.delete(image);
      await ImageFavoriteManager.add(image);
    }, suppressSync: true);

    expect(ImageFavoriteManager.exist(image.id, image.ep, image.page), isTrue);
    expect(ImageFavoriteManager.count(), 1);
  });

  test('user image writes wait for an active maintenance scope', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final maintenance = DataMaintenance.run(() async {
      entered.complete();
      await release.future;
    }, suppressSync: true);
    await entered.future;

    final image = favorite('deferred');
    final insertion = ImageFavoriteManager.add(image);
    expect(ImageFavoriteManager.exist(image.id, image.ep, image.page), isFalse);

    release.complete();
    await maintenance;
    await insertion;
    await DataMaintenance.waitForIdle();
    expect(ImageFavoriteManager.exist(image.id, image.ep, image.page), isTrue);
  });

  test('normal scope leaves synchronization enabled for user writes', () async {
    final image = favorite('normal');
    await DataMaintenance.run(() async {
      expect(DataMaintenance.syncSuppressed, isFalse);
      await ImageFavoriteManager.add(image);
    });

    expect(ImageFavoriteManager.exist(image.id, image.ep, image.page), isTrue);
  });

  test('batch context counts suppressed requests without publishing', () async {
    await DataMaintenance.run(() async {
      for (var i = 0; i < 100; i++) {
        await ImageFavoriteManager.add(favorite('import-$i'));
      }
    }, suppressSync: true, operationName: 'data-import');

    final stats = DataMaintenance.lastStats;
    expect(stats?.operation, 'data-import');
    expect(stats?.syncRequests, 100);
    expect(stats?.suppressedSyncRequests, 100);
    expect(stats?.unsuppressedSyncRequests, 0);
    expect(ImageFavoriteManager.count(), 100);
  });

  test('a 1000-item batch suppresses sync requests for all data stores',
      () async {
    const count = 1000;
    await DataMaintenance.run(() async {
      for (var i = 0; i < count; i++) {
        await manager.addHistory(history('history-$i'));
        await ImageFavoriteManager.add(favorite('image-$i'));
        await favorites.addComic(
            favoritesFolder, comic('comic-$i'), null, false);
      }
    }, suppressSync: true, operationName: 'data-import');

    final stats = DataMaintenance.lastStats;
    expect(stats?.operation, 'data-import');
    // Each local mutator records its publication intent, but suppression must
    // prevent every one of those 3,000 intents from becoming a remote write.
    expect(stats?.syncRequests, count * 3);
    expect(stats?.suppressedSyncRequests, count * 3);
    expect(stats?.unsuppressedSyncRequests, 0);
    expect(manager.findSync('history-${count - 1}'), isNotNull);
    expect(ImageFavoriteManager.count(), count);
    expect(favorites.count(favoritesFolder), count);
  });

  test('a suppressed mutator error propagates and does not wedge the queue',
      () async {
    final db = sqlite3.open('${root.path}/history.db');
    db.execute('''
      create trigger reject_bad_image before insert on image_favorites
      when new.id = 'bad-image'
      begin
        select raise(abort, 'injected image favorite failure');
      end;
    ''');
    db.dispose();

    final failing = DataMaintenance.run(() async {
      await ImageFavoriteManager.add(favorite('good-image'));
      await ImageFavoriteManager.add(favorite('bad-image'));
    }, suppressSync: true, operationName: 'data-import');

    await expectLater(failing, throwsA(isA<SqliteException>()));
    expect(ImageFavoriteManager.exist('good-image', 1, 2), isTrue);
    expect(ImageFavoriteManager.exist('bad-image', 1, 2), isFalse);
    expect(DataMaintenance.lastStats?.syncRequests, 1);
    expect(DataMaintenance.lastStats?.suppressedSyncRequests, 1);
    expect(DataMaintenance.lastStats?.unsuppressedSyncRequests, 0);

    await DataMaintenance.run(() async {
      await ImageFavoriteManager.add(favorite('after-failure'));
    }, suppressSync: true);
    expect(ImageFavoriteManager.exist('after-failure', 1, 2), isTrue);
  });
}
