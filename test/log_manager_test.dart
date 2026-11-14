import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';

void main() {
  late Directory directory;
  late File logFile;
  late int previousLimit;
  late int previousRetention;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pica-log-');
    logFile = File('${directory.path}/log.txt');
    previousLimit = LogManager.maxLogFileBytes;
    previousRetention = LogManager.maxRotatedLogFiles;
    LogManager.maxLogFileBytes = 8 * 1024 * 1024;
    LogManager.maxRotatedLogFiles = 10;
    LogManager.logFile = logFile;
    LogManager.clear();
    await LogManager.flush();
  });

  tearDown(() async {
    await LogManager.flush();
    LogManager.logFile = null;
    LogManager.maxLogFileBytes = previousLimit;
    LogManager.maxRotatedLogFiles = previousRetention;
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('serializes a burst of network events and preserves safe fields',
      () async {
    const secret = 'network-secret-queue-test';
    final safeUrl = safeNetworkUrl(
        'https://user:$secret@example.org/image?token=$secret&page=');

    for (var index = 0; index < 1000; index++) {
      LogManager.addLog(
        LogLevel.info,
        'Network',
        'GET $safeUrl$index',
      );
    }
    await LogManager.flush();

    final text = await logFile.readAsString();
    expect(text, isNot(contains(secret)));
    expect(text, contains('page=0'));
    expect(text, contains('page=999'));
    expect(text.indexOf('page=0'), lessThan(text.indexOf('page=999')));
    expect(RegExp(r'^Network: GET ', multiLine: true).allMatches(text),
        hasLength(1000));
  });

  test('rotates by size and retains the active file', () async {
    LogManager.maxLogFileBytes = 64;
    LogManager.addLog(LogLevel.info, 'Network', 'first event ' * 8);
    await LogManager.flush();
    LogManager.addLog(LogLevel.info, 'Network', 'second event ' * 8);
    await LogManager.flush();

    final rotated = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.startsWith('${logFile.path}.'))
        .toList();
    expect(rotated, isNotEmpty);
    expect(await logFile.exists(), isTrue);
    expect(await logFile.readAsString(), contains('second event'));
  });

  test('rotates an existing file from a previous date', () async {
    await logFile.writeAsString('old event\n');
    await logFile.setLastModified(DateTime(2000, 1, 1));

    LogManager.addLog(LogLevel.info, 'Network', 'current event');
    await LogManager.flush();

    final rotated = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.startsWith('${logFile.path}.'))
        .toList();
    expect(rotated, hasLength(1));
    expect(await rotated.single.readAsString(), 'old event\n');
    expect(await logFile.readAsString(), contains('current event'));
  });

  test('explicit rotation stays ordered between queued writes', () async {
    LogManager.addLog(LogLevel.info, 'Network', 'before rotation');
    final rotation = LogManager.rotate();
    LogManager.addLog(LogLevel.info, 'Network', 'after rotation');
    await rotation;
    await LogManager.flush();

    final rotated = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.startsWith('${logFile.path}.'))
        .toList();
    expect(rotated, hasLength(1));
    final previous = await rotated.single.readAsString();
    final current = await logFile.readAsString();
    expect(previous, contains('before rotation'));
    expect(previous, isNot(contains('after rotation')));
    expect(current, contains('after rotation'));
    expect(current, isNot(contains('before rotation')));
  });

  test('retention removes only generated rotations beyond the limit', () async {
    LogManager.maxRotatedLogFiles = 2;
    final unrelated = File('${logFile.path}.backup');
    await unrelated.writeAsString('keep unrelated file');
    for (var index = 0; index < 4; index++) {
      final old = File('${logFile.path}.2000010${index + 1}-000000-000000');
      await old.writeAsString('old event $index');
      await old.setLastModified(DateTime(2000, 1, index + 1));
    }

    LogManager.addLog(LogLevel.info, 'Network', 'current event');
    await LogManager.flush();

    expect(await unrelated.readAsString(), 'keep unrelated file');
    expect(await logFile.readAsString(), contains('current event'));
    final retained = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.startsWith('${logFile.path}.2000'))
        .toList();
    expect(retained, hasLength(2));
    expect(await Future.wait(retained.map((file) => file.readAsString())),
        unorderedEquals(['old event 2', 'old event 3']));
  });

  test('file failures do not escape addLog or flush', () async {
    final blockedPath = '${directory.path}/blocked';
    await Directory(blockedPath).create();
    LogManager.logFile = File(blockedPath);
    final failuresBefore = LogManager.writeFailureCount;

    expect(
      () => LogManager.addLog(LogLevel.error, 'Network', 'still in memory'),
      returnsNormally,
    );
    await expectLater(LogManager.flush(), completes);

    expect(LogManager.writeFailureCount, failuresBefore + 1);
    expect(LogManager.lastWriteError, isA<FileSystemException>());
    expect(LogManager.lastWriteStackTrace, isNotNull);
    expect(LogManager.logs.last.content, 'still in memory');

    LogManager.logFile = logFile;
    LogManager.addLog(LogLevel.info, 'Network', 'file writing recovered');
    await expectLater(LogManager.flush(), completes);

    expect(await logFile.readAsString(), contains('file writing recovered'));
    expect(LogManager.writeFailureCount, failuresBefore + 1);
  });

  test('export and persisted logs redact free-form diagnostics', () async {
    const secret = 'export-secret-value';
    LogManager.addLog(
      LogLevel.error,
      'Network',
      'GET https://user:$secret@example.org/image?token=$secret&page=4\n'
          'Authorization: Bearer $secret\napi_key=$secret',
    );

    final exported = LogManager.exportString();
    expect(exported, isNot(contains(secret)));
    expect(exported, contains('page=4'));
    expect(exported, contains('Authorization: <redacted>'));
    expect(exported, contains('api_key=<redacted>'));
    await LogManager.flush();
    final persisted = await logFile.readAsString();
    expect(persisted, isNot(contains(secret)));
    expect(persisted, contains('page=4'));
  });

  test('Android log destination stays under application data path', () {
    final file = LogManager.logFileForDataPath('/private/app', isIOS: false)!;
    expect(file.path, '/private/app${Platform.pathSeparator}log.txt');
    expect(
      LogManager.logFileForDataPath('/private/app', isIOS: true),
      isNull,
    );
  });
}
