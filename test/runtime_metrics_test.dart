import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';

void main() {
  setUp(RuntimeMetrics.reset);

  test('records bounded numeric summaries and percentiles', () {
    RuntimeMetrics.record('startup.settings',
        elapsed: const Duration(milliseconds: 10));
    RuntimeMetrics.record('startup.settings',
        elapsed: const Duration(milliseconds: 20));
    RuntimeMetrics.record('startup.settings',
        elapsed: const Duration(milliseconds: 30), success: false);
    RuntimeMetrics.record('startup.settings',
        elapsed: const Duration(milliseconds: 40), cancelled: true, bytes: -1);

    final metric = RuntimeMetrics.snapshot()['startup.settings']!;
    expect(metric.count, 4);
    expect(metric.success, 2);
    expect(metric.failure, 1);
    expect(metric.cancelled, 1);
    expect(metric.bytes, 0);
    expect(metric.active, 0);
    expect(metric.peakActive, 0);
    expect(metric.p50Milliseconds, 30);
    expect(metric.p95Milliseconds, 40);
  });

  test('rejects free-form labels from diagnostic output', () {
    RuntimeMetrics.record(
      'https://user:secret@example.test/path?token=secret',
      elapsed: Duration.zero,
    );

    final summary = RuntimeMetrics.diagnosticSummary().toString();
    expect(summary, contains('custom'));
    expect(summary, isNot(contains('secret')));
    expect(summary, isNot(contains('example.test')));
  });

  test('timer records at most once', () {
    final timer = RuntimeMetrics.start('reader.image');
    timer.finish(bytes: 123);
    timer.finish(success: false, bytes: 456);

    final metric = RuntimeMetrics.snapshot()['reader.image']!;
    expect(metric.count, 1);
    expect(metric.success, 1);
    expect(metric.bytes, 123);
    expect(metric.active, 0);
    expect(metric.peakActive, 1);
  });

  test('tracks overlapping operations through success failure and cancellation',
      () {
    final first = RuntimeMetrics.start('network.request');
    final second = RuntimeMetrics.start('network.request');
    var metric = RuntimeMetrics.snapshot()['network.request']!;
    expect(metric.count, 0);
    expect(metric.active, 2);
    expect(metric.peakActive, 2);
    expect(metric.p50Milliseconds, isNull);

    first.finish();
    final third = RuntimeMetrics.start('network.request');
    second.finish(success: false);
    second.finish();
    third.finish(cancelled: true);

    metric = RuntimeMetrics.snapshot()['network.request']!;
    expect(metric.count, 3);
    expect(metric.success, 1);
    expect(metric.failure, 1);
    expect(metric.cancelled, 1);
    expect(metric.active, 0);
    expect(metric.peakActive, 2);
    expect(metric.toJson()['peakActive'], 2);
  });

  test('reset isolates timers from the previous diagnostics session', () {
    final previous = RuntimeMetrics.start('network.request');
    RuntimeMetrics.reset();
    final current = RuntimeMetrics.start('network.request');

    previous.finish(success: false, bytes: 123);

    var metric = RuntimeMetrics.snapshot()['network.request']!;
    expect(metric.count, 0);
    expect(metric.active, 1);
    expect(metric.peakActive, 1);
    expect(metric.bytes, 0);

    current.finish(bytes: 456);
    metric = RuntimeMetrics.snapshot()['network.request']!;
    expect(metric.count, 1);
    expect(metric.success, 1);
    expect(metric.failure, 0);
    expect(metric.active, 0);
    expect(metric.bytes, 456);
  });

  test('bounds the number of metric operation buckets', () {
    for (var i = 0; i < RuntimeMetrics.maxMetricBuckets + 32; i++) {
      RuntimeMetrics.record('operation$i', elapsed: Duration.zero);
    }

    final snapshot = RuntimeMetrics.snapshot();
    expect(snapshot.length, RuntimeMetrics.maxMetricBuckets);
    expect(snapshot['overflow']?.count, greaterThan(0));
  });

  test('bounds buckets while operations are still active', () {
    final timers = <RuntimeMetricTimer>[];
    for (var i = 0; i < RuntimeMetrics.maxMetricBuckets + 32; i++) {
      timers.add(RuntimeMetrics.start('operation$i'));
    }

    var snapshot = RuntimeMetrics.snapshot();
    expect(snapshot.length, RuntimeMetrics.maxMetricBuckets);
    expect(snapshot.values.fold(0, (sum, metric) => sum + metric.active),
        timers.length);

    for (final timer in timers) {
      timer.finish();
    }
    snapshot = RuntimeMetrics.snapshot();
    expect(snapshot.values.every((metric) => metric.active == 0), isTrue);
    expect(snapshot.values.fold(0, (sum, metric) => sum + metric.count),
        timers.length);
    expect(snapshot['overflow']?.peakActive, 33);
  });
}
