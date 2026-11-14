import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/tools/atomic_file.dart';

/// A bounded summary of a directory tree. The byte count is an estimate of
/// the bytes that need to be copied or that are currently occupying storage;
/// it is intentionally independent from platform-specific free-space APIs.
class DirectoryStats {
  const DirectoryStats({
    required this.fileCount,
    required this.directoryCount,
    required this.totalBytes,
  });

  final int fileCount;
  final int directoryCount;
  final int totalBytes;

  Map<String, Object> toJson() => {
        'fileCount': fileCount,
        'directoryCount': directoryCount,
        'totalBytes': totalBytes,
      };
}

/// Scans a directory without monopolising the isolate between filesystem
/// operations. [batchSize] also bounds how long a large tree can delay a
/// frame or another maintenance operation.
Future<DirectoryStats> inspectDirectory(
  Directory root, {
  int batchSize = 64,
}) async {
  _checkBatchSize(batchSize);
  if (!await root.exists()) {
    return const DirectoryStats(fileCount: 0, directoryCount: 0, totalBytes: 0);
  }

  var files = 0;
  var directories = 0;
  var bytes = 0;
  var pending = 0;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is Directory) {
      directories++;
    } else if (entity is File) {
      try {
        bytes += (await entity.stat()).size;
        files++;
      } on FileSystemException {
        // A file can disappear while a cleanup or migration is scanning it.
        // The caller can retry and the missing entry must not abort the scan.
      }
    }
    if (++pending >= batchSize) {
      pending = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }
  return DirectoryStats(
    fileCount: files,
    directoryCount: directories,
    totalBytes: bytes,
  );
}

class CacheCleanupReport {
  const CacheCleanupReport({
    required this.scannedFiles,
    required this.scannedBytes,
    required this.deletedFiles,
    required this.deletedBytes,
    required this.failedFiles,
    required this.remainingBytes,
  });

  final int scannedFiles;
  final int scannedBytes;
  final int deletedFiles;
  final int deletedBytes;
  final int failedFiles;
  final int remainingBytes;

  Map<String, Object> toJson() => {
        'scannedFiles': scannedFiles,
        'scannedBytes': scannedBytes,
        'deletedFiles': deletedFiles,
        'deletedBytes': deletedBytes,
        'failedFiles': failedFiles,
        'remainingBytes': remainingBytes,
      };
}

class _FileRecord {
  _FileRecord(this.file, this.size, this.lastUsed);

  final File file;
  final int size;
  final DateTime lastUsed;
}

/// Removes old cache files and, when [maxBytes] is supplied, evicts the least
/// recently used remaining files until the budget is met. Deletions are
/// asynchronous and yield every batch. A failed individual delete is counted
/// and does not hide successful cleanup of the rest of the tree.
Future<CacheCleanupReport> cleanupDirectory(
  Directory root, {
  required DateTime olderThan,
  int? maxBytes,
  Set<String> protectedPaths = const <String>{},
  int batchSize = 64,
}) async {
  _checkBatchSize(batchSize);
  if (maxBytes != null && maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes');
  }
  if (!await root.exists()) {
    return const CacheCleanupReport(
      scannedFiles: 0,
      scannedBytes: 0,
      deletedFiles: 0,
      deletedBytes: 0,
      failedFiles: 0,
      remainingBytes: 0,
    );
  }

  final protected = protectedPaths.map(_absolutePath).toSet();
  final records = <_FileRecord>[];
  var scannedBytes = 0;
  var pending = 0;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File || protected.contains(_absolutePath(entity.path))) {
      continue;
    }
    try {
      final stat = await entity.stat();
      final modified = stat.modified;
      // Access time is disabled or coarsely updated on many mobile filesystems
      // and is refreshed by ordinary scans. Modification time is the stable
      // signal for cache retention and makes cleanup deterministic.
      records.add(_FileRecord(entity, stat.size, modified));
      scannedBytes += stat.size;
    } on FileSystemException {
      // Races with writers are expected for a best-effort cache pass.
    }
    if (++pending >= batchSize) {
      pending = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }

  records.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
  final candidates = <_FileRecord>[];
  var remainingBytes = scannedBytes;
  for (final record in records) {
    if (record.lastUsed.isBefore(olderThan)) {
      candidates.add(record);
      remainingBytes -= record.size;
    }
  }
  if (maxBytes != null && remainingBytes > maxBytes) {
    for (final record in records) {
      if (candidates.contains(record)) continue;
      if (remainingBytes <= maxBytes) break;
      candidates.add(record);
      remainingBytes -= record.size;
    }
  }

  var deletedFiles = 0;
  var deletedBytes = 0;
  var failedFiles = 0;
  pending = 0;
  for (final record in candidates) {
    try {
      if (await record.file.exists()) await record.file.delete();
      deletedFiles++;
      deletedBytes += record.size;
    } on FileSystemException {
      failedFiles++;
    }
    if (++pending >= batchSize) {
      pending = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }
  return CacheCleanupReport(
    scannedFiles: records.length,
    scannedBytes: scannedBytes,
    deletedFiles: deletedFiles,
    deletedBytes: deletedBytes,
    failedFiles: failedFiles,
    remainingBytes: scannedBytes - deletedBytes,
  );
}

