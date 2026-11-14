import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/extensions.dart';

void log(
  String content, [
  String title = "debug",
  LogLevel level = LogLevel.info,
]) {
  LogManager.addLog(level, title, content);
}

class LogManager {
  static final List<Log> _logs = <Log>[];

  // File writes are deliberately serialized. A large number of network
  // callbacks can arrive in the same frame, and overlapping append calls do
  // not provide a stable ordering on every supported filesystem.
  static Future<void> _writeQueue = Future<void>.value();
  static File? logFile;

  /// Returns the application-private log destination for a platform.
  ///
  /// Android used to prefer [getExternalStorageDirectory], which made
  /// diagnostics visible outside the app sandbox. Keep iOS disabled as
  /// before, but use the already-private application support directory on
  /// every other platform.
  static File? logFileForDataPath(String dataPath, {required bool isIOS}) {
    if (isIOS) return null;
    return File('$dataPath${Platform.pathSeparator}log.txt');
  }

  static List<Log> get logs => _logs;

  static const maxLogLength = 3000;

  static const maxLogNumber = 500;

  /// The active file is rotated before it grows beyond this size.
  ///
  /// This is mutable so platform tests can use a small threshold without
  /// creating multi-megabyte fixtures.
  static int maxLogFileBytes = 2 * 1024 * 1024;

  /// Number of rotated files retained beside the active log file.
  static int maxRotatedLogFiles = 5;

  static bool ignoreLimitation = false;

  /// Number of file-write failures observed since process start.
  static int writeFailureCount = 0;

  /// Last file-write failure, if any. The in-memory log remains usable when a
  /// log directory is unavailable or a rotation cannot be completed.
  static Object? lastWriteError;
  static StackTrace? lastWriteStackTrace;

  static void printWarning(String text) {
    print('\x1B[33m$text\x1B[0m');
  }

  static void printError(String text) {
    print('\x1B[31m$text\x1B[0m');
  }

  static void addLog(LogLevel level, String title, String content) {
    if (!ignoreLimitation && content.length > maxLogLength) {
      content = "${content.substring(0, maxLogLength)}...";
    }

    if (kDebugMode) {
      switch (level) {
        case LogLevel.error:
          printError("$title: $content");
        case LogLevel.warning:
          printWarning("$title: $content");
        case LogLevel.info:
          print("$title: $content");
      }
    }

    var newLog = Log(level, title, content);

    if (newLog == _logs.lastOrNull) {
      return;
    }

    _logs.add(newLog);
    writeLog(level, title, content);
    if (_logs.length > maxLogNumber) {
      var res = _logs.remove(
        _logs.firstWhereOrNull((element) => element.level == LogLevel.info),
      );
      if (!res) {
        _logs.removeAt(0);
      }
    }
  }

  static void clear() => _logs.clear();

  @override
  String toString() {
    return _formatLogs(redact: false);
  }

  /// Returns a shareable diagnostic snapshot with a second redaction pass.
  ///
  /// In-memory logs remain available to the diagnostics page, while exported
  /// text is protected even when an older caller recorded raw network data.
  static String exportString() => _formatLogs(redact: true);

  static String _formatLogs({required bool redact}) {
    var res = "Logs\n\n";
    for (var entry in _logs) {
      final title = redact ? redactLogText(entry.title) : entry.title;
      final content = redact ? redactLogText(entry.content) : entry.content;
      res += '${entry.level.name} $title ${entry.time} \n$content\n\n';
    }
    return res;
  }

  static void writeLog(LogLevel level, String title, String content) {
    final file = logFile;
    if (file == null) return;

    // Protect the on-disk diagnostic copy even when an older caller bypasses
    // the structured network logging helpers.
    title = redactLogText(title);
    content = redactLogText(content);
    final line =
        "${DateTime.now().toIso8601String()} ${level.name}\n$title: $content\n\n";
    _enqueue(() => _append(file, line));
  }

  /// Waits until all writes queued before this call have completed.
  ///
  /// Write failures are recorded in [writeFailureCount] and intentionally do
  /// not escape this future: logging must never fail the operation being
  /// logged.
  static Future<void> flush() => _writeQueue;

