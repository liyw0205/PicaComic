import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/source_network_policy.dart';

void main() {
  test('classifies authentication, rate limiting, server and transport errors',
      () {
    final policy = SourceNetworkPolicy();
    expect(policy.classifyStatus(401), SourceNetworkErrorKind.authentication);
    expect(policy.classifyStatus(403), SourceNetworkErrorKind.authentication);
    expect(policy.classifyStatus(408), SourceNetworkErrorKind.timeout);
    expect(policy.classifyStatus(429), SourceNetworkErrorKind.rateLimited);
    expect(policy.classifyStatus(503), SourceNetworkErrorKind.server);
    expect(policy.classify(const SocketException('offline')),
        SourceNetworkErrorKind.connection);
    expect(
        policy.classify(
          DioException(
            requestOptions: RequestOptions(path: 'https://source.test'),
            type: DioExceptionType.connectionTimeout,
          ),
        ),
        SourceNetworkErrorKind.timeout);
    expect(
      policy.classify(
        DioException(
          requestOptions: RequestOptions(path: 'https://source.test'),
          error: SourceNetworkException(
            kind: SourceNetworkErrorKind.responseTooLarge,
            sourceKey: 'source.test',
            message: 'fixture response limit',
          ),
        ),
      ),
      SourceNetworkErrorKind.responseTooLarge,
    );
  });

  test('retries only idempotent requests and caps response size', () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(
        maxResponseBytes: 3,
        maxRetries: 2,
        baseBackoff: Duration(milliseconds: 10),
        maxBackoff: Duration(milliseconds: 20),
      ),
    );
    final get = RequestOptions(path: 'https://fixture.test', method: 'GET');
    final post = RequestOptions(path: 'https://fixture.test', method: 'POST');
    expect(policy.shouldRetry(get, SourceNetworkErrorKind.server, 0, 'fixture'),
        isTrue);
    expect(
        policy.shouldRetry(post, SourceNetworkErrorKind.server, 0, 'fixture'),
        isFalse);
    expect(policy.retryDelay('fixture', 1), const Duration(milliseconds: 10));
    expect(policy.retryDelay('fixture', 3), const Duration(milliseconds: 20));
    expect(
      policy.retryDelay('fixture', 1, retryAfter: const Duration(seconds: 1)),
      const Duration(milliseconds: 20),
    );

    final response = ResponseBody.fromBytes(
      Uint8List.fromList([1, 2, 3, 4]),
      200,
      headers: {
        'content-length': ['4']
      },
    );
    expect(
      () => policy.enforceResponseLimit(response, 'fixture'),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.responseTooLarge,
      )),
    );

    final streamed = policy.enforceResponseLimit(
      ResponseBody(
        Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4])),
        200,
      ),
      'fixture',
    );
    await expectLater(
      streamed.stream.toList(),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.responseTooLarge,
      )),
    );
  });

  test('records response-limit failures while reading a streamed response',
      () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(
        maxConcurrent: 1,
        minInterval: Duration.zero,
        maxResponseBytes: 3,
      ),
    );
    final request = RequestOptions(
      path: 'https://fixture.test',
      extra: {'sourceKey': 'fixture'},
    );
    final lease = await policy.beforeRequest(request);
    final response = policy.enforceResponseLimit(
      ResponseBody(
        Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4])),
        200,
      ),
      'fixture',
    );
    policy.reportSuccess(lease, response: response);

    var health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['successes'], 0);
    expect(health['failures'], 0);
    await expectLater(
      response.stream.toList(),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.responseTooLarge,
      )),
    );

    health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['successes'], 0);
    expect(health['failures'], 1);
    final followup = await policy.beforeRequest(request);
    policy.reportSuccess(followup);
    health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['successes'], 1);
  });

  test('opens a source circuit after repeated transient failures', () async {
    var now = DateTime(2026, 1, 1);
    final policy = SourceNetworkPolicy(now: () => now);
    policy.configure(
      'fixture',
      const SourceNetworkConfig(
        minInterval: Duration.zero,
        failureThreshold: 2,
        circuitCooldown: Duration(seconds: 10),
      ),
    );
    final request = RequestOptions(
      path: 'https://fixture.test',
      extra: {'sourceKey': 'fixture'},
    );

    for (var i = 0; i < 2; i++) {
      final lease = await policy.beforeRequest(request);
      policy.reportFailure(lease, const SocketException('offline'));
    }
    var health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['state'], 'open');
    expect(health['cooldownRemainingMs'], 10000);

    now = now.add(const Duration(seconds: 1));
    health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['state'], 'open');
    expect(health['cooldownRemainingMs'], 9000);
    await expectLater(
      policy.beforeRequest(request),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.circuitOpen,
      )),
    );

    now = now.add(const Duration(seconds: 9));
    health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['state'], 'degraded');
    expect(health['cooldownRemainingMs'], 0);
    final lease = await policy.beforeRequest(request);
    policy.reportSuccess(lease);
    health = policy.diagnosticSummary()['fixture'] as Map;
    expect(health['state'], 'healthy');
    expect(health['failures'], 2);
  });

  test('non-transient failures break the consecutive circuit count', () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(
        minInterval: Duration.zero,
        failureThreshold: 2,
      ),
    );
    final request = RequestOptions(
      path: 'https://fixture.test',
      extra: {'sourceKey': 'fixture'},
    );

    var lease = await policy.beforeRequest(request);
    policy.reportFailure(lease, const SocketException('offline'));
    lease = await policy.beforeRequest(request);
    policy.reportFailure(
      lease,
      SourceNetworkException(
        kind: SourceNetworkErrorKind.client,
        sourceKey: 'fixture',
        statusCode: 404,
        message: 'not found',
      ),
    );
    lease = await policy.beforeRequest(request);
    policy.reportFailure(lease, const SocketException('offline'));

    final summary = policy.diagnosticSummary()['fixture'] as Map;
    expect(summary['state'], 'degraded');
    expect(summary['cooldownRemainingMs'], 0);
  });

  test('cancelled requests do not remain queued behind a source budget',
      () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 1, minInterval: Duration.zero),
    );
    final first = await policy.beforeRequest(RequestOptions(
        path: 'https://fixture.test/first', extra: {'sourceKey': 'fixture'}));
    final cancel = Future<void>.delayed(const Duration(milliseconds: 1));
    await expectLater(
      policy.beforeRequest(
        RequestOptions(
          path: 'https://fixture.test/second',
          extra: {'sourceKey': 'fixture'},
        ),
        cancelFuture: cancel,
      ),
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );
    final health = policy.diagnosticSummary()['fixture']! as Map;
    expect(health['requests'], 2);
    expect(health['failures'], 1);
    expect(health['cancelled'], 1);
    first.release();
  });

  test('cancellation during source pacing is accounted without opening circuit',
      () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(
        maxConcurrent: 1,
        minInterval: Duration(seconds: 1),
      ),
    );
    final request = RequestOptions(
      path: 'https://fixture.test/paced',
      extra: {'sourceKey': 'fixture'},
    );
    final first = await policy.beforeRequest(request);
    first.release();

    final cancel = Future<void>.delayed(const Duration(milliseconds: 1));
    await expectLater(
      policy.beforeRequest(request, cancelFuture: cancel),
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );
    final health = policy.diagnosticSummary()['fixture']! as Map;
    expect(health['requests'], 2);
    expect(health['failures'], 1);
    expect(health['cancelled'], 1);
    expect(health['state'], 'healthy');
  });

  test('an already-completed cancellation wins an immediately available permit',
      () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 1, minInterval: Duration.zero),
    );
    final request = RequestOptions(
      path: 'https://fixture.test/immediate-cancel',
      extra: {'sourceKey': 'fixture'},
    );
    final first = await policy.beforeRequest(request);
    first.release();

    await expectLater(
      policy.beforeRequest(request, cancelFuture: Future<void>.value()),
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );

    final health = policy.diagnosticSummary()['fixture']! as Map;
    expect(health['requests'], 2);
    expect(health['failures'], 1);
    expect(health['cancelled'], 1);

    final followup = await policy.beforeRequest(request);
    policy.reportSuccess(followup);
  });

  test('resizing a source budget preserves queued requests', () async {
    final policy = SourceNetworkPolicy();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 1, minInterval: Duration.zero),
    );
    final first = await policy.beforeRequest(RequestOptions(
        path: 'https://fixture.test/first', extra: {'sourceKey': 'fixture'}));
    var expandedCompleted = false;
    final expanded = policy
        .beforeRequest(RequestOptions(
            path: 'https://fixture.test/expanded',
            extra: {'sourceKey': 'fixture'}))
        .then((lease) {
      expandedCompleted = true;
      return lease;
    });
    var expandedSecondCompleted = false;
    final expandedSecond = policy
        .beforeRequest(RequestOptions(
            path: 'https://fixture.test/expanded-second',
            extra: {'sourceKey': 'fixture'}))
        .then((lease) {
      expandedSecondCompleted = true;
      return lease;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(expandedCompleted, isFalse);
    expect(expandedSecondCompleted, isFalse);

    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 3, minInterval: Duration.zero),
    );
    final expandedLeases = await Future.wait([
      expanded.timeout(const Duration(seconds: 1)),
      expandedSecond.timeout(const Duration(seconds: 1)),
    ]);
    expect(expandedCompleted, isTrue);
    expect(expandedSecondCompleted, isTrue);
    expandedLeases.first.release();
    final second = await policy.beforeRequest(RequestOptions(
        path: 'https://fixture.test/second', extra: {'sourceKey': 'fixture'}));
    var shrunkCompleted = false;
    final shrunk = policy
        .beforeRequest(RequestOptions(
            path: 'https://fixture.test/shrunk',
            extra: {'sourceKey': 'fixture'}))
        .then((lease) {
      shrunkCompleted = true;
      return lease;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(shrunkCompleted, isFalse);

    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 1, minInterval: Duration.zero),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(shrunkCompleted, isFalse);
    first.release();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(shrunkCompleted, isFalse);
    expandedLeases[1].release();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(shrunkCompleted, isFalse);
    second.release();
    final shrunkLease = await shrunk.timeout(const Duration(seconds: 1));
    expect(shrunkCompleted, isTrue);
    shrunkLease.release();
  });

  test(
      'reconfiguring pacing applies longer intervals without shortening old ones',
      () async {
    var now = DateTime(2026, 1, 1);
    final policy = SourceNetworkPolicy(now: () => now);
    final request = RequestOptions(
      path: 'https://fixture.test/pacing',
      extra: {'sourceKey': 'fixture'},
    );
    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 1, minInterval: Duration.zero),
    );

    var lease = await policy.beforeRequest(request);
    lease.release();
    policy.configure(
      'fixture',
      const SourceNetworkConfig(
        maxConcurrent: 1,
        minInterval: Duration(seconds: 1),
      ),
    );
    final longerCancel = Completer<void>();
    var longerCompleted = false;
    final longer = policy
        .beforeRequest(
      request,
      cancelFuture: longerCancel.future,
    )
        .then((lease) {
      longerCompleted = true;
      lease.release();
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(longerCompleted, isFalse);
    longerCancel.complete();
    await expectLater(
      longer,
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );

    now = now.add(const Duration(seconds: 1));
    lease = await policy.beforeRequest(request);
    lease.release();

    policy.configure(
      'fixture',
      const SourceNetworkConfig(maxConcurrent: 1, minInterval: Duration.zero),
    );
    final shorterCancel = Completer<void>();
    var shorterCompleted = false;
    final shorter = policy
        .beforeRequest(
      request,
      cancelFuture: shorterCancel.future,
    )
        .then((lease) {
      shorterCompleted = true;
      lease.release();
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(shorterCompleted, isFalse);
    shorterCancel.complete();
    await expectLater(
      shorter,
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );

    now = now.add(const Duration(seconds: 1));
    lease = await policy.beforeRequest(request);
    lease.release();
  });

  test('a circuit opened for one source does not block another source',
      () async {
    var now = DateTime(2026, 1, 1);
    final policy = SourceNetworkPolicy(now: () => now);
    policy.configure(
      'source-a',
      const SourceNetworkConfig(
        minInterval: Duration.zero,
        failureThreshold: 1,
        circuitCooldown: Duration(minutes: 1),
      ),
    );
    policy.configure(
      'source-b',
      const SourceNetworkConfig(
        minInterval: Duration.zero,
        failureThreshold: 1,
      ),
    );
    final requestA = RequestOptions(
      path: 'https://source-a.test',
      extra: {'sourceKey': 'source-a'},
    );
    final requestB = RequestOptions(
      path: 'https://source-b.test',
      extra: {'sourceKey': 'source-b'},
    );

    final failedLease = await policy.beforeRequest(requestA);
    policy.reportFailure(failedLease, const SocketException('fixture offline'));
    await expectLater(
      policy.beforeRequest(requestA),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.circuitOpen,
      )),
    );

    final healthyLease = await policy.beforeRequest(requestB);
    policy.reportSuccess(healthyLease);
    final summary = policy.diagnosticSummary();
    expect((summary['source-a'] as Map)['state'], 'open');
    expect((summary['source-b'] as Map)['state'], 'healthy');
    expect((summary['source-b'] as Map)['successes'], 1);
    now = now.add(const Duration(minutes: 2));
    final recoveredLease = await policy.beforeRequest(requestA);
    policy.reportSuccess(recoveredLease);
    final recovered = policy.diagnosticSummary()['source-a'] as Map;
    expect(recovered['state'], 'healthy');
    expect(recovered['cooldownRemainingMs'], 0);
  });
}