class DirectoryMigrationPlan {
  const DirectoryMigrationPlan({
    required this.sourcePath,
    required this.destinationPath,
    required this.fileCount,
    required this.totalBytes,
  });

  final String sourcePath;
  final String destinationPath;
  final int fileCount;
  final int totalBytes;

  Map<String, Object> toJson() => {
        'sourcePath': sourcePath,
        'destinationPath': destinationPath,
        'fileCount': fileCount,
        'totalBytes': totalBytes,
      };
}

class DirectoryMigrationReport extends DirectoryMigrationPlan {
  const DirectoryMigrationReport({
    required super.sourcePath,
    required super.destinationPath,
    required super.fileCount,
    required super.totalBytes,
    required this.copiedFiles,
    required this.copiedBytes,
    required this.resumed,
  });

  final int copiedFiles;
  final int copiedBytes;
  final bool resumed;

  @override
  Map<String, Object> toJson() => {
        ...super.toJson(),
        'copiedFiles': copiedFiles,
        'copiedBytes': copiedBytes,
        'resumed': resumed,
      };
}

class _MigrationEntry {
  _MigrationEntry({
    required this.relativePath,
    required this.size,
    this.sha256,
    this.done = false,
  });

  final String relativePath;
  final int size;
  String? sha256;
  bool done;

  Map<String, Object?> toJson() => {
        'path': relativePath,
        'size': size,
        'sha256': sha256,
        'done': done,
      };

  static _MigrationEntry fromJson(Object? value) {
    if (value is! Map || value['path'] is! String || value['size'] is! int) {
      throw const FormatException('Invalid directory migration entry');
    }
    final relativePath = value['path'] as String;
    if (!_isSafeRelativePath(relativePath)) {
      throw const FormatException('Invalid directory migration relative path');
    }
    final digest = value['sha256'];
    if (digest != null && digest is! String) {
      throw const FormatException('Invalid directory migration digest');
    }
    return _MigrationEntry(
      relativePath: relativePath,
      size: value['size'] as int,
      sha256: digest as String?,
      done: value['done'] == true,
    );
  }
}

