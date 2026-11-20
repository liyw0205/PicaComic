import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/contract.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/js_engine.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/source_network_policy.dart';

class _RuleFixture {
  const _RuleFixture({
    required this.file,
    required this.key,
    required this.version,
    required this.comicId,
    required this.episode,
    required this.requiredRequests,
  });

  final String file;
  final String key;
  final String version;
  final String comicId;
  final String episode;
  final List<String> requiredRequests;
}

const _rules = <_RuleFixture>[
  _RuleFixture(
    file: 'copy_manga.js',
    key: 'copy_manga',
    version: '1.1.4',
    comicId: 'fixture-comic',
    episode: 'fixture-episode',
    requiredRequests: <String>[
      'GET api.copymanga.tv/api/v3/search/comic',
      'GET api.copymanga.tv/api/v3/comic2/fixture-comic',
      'GET api.copymanga.tv/api/v3/comic/fixture-comic/chapter2/fixture-episode',
      'GET api.copymanga.tv/api/v3/h5/homeIndex',
      'GET api.copymanga.tv/api/v3/member/collect/comics',
    ],
  ),
  _RuleFixture(
    file: 'baozi.js',
    key: 'baozi',
    version: '1.0.1',
    comicId: 'fixture-comic',
    episode: '0',
    requiredRequests: <String>[
      'GET www.twmanga.com/search',
      'GET www.twmanga.com/comic/fixture-comic',
      'GET www.twmanga.com/comic/chapter/fixture-comic/0_0.html',
      'GET www.twmanga.com',
      'GET www.twmanga.com/user/my_bookshelf',
    ],
  ),
  _RuleFixture(
    file: 'komiic.js',
    key: 'Komiic',
    version: '1.0.5',
    comicId: 'fixture-comic',
    episode: 'fixture-episode',
    requiredRequests: <String>[
      'POST komiic.com/api/query#searchComicAndAuthorQuery',
      'POST komiic.com/api/query#recentUpdate',
      'POST komiic.com/api/query#chapterByComicId',
      'POST komiic.com/api/query#imagesByChapterId',
      'POST komiic.com/api/query#folderComicIds',
      'POST komiic.com/api/query#getImageTicket',
    ],
  ),
  _RuleFixture(
    file: 'ikmmh.js',
    key: 'ikmmh',
    version: '1.1.3',
    comicId: 'https://ymcdnyfqdapp.ikmmh.com/book/fixture-comic/',
    episode: 'fixture-episode',
    requiredRequests: <String>[
      'GET ymcdnyfqdapp.ikmmh.com/search',
      'GET ymcdnyfqdapp.ikmmh.com/book/fixture-comic/',
      'GET ymcdnyfqdapp.ikmmh.com/chapter/fixture-comic/fixture-episode.html',
      'GET ymcdnyfqdapp.ikmmh.com/',
      'POST ymcdnyfqdapp.ikmmh.com/api/user/bookcase/ajax',
      'POST ymcdnyfqdapp.ikmmh.com/api/user/bookcase/add',
      'POST ymcdnyfqdapp.ikmmh.com/api/user/bookcase/del',
    ],
  ),
];

class _FixtureAdapter implements HttpClientAdapter {
  final requests = <String>[];
  final unmatched = <String>[];