  /// Rotates the current log file after all earlier writes have completed.
  /// This is useful at lifecycle boundaries and for an explicit diagnostics
  /// export without changing the synchronous logging API.
  static Future<void> rotate() {
    final file = logFile;
    if (file == null) return flush();
    return _enqueue(() async {
      if (await file.exists()) {
        await _rotateFile(file, DateTime.now());
        await _pruneRotatedFiles(file);
      }
    });
  }

  static Future<void> _enqueue(Future<void> Function() operation) {
    _writeQueue = _writeQueue.then<void>((_) async {
      try {
        await operation();
      } catch (error, stack) {
        _recordWriteFailure(error, stack);
      }
    });
    return _writeQueue;
  }

  static void _recordWriteFailure(Object error, StackTrace stack) {
    writeFailureCount++;
    lastWriteError = error;
    lastWriteStackTrace = stack;
  }

  static Future<void> _append(File file, String line) async {
    await file.parent.create(recursive: true);
    final now = DateTime.now();
    final bytes = utf8.encode(line);
    if (await file.exists()) {
      final stat = await file.stat();
      final dateChanged = _dateKey(stat.modified) != _dateKey(now);
      final tooLarge = maxLogFileBytes >= 0 &&
          stat.size > 0 &&
          stat.size + bytes.length > maxLogFileBytes;
      if (dateChanged || tooLarge) {
        await _rotateFile(file, now);
      }
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    await _pruneRotatedFiles(file);
  }

  static Future<void> _rotateFile(File file, DateTime now) async {
    if (!await file.exists()) return;
    if ((await file.stat()).size == 0) return;
    final date = _dateKey(now);
    final stamp = '$date-${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}'
        '-${now.microsecond.toString().padLeft(6, '0')}';
    final base = '${file.path}.$stamp';
    var rotated = File(base);
    var index = 1;
    while (await rotated.exists()) {
      rotated = File('$base.$index');
      index++;
    }
    await file.rename(rotated.path);
  }

  static Future<void> _pruneRotatedFiles(File file) async {
    final keep = maxRotatedLogFiles < 0 ? 0 : maxRotatedLogFiles;
    final parent = file.parent;
    if (!await parent.exists()) return;
    final prefix = '${file.path}.';
    final generatedName = RegExp(r'^\d{8}-\d{6}-\d{6}(?:\.\d+)?$');
    final candidates = <File>[];
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is File &&
          entity.path.startsWith(prefix) &&
          generatedName.hasMatch(entity.path.substring(prefix.length))) {
        candidates.add(entity);
      }
    }
    if (candidates.length <= keep) return;
    final withTimes = <({File file, DateTime modified})>[];
    for (final candidate in candidates) {
      try {
        withTimes.add((
          file: candidate,
          modified: (await candidate.stat()).modified,
        ));
      } catch (_) {
        // A concurrently removed stale rotation needs no further handling.
      }
    }
    withTimes.sort((a, b) => a.modified.compareTo(b.modified));
    final removeCount = withTimes.length - keep;
    for (var index = 0; index < removeCount; index++) {
      try {
        await withTimes[index].file.delete();
      } catch (_) {
        // Retention cleanup is best effort and must not hide a successful log.
      }
    }
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}';
}

class Log {
  final LogLevel level;
  final String title;
  final String content;
  final DateTime time = DateTime.now();

  @override
  toString() => "${level.name} $title $time \n$content\n\n";

  Log(this.level, this.title, this.content);

  static void info(String title, String message) {
    LogManager.addLog(LogLevel.info, title, message);
  }

  static void warning(String title, String message) {
    LogManager.addLog(LogLevel.warning, title, message);
  }

  static void error(String title, String message) {
    LogManager.addLog(LogLevel.error, title, message);
  }

  @override
  bool operator ==(Object other) {
    if (other is! Log) return false;
    return other.level == level &&
        other.title == title &&
        other.content == content;
  }

  @override
  int get hashCode => level.hashCode ^ title.hashCode ^ content.hashCode;
}

enum LogLevel { error, warning, info }