/// Copies a directory through a sibling staging directory and records every
/// verified file in a journal. If the process stops, calling this function
/// again with the same source and destination resumes from the journal. The
/// source is deleted only after the staging directory has been atomically
/// renamed into place; any copy or verification failure leaves the source
/// untouched.
Future<DirectoryMigrationReport> migrateDirectory(
  Directory source,
  Directory destination, {
  File? journalFile,
  int batchSize = 32,
  bool deleteSource = true,
}) async {
  _checkBatchSize(batchSize);
  final sourcePath = _absolutePath(source.path);
  final destinationPath = _absolutePath(destination.path);
  if (sourcePath == destinationPath || _isWithin(destinationPath, sourcePath)) {
    throw ArgumentError('Destination must not be inside the source directory');
  }
  if (!await source.exists()) {
    throw FileSystemException('Source directory does not exist', source.path);
  }

  final journal = journalFile ?? File('$destinationPath.migration.json');
  final timer = RuntimeMetrics.start('directory.migration');
  try {
    var resumed = false;
    Map<String, Object?> state;
    List<_MigrationEntry> entries;
    Directory staging;
    if (await journal.exists()) {
      resumed = true;
      state = await _readMigrationJournal(journal);
      if (state['source'] != sourcePath ||
          state['destination'] != destinationPath) {
        throw StateError(
            'Directory migration journal does not match the requested paths');
      }
      entries = (state['files'] as List<Object?>)
          .map(_MigrationEntry.fromJson)
          .toList();
      staging = Directory(state['staging'] as String);
      if (!_isSafeStagingPath(staging.path, destinationPath)) {
        throw const FormatException('Invalid directory migration staging path');
      }
      if (state['phase'] == 'committed' && await destination.exists()) {
        if (!await _destinationMatches(destination, entries)) {
          throw StateError(
              'Committed migration destination failed verification');
        }
        await _finishMigration(journal, source, destination,
            deleteSource: state['deleteSource'] != false);
        timer.finish(bytes: state['totalBytes'] as int);
        return DirectoryMigrationReport(
          sourcePath: sourcePath,
          destinationPath: destinationPath,
          fileCount: entries.length,
          totalBytes: state['totalBytes'] as int,
          copiedFiles: entries.length,
          copiedBytes: state['totalBytes'] as int,
          resumed: true,
        );
      }
    } else {
      final plan = await _planMigration(source, destination);
      entries = plan.entries;
      staging = Directory(
          '$destinationPath.migration-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp');
      state = <String, Object?>{
        'version': 1,
        'phase': 'copying',
        'source': sourcePath,
        'destination': destinationPath,
        'staging': staging.path,
        'deleteSource': deleteSource,
        'totalBytes': plan.totalBytes,
        'files': entries.map((entry) => entry.toJson()).toList(),
      };
      await _writeMigrationJournal(journal, state);
    }

    // A process can stop after the staging directory is renamed but before
    // the committed phase is persisted. Recognise that state before creating
    // a fresh staging directory and deleting the source.
    if (state['phase'] == 'copying' &&
        !await staging.exists() &&
        await destination.exists() &&
        await _destinationMatches(destination, entries)) {
      state['phase'] = 'committed';
      await _writeMigrationJournal(journal, state);
      await _finishMigration(journal, source, destination,
          deleteSource: state['deleteSource'] != false);
      final totalBytes = state['totalBytes'] as int;
      timer.finish(bytes: totalBytes);
      return DirectoryMigrationReport(
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        fileCount: entries.length,
        totalBytes: totalBytes,
        copiedFiles: entries.length,
        copiedBytes: totalBytes,
        resumed: true,
      );
    }

    if (await destination.exists()) {
      final existing =
          await inspectDirectory(destination, batchSize: batchSize);
      if (existing.fileCount != 0 && !resumed) {
        throw StateError('Destination directory is not empty');
      }
    }

    await staging.create(recursive: true);
    var copiedFiles = entries.where((entry) => entry.done).length;
    var copiedBytes = entries
        .where((entry) => entry.done)
        .fold<int>(0, (sum, entry) => sum + entry.size);
    var pending = 0;
    for (final entry in entries) {
      final sourceFile = File(_joinRelative(sourcePath, entry.relativePath));
      final targetFile = File(_joinRelative(staging.path, entry.relativePath));
      if (entry.done &&
          await _matchesDigest(targetFile, entry.size, entry.sha256)) {
        if (entry.sha256 != null &&
            await _digestFile(sourceFile) != entry.sha256) {
          throw StateError(
              'Source changed during migration: ${entry.relativePath}');
        }
        continue;
      }
      final stat = await sourceFile.stat();
      if (stat.size != entry.size) {
        throw StateError(
            'Source changed during migration: ${entry.relativePath}');
      }
      final digest = await _copyAndDigest(sourceFile, targetFile);
      if (digest.size != entry.size) {
        throw StateError('Copied size mismatch: ${entry.relativePath}');
      }
      entry.sha256 = digest.digest;
      entry.done = true;
      copiedFiles++;
      copiedBytes += entry.size;
      state['files'] = entries.map((item) => item.toJson()).toList();
      await _writeMigrationJournal(journal, state);
      if (++pending >= batchSize) {
        pending = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (await destination.exists()) {
      final existing =
          await inspectDirectory(destination, batchSize: batchSize);
      if (existing.fileCount != 0) {
        throw StateError('Destination directory is not empty');
      }
      await destination.delete();
    }
    await staging.rename(destination.path);
    state['phase'] = 'committed';
    state['files'] = entries.map((item) => item.toJson()).toList();
    await _writeMigrationJournal(journal, state);
    await _finishMigration(journal, source, destination,
        deleteSource: state['deleteSource'] != false);
    timer.finish(bytes: copiedBytes);
    return DirectoryMigrationReport(
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      fileCount: entries.length,
      totalBytes: state['totalBytes'] as int,
      copiedFiles: copiedFiles,
      copiedBytes: copiedBytes,
      resumed: resumed,
    );
  } catch (_) {
    timer.finish(success: false);
    rethrow;
  }
}

Future<Map<String, Object?>> _readMigrationJournal(File journal) async {
  final decoded = jsonDecode(await journal.readAsString());
  if (decoded is! Map ||
      decoded['version'] != 1 ||
      decoded['source'] is! String ||
      decoded['destination'] is! String ||
      decoded['staging'] is! String ||
      decoded['files'] is! List ||
      decoded['totalBytes'] is! int) {
    throw const FormatException('Invalid directory migration journal');
  }
  final state = Map<String, Object?>.from(decoded);
  final phase = state['phase'];
  if (phase != 'copying' && phase != 'committed') {
    throw const FormatException('Invalid directory migration phase');
  }
  return state;
}

Future<void> _writeMigrationJournal(
    File journal, Map<String, Object?> state) async {
  final encoded = const JsonEncoder().convert(state);
  await writeTextFileAtomically(journal, encoded);
}

Future<void> _finishMigration(
  File journal,
  Directory source,
  Directory destination, {
  required bool deleteSource,
}) async {
  if (deleteSource && await source.exists()) {
    await source.delete(recursive: true);
  }
  if (await journal.exists()) await journal.delete();
}

Future<bool> _destinationMatches(
  Directory destination,
  List<_MigrationEntry> entries,
) async {
  for (final entry in entries) {
    final file = File(_joinRelative(destination.path, entry.relativePath));
    if (!await _matchesDigest(file, entry.size, entry.sha256)) return false;
  }
  return true;
}

class _MigrationPlanData {
  const _MigrationPlanData(this.entries, this.totalBytes);

  final List<_MigrationEntry> entries;
  final int totalBytes;
}

Future<_MigrationPlanData> _planMigration(
  Directory source,
  Directory destination,
) async {
  final sourcePath = _absolutePath(source.path);
  final entries = <_MigrationEntry>[];
  var totalBytes = 0;
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    final relative = entity.path
        .substring(sourcePath.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    entries.add(_MigrationEntry(relativePath: relative, size: stat.size));
    totalBytes += stat.size;
    if (entries.length % 32 == 0) await Future<void>.delayed(Duration.zero);
  }
  entries.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return _MigrationPlanData(entries, totalBytes);
}

class _CopyDigest {
  const _CopyDigest(this.size, this.digest);

  final int size;
  final String digest;
}

Future<_CopyDigest> _copyAndDigest(File source, File target) async {
  await target.parent.create(recursive: true);
  final temporary = File('${target.path}.$pid.part');
  final output = temporary.openWrite();
  final digestOutput = _DigestCollector();
  final digestInput = sha256.startChunkedConversion(digestOutput);
  var size = 0;
  try {
    await for (final chunk in source.openRead()) {
      digestInput.add(chunk);
      output.add(chunk);
      size += chunk.length;
    }
    digestInput.close();
    await output.flush();
    await output.close();
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    return _CopyDigest(size, digestOutput.value.toString());
  } catch (_) {
    await output.close();
    rethrow;
  } finally {
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } catch (_) {
        // Keep a partial artifact for a later maintenance pass.
      }
    }
  }
}