  void reset() {
    requests.clear();
    unmatched.clear();
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final operation = _operation(options.data);
    final label = '${options.method} ${options.uri.host}${options.uri.path}'
        '${operation == null ? '' : '#$operation'}';
    requests.add(label);

    final body = switch (options.uri.host) {
      'api.copymanga.tv' => _copyManga(options),
      'www.twmanga.com' => _baozi(options),
      'komiic.com' => _komiic(operation),
      'ymcdnyfqdapp.ikmmh.com' => _ikmmh(options),
      _ => null,
    };
    if (body == null) {
      unmatched.add(label);
      throw StateError('Unexpected fixture request: $label');
    }

    return ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        'content-type': [
          body.startsWith('<') ? 'text/html' : 'application/json'
        ],
      },
    );
  }

  String? _operation(Object? data) {
    try {
      final decoded = data is String ? jsonDecode(data) : data;
      if (decoded is Map) return decoded['operationName'] as String?;
    } catch (_) {
      return null;
    }
    return null;
  }

  String _json(Object value) => jsonEncode(value);

  Map<String, dynamic> _copyComic() => <String, dynamic>{
        'path_word': 'fixture-comic',
        'uuid': 'fixture-uuid',
        'name': 'Fixture comic',
        'cover': 'https://fixture.test/copy-cover.jpg',
        'brief': 'Fixture description',
        'author': <Map<String, String>>[
          <String, String>{'name': 'Fixture author'},
        ],
        'theme': <Map<String, String>>[
          <String, String>{'name': 'fixture'},
        ],
        'datetime_updated': '2026-01-01',
      };

  String? _copyManga(RequestOptions options) {
    final path = options.uri.path;
    if (path.endsWith('/search/comic')) {
      return _json({
        'results': {
          'total': 1,
          'list': [_copyComic()]
        },
      });
    }
    if (path.endsWith('/h5/homeIndex')) {
      final comic = _copyComic();
      return _json({
        'results': {
          'recComics': {
            'list': [comic]
          },
          'hotComics': [comic],
          'newComics': [comic],
          'finishComics': {
            'list': [comic]
          },
          'rankDayComics': {
            'list': [comic]
          },
          'rankWeekComics': {
            'list': [comic]
          },
          'rankMonthComics': {
            'list': [comic]
          },
        },
      });
    }
    if (path.endsWith('/member/collect/comics')) {
      return _json({
        'results': {
          'total': 1,
          'list': [_copyComic()]
        },
      });
    }
    if (path.endsWith('/member/collect/comic')) return _json({'results': {}});
    if (path.endsWith('/comic2/fixture-comic/query')) {
      return _json({
        'results': {'collect': null},
      });
    }
    if (path.endsWith('/comic2/fixture-comic')) {
      return _json({
        'results': {'comic': _copyComic()},
      });
    }
    if (path.endsWith('/group/default/chapters')) {
      return _json({
        'results': {
          'total': 1,
          'list': [
            {'uuid': 'fixture-episode', 'name': 'Chapter 1'},
          ],
        },
      });
    }
    if (path.endsWith('/chapter2/fixture-episode')) {
      return _json({
        'results': {
          'chapter': {
            'contents': [
              {'url': 'https://fixture.test/copy-1.jpg'},
              {'url': 'https://fixture.test/copy-2.jpg'},
            ],
            'words': [1, 0],
          },
        },
      });
    }
    return null;
  }

  String _baoziCard() => '''
<div class="comics-card">
  <a href="/comic/fixture-comic"><amp-img src="https://fixture.test/baozi-cover.jpg"></amp-img></a>
  <h3>Fixture comic</h3>
  <div class="tabs"><span>fixture</span></div>
  <small>Updated</small>
</div>
''';

  String _baoziDetail() => '''
<h1 class="comics-detail__title">Fixture comic</h1>
<div class="l-content"><div><div><amp-img src="https://fixture.test/baozi-cover.jpg"></amp-img></div></div></div>
<h2 class="comics-detail__author">Fixture author</h2>
<div class="tag-list"><span>fixture</span></div>
<div class="supporting-text"><div><span><em>(2026-01-01)</em></span></div></div>
<p class="comics-detail__desc">Fixture description</p>
<div id="chapter-items"><div class="comics-chapters"><a><div><span>Chapter 1</span></div></a></div></div>
''';

  String _baoziFavorite() => '''
<div class="bookshelf-items">
  <h4><a href="/comic/fixture-comic">Fixture comic</a></h4>
  <amp-img src="https://fixture.test/baozi-cover.jpg"></amp-img>
  <div class="info"><ul>
    <li>Type</li><li>Author：Fixture author</li><li>State</li><li>Update</li>
    <li><a>Chapter 1</a></li>
  </ul></div>
</div>
''';

  String? _baozi(RequestOptions options) {
    final path = options.uri.path;
    if (path == '/search') return _baoziCard();
    if (path.isEmpty || path == '/') {
      return '<div class="index-recommend-items">'
          '<div class="catalog-title">Featured</div>${_baoziCard()}</div>';
    }
    if (path == '/comic/fixture-comic') return _baoziDetail();
    if (path == '/comic/chapter/fixture-comic/0_0.html') {
      return '<amp-img class="comic-contain__item" src="https://fixture.test/baozi-1.jpg"></amp-img>';
    }
    if (path == '/user/my_bookshelf') return _baoziFavorite();
    if (path == '/user/operation_v2') return _json({'ok': true});
    return null;
  }

  Map<String, dynamic> _komiicComic() => <String, dynamic>{
        'id': 'fixture-comic',
        'title': 'Fixture comic',
        'status': 'ONGOING',
        'year': 2026,
        'imageUrl': 'https://fixture.test/komiic-cover.jpg',
        'authors': [
          {'id': 'fixture-author', 'name': 'Fixture author'},
        ],
        'categories': [
          {'id': 'fixture-category', 'name': 'fixture'},
        ],
        'dateUpdated': '2026-01-01T00:00:00Z',
        'monthViews': 1,
        'views': 1,
        'favoriteCount': 1,
        'lastBookUpdate': '2026-01-01',
        'lastChapterUpdate': '2026-01-01',
      };

  String? _komiic(String? operation) {
    final comic = _komiicComic();
    final data = switch (operation) {
      'searchComicAndAuthorQuery' => {
          'searchComicsAndAuthors': {
            'comics': [comic],
            'authors': <Object>[],
          },
        },
      'recentUpdate' => {
          'recentUpdate': [comic],
        },
      'recommendComicById' => {
          'recommendComicById': <Object>[],
        },
      'chapterByComicId' => {
          'chaptersByComicId': [
            {
              'id': 'fixture-episode',
              'serial': '1',
              'type': 'chapter',
              'dateCreated': '2026-01-01',
              'dateUpdated': '2026-01-01',
              'size': 2,
            },
          ],
        },
      'comicByIds' => {
          'comicByIds': [comic],
        },
      'imagesByChapterId' => {
          'imagesByChapterId': [
            {
              'id': 'fixture-image',
              'kid': 'fixture-kid',
              'height': 1,
              'width': 1
            },
          ],
        },
      'myFolder' => {
          'folders': [
            {
              'id': 'fixture-folder',
              'key': 'fixture-folder',
              'name': 'Fixture folder'
            },
          ],
        },
      'folderComicIds' => {
          'folderComicIds': {
            'comicIds': ['fixture-comic']
          },
        },
      'getImageTicket' => {
          'getImageTicket': {
            'url': 'https://fixture.test/komiic-image.jpg',
            'ticket': 'fixture-ticket',
            'kid': 'fixture-kid',
            'width': 1,
            'height': 1,
            'expiresAt': '2026-01-01T00:00:00Z',
          },
        },
      'comicInAccountFolders' => {
          'comicInAccountFolders': <String>['fixture-folder'],
        },
      'addComicToFolder' => {'addComicToFolder': true},
      'removeComicToFolder' => {'removeComicToFolder': true},
      _ => null,
    };
    return data == null ? null : _json({'data': data});
  }

  String _ikmmhHomeCard() => '''
<li>
  <a href="/book/fixture-comic/"><h4>Fixture comic</h4><img data-src="https://fixture.test/ikmmh-cover.jpg"></a>
  <div class="tag-wrap"><p>fixture</p></div>
</li>
''';

  String _ikmmhSearchCard() => '''
<div class="classification">
  <a href="/book/fixture-comic/">Fixture comic<img data-src="https://fixture.test/ikmmh-cover.jpg"></a>
  <p class="describe"><a>Updated</a></p>
</div>
''';

  String _ikmmhDetail() => '''
<h1 class="detail-title">Fixture comic</h1>
<div class="banner-img"><img data-src="https://fixture.test/ikmmh-cover.jpg"></div>
<p class="author">Fixture author</p>
<p class="ui-tag"><a>fixture</a></p>
<div class="detail-desc">Fixture description</div>
<div class="detail-info"><div><span><b>2026-01-01</b></span></div></div>
<ol class="chapter-list"><li data-chapter="fixture-episode"><a title="Chapter 1"></a></li></ol>
''';

  String? _ikmmh(RequestOptions options) {
    final path = options.uri.path;
    if (path == '/') {
      return '<ul class="panel-comic-r">${_ikmmhHomeCard()}</ul>';
    }
    if (path.startsWith('/search')) return _ikmmhSearchCard();
    if (path == '/book/fixture-comic/') return _ikmmhDetail();
    if (path == '/chapter/fixture-comic/fixture-episode.html') {
      return '<img class="lazy" data-src="https://fixture.test/ikmmh-1.jpg">';
    }
    if (path == '/api/user/bookcase/ajax') {
      return _json({
        'code': 0,
        'end': 1,
        'data': [
          {
            'name': 'Fixture comic',
            'author': 'Fixture author',
            'cover': 'https://fixture.test/ikmmh-cover.jpg',
            'info_url': '/book/fixture-comic/',
          },
        ],
      });
    }
    if (path == '/api/user/bookcase/add' || path == '/api/user/bookcase/del') {
      return _json({'code': 0});
    }
    return null;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Dio dio;
  late _FixtureAdapter adapter;
  late SingleInstanceCookieJar cookieJar;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-remote-rules-');
    App.dataPath = '${root.path}/data';
    await Directory('${App.dataPath}/comic_source').create(recursive: true);
    cookieJar = SingleInstanceCookieJar('${App.dataPath}/cookies.db');
    adapter = _FixtureAdapter();
    dio = Dio(BaseOptions(
      responseType: ResponseType.plain,
      validateStatus: (status) => true,
    ))
      ..httpClientAdapter = adapter;
    await JsEngine().init(throwOnError: true, dio: dio);
  });

  tearDownAll(() async {
    ComicSource.sources.clear();
    JsEngine().runCode('ComicSource.sources = {};');
    JsEngine().dispose();
    dio.close(force: true);
    cookieJar.dispose();
    SingleInstanceCookieJar.instance = null;
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('custom source search flags are parsed and default to disabled',
      () async {
    ComicSource.sources.clear();
    JsEngine().runCode('ComicSource.sources = {};');
    const configuredScript = '''
class SearchFlagsFixture extends ComicSource {
  name = "Search Flags Fixture"
  key = "search_flags_fixture"
  version = "1.0.0"
  comic = {}
  search = {
    enableLanguageFilter: true,
    enableTagsSuggestions: true,
    optionList: [],
    load: async () => ({ comics: [], maxPage: 1 })
  }
}
''';
    final configured = await ComicSourceParser()
        .parse(configuredScript, 'fixture/search-flags.js');
    expect(configured.searchPageData?.enableLanguageFilter, isTrue);
    expect(configured.searchPageData?.enableTagsSuggestions, isTrue);

    ComicSource.sources.clear();
    JsEngine().runCode('ComicSource.sources = {};');
    const defaultScript = '''
class SearchDefaultsFixture extends ComicSource {
  name = "Search Defaults Fixture"
  key = "search_defaults_fixture"
  version = "1.0.0"
  comic = {}
  search = {
    optionList: [],
    load: async () => ({ comics: [], maxPage: 1 })
  }
}
''';
    final defaults = await ComicSourceParser()
        .parse(defaultScript, 'fixture/search-defaults.js');
    expect(defaults.searchPageData?.enableLanguageFilter, isFalse);
    expect(defaults.searchPageData?.enableTagsSuggestions, isFalse);
  });

  test('custom source detail parses and persists page counts', () async {
    ComicSource.sources.clear();
    JsEngine().runCode('ComicSource.sources = {};');
    const script = '''
class ComicPageCountFixture extends ComicSource {
  name = "Comic Page Count Fixture"
  key = "comic_page_count_fixture"
  version = "1.0.0"
  comic = {
    loadInfo: async (id) => ({
      title: "Fixture",
      cover: "https://fixture.test/cover.jpg",
      tags: {},
      pages: id === "string" ? "15" : id === "fallback" ? 0 : id === "invalid" ? "bad" : 14,
      maxPage: id === "fallback" ? "16" : id === "invalid" ? 0 : 20
    })
  }
}
''';
    final source =
        await ComicSourceParser().parse(script, 'fixture/comic-page-count.js');
    ComicSource.sources.add(source);

    for (final fixture in {
      'number': 14,
      'string': 15,
      'fallback': 16,
    }.entries) {
      final result = await source.loadComicInfo!(fixture.key);
      expect(result.error, isFalse, reason: result.errorMessage);
      expect(result.data.pages, fixture.value);
      expect(ComicInfoData.fromJson(result.data.toJson()).pages, fixture.value);
    }
    final invalid = await source.loadComicInfo!('invalid');
    expect(invalid.error, isFalse, reason: invalid.errorMessage);
    expect(invalid.data.pages, isNull);
  });

  test('pinned remote rules satisfy the offline source contract', () async {
    for (final fixture in _rules) {
      ComicSource.sources.clear();
      JsEngine().runCode('ComicSource.sources = {};');
      adapter.reset();

      final script = await File(
        'test/fixtures/remote_sources/${fixture.file}',
      ).readAsString();
      final source = await ComicSourceParser().parse(
        script,
        'fixture/${fixture.file}',
      );
      expect(source.key, fixture.key, reason: fixture.file);
      expect(source.version, fixture.version, reason: fixture.file);
      expect(
        source.url,
        'https://raw.githubusercontent.com/liyw0205/pica_configs/master/${fixture.file}',
        reason: fixture.file,
      );
      ComicSource.sources.add(source);
      SourceNetworkPolicy.instance.configure(
        source.key,
        const SourceNetworkConfig(
          minInterval: Duration.zero,
          maxRetries: 0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final report = await ComicSourceContract.verify(
        source: source,
        comicId: fixture.comicId,
        episode: fixture.episode,
        searchKeyword: 'fixture',
        maxPages: 1,
      );
      expect(report.isValid, isTrue,
          reason: '${fixture.key}: ${report.violations.join('\n')}');
      expect(report.pagesChecked, <int>[1], reason: fixture.key);

      final explore = source.explorePages.single;
      if (explore.loadMultiPart != null) {
        final home = await explore.loadMultiPart!();
        expect(
          home.success,
          isTrue,
          reason: '${fixture.key} home: ${home.errorMessage}',
        );
        expect(
          home.dataOrNull!.expand((part) => part.comics),
          isNotEmpty,
          reason: '${fixture.key} home cards',
        );
      } else {
        final home = await explore.loadPage!(1);
        expect(
          home.success,
          isTrue,
          reason: '${fixture.key} home: ${home.errorMessage}',
        );
        expect(home.dataOrNull, isNotEmpty,
            reason: '${fixture.key} home cards');
      }

      source.data['account'] = <String>['fixture-user', 'fixture-password'];
      source.data['token'] = 'fixture-token';
      final favorites = source.favoriteData!;
      String? folder;
      if (favorites.loadFolders != null) {
        final folders = await favorites.loadFolders!();
        expect(folders.success, isTrue, reason: '${fixture.key} folders');
        expect(folders.dataOrNull, isNotEmpty,
            reason: '${fixture.key} folders');
        folder = folders.dataOrNull!.keys.first;
      }
      final saved = await favorites.loadComic(1, folder);
      expect(
        saved.success,
        isTrue,
        reason: '${fixture.key} favorites: ${saved.errorMessage}',
      );
      expect(saved.dataOrNull, isNotEmpty, reason: '${fixture.key} favorites');
      expect(
        (await favorites.addOrDelFavorite!(fixture.comicId, folder ?? '', true))
            .success,
        isTrue,
        reason: '${fixture.key} add favorite',
      );
      expect(
        (await favorites.addOrDelFavorite!(
                fixture.comicId, folder ?? '', false))
            .success,
        isTrue,
        reason: '${fixture.key} remove favorite',
      );

      if (source.key == 'Komiic') {
        final imageConfig = await source.getImageLoadingConfig!(
          'https://komiic.com/api/image/fixture-kid',
          fixture.comicId,
          fixture.episode,
        );
        expect(imageConfig['url'], 'https://fixture.test/komiic-image.jpg');
        expect((imageConfig['headers'] as Map)['X-Image-Ticket'],
            'fixture-ticket');
      }

      expect(adapter.unmatched, isEmpty, reason: fixture.key);
      for (final requiredRequest in fixture.requiredRequests) {
        expect(adapter.requests, contains(requiredRequest),
            reason: fixture.key);
      }
    }
  });
}
