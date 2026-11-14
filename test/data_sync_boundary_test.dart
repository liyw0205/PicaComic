import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late HistoryManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pica-sync-boundary-');
    manager = HistoryManager.create();
    HistoryManager.cache = manager;
    await manager.init(
      databasePath: '${root.path}/history.db',
      importLegacy: false,
    );
  });

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    manager.close();
    if (identical(HistoryManager.cache, manager)) HistoryManager.cache = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  ImageFavorite favorite(String id) =>
      ImageFavorite(id, 'cover', 'title', 1, 2, const {});

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
}