Future<bool> _matchesDigest(
    File file, int expectedSize, String? expectedDigest) async {
  if (expectedDigest == null || !await file.exists()) return false;
  final stat = await file.stat();
  if (stat.size != expectedSize) return false;
  return await _digestFile(file) == expectedDigest;
}

Future<String> _digestFile(File file) async {
  final output = _DigestCollector();
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return output.value.toString();
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

Future<DirectoryMigrationPlan> planDirectoryMigration(
  Directory source,
  Directory destination,
) async {
  if (!await source.exists()) {
    throw FileSystemException('Source directory does not exist', source.path);
  }
  final sourcePath = _absolutePath(source.path);
  final destinationPath = _absolutePath(destination.path);
  if (sourcePath == destinationPath || _isWithin(destinationPath, sourcePath)) {
    throw ArgumentError('Destination must not be inside the source directory');
  }
  final plan = await _planMigration(source, destination);
  return DirectoryMigrationPlan(
    sourcePath: sourcePath,
    destinationPath: destinationPath,
    fileCount: plan.entries.length,
    totalBytes: plan.totalBytes,
  );
}

String _absolutePath(String path) => File(path).absolute.path;

bool _isWithin(String child, String parent) {
  final prefix = parent.endsWith(Platform.pathSeparator)
      ? parent
      : '$parent${Platform.pathSeparator}';
  return child.startsWith(prefix);
}

String _joinRelative(String root, String relative) =>
    '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

bool _isSafeStagingPath(String staging, String destination) {
  final stagingFile = File(staging).absolute;
  final destinationFile = File(destination).absolute;
  return stagingFile.parent.path == destinationFile.parent.path &&
      stagingFile.path.startsWith('${destinationFile.path}.migration-');
}

bool _isSafeRelativePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    return false;
  }
  final segments = path.split('/');
  return !segments.any((segment) => segment.isEmpty || segment == '..');
}

void _checkBatchSize(int batchSize) {
  if (batchSize < 1) throw ArgumentError.value(batchSize, 'batchSize');
}
