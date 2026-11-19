import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';

typedef _ResponseHandler = Future<ResponseBody> Function(
    RequestOptions options);
typedef _RequestSnapshot = ({
  String method,
  String path,
  String? authorization,
});

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handle);

  final _ResponseHandler handle;
  final requests = <RequestOptions>[];
  final snapshots = <_RequestSnapshot>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    snapshots.add((
      method: options.method,
      path: options.uri.path,
      authorization: _authorization(options),
    ));
    return handle(options);
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryCookieJar implements SingleInstanceCookieJar {
  final Map<String, Cookie> _cookies = {};

  void set(String name, String value) {
    saveFromResponse(Uri.parse('https://nhentai.net/'), [
      Cookie(name, value)
        ..domain = '.nhentai.net'
        ..path = '/',
    ]);
  }

  String? value(String name) => _cookies[name]?.value;

  @override
  List<Cookie> loadForRequest(Uri uri) => _cookies.values.toList();

  @override
  String loadForRequestCookieHeader(Uri uri) => loadForRequest(uri)
      .map((cookie) => '${cookie.name}=${cookie.value}')
      .join('; ');

  @override
  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    for (final cookie in cookies) {
      _cookies[cookie.name] = Cookie(cookie.name, cookie.value)
        ..domain = cookie.domain ?? uri.host
        ..path = cookie.path ?? '/';
    }
  }

  @override
  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeaders) {
    saveFromResponse(
      uri,
      cookieHeaders.map(Cookie.fromSetCookieValue).toList(),
    );
  }

  @override
  void deleteUri(Uri uri) => _cookies.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late NhentaiNetwork network;
  late _MemoryCookieJar cookieJar;
  SingleInstanceCookieJar? previousCookieJar;
  HttpOverrides? previousOverrides;
  ProxyHttpOverrides? previousProxy;

  setUp(() async {
    previousCookieJar = SingleInstanceCookieJar.instance;
    previousOverrides = HttpOverrides.current;
    previousProxy = proxyHttpOverrides;
    cookieJar = _MemoryCookieJar();
    SingleInstanceCookieJar.instance = cookieJar;
    network = NhentaiNetwork();
    network.cookieJar = null;
    await network.init();
    addTearDown(() {
      network.dio.close(force: true);
      network.cookieJar = null;
      SingleInstanceCookieJar.instance = previousCookieJar;
      HttpOverrides.global = previousOverrides;
      proxyHttpOverrides = previousProxy;
    });
  });

  test('401 refreshes credentials and retries the original API request',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {
          'access_token': 'fresh-access',
          'refresh_token': 'fresh-refresh',
        });
      }
      if (options.uri.path == '/api/v2/user') {
        return _jsonResponse(
          _authorization(options) == 'User fresh-access' ? 200 : 401,
          {'id': 'fixture-user'},
        );
      }
      return _jsonResponse(404, {'error': 'unexpected path'});
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.validateLogin();

    expect(result.success, isTrue);
    expect(network.logged, isTrue);
    expect(cookieJar.value('access_token'), 'fresh-access');
    expect(cookieJar.value('refresh_token'), 'fresh-refresh');
    expect(adapter.requests.map((request) => request.uri.path), [
      '/api/v2/user',
      '/api/v2/auth/refresh',
      '/api/v2/user',
    ]);
    expect(
      adapter.snapshots
          .where((request) => request.path == '/api/v2/user')
          .map((request) => request.authorization),
      ['User expired-access', 'User fresh-access'],
    );
  });

  test('403 on a protected favorite endpoint also refreshes and retries',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {'access_token': 'fresh-access'});
      }
      if (options.uri.path == '/api/v2/galleries/123/favorite') {
        return _jsonResponse(
          _authorization(options) == 'User fresh-access' ? 200 : 403,
          {'ok': true},
        );
      }
      return _jsonResponse(404, {'error': 'unexpected path'});
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.favoriteComic('123', 'unused');

    expect(result.success, isTrue);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/api/v2/galleries/123/favorite',
      '/api/v2/auth/refresh',
      '/api/v2/galleries/123/favorite',
    ]);
  });

  test('403 on a gallery detail does not trigger an auth refresh', () async {
    cookieJar.set('access_token', 'valid-access');
    cookieJar.set('refresh_token', 'unused-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/galleries/123') {
        return _jsonResponse(403, {'error': 'forbidden'});
      }
      return _jsonResponse(404, {'error': 'not found'});
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.getComicInfo('123');

    expect(result.success, isFalse);
    expect(
      adapter.snapshots.map((request) => request.path),
      ['/api/v2/galleries/123', '/g/123/'],
    );
  });

  test('403 on the unfavorite endpoint refreshes and retries', () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {'access_token': 'fresh-access'});
      }
      if (options.uri.path == '/api/v2/galleries/123/favorite') {
        return _jsonResponse(
          _authorization(options) == 'User fresh-access' ? 200 : 403,
          {'ok': true},
        );
      }
      return _jsonResponse(404, {'error': 'unexpected path'});
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.unfavoriteComic('123', 'unused');

    expect(result.success, isTrue);
    expect(
      adapter.snapshots
          .where((request) => request.path == '/api/v2/galleries/123/favorite')
          .map((request) => request.method),
      ['DELETE', 'DELETE'],
    );
  });

  test('concurrent unauthorized requests share one token refresh', () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<ResponseBody>();
    var refreshCalls = 0;
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        refreshCalls++;
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        return releaseRefresh.future;
      }
      if (options.uri.path == '/api/v2/user') {
        return _jsonResponse(
          _authorization(options) == 'User fresh-access' ? 200 : 401,
          {'id': 'fixture-user'},
        );
      }
      return _jsonResponse(404, {'error': 'unexpected path'});
    });
    network.dio.httpClientAdapter = adapter;

    final resultsFuture = Future.wait([
      network.validateLogin(),
      network.validateLogin(),
    ]);
    await refreshStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(refreshCalls, 1);
    releaseRefresh.complete(_jsonResponse(200, {
      'access_token': 'fresh-access',
      'refresh_token': 'fresh-refresh',
    }));

    final results = await resultsFuture;

    expect(results.every((result) => result.success), isTrue);
    expect(refreshCalls, 1);
    expect(
      adapter.requests.where((request) => request.uri.path == '/api/v2/user'),
      hasLength(4),
    );
  });

  test('missing refresh token does not issue a refresh request', () async {
    cookieJar.set('access_token', 'expired-access');
    final adapter = _Adapter((options) async => _jsonResponse(401, {}));
    network.dio.httpClientAdapter = adapter;

    final result = await network.validateLogin();

    expect(result.success, isFalse);
    expect(network.logged, isFalse);
    expect(
        adapter.requests.map((request) => request.uri.path), ['/api/v2/user']);
  });

  test('refresh without a replacement access token does not retry stale auth',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {'refresh_token': 'rotated-refresh'});
      }
      return _jsonResponse(401, {});
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.validateLogin();

    expect(result.success, isFalse);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/api/v2/user',
      '/api/v2/auth/refresh',
    ]);
    expect(cookieJar.value('access_token'), 'expired-access');
    expect(cookieJar.value('refresh_token'), 'rotated-refresh');
  });
}

String? _authorization(RequestOptions options) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') {
      return entry.value?.toString();
    }
  }
  return null;
}

ResponseBody _jsonResponse(int statusCode, Object value) =>
    ResponseBody.fromString(
      jsonEncode(value),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
