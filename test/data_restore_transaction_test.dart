import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/data_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('data-restore-test-');
    SharedPreferences.setMockInitialValues({
      'firstUse': ['old']
    });
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<File> writeZip(String name, Iterable<ArchiveFile> entries) async {
    final archive = Archive();
    for (final entry in entries) {
      archive.addFile(entry);
    }
    final bytes = ZipEncoder().encode(archive)!;
    final file = File('${root.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  int readU16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  void writeU32(List<int> bytes, int offset, int value) {
    for (var i = 0; i < 4; i++) {
      bytes[offset + i] = value >> (i * 8) & 0xff;
    }
  }

  int patchZipNames(List<int> bytes, String from, String to) {
    final oldBytes = utf8.encode(from);
    final newBytes = utf8.encode(to);
    if (oldBytes.length != newBytes.length) {
      throw ArgumentError('ZIP name patch must preserve length');
    }
    var patched = 0;
    for (var offset = 0; offset + 30 <= bytes.length; offset++) {
      final signature = bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
      final local = signature == 0x04034b50;
      final central = signature == 0x02014b50;
      if (!local && !central) continue;
      final nameLength = readU16(bytes, offset + (local ? 26 : 28));
      final extraLength = readU16(bytes, offset + (local ? 28 : 30));
      final nameOffset = offset + (local ? 30 : 46);
      if (nameOffset + nameLength > bytes.length ||
          nameOffset + nameLength + extraLength > bytes.length) continue;
      if (bytes.sublist(nameOffset, nameOffset + nameLength).toString() !=
          oldBytes.toString()) continue;
      bytes.setRange(nameOffset, nameOffset + nameLength, newBytes);
      patched++;
    }
    return patched;
  }

  int patchZipSizes(List<int> bytes, String name, int size) {
    final nameBytes = utf8.encode(name);
    var patched = 0;
    for (var offset = 0; offset + 30 <= bytes.length; offset++) {
      final signature = bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
      final local = signature == 0x04034b50;
      final central = signature == 0x02014b50;
      if (!local && !central) continue;
      final nameLength = readU16(bytes, offset + (local ? 26 : 28));
      final nameOffset = offset + (local ? 30 : 46);
      if (nameOffset + nameLength > bytes.length ||
          bytes.sublist(nameOffset, nameOffset + nameLength).toString() !=
              nameBytes.toString()) continue;
      writeU32(bytes, offset + (local ? 22 : 24), size);
      patched++;
    }
    return patched;
  }

  Future<void> extractRejected(Iterable<ArchiveFile> entries,
      {int maxFiles = 100000,
      int maxExpandedBytes = 8 * 1024 * 1024 * 1024,
      int maxFileBytes = 256 * 1024 * 1024}) async {
    final archive = await writeZip('bad.zip', entries);
    final output = Directory('${root.path}/out');
    await expectLater(
        extractDataBackup(archive.path, output,
            maxFiles: maxFiles,
            maxExpandedBytes: maxExpandedBytes,
            maxFileBytes: maxFileBytes),
        throwsA(anything));
  }

  test(
      'replace interruption at every file and directory boundary replays old state',
      () async {
    final dataPath = '${root.path}/data';
    final first = File('$dataPath/first');
    final second = File('$dataPath/second');
    final directory = Directory('$dataPath/source');
    await first.parent.create(recursive: true);
    await first.writeAsString('old-first');
    await second.writeAsString('old-second');
    await directory.create();
    await File('${directory.path}/nested').writeAsString('old-nested');
    final replacements = <String, String>{};
    for (final (name, content) in [
      ('first', 'new-first'),
      ('second', 'new-second')
    ]) {
      final source = File('${root.path}/$name.new')..writeAsStringSync(content);
      replacements['$dataPath/$name'] = source.path;
    }
    final sourceDirectory = Directory('${root.path}/source.new')..createSync();
    File('${sourceDirectory.path}/nested').writeAsStringSync('new-nested');
    replacements['$dataPath/source'] = sourceDirectory.path;

    for (var failAt = 0; failAt < replacements.length; failAt++) {
      await first.writeAsString('old-first');
      await second.writeAsString('old-second');
      await File('${directory.path}/nested').writeAsString('old-nested');
      final transaction =
          await DataRestoreTransaction.prepare(dataPath, replacements);
      expect(
          () => transaction.apply(afterReplace: (index) {
                if (index == failAt) throw StateError('simulated process loss');
              }),
          throwsStateError);
      await recoverPendingDataRestore(dataPath);
      await recoverPendingDataRestore(dataPath);
      expect(await first.readAsString(), 'old-first');
      expect(await second.readAsString(), 'old-second');
      expect(
          await File('${directory.path}/nested').readAsString(), 'old-nested');
    }
  });

  test('database and settings replacement retain a verified old snapshot',
      () async {
    final dataPath = '${root.path}/data';
    final oldDatabase = File('$dataPath/local_favorite.db')
      ..createSync(recursive: true);
    var database = sqlite3.open(oldDatabase.path);
    database.execute(
        'CREATE TABLE folder_order (name TEXT PRIMARY KEY, sort INTEGER)');
    database.execute("INSERT INTO folder_order VALUES ('old', 1)");
    database.dispose();
    final oldSettings = File('$dataPath/settings')
      ..writeAsStringSync('["old-setting"]');

    final newDatabase = File('${root.path}/local_favorite.new.db');
    database = sqlite3.open(newDatabase.path);
    database.execute(
        'CREATE TABLE folder_order (name TEXT PRIMARY KEY, sort INTEGER)');
    database.execute("INSERT INTO folder_order VALUES ('new', 2)");
    database.dispose();
    final newSettings = File('${root.path}/settings.new')
      ..writeAsStringSync('["new-setting"]');

    final transaction = await DataRestoreTransaction.prepare(dataPath, {
      oldDatabase.path: newDatabase.path,
      oldSettings.path: newSettings.path,
    });
    expect(
        () => transaction.apply(afterReplace: (index) {
              if (index == 0) throw StateError('simulated process loss');
            }),
        throwsStateError);
    await recoverPendingDataRestore(dataPath);

    expect(await oldSettings.readAsString(), '["old-setting"]');
    checkBackupDatabase(oldDatabase.path, 'folder_order');
    database = sqlite3.open(oldDatabase.path, mode: OpenMode.readOnly);
    expect(
        database.select('SELECT name FROM folder_order').single['name'], 'old');
    database.dispose();
  });

  test('prepare copy failure retains journal and restores originals', () async {
    final dataPath = '${root.path}/data';
    final target = File('$dataPath/settings')..createSync(recursive: true);
    await target.writeAsString('original');
    await expectLater(
        DataRestoreTransaction.prepare(
            dataPath, {target.path: '${root.path}/missing-source'}),
        throwsA(isA<FormatException>()));
    expect(File('$dataPath/data-restore/journal.json').existsSync(), isTrue);
    await recoverPendingDataRestore(dataPath);
    expect(await target.readAsString(), 'original');
    expect(File('$dataPath/data-restore/journal.json').existsSync(), isFalse);
  });

  test('rollback preference failure retains journal and retry is idempotent',
      () async {
    final dataPath = '${root.path}/data';
    final target = File('$dataPath/settings')..createSync(recursive: true);
    await target.writeAsString('original');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {target.path: replacement.path});
    transaction.apply();
    final journal = File('$dataPath/data-restore/journal.json');
    final state =
        jsonDecode(await journal.readAsString()) as Map<String, dynamic>;
    state['preferences']['firstUse'] = 'invalid-list';
    await journal.writeAsString(jsonEncode(state), flush: true);
    await expectLater(recoverPendingDataRestore(dataPath), throwsA(anything));
    expect(await target.readAsString(), 'original');
    expect(journal.existsSync(), isTrue);
    state['preferences']['firstUse'] = ['old'];
    await journal.writeAsString(jsonEncode(state), flush: true);
    await recoverPendingDataRestore(dataPath);
    await recoverPendingDataRestore(dataPath);
    expect(await target.readAsString(), 'original');
    expect(journal.existsSync(), isFalse);
  });

  test('committed state keeps new data when backup cleanup is retried',
      () async {
    final dataPath = '${root.path}/data';
    final target = File('$dataPath/settings')..createSync(recursive: true);
    await target.writeAsString('old');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {target.path: replacement.path});
    transaction.apply();
    transaction.commit();
    final state = jsonDecode(await transaction.journal.readAsString()) as Map;
    final staged = state['entries'][0]['staged'] as String;
    await Link(staged).create(target.path);
    await expectLater(transaction.recover(), throwsA(isA<FormatException>()));
    expect(await target.readAsString(), 'new');
    expect(transaction.journal.existsSync(), isTrue);
    await Link(staged).delete();
    await recoverPendingDataRestore(dataPath);
    expect(await target.readAsString(), 'new');
    expect(transaction.journal.existsSync(), isFalse);
  });

  test('prepare without any target restores newly created paths on replay',
      () async {
    final dataPath = '${root.path}/data';
    final replacement = File('${root.path}/new.db')..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {'$dataPath/new.db': replacement.path});
    transaction.apply();
    expect(File('$dataPath/new.db').existsSync(), isTrue);
    await recoverPendingDataRestore(dataPath);
    expect(File('$dataPath/new.db').existsSync(), isFalse);
  });

  test(
      'missing original backup must retain journal instead of claiming recovery',
      () async {
    final dataPath = '${root.path}/data';
    final target = File('$dataPath/settings')..createSync(recursive: true);
    await target.writeAsString('old');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {target.path: replacement.path});
    transaction.apply();
    final state = jsonDecode(await transaction.journal.readAsString()) as Map;
    await File(state['entries'][0]['backup'] as String).delete();
    await target.delete();

    await expectLater(recoverPendingDataRestore(dataPath), throwsA(anything));
    expect(transaction.journal.existsSync(), isTrue);
  });

  test('rollback rejects a planted backup link before changing the target',
      () async {
    final dataPath = '${root.path}/data';
    final target = File('$dataPath/settings')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {target.path: replacement.path});
    transaction.apply();
    final state = jsonDecode(await transaction.journal.readAsString()) as Map;
    final backup = state['entries'][0]['backup'] as String;
    await File(backup).delete();
    await Link(backup).create(target.path);

    await expectLater(
        recoverPendingDataRestore(dataPath), throwsA(isA<FormatException>()));
    expect(await target.readAsString(), 'new');
    expect(FileSystemEntity.typeSync(backup, followLinks: false),
        FileSystemEntityType.link);
    expect(transaction.journal.existsSync(), isTrue);
  });

  test('overlapping restore targets are rejected before journaling', () async {
    final dataPath = '${root.path}/data';
    final directory = Directory('$dataPath/favorites')
      ..createSync(recursive: true);
    final nested = File('${directory.path}/nested')..writeAsStringSync('old');
    final replacementDirectory = Directory('${root.path}/favorites.new')
      ..createSync();
    await expectLater(
        DataRestoreTransaction.prepare(dataPath, {
          directory.path: replacementDirectory.path,
          nested.path: replacementDirectory.path,
        }),
        throwsA(isA<FormatException>()));
    expect(File('$dataPath/data-restore/journal.json').existsSync(), isFalse);
  });

  test('restore targets stay inside data path across prepare and recovery',
      () async {
    final dataPath = '${root.path}/data';
    final outside = File('${root.path}/outside-target')
      ..writeAsStringSync('outside');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');

    await expectLater(
        DataRestoreTransaction.prepare(
            dataPath, {outside.path: replacement.path}),
        throwsA(isA<FormatException>()));

    final externalRoot = Directory('${root.path}/downloads')..createSync();
    final externalTarget = File('${externalRoot.path}/settings')
      ..writeAsStringSync('old-external');
    final externalTransaction = await DataRestoreTransaction.prepare(
        dataPath, {externalTarget.path: replacement.path},
        allowedRoots: [externalRoot.path]);
    externalTransaction.apply();
    externalTransaction.commit();
    await recoverPendingDataRestore(dataPath,
        trustedAllowedRoots: [externalRoot.path]);
    expect(await externalTarget.readAsString(), 'new');

    final linkParent = Link('$dataPath/link-to-download');
    await linkParent.create(externalRoot.path);
    await expectLater(
        DataRestoreTransaction.prepare(
            dataPath, {'${linkParent.path}/settings': replacement.path}),
        throwsA(isA<FormatException>()));

    final target = File('$dataPath/settings')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {target.path: replacement.path});
    transaction.apply();
    final state = jsonDecode(await transaction.journal.readAsString())
        as Map<String, dynamic>;
    final id = state['id'] as String;
    final outsideBackup = File('${outside.path}.restore-old-$id')
      ..writeAsStringSync('old-outside');
    final entry = Map<String, dynamic>.from(
        (state['entries'] as List).single as Map<String, dynamic>);
    entry['target'] = outside.path;
    entry['backup'] = outsideBackup.path;
    entry['staged'] = '${outside.path}.restore-new-$id';
    state['entries'] = [entry];
    await transaction.journal.writeAsString(jsonEncode(state), flush: true);

    await expectLater(
        recoverPendingDataRestore(dataPath), throwsA(isA<FormatException>()));
    expect(await outside.readAsString(), 'outside');
    expect(await outsideBackup.readAsString(), 'old-outside');
    expect(transaction.journal.existsSync(), isTrue);
  });

  test('recovery rejects journal-tampered external allowed roots', () async {
    final dataPath = '${root.path}/data';
    final trustedRoot = Directory('${root.path}/trusted')..createSync();
    final attackerRoot = Directory('${root.path}/attacker')..createSync();
    final trustedTarget = File('${trustedRoot.path}/settings')
      ..writeAsStringSync('old-trusted');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {trustedTarget.path: replacement.path},
        allowedRoots: [trustedRoot.path]);
    transaction.apply();

    final attackerTarget = File('${attackerRoot.path}/settings')
      ..writeAsStringSync('old-attacker');
    final state = jsonDecode(await transaction.journal.readAsString())
        as Map<String, dynamic>;
    final id = state['id'] as String;
    state['allowedRoots'] = [attackerRoot.path];
    state['entries'] = [
      {
        'target': attackerTarget.path,
        'staged': '${attackerTarget.path}.restore-new-$id',
        'backup': '${attackerTarget.path}.restore-old-$id',
        'existed': true,
      }
    ];
    await transaction.journal.writeAsString(jsonEncode(state), flush: true);

    await expectLater(
        recoverPendingDataRestore(dataPath,
            trustedAllowedRoots: [trustedRoot.path]),
        throwsA(isA<FormatException>()));
    expect(await attackerTarget.readAsString(), 'old-attacker');
    expect(await trustedTarget.readAsString(), 'new');
    expect(transaction.journal.existsSync(), isTrue);
  });

  test('recovery cleans a committed journal after external root removal',
      () async {
    final dataPath = '${root.path}/data';
    final externalRoot = Directory('${root.path}/downloads')..createSync();
    final target = File('${externalRoot.path}/settings')
      ..writeAsStringSync('old');
    final replacement = File('${root.path}/settings.new')
      ..writeAsStringSync('new');
    final transaction = await DataRestoreTransaction.prepare(
        dataPath, {target.path: replacement.path},
        allowedRoots: [externalRoot.path]);
    transaction.apply();
    transaction.commit();

    // Simulate a user removing the configured download directory before the
    // next startup. A committed journal only needs cleanup, not data access.
    await externalRoot.delete(recursive: true);
    await recoverPendingDataRestore(dataPath,
        trustedAllowedRoots: [externalRoot.path]);
    expect(transaction.journal.existsSync(), isFalse);
  });

  test('ZIP rejects traversal, links, duplicate paths, count and expanded size',
      () async {
    final link = ArchiveFile.string('link', 'target')
      ..isSymbolicLink = true
      ..mode = 0xA1FF;
    await extractRejected([ArchiveFile.string('../escape', 'x')]);
    await extractRejected([link]);
    await extractRejected(
        [ArchiveFile.string('a', '1'), ArchiveFile.string('b', '2')],
        maxFiles: 1);
    await extractRejected([ArchiveFile.string('a', '1234')], maxFileBytes: 3);
    await extractRejected(
        [ArchiveFile.string('a', '12'), ArchiveFile.string('b', '34')],
        maxExpandedBytes: 3, maxFileBytes: 3);
  });

  test('ZIP rejects duplicate central names before creating output', () async {
    final archive = await writeZip('duplicate.zip', [
      ArchiveFile.string('a', 'first'),
      ArchiveFile.string('b', 'second'),
    ]);
    final bytes = await archive.readAsBytes();
    expect(patchZipNames(bytes, 'b', 'a'), 2);
    await archive.writeAsBytes(bytes, flush: true);
    final output = Directory('${root.path}/duplicate-output');
    await expectLater(extractDataBackup(archive.path, output),
        throwsA(isA<FormatException>()));
    expect(output.existsSync(), isFalse);
  });

  test('ZIP forged small size is bounded before decompression can expand',
      () async {
    final archive = await writeZip(
        'forged-size.zip', [ArchiveFile.string('payload', '0123456789')]);
    final bytes = await archive.readAsBytes();
    expect(patchZipSizes(bytes, 'payload', 1), 2);
    await archive.writeAsBytes(bytes, flush: true);
    final output = Directory('${root.path}/forged-output');
    await expectLater(
        extractDataBackup(archive.path, output, maxFileBytes: 1024),
        throwsA(isA<FormatException>()));
    expect(output.existsSync(), isFalse);
  });

  test('ZIP deflate extraction keeps a bounded back-reference window',
      () async {
    final payload = List.filled(200000, 'A').join();
    final archive = await writeZip('streaming.zip', [
      ArchiveFile.string('appdata', '{"settings":["ok"]}'),
      ArchiveFile.string('payload', payload),
    ]);
    final output = Directory('${root.path}/streaming-output');
    await extractDataBackup(archive.path, output);
    expect(await File('${output.path}/payload').length(), payload.length);
  });

  test('manifest hash and required backup payload are validated', () async {
    final good = await writeZip('missing-appdata.zip', [
      ArchiveFile.string(
          backupManifestName,
          jsonEncode({
            'formatVersion': 1,
            'files': <String, Object>{},
          }))
    ]);
    await expectLater(
        extractDataBackup(good.path, Directory('${root.path}/missing')),
        throwsA(anything));

    final manifest = jsonEncode({
      'formatVersion': 1,
      'files': {
        'appdata': {'size': 2, 'sha256': '0' * 64}
      }
    });
    final tampered = await writeZip('tampered.zip', [
      ArchiveFile.string('appdata', '{"settings":[]}'),
      ArchiveFile.string(backupManifestName, manifest)
    ]);
    await expectLater(
        extractDataBackup(tampered.path, Directory('${root.path}/tampered')),
        throwsA(isA<FormatException>()));
  });
}
