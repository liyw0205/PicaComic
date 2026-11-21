import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String previousSync;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('favorite-sync-merge-');
    App.dataPath = root.path;
  });

  setUp(() {
    previousSync = appdata.settings[45];
    appdata.settings[45] = '';
  });

  tearDown(() {
    appdata.settings[45] = previousSync;
  });

  tearDownAll(() async {
    await root.delete(recursive: true);
  });

  test('a stale branch does not restore a locally deleted favorite', () async {
    final source = LocalFavoritesManager.create();
    final device = LocalFavoritesManager.create();
    final sourcePath = '${root.path}/source.db';
    final archivePath = '${root.path}/branch.db';
    final devicePath = '${root.path}/device.db';

    try {
      await source.init(databasePath: sourcePath, importLegacy: false);
      source.createFolder('Favorites');
      await source.addComic(
        'Favorites',
        FavoriteItem(
          target: 'comic-1',
          name: 'Comic 1',
          author: 'Author',
          type: FavoriteType.picacg,
          tags: const [],
          coverPath: 'https://example.invalid/cover.jpg',
        ),
        null,
        false,
      );
      await source.snapshotTo(archivePath);
      final archivedFavorites =
          sqlite3.open(archivePath, mode: OpenMode.readOnly);
      try {
        final tables = archivedFavorites
            .select("SELECT name FROM sqlite_master WHERE type = 'table';")
            .map((row) => row['name'] as String)
            .toSet();
        expect(tables, isNot(contains('deleted_items')));
        expect(File('$archivePath.deletions').existsSync(), isTrue);
      } finally {
        archivedFavorites.dispose();
      }

      await device.init(databasePath: devicePath, importLegacy: false);
      await device.mergeFrom(archivePath);
      await device.deleteComicWithTarget(
          'Favorites', 'comic-1', FavoriteType.picacg);

      await device.mergeFrom(archivePath);

      expect(device.getAllComics('Favorites'), isEmpty);
    } finally {
      source.close();
      device.close();
    }
  });

  test('a later re-add survives merging an older deletion branch', () async {
    final source = LocalFavoritesManager.create();
    final device = LocalFavoritesManager.create();
    final verifier = LocalFavoritesManager.create();
    final staleBranch = '${root.path}/readd-stale.db';
    final deletionBranch = '${root.path}/readd-deleted.db';
    final readdedBranch = '${root.path}/readd-current.db';

    FavoriteItem comic() => FavoriteItem(
          target: 'comic-2',
          name: 'Comic 2',
          author: 'Author',
          type: FavoriteType.picacg,
          tags: const [],
          coverPath: 'https://example.invalid/cover-2.jpg',
        );

    try {
      await source.init(
          databasePath: '${root.path}/readd-source.db', importLegacy: false);
      source.createFolder('Favorites');
      await source.addComic('Favorites', comic(), null, false);
      await source.snapshotTo(staleBranch);

      await device.init(
          databasePath: '${root.path}/readd-device.db', importLegacy: false);
      await device.mergeFrom(staleBranch);
      await device.deleteComicWithTarget(
          'Favorites', 'comic-2', FavoriteType.picacg);
      await device.snapshotTo(deletionBranch);
      await device.addComic('Favorites', comic(), null, false);
      await device.snapshotTo(readdedBranch);

      await verifier.init(
          databasePath: '${root.path}/readd-verifier.db', importLegacy: false);
      await verifier.mergeFrom(staleBranch);
      await verifier.mergeFrom(readdedBranch);
      await verifier.mergeFrom(deletionBranch);

      expect(verifier.getAllComics('Favorites').map((item) => item.target),
          ['comic-2']);
    } finally {
      source.close();
      device.close();
      verifier.close();
    }
  });

  test('Hitomi deletion matches equivalent gallery URL forms', () async {
    final source = LocalFavoritesManager.create();
    final deletedDevice = LocalFavoritesManager.create();
    final verifier = LocalFavoritesManager.create();
    final staleBranch = '${root.path}/hitomi-stale.db';
    final deletionBranch = '${root.path}/hitomi-deleted.db';

    FavoriteItem hitomi(String target) => FavoriteItem(
          target: target,
          name: 'Hitomi gallery',
          author: 'Author',
          type: FavoriteType.hitomi,
          tags: const [],
          coverPath: 'https://example.invalid/hitomi-cover.jpg',
        );

    try {
      await source.init(
          databasePath: '${root.path}/hitomi-source.db', importLegacy: false);
      source.createFolder('Favorites');
      await source.addComic(
        'Favorites',
        hitomi('https://hitomi.la/galleries/42.html'),
        null,
        false,
      );
      await source.snapshotTo(staleBranch);

      await deletedDevice.init(
          databasePath: '${root.path}/hitomi-device.db', importLegacy: false);
      deletedDevice.createFolder('Favorites');
      await deletedDevice.addComic(
        'Favorites',
        hitomi('https://hitomi.la/reader/42.html'),
        null,
        false,
      );
      await deletedDevice.deleteComicWithTarget(
          'Favorites', 'https://hitomi.la/reader/42.html', FavoriteType.hitomi);
      await deletedDevice.snapshotTo(deletionBranch);

      await verifier.init(
          databasePath: '${root.path}/hitomi-verifier.db', importLegacy: false);
      await verifier.mergeFrom(staleBranch);
      await verifier.mergeFrom(deletionBranch);

      expect(verifier.getAllComics('Favorites'), isEmpty);
    } finally {
      source.close();
      deletedDevice.close();
      verifier.close();
    }
  });

  for (final clearAll in [false, true]) {
    test(
        '${clearAll ? 'clearing' : 'deleting'} a folder does not restore its items',
        () async {
      final source = LocalFavoritesManager.create();
      final device = LocalFavoritesManager.create();
      final staleBranch = '${root.path}/folder-delete-$clearAll.db';

      try {
        await source.init(
            databasePath: '${root.path}/folder-source-$clearAll.db',
            importLegacy: false);
        source.createFolder('Favorites');
        await source.addComic(
          'Favorites',
          FavoriteItem(
            target: 'comic-folder',
            name: 'Folder comic',
            author: 'Author',
            type: FavoriteType.picacg,
            tags: const [],
            coverPath: 'https://example.invalid/folder-cover.jpg',
          ),
          null,
          false,
        );
        await source.snapshotTo(staleBranch);

        await device.init(
            databasePath: '${root.path}/folder-device-$clearAll.db',
            importLegacy: false);
        await device.mergeFrom(staleBranch);
        if (clearAll) {
          await device.clearAll();
        } else {
          await device.deleteFolder('Favorites');
        }
        await device.mergeFrom(staleBranch);

        expect(device.folderNames, isEmpty);
      } finally {
        source.close();
        device.close();
      }
    });
  }
}
