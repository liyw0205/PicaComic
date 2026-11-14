import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/cache_auto_clear.dart';
import 'package:pica_comic/tools/directory_maintenance.dart';

void main() {
  test('cache cleanup reports bytes and preserves recent files', () async {
    final root = await Directory.systemTemp.createTemp('pica-cache-maint-');
    addTearDown(() => root.delete(recursive: true));
    final image = Directory('${root.path}/imageCache');
    final network = Directory('${root.path}/cachedNetwork');
    await image.create(recursive: true);
    await network.create(recursive: true);
    final old = File('${image.path}/old.bin');
    final recent = File('${network.path}/recent.bin');
    await old.writeAsBytes(List<int>.filled(11, 1));
    await recent.writeAsBytes(List<int>.filled(13, 2));
    final now = DateTime.now();
    await old.setLastModified(now.subtract(const Duration(days: 10)));
    await recent.setLastModified(now);

    final report = await clearStaleCache(root.path, now: now, batchSize: 1);
    expect(report.scannedFiles, 2);
    expect(report.scannedBytes, 24);
    expect(report.deletedFiles, 1);
    expect(report.deletedBytes, 11);
    expect(await old.exists(), isFalse);
    expect(await recent.exists(), isTrue);
  });

  test('directory migration writes a resumable journal and verifies files',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-dir-migration-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await Directory('${source.path}/nested').create(recursive: true);
    await File('${source.path}/one.txt').writeAsString('one');
    await File('${source.path}/nested/two.txt').writeAsString('two');

    final plan = await planDirectoryMigration(source, destination);
    expect(plan.fileCount, 2);
    expect(plan.totalBytes, 6);
    final report = await migrateDirectory(source, destination, batchSize: 1);
    expect(report.fileCount, 2);
    expect(report.copiedBytes, 6);
    expect(await File('${destination.path}/one.txt').readAsString(), 'one');
    expect(
        await File('${destination.path}/nested/two.txt').readAsString(), 'two');
    expect(await source.exists(), isFalse);
    expect(await File('${destination.path}.migration.json').exists(), isFalse);
  });

  test('failed destination keeps source and journal for a retry', () async {
    final root = await Directory.systemTemp.createTemp('pica-dir-retry-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await source.create(recursive: true);
    await File('${source.path}/comic.bin').writeAsString('comic');
    await destination.create(recursive: true);
    await File('${destination.path}/blocker').writeAsString('occupied');

    await expectLater(
      migrateDirectory(source, destination),
      throwsA(isA<StateError>()),
    );
    final journal = File('${destination.path}.migration.json');
    expect(await source.exists(), isTrue);
    expect(await journal.exists(), isTrue);

    await destination.delete(recursive: true);
    final retry = await migrateDirectory(source, destination);
    expect(retry.resumed, isTrue);
    expect(await source.exists(), isFalse);
    expect(await File('${destination.path}/comic.bin').readAsString(), 'comic');
    expect(await journal.exists(), isFalse);
  });
}
