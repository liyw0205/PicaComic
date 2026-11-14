import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/native_curl.dart';
import 'package:pica_comic/network/source_network_policy.dart';

class _Adapter extends AppHttpAdapter {
  _Adapter(this.failure, {this.onFailure}) : super(false);

  final DioExceptionType failure;
  final void Function()? onFailure;
  int calls = 0;

  @override
  Future<ResponseBody> fetchOnce(RequestOptions options,
      Stream<Uint8List>? stream, Future<void>? cancelFuture) async {
    calls++;
    if (calls == 1) {
      onFailure?.call();
      throw DioException(requestOptions: options, type: failure);
    }
    return ResponseBody.fromString('ok', 200);
  }
}

/// A deterministic transport script for status, timeout and parser fixtures.
/// It overrides only the final transport call, so AppHttpAdapter still runs
/// source budgets, retry handling and circuit accounting.
class _ScriptedAdapter extends AppHttpAdapter {
  _ScriptedAdapter(this.steps) : super(false);

  final List<Object> steps;
  int calls = 0;

  @override
  Future<ResponseBody> fetchOnce(RequestOptions options,
      Stream<Uint8List>? stream, Future<void>? cancelFuture) async {
    if (calls >= steps.length) {
      throw StateError('transport fixture exhausted at call $calls');
    }
    final step = steps[calls++];
    if (step is DioException) throw step;
    return step as ResponseBody;
  }
}

ResponseBody _fixtureResponse(int statusCode, String body,
    {String? retryAfter}) {
  return ResponseBody.fromString(
    body,
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      if (retryAfter != null) 'retry-after': [retryAfter],
    },
  );
}

RequestOptions _fixtureRequest({String method = 'GET'}) {
  return RequestOptions(
    path: 'https://fixture.test/api',
    method: method,
    extra: {'sourceKey': 'fixture'},
  );
}

void _configureFixturePolicy({
  int maxRetries = 1,
  int failureThreshold = 3,
  Duration circuitCooldown = const Duration(seconds: 30),
}) {
  SourceNetworkPolicy.instance.configure(
    'fixture',
    SourceNetworkConfig(
      maxConcurrent: 1,
      minInterval: Duration.zero,
      maxRetries: maxRetries,
      baseBackoff: Duration.zero,
      maxBackoff: const Duration(seconds: 1),
      failureThreshold: failureThreshold,
      circuitCooldown: circuitCooldown,
    ),
  );
}

