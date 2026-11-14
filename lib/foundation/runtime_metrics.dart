import 'dart:math' as math;

import 'package:pica_comic/network/source_network_policy.dart';

/// A bounded, in-memory metric sample. Values are intentionally numeric so a
/// diagnostic export cannot accidentally contain URLs, response bodies, or
/// credentials.
class RuntimeMetricSnapshot {
  const RuntimeMetricSnapshot({
    required this.count,
    required this.success,
    required this.failure,
    required this.cancelled,
    required this.bytes,
    this.active = 0,
    this.peakActive = 0,
    required this.p50Milliseconds,
    required this.p95Milliseconds,
  });

  final int count;
  final int success;
  final int failure;
  final int cancelled;
  final int bytes;
  /// Number of timers that have started and not finished at snapshot time.
  final int active;
  /// Highest simultaneous timer count observed for this operation.
  final int peakActive;
  final int? p50Milliseconds;
  final int? p95Milliseconds;

  Map<String, Object?> toJson() => {
        'count': count,
        'success': success,
        'failure': failure,
        'cancelled': cancelled,
        'bytes': bytes,
        'active': active,
        'peakActive': peakActive,
        'p50Ms': p50Milliseconds,
        'p95Ms': p95Milliseconds,
      };
}

class _MetricBucket {
  int count = 0;
  int success = 0;
  int failure = 0;
  int cancelled = 0;
  int bytes = 0;
  int active = 0;
  int peakActive = 0;
  final List<int> durations = <int>[];
}

/// Low-cost runtime metrics for local diagnostics.
///
/// Samples are bounded per operation and are never persisted automatically.
/// Callers may use [start] for an operation or [record] when a duration is
/// already available. Unknown or sensitive labels are not interpreted, but a
/// conservative label limit keeps accidental unbounded input out of memory.
class RuntimeMetrics {
  RuntimeMetrics._();

  static const int maxMetricBuckets = 128;
  static const int maxSamplesPerMetric = 256;
  static final Map<String, _MetricBucket> _buckets = <String, _MetricBucket>{};

  static RuntimeMetricTimer start(String operation) {
    final bucket = _bucketFor(operation);
    bucket.active++;
    bucket.peakActive = math.max(bucket.peakActive, bucket.active);
    return RuntimeMetricTimer._(operation, Stopwatch()..start(), bucket);
  }

  static void record(
    String operation, {
    required Duration elapsed,
    bool success = true,
    bool cancelled = false,
    int bytes = 0,
  }) =>
      _record(
        _bucketFor(operation),
        elapsed: elapsed,
        success: success,
        cancelled: cancelled,
        bytes: bytes,
      );

  static _MetricBucket _bucketFor(String operation) {
    var key = _normaliseOperation(operation);
    if (!_buckets.containsKey(key) && _buckets.length >= maxMetricBuckets - 1) {
      key = 'overflow';
    }
    return _buckets.putIfAbsent(key, _MetricBucket.new);
  }

  static void _record(
    _MetricBucket bucket, {
    required Duration elapsed,
    required bool success,
    required bool cancelled,
    required int bytes,
  }) {
    bucket.count++;
    if (cancelled) {
      bucket.cancelled++;
    } else if (success) {
      bucket.success++;
    } else {
      bucket.failure++;
    }
    bucket.bytes += math.max(0, bytes);
    if (bucket.durations.length == maxSamplesPerMetric) {
      bucket.durations.removeAt(0);
    }
    bucket.durations.add(math.max(0, elapsed.inMicroseconds));
  }

  static Map<String, RuntimeMetricSnapshot> snapshot() {
    final result = <String, RuntimeMetricSnapshot>{};
    for (final entry in _buckets.entries) {
      final values = List<int>.from(entry.value.durations)..sort();
      result[entry.key] = RuntimeMetricSnapshot(
        count: entry.value.count,
        success: entry.value.success,
        failure: entry.value.failure,
        cancelled: entry.value.cancelled,
        bytes: entry.value.bytes,
        active: entry.value.active,
        peakActive: entry.value.peakActive,
        p50Milliseconds: _percentile(values, .50),
        p95Milliseconds: _percentile(values, .95),
      );
    }
    return Map.unmodifiable(result);
  }

  static Map<String, Object?> diagnosticSummary() => {
        'metrics': {
          for (final entry in snapshot().entries)
            entry.key: entry.value.toJson(),
        },
        'sourceNetwork': SourceNetworkPolicy.instance.diagnosticSummary(),
      };

  static void reset() => _buckets.clear();

  static String _normaliseOperation(String operation) {
    final trimmed = operation.trim();
    if (trimmed.isEmpty) return 'unknown';
    // Only structured metric labels are retained. This prevents a caller
    // accidentally passing a URL, exception, or other sensitive payload.
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.:-]{0,79}$').hasMatch(trimmed)) {
      return 'custom';
    }
    return trimmed;
  }

  static int? _percentile(List<int> sorted, double percentile) {
    if (sorted.isEmpty) return null;
    final index = ((sorted.length - 1) * percentile).round();
    return (sorted[index] / Duration.microsecondsPerMillisecond).round();
  }
}

class RuntimeMetricTimer {
  RuntimeMetricTimer._(this.operation, this._watch, this._bucket);

  final String operation;
  final Stopwatch _watch;
  final _MetricBucket _bucket;
  bool _finished = false;

  void finish({bool success = true, bool cancelled = false, int bytes = 0}) {
    if (_finished) return;
    _finished = true;
    _watch.stop();
    _bucket.active--;
    // Keep a timer in the bucket it started in. A reset must not let an older
    // operation decrement or add samples to a new diagnostics session.
    RuntimeMetrics._record(
      _bucket,
      elapsed: _watch.elapsed,
      success: success,
      cancelled: cancelled,
      bytes: bytes,
    );
  }
}
