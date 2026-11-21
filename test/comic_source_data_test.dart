import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('comic-source-data-test-');
    App.dataPath = root.path;
  });

  tearDownAll(() => root.delete(recursive: true));

  ComicSource source(String key) => ComicSource.named(
        name: key,
        key: key,
        filePath: 'test-fixture',
      );

  test('corrupt source snapshots are preserved and defaults can load',
      () async {
    final sourceDirectory = Directory('${root.path}/comic_source');
    await sourceDirectory.create();
    const invalidSnapshots = ['', '{"account":', 'null', '[]'];

    for (var index = 0; index < invalidSnapshots.length; index++) {
      final key = 'fixture-$index';
      final file = File('${sourceDirectory.path}/$key.data');
      final original = invalidSnapshots[index];
      await file.writeAsString(original);

      final comicSource = source(key);
      await expectLater(comicSource.loadData(), completes);

      expect(comicSource.data, isEmpty);
      expect(await file.exists(), isFalse);
      final backup = sourceDirectory.listSync().whereType<File>().singleWhere(
          (candidate) => candidate.path.startsWith('${file.path}.corrupt.'));
      expect(await backup.readAsString(), original);
    }
  });

  test('valid source snapshots load without creating a recovery copy',
      () async {
    final sourceDirectory = Directory('${root.path}/comic_source');
    await sourceDirectory.create();
    final file = File('${sourceDirectory.path}/valid.data');
    await file.writeAsString('{"account":["user","password"]}');

    final comicSource = source('valid');
    await comicSource.loadData();

    expect(comicSource.data, {
      'account': ['user', 'password']
    });
    expect(
      sourceDirectory.listSync().whereType<File>().where(
          (candidate) => candidate.path.startsWith('${file.path}.corrupt.')),
      isEmpty,
    );
  });
}