Future<String> _readFixtureBody(ResponseBody response) async {
  final bytes = await response.stream
      .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
  return utf8.decode(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.pacalini.pica_comic/native_curl');

  setUp(() {
    SourceNetworkPolicy.instance.reset();
    final settings = List<String>.from(appdata.settings);
    final overrides = HttpOverrides.current;
    final proxy = proxyHttpOverrides;
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    addTearDown(() {
      appdata.settings = settings;
      HttpOverrides.global = overrides;
      proxyHttpOverrides = proxy;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  test('bodyless GET retries a transient connection failure once', () async {
    final adapter = _Adapter(DioExceptionType.connectionError);
    addTearDown(() => adapter.close(force: true));
    final response = await adapter.fetch(
        RequestOptions(path: 'https://example.org'), null, null);
    expect(response.statusCode, 200);
    expect(adapter.calls, 2);
  });

  test('429 response retries once and records rate limiting', () async {
    _configureFixturePolicy();
    final adapter = _ScriptedAdapter([
      _fixtureResponse(429, '{"error":"fixture-rate"}', retryAfter: '0'),
      _fixtureResponse(200, '{"ok":true}'),
    ]);
    addTearDown(() => adapter.close(force: true));

    final response = await adapter.fetch(_fixtureRequest(), null, null);
    expect(response.statusCode, 200);
    expect(await _readFixtureBody(response), '{"ok":true}');
    expect(adapter.calls, 2);
    final health =
        SourceNetworkPolicy.instance.diagnosticSummary()['fixture']! as Map;
    expect(health['rateLimited'], 1);
    expect(health['retries'], 1);
  });

  test('403 error JSON is returned without replay and is classified as auth',
      () async {
    _configureFixturePolicy(maxRetries: 2);
    final adapter = _ScriptedAdapter([
      _fixtureResponse(403, '{"error":"fixture-auth"}'),
    ]);
    addTearDown(() => adapter.close(force: true));

    final response = await adapter.fetch(_fixtureRequest(), null, null);
    expect(response.statusCode, 403);
    expect(await _readFixtureBody(response), '{"error":"fixture-auth"}');
    expect(adapter.calls, 1);
    final health =
        SourceNetworkPolicy.instance.diagnosticSummary()['fixture']! as Map;
    expect(health['authenticationFailures'], 1);
    expect(health['retries'], 0);
  });

  test('timeout transport error retries and keeps source accounting', () async {
    _configureFixturePolicy();
    final request = _fixtureRequest();
    final adapter = _ScriptedAdapter([
      DioException(
          requestOptions: request, type: DioExceptionType.connectionTimeout),
      _fixtureResponse(200, '{"ok":true}'),
    ]);
    addTearDown(() => adapter.close(force: true));

    final response = await adapter.fetch(request, null, null);
    expect(response.statusCode, 200);
    await _readFixtureBody(response);
    expect(adapter.calls, 2);
    final health =
        SourceNetworkPolicy.instance.diagnosticSummary()['fixture']! as Map;
    expect(health['connectionFailures'], 1);
    expect(health['retries'], 1);
  });

  test('malformed JSON fixture is parse-classifiable and never replayed',
      () async {
    _configureFixturePolicy();
    final adapter = _ScriptedAdapter([
      _fixtureResponse(200, '{"broken":'),
    ]);
    addTearDown(() => adapter.close(force: true));

    final response = await adapter.fetch(_fixtureRequest(), null, null);
    final body = await _readFixtureBody(response);
    expect(() => jsonDecode(body), throwsFormatException);
    expect(
        SourceNetworkPolicy.instance
            .classify(const FormatException('fixture JSON')),
        SourceNetworkErrorKind.parse);
    expect(
        SourceNetworkPolicy.instance.classify(DioException(
            requestOptions: _fixtureRequest(),
            type: DioExceptionType.connectionError,
            error: const FormatException('fixture JSON'))),
        SourceNetworkErrorKind.parse);
    expect(adapter.calls, 1);
  });

  test(
      'repeated 503 responses open the source circuit and short-circuit next call',
      () async {
    _configureFixturePolicy(failureThreshold: 2);
    final adapter = _ScriptedAdapter([
      _fixtureResponse(503, '{"error":"fixture-down"}'),
      _fixtureResponse(503, '{"error":"fixture-down"}'),
    ]);
    addTearDown(() => adapter.close(force: true));

    var response = await adapter.fetch(_fixtureRequest(), null, null);
    expect(response.statusCode, 503);
    await _readFixtureBody(response);
    expect(adapter.calls, 2);
    final health =
        SourceNetworkPolicy.instance.diagnosticSummary()['fixture']! as Map;
    expect(health['serverFailures'], 2);
    expect(health['retries'], 1);
    expect(health['state'], 'open');

    await expectLater(
      adapter.fetch(_fixtureRequest(), null, null),
      throwsA(isA<SourceNetworkException>().having(
        (error) => error.kind,
        'kind',
        SourceNetworkErrorKind.circuitOpen,
      )),
    );
    expect(adapter.calls, 2);
  });

  for (final method in ['POST', 'PUT', 'DELETE']) {
    test('$method is never replayed automatically', () async {
      final adapter = _Adapter(DioExceptionType.connectionError);
      addTearDown(() => adapter.close(force: true));
      await expectLater(
          adapter.fetch(
              RequestOptions(path: 'https://example.org', method: method),
              null,
              null),
          throwsA(isA<DioException>()));
      expect(adapter.calls, 1);
    });
  }

  test('request streams are not consumed a second time', () async {
    final adapter = _Adapter(DioExceptionType.connectionError);
    addTearDown(() => adapter.close(force: true));
    await expectLater(
        adapter.fetch(RequestOptions(path: 'https://example.org'),
            Stream.value(Uint8List.fromList([1])), null),
        throwsA(isA<DioException>()));
    expect(adapter.calls, 1);
  });

  for (final type in [
    DioExceptionType.cancel,
    DioExceptionType.badCertificate
  ]) {
    test('$type does not trigger retries', () async {
      final adapter = _Adapter(type);
      addTearDown(() => adapter.close(force: true));
      await expectLater(
          adapter.fetch(
              RequestOptions(path: 'https://example.org'), null, null),
          throwsA(isA<DioException>()));
      expect(adapter.calls, 1);
    });
  }

  test('cancellation stops a pending retry', () async {
    final cancel = Completer<void>();
    final adapter =
        _Adapter(DioExceptionType.connectionError, onFailure: cancel.complete);
    addTearDown(() => adapter.close(force: true));
    await expectLater(
        adapter.fetch(
            RequestOptions(path: 'https://example.org'), null, cancel.future),
        throwsA(isA<DioException>()
            .having((error) => error.type, 'type', DioExceptionType.cancel)));
    expect(adapter.calls, 1);
  });

  test('native requests use one attempt and receive cancellation', () async {
    proxyHttpOverrides = ProxyHttpOverrides(
        null, AppProxyConfig(scheme: 'http', host: 'localhost', port: 8080));
    final started = Completer<void>();
    final pending = Completer<Map<String, Object>>();
    String? requestId;
    String? cancelledId;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'fetch') {
        final args = call.arguments as Map;
        expect(args['attempts'], 1);
        requestId = args['requestId'] as String;
        started.complete();
        return pending.future;
      }
      cancelledId = call.arguments as String;
      pending.complete({'curlCode': 42, 'error': 'cancelled'});
      return null;
    });
    final cancel = Completer<void>();
    final request = NativeCurlHttpClient.fetch(
        RequestOptions(path: 'https://example.org'), null,
        cancelFuture: cancel.future);
    final assertion = expectLater(
        request,
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)));
    await started.future;
    cancel.complete();
    await assertion;
    await Future<void>.delayed(Duration.zero);
    expect(cancelledId, requestId);
  });

  test('native certificate errors retain their error category', () async {
    proxyHttpOverrides = ProxyHttpOverrides(
        null, AppProxyConfig(scheme: 'http', host: 'localhost', port: 8080));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel,
            (_) async => {'curlCode': 60, 'error': 'untrusted certificate'});
    await expectLater(
        NativeCurlHttpClient.fetch(
            RequestOptions(path: 'https://example.org'), null),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.badCertificate)));
  });
}
