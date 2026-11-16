import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HistoryManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pica_history_cache_');
    manager = HistoryManager.create();
    await manager.init(
      databasePath: '${directory.path}/history.db',
      importLegacy: false,
    );
  });

  tearDown(() async {
    manager.close();
    await directory.delete(recursive: true);
  });

  test('lazy existence cache tracks absent, added, and removed targets',
      () async {
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

    manager.remove(target);
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
  });
}
