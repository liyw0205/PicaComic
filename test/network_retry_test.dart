import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/native_curl.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.pacalini.pica_comic/native_curl');

  setUp(() {
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
