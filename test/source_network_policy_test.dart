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
    await expectLater(
      policy.beforeRequest(request),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.circuitOpen,
      )),
    );

    now = now.add(const Duration(seconds: 11));
    final lease = await policy.beforeRequest(request);
    policy.reportSuccess(lease);
    final health = policy.diagnosticSummary()['fixture'] as Map;
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
    first.release();
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
  });
}
