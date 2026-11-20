import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/cache_auto_clear.dart';
import 'package:pica_comic/tools/directory_maintenance.dart';
import 'package:pica_comic/tools/atomic_file.dart';

void main() {
  test('replaces a text file without leaving a temporary sibling', () async {
    final root = await Directory.systemTemp.createTemp('pica-atomic-file-');
    addTearDown(() => root.delete(recursive: true));

    final target = File('${root.path}/nested/rule.json');
    await writeTextFileAtomically(target, 'first');
    expect(await target.readAsString(), 'first');

    await writeTextFileAtomically(target, 'second');
    expect(await target.readAsString(), 'second');
    final siblings = await target.parent
        .list()
        .where((entry) => entry.path.contains('.tmp'))
        .toList();
    expect(siblings, isEmpty);
  });

  test('keeps the previous destination when replacement cannot complete',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-atomic-file-');
    addTearDown(() => root.delete(recursive: true));

    final destination = Directory('${root.path}/existing');
    await destination.create();
    final target = File(destination.path);

    await expectLater(writeTextFileAtomically(target, 'new'),
        throwsA(isA<FileSystemException>()));
    expect(await destination.exists(), isTrue);
  });

  test('replaces binary data atomically', () async {
    final root = await Directory.systemTemp.createTemp('pica-atomic-file-');
    addTearDown(() => root.delete(recursive: true));

    final target = File('${root.path}/nested/output.pdf');
    await writeBytesFileAtomically(target, <int>[0, 1, 2, 255]);
    expect(await target.readAsBytes(), <int>[0, 1, 2, 255]);

    await writeBytesFileAtomically(target, <int>[37, 80, 68, 70]);
    expect(await target.readAsBytes(), <int>[37, 80, 68, 70]);
    final siblings = await target.parent.list().toList();
    expect(siblings.where((entry) => entry.path.contains('.tmp')), isEmpty);
  });

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

  test('startup cache cleanup uses the injected cache directory', () async {
    final root = await Directory.systemTemp.createTemp('pica-cache-startup-');
    addTearDown(() => root.delete(recursive: true));
    final image = Directory('${root.path}/imageCache');
    await image.create(recursive: true);
    final old = File('${image.path}/old.bin');
    await old.writeAsBytes(List<int>.filled(7, 1));
    final now = DateTime.now();
    await old.setLastModified(now.subtract(const Duration(days: 10)));

    await startClearCache(cacheDirectoryProvider: () async => root);

    expect(await old.exists(), isFalse);
  });

  test('cache cleanup rejects a symbolic-link root', () async {
    final root = await Directory.systemTemp.createTemp('pica-cache-link-');
    addTearDown(() => root.delete(recursive: true));
    final external = Directory('${root.path}/external');
    final link = Directory('${root.path}/cache');
    await external.create(recursive: true);
    final old = File('${external.path}/old.bin');
    await old.writeAsBytes(List<int>.filled(9, 1));
    final now = DateTime.now();
    await old.setLastModified(now.subtract(const Duration(days: 10)));
    await Link(link.path).create(external.path);

    await expectLater(
      cleanupDirectory(link, olderThan: now),
      throwsA(isA<StateError>()),
    );
    expect(await old.exists(), isTrue);
  });

  test('cache capacity accounts for protected files without evicting them',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-cache-budget-');
    addTearDown(() => root.delete(recursive: true));
    final protectedFile = File('${root.path}/protected.bin');
    final ordinaryFile = File('${root.path}/ordinary.bin');
    await protectedFile.writeAsBytes(List<int>.filled(8, 1));
    await ordinaryFile.writeAsBytes(List<int>.filled(8, 2));
    final now = DateTime.now();

    final report = await cleanupDirectory(
      root,
      olderThan: now.subtract(const Duration(days: 1)),
      maxBytes: 8,
      protectedPaths: {protectedFile.path},
    );

    expect(report.scannedFiles, 2);
    expect(report.scannedBytes, 16);
    expect(report.deletedFiles, 1);
    expect(report.deletedBytes, 8);
    expect(report.remainingBytes, 8);
    expect(await protectedFile.exists(), isTrue);
    expect(await ordinaryFile.exists(), isFalse);
  });

  test('cache capacity reports protected files that exceed the budget',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-cache-protected-');
    addTearDown(() => root.delete(recursive: true));
    final protectedFile = File('${root.path}/protected.bin');
    await protectedFile.writeAsBytes(List<int>.filled(8, 1));

    final report = await cleanupDirectory(
      root,
      olderThan: DateTime.now().subtract(const Duration(days: 1)),
      maxBytes: 1,
      protectedPaths: {protectedFile.path},
    );

    expect(report.scannedFiles, 1);
    expect(report.scannedBytes, 8);
    expect(report.deletedFiles, 0);
    expect(report.deletedBytes, 0);
    expect(report.remainingBytes, 8);
    expect(await protectedFile.exists(), isTrue);
  });

  test('legacy cache cleanup is gated by its one-time index marker', () async {
    final root = await Directory.systemTemp.createTemp('pica-cache-legacy-');
    addTearDown(() => root.delete(recursive: true));
    final data = Directory('${root.path}/data');
    final cache = Directory('${root.path}/cache');
    await data.create(recursive: true);
    for (final name in const ['imageCache', 'cachedNetwork']) {
      final directory = Directory('${cache.path}/$name');
      await directory.create(recursive: true);
      await File('${directory.path}/recent.bin').writeAsString('recent');
    }
    final marker = File('${data.path}/cache.json');
    await marker.writeAsString('{}');

    await clearLegacyCacheOnce(dataPath: data.path, cachePath: cache.path);

    expect(await marker.exists(), isFalse);
    expect(await Directory('${cache.path}/imageCache').exists(), isFalse);
    expect(await Directory('${cache.path}/cachedNetwork').exists(), isFalse);

    // Once the legacy index is gone, a later startup must not delete newly
    // created cache files; the normal retention pass owns that cleanup.
    final recent = File('${cache.path}/imageCache/recent.bin');
    await recent.create(recursive: true);
    await clearLegacyCacheOnce(dataPath: data.path, cachePath: cache.path);
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

  test('migration replaces a destination containing only empty directories',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-dir-empty-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await source.create(recursive: true);
    await File('${source.path}/comic.bin').writeAsString('comic');
    await Directory('${destination.path}/stale/nested').create(recursive: true);

    final report = await migrateDirectory(source, destination);

    expect(report.fileCount, 1);
    expect(await source.exists(), isFalse);
    expect(await File('${destination.path}/comic.bin').readAsString(), 'comic');
  });

  test('committed recovery retains source when destination has extra files',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-dir-extra-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await source.create(recursive: true);
    await destination.create(recursive: true);
    const contents = 'payload';
    await File('${source.path}/comic.bin').writeAsString(contents);
    await File('${destination.path}/comic.bin').writeAsString(contents);
    final digest = sha256.convert(utf8.encode(contents)).toString();
    final journal = File('${destination.path}.migration.json');
    await journal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'committed',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': '${destination.path}.migration-recovery.tmp',
      'deleteSource': true,
      'totalBytes': contents.length,
      'files': [
        {
          'path': 'comic.bin',
          'size': contents.length,
          'sha256': digest,
          'done': true,
        },
      ],
    }));
    final extra = File('${destination.path}/unexpected.bin');
    await extra.writeAsString('external write');

    await expectLater(
      migrateDirectory(source, destination),
      throwsA(isA<StateError>()),
    );
    expect(await source.exists(), isTrue);
    expect(await journal.exists(), isTrue);
    expect(await extra.exists(), isTrue);
  });

  test('committed journal is cleaned after source deletion before replay',
      () async {
    final root =
        await Directory.systemTemp.createTemp('pica-dir-source-deleted-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await destination.create(recursive: true);
    const contents = 'payload';
    await File('${destination.path}/comic.bin').writeAsString(contents);
    final digest = sha256.convert(utf8.encode(contents)).toString();
    final journal = File('${destination.path}.migration.json');
    await journal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'committed',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': '${destination.path}.migration-recovery.tmp',
      'deleteSource': true,
      'totalBytes': contents.length,
      'files': [
        {
          'path': 'comic.bin',
          'size': contents.length,
          'sha256': digest,
          'done': true,
        },
      ],
    }));

    await migrateDirectory(source, destination);

    expect(await source.exists(), isFalse);
    expect(await journal.exists(), isFalse);
    expect(
        await File('${destination.path}/comic.bin').readAsString(), contents);
  });

  test('committed recovery retains source when source has extra files',
      () async {
    final root =
        await Directory.systemTemp.createTemp('pica-dir-source-extra-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await source.create(recursive: true);
    await destination.create(recursive: true);
    const contents = 'payload';
    await File('${source.path}/comic.bin').writeAsString(contents);
    final extra = File('${source.path}/new-download.bin');
    await extra.writeAsString('created after the migration plan');
    await File('${destination.path}/comic.bin').writeAsString(contents);
    final digest = sha256.convert(utf8.encode(contents)).toString();
    final journal = File('${destination.path}.migration.json');
    await journal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'committed',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': '${destination.path}.migration-recovery.tmp',
      'deleteSource': true,
      'totalBytes': contents.length,
      'files': [
        {
          'path': 'comic.bin',
          'size': contents.length,
          'sha256': digest,
          'done': true,
        },
      ],
    }));

    await expectLater(
      migrateDirectory(source, destination),
      throwsA(isA<StateError>()),
    );
    expect(await source.exists(), isTrue);
    expect(await extra.exists(), isTrue);
    expect(await journal.exists(), isTrue);
  });

  test('committed recovery finishes source cleanup after partial deletion',
      () async {
    final root =
        await Directory.systemTemp.createTemp('pica-dir-partial-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await Directory(source.path).create(recursive: true);
    await Directory(destination.path).create(recursive: true);
    const files = <String, String>{
      'one.txt': 'one',
      'nested/two.txt': 'two',
    };
    for (final entry in files.entries) {
      final sourceFile = File('${source.path}/${entry.key}');
      final destinationFile = File('${destination.path}/${entry.key}');
      await sourceFile.parent.create(recursive: true);
      await destinationFile.parent.create(recursive: true);
      await sourceFile.writeAsString(entry.value);
      await destinationFile.writeAsString(entry.value);
    }
    final journal = File('${destination.path}.migration.json');
    await journal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'committed',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': '${destination.path}.migration-recovery.tmp',
      'deleteSource': true,
      'totalBytes': 6,
      'files': [
        for (final entry in files.entries)
          {
            'path': entry.key,
            'size': entry.value.length,
            'sha256': sha256.convert(utf8.encode(entry.value)).toString(),
            'done': true,
          },
      ],
    }));
    await File('${source.path}/one.txt').delete();

    final report = await migrateDirectory(source, destination);

    expect(report.resumed, isTrue);
    expect(await source.exists(), isFalse);
    expect(await journal.exists(), isFalse);
    for (final entry in files.entries) {
      expect(await File('${destination.path}/${entry.key}').readAsString(),
          entry.value);
    }
  });

  test('malformed journal cannot opt into source deletion', () async {
    final root = await Directory.systemTemp.createTemp('pica-dir-journal-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    await source.create(recursive: true);
    await destination.create(recursive: true);
    const contents = 'payload';
    await File('${source.path}/comic.bin').writeAsString(contents);
    await File('${destination.path}/comic.bin').writeAsString(contents);
    final digest = sha256.convert(utf8.encode(contents)).toString();
    final journal = File('${destination.path}.migration.json');
    await journal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'committed',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': '${destination.path}.migration-recovery.tmp',
      // A corrupted JSON type must not be interpreted as the default `true`.
      'deleteSource': 'false',
      'totalBytes': contents.length,
      'files': [
        {
          'path': 'comic.bin',
          'size': contents.length,
          'sha256': digest,
          'done': true,
        },
      ],
    }));

    await expectLater(
      migrateDirectory(source, destination),
      throwsA(isA<FormatException>()),
    );
    expect(await source.exists(), isTrue);
    expect(await File('${source.path}/comic.bin').readAsString(), contents);
    expect(await journal.exists(), isTrue);
  });

  test('journal staging symlink is rejected before copying', () async {
    final root = await Directory.systemTemp.createTemp('pica-dir-link-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    final external = Directory('${root.path}/external');
    await source.create(recursive: true);
    await external.create(recursive: true);
    const contents = 'payload';
    await File('${source.path}/comic.bin').writeAsString(contents);
    final stagingPath = '${destination.path}.migration-attacker.tmp';
    await Link(stagingPath).create(external.path);
    final journal = File('${destination.path}.migration.json');
    await journal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'copying',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': stagingPath,
      'deleteSource': true,
      'totalBytes': contents.length,
      'files': [
        {
          'path': 'comic.bin',
          'size': contents.length,
          'sha256': null,
          'done': false,
        },
      ],
    }));

    await expectLater(
      migrateDirectory(source, destination),
      throwsA(isA<FormatException>()),
    );
    expect(await source.exists(), isTrue);
    expect(await File('${external.path}/comic.bin').exists(), isFalse);
    expect(await Link(stagingPath).exists(), isTrue);
    expect(await journal.exists(), isTrue);
  });

  test('journal symlink is rejected before source deletion', () async {
    final root =
        await Directory.systemTemp.createTemp('pica-dir-journal-link-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    final destination = Directory('${root.path}/destination');
    final external = Directory('${root.path}/external');
    await source.create(recursive: true);
    await destination.create(recursive: true);
    await external.create(recursive: true);
    const contents = 'payload';
    await File('${source.path}/comic.bin').writeAsString(contents);
    await File('${destination.path}/comic.bin').writeAsString(contents);
    final digest = sha256.convert(utf8.encode(contents)).toString();
    final externalJournal = File('${external.path}/journal.json');
    await externalJournal.writeAsString(jsonEncode({
      'version': 1,
      'phase': 'committed',
      'source': File(source.path).absolute.path,
      'destination': File(destination.path).absolute.path,
      'staging': '${destination.path}.migration-attacker.tmp',
      'deleteSource': true,
      'totalBytes': contents.length,
      'files': [
        {
          'path': 'comic.bin',
          'size': contents.length,
          'sha256': digest,
          'done': true,
        },
      ],
    }));
    final journal = File('${destination.path}.migration.json');
    await Link(journal.path).create(externalJournal.path);

    await expectLater(
      migrateDirectory(source, destination),
      throwsA(isA<StateError>()),
    );
    expect(await source.exists(), isTrue);
    expect(await externalJournal.exists(), isTrue);
    expect(await Link(journal.path).exists(), isTrue);
  });
}
