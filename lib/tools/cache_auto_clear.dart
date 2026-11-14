import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/tools/directory_maintenance.dart';

const _cacheRetention = Duration(days: 7);

/// Cleans the two temporary image cache trees in bounded asynchronous batches.
/// The report is useful to diagnostics and keeps capacity accounting in one
/// place for callers that need to display maintenance results.
Future<CacheCleanupReport> clearStaleCache(
  String cachePath, {
  DateTime? now,
  Duration retention = _cacheRetention,
  int? maxBytes,
  int batchSize = 64,
  Set<String> protectedPaths = const <String>{},
}) async {
  if (retention.isNegative) {
    throw ArgumentError.value(retention, 'retention');
  }
  final cutoff = (now ?? DateTime.now()).subtract(retention);
  final reports = <CacheCleanupReport>[];
  for (final name in const ['imageCache', 'cachedNetwork']) {
    reports.add(await cleanupDirectory(
      Directory('$cachePath${Platform.pathSeparator}$name'),
      olderThan: cutoff,
      maxBytes: maxBytes,
      protectedPaths: protectedPaths,
      batchSize: batchSize,
    ));
  }
  return CacheCleanupReport(
    scannedFiles: reports.fold(0, (sum, item) => sum + item.scannedFiles),
    scannedBytes: reports.fold(0, (sum, item) => sum + item.scannedBytes),
    deletedFiles: reports.fold(0, (sum, item) => sum + item.deletedFiles),
    deletedBytes: reports.fold(0, (sum, item) => sum + item.deletedBytes),
    failedFiles: reports.fold(0, (sum, item) => sum + item.failedFiles),
    remainingBytes: reports.fold(0, (sum, item) => sum + item.remainingBytes),
  );
}

/// Startup entry point. Filesystem work is asynchronous and yields between
/// batches, so a large temporary cache does not block the first frame.
Future<void> startClearCache() async {
  final timer = RuntimeMetrics.start('cache.cleanup');
  try {
    final cachePath = await getTemporaryDirectory();
    final report = await clearStaleCache(cachePath.path);
    timer.finish(bytes: report.deletedBytes, success: report.failedFiles == 0);
  } catch (_) {
    timer.finish(success: false);
    rethrow;
  }
}
