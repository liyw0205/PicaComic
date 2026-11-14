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
  });

  test('bounds the number of metric operation buckets', () {
    for (var i = 0; i < RuntimeMetrics.maxMetricBuckets + 32; i++) {
      RuntimeMetrics.record('operation$i', elapsed: Duration.zero);
    }

    final snapshot = RuntimeMetrics.snapshot();
    expect(snapshot.length, RuntimeMetrics.maxMetricBuckets);
    expect(snapshot['overflow']?.count, greaterThan(0));
  });
}
