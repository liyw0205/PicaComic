import 'dart:async';

class _MaintenanceScope {
  bool active = true;
}

/// Counters for one serialized maintenance operation.
///
/// The counters are intentionally local to the current zone.  This keeps
/// import tests and diagnostics deterministic without introducing a global
/// lock around every database mutation.
final class DataMaintenanceStats {
  DataMaintenanceStats(this.operation);

  final String operation;
  int syncRequests = 0;
  int suppressedSyncRequests = 0;
  int unsuppressedSyncRequests = 0;

  DataMaintenanceStats snapshot() => DataMaintenanceStats(operation)
    ..syncRequests = syncRequests
    ..suppressedSyncRequests = suppressedSyncRequests
    ..unsuppressedSyncRequests = unsuppressedSyncRequests;
}

/// Serializes maintenance and lets nested backup/sync calls reuse the scope.
class DataMaintenance {
  static final _scopeKey = Object();
  static final _syncKey = Object();
  static final _statsKey = Object();
  static Future<void> _tail = Future<void>.value();
  static _MaintenanceScope? _active;
  static DataMaintenanceStats? _lastStats;

  static bool get syncSuppressed => Zone.current[_syncKey] == true;
  static bool get ownsScope =>
      Zone.current[_scopeKey] is _MaintenanceScope &&
      (Zone.current[_scopeKey] as _MaintenanceScope).active;
  static bool get busy => _active != null && !ownsScope;

  /// Statistics for the current operation, if one is active in this zone.
  static DataMaintenanceStats? get currentStats =>
      Zone.current[_statsKey] as DataMaintenanceStats?;

  /// A snapshot of the most recently completed top-level operation.
  static DataMaintenanceStats? get lastStats => _lastStats?.snapshot();

  /// Record a request to publish local data.  The request is counted even
  /// when synchronization is suppressed, which makes a large import's
  /// "zero remote writes" invariant testable without a WebDAV server.
  static void recordSyncRequest() {
    final stats = currentStats;
    if (stats == null) return;
    stats.syncRequests++;
    if (syncSuppressed) {
      stats.suppressedSyncRequests++;
    } else {
      stats.unsuppressedSyncRequests++;
    }
  }

  static Future<T> run<T>(FutureOr<T> Function() operation,
      {bool suppressSync = false, String operationName = 'maintenance'}) {
    if (ownsScope) {
      return Future<T>.sync(() => runZoned(operation, zoneValues: {
            _syncKey: syncSuppressed || suppressSync,
            if (currentStats != null) _statsKey: currentStats,
          }));
    }
    final task = _tail.then<T>((_) async {
      final scope = _MaintenanceScope();
      final stats = DataMaintenanceStats(operationName);
      _active = scope;
      try {
        return await runZoned(() => Future<T>.sync(operation), zoneValues: {
          _scopeKey: scope,
          _syncKey: syncSuppressed || suppressSync,
          _statsKey: stats,
        });
      } finally {
        _lastStats = stats.snapshot();
        scope.active = false;
        _active = null;
      }
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  static Future<void> waitForIdle() => _tail;
}
