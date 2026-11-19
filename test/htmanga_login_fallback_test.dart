import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/tools/translations.dart';

class _WwwForbiddenAdapter implements HttpClientAdapter {
  _WwwForbiddenAdapter({this.statusCode = 403, this.fallbackStatus = 200});

  final int statusCode;
  final int fallbackStatus;
  final List<Uri> requests = [];
  final List<String?> requestBodies = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.uri);
    if (requestStream == null) {
      requestBodies.add(null);
    } else {
      final bytes = await requestStream.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      requestBodies.add(utf8.decode(bytes.takeBytes()));
    }

    final status =
        options.uri.host == 'wnacg.com' ? fallbackStatus : statusCode;
    if (status != 200) {
      return ResponseBody.fromString(
        'blocked',
        status,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    }
    return ResponseBody.fromString(
      '{"html":"fixture success"}',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FixtureCachedNetwork extends CachedNetwork {
  _FixtureCachedNetwork(this.adapter, {this.landingUrl});

  final HttpClientAdapter adapter;
  final String? landingUrl;

  @override
  Future<CachedNetworkRes<String>> get(String url, BaseOptions options,
      {CacheExpiredTime expiredTime = CacheExpiredTime.short,
      CookieJarSql? cookieJar,
      bool log = true,
      bool http2 = false,
      CancelToken? cancelToken}) async {
    options.responseType = ResponseType.bytes;
    final dio = Dio(options)..httpClientAdapter = adapter;
    if (cookieJar != null) dio.interceptors.add(CookieManagerSql(cookieJar));
    try {
      final response = await dio.get<Uint8List>(url, cancelToken: cancelToken);
      return CachedNetworkRes(
        utf8.decode(response.data!, allowMalformed: true),
        response.statusCode,
        landingUrl ?? response.realUri.toString(),
        response.headers.map,
      );
    } finally {
      dio.close(force: true);
    }
  }
}

void main() {
  AppTranslation.translations = const {};
  late Directory tempDir;
  late SingleInstanceCookieJar? previousCookieJar;
  late SingleInstanceCookieJar? testCookieJar;

  setUp(() async {
    previousCookieJar = SingleInstanceCookieJar.instance;
    testCookieJar = null;
    if (previousCookieJar == null) {
      tempDir = await Directory.systemTemp.createTemp('pica-htmanga-login-');
      testCookieJar = SingleInstanceCookieJar('${tempDir.path}/cookies.sqlite');
    }
  });

  tearDown(() async {
    if (testCookieJar != null) {
      testCookieJar!.dispose();
      SingleInstanceCookieJar.instance = previousCookieJar;
      await tempDir.delete(recursive: true);
    }
  });

  HtmangaNetwork fixtureNetwork(_WwwForbiddenAdapter adapter,
      {String? landingUrl}) {
    return HtmangaNetwork.forTesting(
      dioFactory: (options) {
        final dio = Dio(options)..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        return dio;
      },
      cachedNetworkFactory: () =>
          _FixtureCachedNetwork(adapter, landingUrl: landingUrl),
    );
  }

  test('GET retries a www 403 against the apex host', () async {
    final adapter = _WwwForbiddenAdapter();
    final network = fixtureNetwork(adapter);

    final result = await network.get(
      'https://www.wnacg.com/photos-index-aid-123.html?key=fixture',
      cache: false,
    );

    expect(result.success, isTrue);
    expect(result.data, '{"html":"fixture success"}');
    expect(adapter.requests.map((uri) => uri.host), [
      'www.wnacg.com',
      'wnacg.com',
    ]);
    expect(adapter.requests.last.queryParameters['key'], 'fixture');
  });

  test('login POST retries a www 403 and preserves the form body', () async {
    final adapter = _WwwForbiddenAdapter();
    final network = fixtureNetwork(adapter);

    final result = await network.post(
      'https://www.wnacg.com/users-check_login.html?next=home',
      'login_name=fixture&login_pass=dummy',
    );

    expect(result.success, isTrue);
    expect(result.data, '{"html":"fixture success"}');
    expect(adapter.requests.map((uri) => uri.host), [
      'www.wnacg.com',
      'wnacg.com',
    ]);
    expect(adapter.requests.last.queryParameters['next'], 'home');
    expect(adapter.requestBodies, [
      'login_name=fixture&login_pass=dummy',
      'login_name=fixture&login_pass=dummy',
    ]);
  });

  test('ordinary POST is not replayed after a www 403', () async {
    final adapter = _WwwForbiddenAdapter();
    final network = fixtureNetwork(adapter);

    final result = await network.post(
      'https://www.wnacg.com/users-check_favorite.html',
      'comic_id=123',
    );

    expect(result.error, isTrue);
    expect(adapter.requests, hasLength(1));
  });

  for (final method in ['GET', 'POST']) {
    for (final url in [
      'https://www.wnacg.com.fixture.test/users-check_login.html',
      'https://fixture.test/users-check_login.html?next=www.wnacg.com',
    ]) {
      test('$method does not replace a host from $url', () async {
        final adapter = _WwwForbiddenAdapter();
        final network = fixtureNetwork(adapter);

        final result = method == 'GET'
            ? await network.get(url, cache: false)
            : await network.post(url, 'login_name=fixture');

        expect(result.error, isTrue);
        expect(adapter.requests.map((uri) => uri.toString()), [url]);
      });
    }

    for (final status in [401, 500]) {
      test('$method does not retry status $status', () async {
        final adapter = _WwwForbiddenAdapter(statusCode: status);
        final network = fixtureNetwork(adapter);
        const url = 'https://www.wnacg.com/users-check_login.html';

        final result = method == 'GET'
            ? await network.get(url, cache: false)
            : await network.post(url, 'login_name=fixture');

        expect(result.error, isTrue);
        expect(adapter.requests, hasLength(1));
      });
    }

    test('$method stops when the fallback also returns 403', () async {
      final adapter = _WwwForbiddenAdapter(fallbackStatus: 403);
      final network = fixtureNetwork(adapter);
      const url = 'https://www.wnacg.com/users-check_login.html';

      final result = method == 'GET'
          ? await network.get(url, cache: false)
          : await network.post(url, 'login_name=fixture');

      expect(result.error, isTrue);
      expect(adapter.requests.map((uri) => uri.host), [
        'www.wnacg.com',
        'wnacg.com',
      ]);
    });
  }

  test('GET fallback to a login page reports an expired session', () async {
    final adapter = _WwwForbiddenAdapter();
    final network = fixtureNetwork(adapter,
        landingUrl: 'https://wnacg.com/users-login.html');

    final result = await network.get(
      'https://www.wnacg.com/users-favorite.html',
      cache: false,
    );

    expect(result.error, isTrue);
    expect(result.errorMessage, '未登录或登录到期');
    expect(adapter.requests, hasLength(2));
  });
}
