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

  test('Set-Cookie refresh credentials are used by the original request',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {}, headers: {
          'set-cookie': [
            'access_token=cookie-access; Domain=.nhentai.net; Path=/',
            'refresh_token=cookie-refresh; Domain=.nhentai.net; Path=/',
          ],
        });
      }
      return _jsonResponse(
        _authorization(options) == 'User cookie-access' ? 200 : 401,
        {'id': 'fixture-user'},
      );
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.validateLogin();

    expect(result.success, isTrue);
    expect(cookieJar.value('access_token'), 'cookie-access');
    expect(cookieJar.value('refresh_token'), 'cookie-refresh');
    expect(adapter.snapshots.map((request) => request.authorization), [
      'User expired-access',
      null,
      'User cookie-access',
    ]);
  });

  test('refresh failure releases the shared refresh for a later attempt',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    var refreshCalls = 0;
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        refreshCalls++;
        return refreshCalls == 1
            ? _jsonResponse(401, {'error': 'refresh rejected'})
            : _jsonResponse(200, {'access_token': 'fresh-access'});
      }
      return _jsonResponse(
        _authorization(options) == 'User fresh-access' ? 200 : 401,
        {'id': 'fixture-user'},
      );
    });
    network.dio.httpClientAdapter = adapter;

    expect((await network.validateLogin()).success, isFalse);
    expect(network.logged, isFalse);
    expect(adapter.requests, hasLength(2));
    expect((await network.validateLogin()).success, isTrue);
    expect(refreshCalls, 2);
    expect(adapter.requests, hasLength(5));
  });

  test('an unauthorized retry does not refresh a second time', () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {'access_token': 'still-invalid'});
      }
      return _jsonResponse(401, {'error': 'unauthorized'});
    });
    network.dio.httpClientAdapter = adapter;

    final result = await network.validateLogin();

    expect(result.success, isFalse);
    expect(network.logged, isFalse);
    expect(adapter.snapshots.map((request) => request.path), [
      '/api/v2/user',
      '/api/v2/auth/refresh',
      '/api/v2/user',
    ]);
  });

  test('a late 401 reuses the completed refresh without rotating tokens again',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final favoriteStarted = Completer<void>();
    final releaseFavorite = Completer<ResponseBody>();
    var refreshCalls = 0;
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        refreshCalls++;
        return _jsonResponse(200, {
          'access_token': 'fresh-access',
          'refresh_token': 'fresh-refresh',
        });
      }
      if (options.uri.path.endsWith('/favorite') &&
          _authorization(options) == 'User expired-access') {
        favoriteStarted.complete();
        return releaseFavorite.future;
      }
      return _jsonResponse(
        _authorization(options) == 'User fresh-access' ? 200 : 401,
        {'id': 'fixture-user'},
      );
    });
    network.dio.httpClientAdapter = adapter;

    final favorite = network.favoriteComic('123', 'unused');
    await favoriteStarted.future;
    expect((await network.validateLogin()).success, isTrue);
    releaseFavorite.complete(_jsonResponse(401, {}));

    expect((await favorite).success, isTrue);
    expect(refreshCalls, 1);
    expect(
      adapter.snapshots
          .where((request) => request.path.endsWith('/favorite'))
          .map((request) => request.authorization),
      ['User expired-access', 'User fresh-access'],
    );
  });

  test('a late success after refresh cannot restore the old token cookie',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final favoriteStarted = Completer<void>();
    final releaseFavorite = Completer<ResponseBody>();
    final adapter = _Adapter((options) async {
      if (options.uri.path.endsWith('/favorite')) {
        favoriteStarted.complete();
        return releaseFavorite.future;
      }
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {'access_token': 'fresh-access'});
      }
      return _jsonResponse(
        _authorization(options) == 'User fresh-access' ? 200 : 401,
        {'id': 'fixture-user'},
      );
    });
    network.dio.httpClientAdapter = adapter;

    final favorite = network.favoriteComic('123', 'unused');
    await favoriteStarted.future;
    expect((await network.validateLogin()).success, isTrue);
    releaseFavorite.complete(_jsonResponse(200, {}, headers: {
      'set-cookie': ['access_token=expired-access; Path=/'],
    }));

    expect((await favorite).success, isTrue);
    expect(cookieJar.value('access_token'), 'fresh-access');
  });

  test('login validation accepts cookies rotated by its own response',
      () async {
    cookieJar.set('access_token', 'valid-access');
    final adapter = _Adapter((options) async => _jsonResponse(200, {
          'id': 'fixture-user'
        }, headers: {
          'set-cookie': ['access_token=rotated-access; Path=/'],
        }));
    network.dio.httpClientAdapter = adapter;

    expect((await network.validateLogin()).success, isTrue);
    expect(network.logged, isTrue);
    expect(cookieJar.value('access_token'), 'rotated-access');
  });

  test('a queued validation uses credentials refreshed before dispatch',
      () async {
    cookieJar.set('access_token', 'expired-access');
    cookieJar.set('refresh_token', 'old-refresh');
    final validationQueued = Completer<void>();
    final dispatchValidation = Completer<void>();
    network.dio.interceptors.insert(
      0,
      InterceptorsWrapper(onRequest: (options, handler) async {
        if (options.uri.path == '/api/v2/user') {
          validationQueued.complete();
          await dispatchValidation.future;
        }
        handler.next(options);
      }),
    );
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/api/v2/auth/refresh') {
        return _jsonResponse(200, {'access_token': 'fresh-access'});
      }
      return _jsonResponse(
        _authorization(options) == 'User fresh-access' ? 200 : 401,
        {'id': 'fixture-user'},
      );
    });
    network.dio.httpClientAdapter = adapter;

    final validation = network.validateLogin();
    await validationQueued.future;
    expect(await network.refreshAuthTokens(), isTrue);
    dispatchValidation.complete();

    expect((await validation).success, isTrue);
    expect(adapter.snapshots.map((request) => request.authorization),
        [null, 'User fresh-access']);
  });

  for (final fromCookie in [false, true]) {
    for (final replaceAccount in [false, true]) {
      test(
          'late refresh preserves ${replaceAccount ? 'new account' : 'logout'} '
          '(Set-Cookie: $fromCookie)', () async {
        cookieJar.set('access_token', 'expired-access');
        cookieJar.set('refresh_token', 'old-refresh');
        final refreshStarted = Completer<void>();
        final releaseRefresh = Completer<ResponseBody>();
        final adapter = _Adapter((options) async {
          if (options.uri.path == '/api/v2/auth/refresh') {
            refreshStarted.complete();
            return releaseRefresh.future;
          }
          return _jsonResponse(
            _authorization(options) == 'User expired-access' ? 401 : 200,
            {'id': 'fixture-user'},
          );
        });
        network.dio.httpClientAdapter = adapter;

        final resultFuture = network.validateLogin();
        await refreshStarted.future;
        if (replaceAccount) {
          cookieJar.set('access_token', 'other-access');
          cookieJar.set('refresh_token', 'other-refresh');
          network.logged = true;
          expect((await network.validateLogin()).success, isTrue);
        } else {
          network.logout();
        }
        releaseRefresh.complete(fromCookie
            ? _jsonResponse(200, {}, headers: {
                'set-cookie': [
                  'access_token=stale-access; Domain=.nhentai.net; Path=/',
                  'refresh_token=stale-refresh; Domain=.nhentai.net; Path=/',
                ],
              })
            : _jsonResponse(200, {
                'access_token': 'stale-access',
                'refresh_token': 'stale-refresh',
              }));
        final result = await resultFuture;

        expect(result.success, isFalse);
        expect(cookieJar.value('access_token'),
            replaceAccount ? 'other-access' : isNull);
        expect(cookieJar.value('refresh_token'),
            replaceAccount ? 'other-refresh' : isNull);
        expect(network.logged, replaceAccount);
        expect(adapter.snapshots.map((request) => request.path), [
          '/api/v2/user',
          '/api/v2/auth/refresh',
          if (replaceAccount) '/api/v2/user',
        ]);
      });
    }
  }

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

ResponseBody _jsonResponse(int statusCode, Object value,
        {Map<String, List<String>> headers = const {}}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );
