import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/page_parser.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedCookieJar implements SingleInstanceCookieJar {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GalleryAdapter implements HttpClientAdapter {
  _GalleryAdapter(this.gallery,
      {this.totalPages,
      this.pageCounts,
      this.emptyAfterPage,
      this.htmlFallback = false});

  final Map<String, dynamic> gallery;
  final int? totalPages;
  final Map<int, int?>? pageCounts;
  final int? emptyAfterPage;
  final bool htmlFallback;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (htmlFallback) {
      final isApi = options.uri.path.contains('/api/');
      return ResponseBody.fromString(
        isApi ? '{"unexpected":true}' : '<html><body></body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: [
            isApi ? Headers.jsonContentType : 'text/html; charset=utf-8'
          ],
        },
      );
    }
    final requestedPage = int.tryParse(options.uri.queryParameters['page'] ??
            options.queryParameters['page']?.toString() ??
            '') ??
        1;
    final pageCount = pageCounts?.containsKey(requestedPage) == true
        ? pageCounts![requestedPage]
        : totalPages;
    return ResponseBody.fromString(
      jsonEncode({
        'result': emptyAfterPage != null && requestedPage >= emptyAfterPage!
            ? []
            : [gallery],
        if (pageCount != null) 'num_pages': pageCount,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _HtmlSearchFallbackAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.uri.path == '/api/v2/search') {
      return ResponseBody.fromString(
        '{"error":"fixture API unavailable"}',
        503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final page = int.parse(options.uri.queryParameters['page'] ?? '1');
    final embedded = jsonEncode({
      'body': jsonEncode({
        'result': [
          {
            'id': 100 + page,
            'tag_ids': [29963, 20905],
          },
        ],
      }),
    });
    return ResponseBody.fromString(
      '<script data-sveltekit-fetched>$embedded</script>'
      '<div class="gallery">'
      '<a href="/g/${100 + page}/"><img src="thumb.jpg"></a>'
      '<div class="caption">Page $page</div>'
      '</div>'
      '<section class="pagination"><a class="last" '
      'href="/search/?q=artist%3A123&amp;page=12&amp;sort=popular">Last</a>'
      '</section>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _HtmlDetailFallbackAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.uri.path.startsWith('/api/v2/')) {
      return ResponseBody.fromString(
        '{"error":"fixture API unavailable"}',
        503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final embedded = jsonEncode({
      'body': jsonEncode({'is_favorited': true}),
    });
    return ResponseBody.fromString(
      '<script data-sveltekit-fetched '
      'data-url="https://nhentai.net/api/v2/galleries/42">$embedded</script>'
      '<div id="cover"><a><img src="cover.jpg"></a></div>'
      '<h1 class="title"><span>Fixture gallery</span></h1>'
      '<button id="favorite" aria-pressed="false">'
      '<span class="text">Favorite</span></button>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _EmptyGalleryImageAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.uri.path.startsWith('/api/v2/')) {
      return ResponseBody.fromString(
        '{"error":"fixture API unavailable"}',
        503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final embedded = jsonEncode({
      'body': jsonEncode({'media_id': 42, 'pages': const []}),
    });
    return ResponseBody.fromString(
      '<script>$embedded</script>'
      '<div id="image-container"><a><img '
      'src="https://i.nhentai.net/galleries/42/1.jpg"></a></div>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RedirectAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    switch (options.uri.path) {
      case '/favorites/':
        return ResponseBody.fromString('', 308, headers: {
          'location': ['/user/favorites?page=1'],
        });
      case '/user/favorites' when options.uri.queryParameters['ready'] != '1':
        return ResponseBody.fromString('', 301, headers: {
          'Location': ['https://nhentai.net/user/favorites?page=1&ready=1'],
        });
      case '/loop':
        return ResponseBody.fromString('', 308, headers: {
          'Location': ['/loop'],
        });
      default:
        return ResponseBody.fromString('<html>ready</html>', 200, headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        });
    }
  }

  @override
  void close({bool force = false}) {}
}

class _FavoritesPathAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.uri.path == '/api/v2/favorites') {
      return ResponseBody.fromString('{}', 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      });
    }
    return ResponseBody.fromString('<html><body></body></html>', 200, headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'stacked category queries retain sort, pagination and default exclusions',
      () async {
    SharedPreferences.setMockInitialValues({});
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final savedSources = ComicSource.sources;
    final savedHistory = List<String>.from(appdata.searchHistory);
    final adapter = _GalleryAdapter({
      'id': 123,
      'english_title': 'Test gallery',
      'thumbnail': 'galleries/456/thumb.jpg',
      'tag_ids': [29963],
    }, totalPages: 7);
    final dio = Dio()..httpClientAdapter = adapter;
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    ComicSource.sources = [
      ComicSource.named(name: 'nhentai', key: 'nhentai', filePath: 'test')
        ..data['multiTagDefaultExcludes'] = '-tag:"yaoi"',
    ];
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '1';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      appdata.searchHistory
        ..clear()
        ..addAll(savedHistory);
      ComicSource.sources = savedSources;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final param = nhentaiStackParam(const [
      NhentaiTagTerm('tag', 'glasses'),
      NhentaiTagTerm('language', 'translated'),
    ]);
    final result = await nhentai.categoryComicsData!
        .load('glasses', param, ['&sort=popular-month'], 3);
    expect(result.success, isTrue);
    expect(result.subData, 7);
    final request = adapter.requests.single.uri;
    expect(request.path, '/api/v2/search');
    expect(request.queryParameters['page'], '3');
    expect(request.queryParameters['sort'], 'popular-month');
    expect(request.queryParameters['query'],
        'tag:"glasses" language:translated language:chinese -tag:"yaoi"');

    await nhentai.categoryComicsData!.load('yaoi', '/tag/yaoi', [''], 1);
    expect(adapter.requests.last.uri.queryParameters['query'],
        'tag:"yaoi" language:chinese');
  });

  test('HTML category fallback preserves query, sort and page count', () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedSources = ComicSource.sources;
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final adapter = _HtmlSearchFallbackAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    ComicSource.sources = [
      ComicSource.named(name: 'nhentai', key: 'nhentai', filePath: 'test'),
    ];
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '0';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      ComicSource.sources = savedSources;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getCategoryComics(
        '/tag/full-color', 2, NhentaiSort.popularAll);
    expect(result.success, isTrue);
    expect(result.data.single.id, '102');
    expect(result.data.single.lang, '中文');
    expect(result.data.single.tags, contains('full color'));
    expect(result.subData, 12);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests[0].uri.path, '/api/v2/search');
    expect(adapter.requests[0].uri.queryParameters, {
      'query': 'tag:"full color"',
      'page': '2',
      'sort': 'popular',
    });
    expect(adapter.requests[1].uri.path, '/search/');
    expect(adapter.requests[1].uri.queryParameters, {
      'q': 'tag:"full color"',
      'page': '2',
      'sort': 'popular',
    });

    final numeric = await network.getCategoryComics(
        '/tag/artist-123', 2, NhentaiSort.popularAll);
    expect(numeric.success, isTrue);
    expect(numeric.subData, 12,
        reason: 'query digits must not be mistaken for the last page');
    expect(adapter.requests.last.uri.path, '/search/');
    expect(adapter.requests.last.uri.queryParameters['q'], 'tag:"artist 123"');
  });

  test('embedded HTML gallery metadata restores tags without data-tags', () {
    final document = html.parse(
      '<script data-sveltekit-fetched>${jsonEncode({
            'body': jsonEncode({
              'result': [
                {
                  'id': 42,
                  'tag_ids': [29963, 20905, '8378']
                },
              ],
            }),
          })}</script>'
      '<div class="gallery">'
      '<a href="/g/42/"><img src="thumb.jpg"></a>'
      '<div class="caption">Fixture</div>'
      '</div>',
    );
    final metadata = nhentaiTagIdsFromFetchedData(document);
    final comic = NhentaiNetwork()
        .parseComic(document.querySelector('.gallery')!, metadata);

    expect(metadata, {
      '42': {'29963', '20905', '8378'},
    });
    expect(comic.lang, '中文');
    expect(comic.tags, containsAll(['full color', 'glasses']));
  });

  test('malformed embedded blocks do not erase legacy gallery tags', () {
    final document = html.parse(
      '<script data-sveltekit-fetched>not-json</script>'
      '<script data-sveltekit-fetched>${jsonEncode({
            'body': jsonEncode({
              'result': [
                {
                  'id': '42',
                  'tag_ids': [29963, '8378', null, {}, 1.5],
                },
                {'id': 43, 'tag_ids': null},
              ],
            }),
          })}</script>'
      '<div class="gallery" data-tags="20905 8378 999999999">'
      '<a href="/g/42/"><img src="thumb.jpg"></a>'
      '<div class="caption">Fixture</div>'
      '</div>',
    );
    final comic = NhentaiNetwork().parseComic(
      document.querySelector('.gallery')!,
      nhentaiTagIdsFromFetchedData(document),
    );

    expect(comic.lang, '中文');
    expect(comic.tags.where((tag) => tag == 'glasses'), hasLength(1));
    expect(comic.tags.where((tag) => tag == 'full color'), hasLength(1));
  });

  test('HTML detail favorite state uses embedded data and explicit controls',
      () {
    final embedded = html.parse('''
      <script data-sveltekit-fetched
          data-url="https://nhentai.net/api/v2/galleries/42">
        ${jsonEncode({
          'body': jsonEncode({'is_favorited': true}),
        })}
      </script>
      <button id="favorite" aria-pressed="false"><span class="text">Favorite</span></button>
    ''');
    expect(nhentaiFavoriteState(embedded, '42'), isTrue);

    final pressed = html.parse(
      '<button id="favorite" aria-pressed="true">Favorite</button>',
    );
    expect(nhentaiFavoriteState(pressed, '42'), isTrue);

    final unpressed = html.parse(
      '<button id="favorite" aria-pressed="false">Unfavorite</button>',
    );
    expect(nhentaiFavoriteState(unpressed, '42'), isFalse);

    final missing = html.parse('<main>gallery</main>');
    expect(nhentaiFavoriteState(missing, '42'), isFalse);
  });

  test('HTML requests follow 301/308 redirects with a loop bound', () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final adapter = _RedirectAdapter();
    final dio = Dio(BaseOptions(
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400))
      ..httpClientAdapter = adapter;
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[91] = '0';
    proxyHttpOverrides = null;
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close(force: true);
    });

    final result = await network.get('https://nhentai.net/favorites/?page=1');
    expect(result.success, isTrue);
    expect(result.data, '<html>ready</html>');
    expect(adapter.requests.map((request) => request.uri.toString()), [
      'https://nhentai.net/favorites/?page=1',
      'https://nhentai.net/user/favorites?page=1',
      'https://nhentai.net/user/favorites?page=1&ready=1',
    ]);

    adapter.requests.clear();
    final loop = await network.get('https://nhentai.net/loop');
    expect(loop.success, isTrue);
    expect(adapter.requests, hasLength(6));
  });

  test('favorites HTML fallback uses the migrated user path', () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    final temp = await Directory.systemTemp.createTemp('pica-nh-favorites-');
    final cookieJarPath = '${temp.path}/cookies.db';
    SingleInstanceCookieJar.instance = null;
    final testCookieJar = SingleInstanceCookieJar(cookieJarPath);
    testCookieJar.saveFromResponse(Uri.parse('https://nhentai.net'), [
      Cookie('access_token', 'fixture-token')
        ..domain = '.nhentai.net'
        ..path = '/',
    ]);

    final network = NhentaiNetwork();
    final savedNetworkCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final adapter = _FavoritesPathAdapter();
    final dio = Dio(BaseOptions(
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400))
      ..httpClientAdapter = adapter;
    network.cookieJar = testCookieJar;
    network.dio = dio;
    network.logged = true;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[91] = '0';
    proxyHttpOverrides = null;
    addTearDown(() async {
      network.cookieJar = savedNetworkCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close(force: true);
      testCookieJar.dispose();
      SingleInstanceCookieJar.instance = previousCookieJar;
      await temp.delete(recursive: true);
    });

    final result = await network.getFavorites(1);
    expect(result.success, isTrue, reason: result.errorMessage);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/api/v2/favorites',
      '/user/favorites',
    ]);
    expect(adapter.requests.last.uri.queryParameters['page'], '1');
  });

  test('HTML detail fallback exposes embedded favorite state', () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedLogged = network.logged;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final adapter = _HtmlDetailFallbackAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    network.logged = true;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    proxyHttpOverrides = null;
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      network.logged = savedLogged;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getComicInfo('42');
    expect(result.success, isTrue, reason: result.errorMessage);
    expect(result.data.favorite, isTrue);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/api/v2/galleries/42',
      '/g/42/',
    ]);
  });

  test('HTML image fallback rejects an empty gallery', () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final adapter = _EmptyGalleryImageAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    proxyHttpOverrides = null;
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getImages('42');
    expect(result.error, isTrue);
    expect(result.errorMessage, contains('图片列表为空'));
    expect(adapter.requests.map((request) => request.uri.path), [
      '/api/v2/galleries/42',
      '/g/42/1/',
    ]);
  });

  test('API gallery page count is separate from listing pagination', () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final dio = Dio()
      ..httpClientAdapter = _GalleryAdapter({
        'id': 123,
        'english_title': 'Test gallery',
        'thumbnail': 'galleries/456/thumb.jpg',
        'tag_ids': [29963],
        'num_pages': 106,
      }, totalPages: 1);
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '1';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getHomePage(1);

    expect(result.success, isTrue);
    expect(result.data.latest.single.pages, 106);
    expect(result.data.latest.single.lang, isNot('Unknown'));
  });

  test('missing listing metadata stays unknown and empty next page ends',
      () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final dio = Dio()
      ..httpClientAdapter = _GalleryAdapter({
        'id': 123,
        'english_title': 'Test gallery',
        'thumbnail': 'galleries/456/thumb.jpg',
        'tag_ids': [29963],
      }, emptyAfterPage: 2);
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '1';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getHomePage(1);
    expect(result.data.totalPages, isNull);

    final nextPage = await network.loadMoreHomePageData(result.data);
    expect(nextPage.data, isFalse);
    expect(result.data.page, 1);
    expect(result.data.totalPages, 1);
    expect(result.data.latest, hasLength(1));
  });

  test('known API page count survives a later response without metadata',
      () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final dio = Dio()
      ..httpClientAdapter = _GalleryAdapter({
        'id': 124,
        'english_title': 'Test gallery',
        'thumbnail': 'galleries/457/thumb.jpg',
        'tag_ids': [29963],
      }, pageCounts: {
        1: 3
      });
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '1';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getHomePage(1);
    expect(result.data.totalPages, 3);
    final nextPage = await network.loadMoreHomePageData(result.data);
    expect(nextPage.data, isTrue);
    expect(result.data.page, 2);
    expect(result.data.totalPages, 3);
  });

  test('empty HTML fallback page is excluded from the total page count',
      () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final dio = Dio()
      ..httpClientAdapter = _GalleryAdapter({}, htmlFallback: true);
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '1';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getHomePage(2);
    expect(result.success, isTrue);
    expect(result.data.latest, isEmpty);
    expect(result.data.totalPages, 1);

    final mixed = await nhentai.explorePages.single.loadMixed!(2);
    expect(mixed.success, isTrue);
    expect(mixed.data, isEmpty);
    expect(mixed.subData, 1);
  });

  test('HTML page count remains optional', () {
    NhentaiComicBrief parse(String attributes) {
      final document = html.parse('''
        <div class="gallery" $attributes>
          <a href="/g/123/"><img src="thumb.jpg"></a>
          <div class="caption">Test gallery</div>
        </div>
      ''');
      return NhentaiNetwork().parseComic(document.querySelector('.gallery')!);
    }

    expect(parse('data-pages="106"').pages, 106);
    expect(parse('').pages, isNull);
    expect(parse('data-pages="invalid"').pages, isNull);
  });

  testWidgets('page count uses the slot above language', (tester) async {
    late ComicTile tile;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        tile = nhentai.comicTileBuilderOverride!(
          context,
          const NhentaiComicBrief(
              'Test gallery', '', '123', 'English', [], 106),
          null,
        ) as ComicTile;
        return Column(children: [
          tile.buildSubDescription(context)!,
          Text(tile.description),
        ]);
      }),
    ));

    expect(find.text('106P'), findsOneWidget);
    expect(tester.getBottomLeft(find.text('106P')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('English')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing and invalid page counts are hidden', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        for (final pages in [null, 0, -1]) {
          final tile = nhentai.comicTileBuilderOverride!(
            context,
            NhentaiComicBrief(
                'Test gallery', '', '123', 'English', const [], pages),
            null,
          ) as ComicTile;
          expect(tile.buildSubDescription(context), isNull);
          expect(tile.description, 'English');
        }
        return const SizedBox();
      }),
    ));
    expect(tester.takeException(), isNull);
  });
}
