import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/contract.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';

/// A deliberately small transport seam for source fixtures.  It records the
/// logical request stage instead of opening a socket, so a failed assertion
/// identifies the source operation that changed.
class _FixtureTransport {
  _FixtureTransport(this.payloads);

  final Map<String, String> payloads;
  final List<String> requests = <String>[];

  String get(String stage) {
    requests.add('GET:$stage');
    return payloads[stage] ?? (throw StateError('missing fixture $stage'));
  }

  String post(String stage) {
    requests.add('POST:$stage');
    return payloads[stage] ?? (throw StateError('missing fixture $stage'));
  }
}

class _RemoteComic extends BaseComic {
  const _RemoteComic(this.id, this.title, this.cover,
      {this.subTitle = '', this.tags = const []});

  @override
  final String id;

  @override
  final String title;

  @override
  final String cover;

  @override
  final String subTitle;

  @override
  final List<String> tags;

  @override
  String get description => '';
}

class _RemoteFixture {
  const _RemoteFixture({
    required this.name,
    required this.key,
    required this.version,
    required this.id,
    required this.episode,
    required this.source,
    required this.transport,
  });

  final String name;
  final String key;
  final String version;
  final String id;
  final String episode;
  final ComicSource source;
  final _FixtureTransport transport;
}

ComicInfoData _detail({
  required String sourceKey,
  required String id,
  required String title,
  required String cover,
  required String chapterId,
  required String chapterTitle,
  required List<String> thumbnails,
}) {
  return ComicInfoData(
    title,
    'Fixture author',
    cover,
    'Fixture description',
    const <String, List<String>>{
      'author': <String>['Fixture author'],
      'tag': <String>['fixture'],
    },
    <String, String>{chapterTitle: chapterId},
    thumbnails,
    null,
    1,
    const <BaseComic>[],
    sourceKey,
    id,
  );
}

ComicSource _source({
  required String name,
  required String key,
  required String version,
  required String url,
  required _FixtureTransport transport,
  required String comicId,
  required String episode,
  required Future<Res<List<BaseComic>>> Function(String keyword, int page)
      search,
  required Future<Res<ComicInfoData>> Function(String id) detail,
  required Future<Res<List<String>>> Function(String id, String? ep) pages,
  Future<Res<Map<String, String>>> Function([String? id])? loadFolders,
  Future<Res<List<BaseComic>>> Function(int page, [String? folder])?
      loadFavorites,
  Future<Res<bool>> Function(String id, String folder, bool adding)? favorite,
  GetImageLoadingConfigFunc? imageLoading,
}) {
  return ComicSource.named(
    name: name,
    key: key,
    version: version,
    url: url,
    filePath: 'remote-fixture',
    explorePages: <ExplorePageData>[
      ExplorePageData.named(
        title: name,
        type: ExplorePageType.singlePageWithMultiPart,
        loadMultiPart: () async {
          // The source fixtures intentionally share the card payload between
          // the home and search routes, while keeping one parser/transport
          // implementation per source.
          final result = await search('fixture', 1);
          return Res(<ExplorePagePart>[
            ExplorePagePart(
                name, result.dataOrNull ?? const <BaseComic>[], null),
          ]);
        },
      ),
    ],
    searchPageData: SearchPageData.named(
      loadPage: (keyword, page, options) => search(keyword, page),
    ),
    loadComicInfo: detail,
    loadComicPages: pages,
    getImageLoadingConfig: imageLoading,
    favoriteData: loadFavorites == null
        ? null
        : FavoriteData(
            key: key,
            title: name,
            multiFolder: loadFolders != null,
            loadComic: loadFavorites,
            loadFolders: loadFolders,
            addOrDelFavorite: favorite,
          ),
  );
}

_RemoteFixture _copyMangaFixture() {
  final transport = _FixtureTransport(<String, String>{
    'search': jsonEncode(<String, dynamic>{
      'results': <String, dynamic>{
        'total': 1,
        'list': <Map<String, dynamic>>[
          <String, dynamic>{
            'path_word': 'copy-fixture',
            'name': 'Copy fixture',
            'cover': 'https://fixture.test/copy-cover.jpg',
            'author': <Map<String, String>>[
              <String, String>{'name': 'Fixture author'},
            ],
            'theme': <Map<String, String>>[
              <String, String>{'name': 'fixture'},
            ],
            'datetime_updated': '2026-01-01',
          },
        ],
      },
    }),
    'detail': jsonEncode(<String, dynamic>{
      'results': <String, dynamic>{
        'comic': <String, dynamic>{
          'uuid': 'copy-uuid',
          'name': 'Copy fixture',
          'cover': 'https://fixture.test/copy-cover.jpg',
          'brief': 'Fixture description',
          'datetime_updated': '2026-01-01',
          'author': <Map<String, String>>[
            <String, String>{'name': 'Fixture author'},
          ],
          'theme': <Map<String, String>>[
            <String, String>{'name': 'fixture'},
          ],
        },
      },
    }),
    'chapters': jsonEncode(<String, dynamic>{
      'results': <String, dynamic>{
        'total': 1,
        'list': <Map<String, String>>[
          <String, String>{'uuid': 'copy-episode', 'name': 'Chapter 1'},
        ],
      },
    }),
    'images': jsonEncode(<String, dynamic>{
      'results': <String, dynamic>{
        'chapter': <String, dynamic>{
          'contents': <Map<String, dynamic>>[
            <String, dynamic>{'url': 'https://fixture.test/copy-1.jpg'},
            <String, dynamic>{'url': 'https://fixture.test/copy-2.jpg'},
          ],
          'words': <int>[1, 0],
        },
      },
    }),
    'favorite': '{"code":0}',
  });

  Map<String, dynamic> comic(String key) =>
      (jsonDecode(transport.get(key)) as Map<String, dynamic>)['results']
          ['comic'] as Map<String, dynamic>;
  _RemoteComic parse(Map<String, dynamic> value) => _RemoteComic(
        value['path_word'] as String,
        value['name'] as String,
        value['cover'] as String,
        subTitle: (value['author'] as List).first['name'] as String,
        tags: (value['theme'] as List)
            .map((e) => (e as Map)['name'] as String)
            .toList(),
      );
  final source = _source(
    name: 'Copy fixture',
    key: 'copy_manga',
    version: '1.1.4',
    url:
        'https://raw.githubusercontent.com/liyw0205/pica_configs/master/copy_manga.js',
    transport: transport,
    comicId: 'copy-fixture',
    episode: 'copy-episode',
    search: (keyword, page) async {
      if (page > 1) return const Res(<BaseComic>[]);
      final data = jsonDecode(transport.get('search')) as Map<String, dynamic>;
      final list = ((data['results'] as Map)['list'] as List)
          .cast<Map<String, dynamic>>();
      return Res(list.map(parse).toList());
    },
    detail: (id) async {
      final value = comic('detail');
      final chapterData =
          jsonDecode(transport.get('chapters')) as Map<String, dynamic>;
      final chapter = ((chapterData['results'] as Map)['list'] as List).single
          as Map<String, dynamic>;
      return Res(_detail(
        sourceKey: 'copy_manga',
        id: id,
        title: value['name'] as String,
        cover: value['cover'] as String,
        chapterId: chapter['uuid'] as String,
        chapterTitle: chapter['name'] as String,
        thumbnails: <String>[value['cover'] as String],
      ));
    },
    pages: (id, ep) async {
      final value = jsonDecode(transport.get('images')) as Map<String, dynamic>;
      final chapter = ((value['results'] as Map)['chapter'] as Map);
      final urls = (chapter['contents'] as List)
          .map((e) => (e as Map)['url'] as String)
          .toList();
      final words = (chapter['words'] as List).cast<int>();
      final ordered = List<String>.filled(urls.length, '');
      for (var i = 0; i < urls.length; i++) {
        ordered[words[i]] = urls[i];
      }
      return Res(ordered);
    },
    loadFavorites: (page, [folder]) async {
      if (page > 1) return const Res(<BaseComic>[]);
      final data = jsonDecode(transport.get('search')) as Map<String, dynamic>;
      final list = ((data['results'] as Map)['list'] as List)
          .cast<Map<String, dynamic>>();
      return Res(list.map(parse).toList(), subData: 1);
    },
    favorite: (id, folder, adding) async {
      expect(jsonDecode(transport.post('favorite'))['code'], 0);
      return const Res(true);
    },
  );
  return _RemoteFixture(
    name: 'Copy fixture',
    key: 'copy_manga',
    version: '1.1.4',
    id: 'copy-fixture',
    episode: 'copy-episode',
    source: source,
    transport: transport,
  );
}

_RemoteFixture _baoziFixture() {
  final transport = _FixtureTransport(<String, String>{
    'search': '''
      <div class="comics-card"><a href="/comic/baozi-fixture"><amp-img src="https://fixture.test/baozi-cover.jpg"></amp-img></a>
      <h3>Baozi fixture</h3><div class="tabs"><span>fixture</span></div><small>updated</small></div>
    ''',
    'detail': '''
      <h1 class="comics-detail__title">Baozi fixture</h1>
      <div class="l-content"><div><amp-img src="https://fixture.test/baozi-cover.jpg"></amp-img></div></div>
      <h2 class="comics-detail__author">Fixture author</h2>
      <div class="tag-list"><span>fixture</span></div>
      <div class="supporting-text"><div><span><em>(2026-01-01)</em></span></div></div>
      <p class="comics-detail__desc">Fixture description</p>
      <div id="chapter-items"><div class="comics-chapters"><a><div><span>Chapter 1</span></div></a></div></div>
    ''',
    'images': '''
      <amp-img class="comic-contain__item" src="https://fixture.test/baozi-1.jpg"></amp-img>
      <amp-img class="comic-contain__item" data-src="https://fixture.test/baozi-2.jpg"></amp-img>
    ''',
    'favorite': '{"code":0}',
  });
  final source = _source(
    name: 'Baozi fixture',
    key: 'baozi',
    version: '1.0.1',
    url:
        'https://raw.githubusercontent.com/liyw0205/pica_configs/master/baozi.js',
    transport: transport,
    comicId: 'baozi-fixture',
    episode: '0',
    search: (keyword, page) async {
      if (page > 1) return const Res(<BaseComic>[]);
      final document = html.parse(transport.get('search'));
      final card = document.querySelector('div.comics-card')!;
      final anchor = card.querySelector('a')!;
      final image = anchor.querySelector('amp-img')!;
      return Res(<BaseComic>[
        _RemoteComic(
          anchor.attributes['href']!.split('/').last,
          card.querySelector('h3')!.text.trim(),
          image.attributes['src']!,
          tags: card
              .querySelectorAll('div.tabs > span')
              .map((e) => e.text.trim())
              .toList(),
        )
      ]);
    },
    detail: (id) async {
      final document = html.parse(transport.get('detail'));
      return Res(_detail(
        sourceKey: 'baozi',
        id: id,
        title: document.querySelector('h1.comics-detail__title')!.text.trim(),
        cover:
            document.querySelector('div.l-content amp-img')!.attributes['src']!,
        chapterId: '0',
        chapterTitle:
            document.querySelector('div#chapter-items span')!.text.trim(),
        thumbnails: <String>[
          document.querySelector('div.l-content amp-img')!.attributes['src']!
        ],
      ));
    },
    pages: (id, ep) async {
      final document = html.parse(transport.get('images'));
      return Res(document
          .querySelectorAll('amp-img.comic-contain__item')
          .map(
            (e) => e.attributes['src'] ?? e.attributes['data-src']!,
          )
          .toList());
    },
    loadFavorites: (page, [folder]) async {
      if (page > 1) return const Res(<BaseComic>[]);
      return const Res(<BaseComic>[
        _RemoteComic(
          'baozi-fixture',
          'Baozi fixture',
          'https://fixture.test/baozi-cover.jpg',
        )
      ], subData: 1);
    },
    favorite: (id, folder, adding) async {
      expect(jsonDecode(transport.post('favorite'))['code'], 0);
      return const Res(true);
    },
  );
  return _RemoteFixture(
    name: 'Baozi fixture',
    key: 'baozi',
    version: '1.0.1',
    id: 'baozi-fixture',
    episode: '0',
    source: source,
    transport: transport,
  );
}

Map<String, dynamic> _komiicComic() => <String, dynamic>{
      'id': 'komiic-fixture',
      'title': 'Komiic fixture',
      'imageUrl': 'https://fixture.test/komiic-cover.jpg',
      'authors': <Map<String, String>>[
        <String, String>{'name': 'Fixture author'},
      ],
      'categories': <Map<String, String>>[
        <String, String>{'name': 'fixture'},
      ],
      'dateUpdated': '2026-01-01T00:00:00Z',
    };

_RemoteFixture _komiicFixture() {
  final comic = _komiicComic();
  final transport = _FixtureTransport(<String, String>{
    'search': jsonEncode(<String, dynamic>{
      'data': <String, dynamic>{
        'searchComicsAndAuthors': <String, dynamic>{
          'comics': <dynamic>[comic]
        },
      },
    }),
    'recommend': '{"data":{"recommendComicById":[]}}',
    'detail': jsonEncode(<String, dynamic>{
      'data': <String, dynamic>{
        'comicByIds': <dynamic>[comic]
      }
    }),
    'chapters':
        '{"data":{"chaptersByComicId":[{"id":"komiic-episode","serial":"1","type":"chapter"}]}}',
    'images':
        '{"data":{"imagesByChapterId":[{"id":"image-1","kid":"kid-1","height":100,"width":100},{"id":"image-2","kid":"kid-2","height":100,"width":100}]}}',
    'image-ticket':
        '{"data":{"getImageTicket":{"url":"https://cdn.fixture.test/kid-1","ticket":"fixture-ticket","kid":"kid-1"}}}',
    'favorite': '{"data":{"addComicToFolder":true}}',
  });
  _RemoteComic parse(Map<String, dynamic> value) => _RemoteComic(
        value['id'] as String,
        value['title'] as String,
        value['imageUrl'] as String,
        subTitle: (value['authors'] as List).first['name'] as String,
        tags: (value['categories'] as List)
            .map((e) => (e as Map)['name'] as String)
            .toList(),
      );
  final source = _source(
    name: 'Komiic fixture',
    key: 'Komiic',
    version: '1.0.5',
    url:
        'https://raw.githubusercontent.com/liyw0205/pica_configs/master/komiic.js',
    transport: transport,
    comicId: 'komiic-fixture',
    episode: 'komiic-episode',
    search: (keyword, page) async {
      if (page > 1) return const Res(<BaseComic>[]);
      final data = jsonDecode(transport.get('search')) as Map<String, dynamic>;
      final comics = (((data['data'] as Map)['searchComicsAndAuthors']
              as Map)['comics'] as List)
          .cast<Map<String, dynamic>>();
      return Res(comics.map(parse).toList());
    },
    detail: (id) async {
      final value = (jsonDecode(transport.get('detail')) as Map)['data']
          ['comicByIds'][0] as Map<String, dynamic>;
      final chapters = (jsonDecode(transport.get('chapters')) as Map)['data']
          ['chaptersByComicId'] as List;
      final chapter = chapters.single as Map<String, dynamic>;
      return Res(_detail(
        sourceKey: 'Komiic',
        id: id,
        title: value['title'] as String,
        cover: value['imageUrl'] as String,
        chapterId: chapter['id'] as String,
        chapterTitle: chapter['serial'].toString(),
        thumbnails: <String>[value['imageUrl'] as String],
      ));
    },
    pages: (id, ep) async {
      final data = jsonDecode(transport.get('images')) as Map<String, dynamic>;
      final images = (data['data']['imagesByChapterId'] as List)
          .cast<Map<String, dynamic>>();
      return Res(images
          .map((e) => 'https://komiic.com/api/image/${e['kid']}')
          .toList());
    },
    loadFolders: ([id]) async =>
        const Res(<String, String>{'folder-1': 'Fixture'}),
    loadFavorites: (page, [folder]) async {
      if (page > 1) return const Res(<BaseComic>[]);
      return Res(<BaseComic>[parse(comic)], subData: 1);
    },
    favorite: (id, folder, adding) async {
      expect(jsonDecode(transport.post('favorite'))['data']['addComicToFolder'],
          true);
      return const Res(true);
    },
    imageLoading: (imageKey, comicId, epId) async {
      final data =
          jsonDecode(transport.get('image-ticket')) as Map<String, dynamic>;
      final ticket = data['data']['getImageTicket'] as Map<String, dynamic>;
      return <String, dynamic>{
        'url': ticket['url'],
        'headers': <String, String>{
          'X-Image-Ticket': ticket['ticket'] as String
        },
      };
    },
  );
  return _RemoteFixture(
    name: 'Komiic fixture',
    key: 'Komiic',
    version: '1.0.5',
    id: 'komiic-fixture',
    episode: 'komiic-episode',
    source: source,
    transport: transport,
  );
}

_RemoteFixture _ikmmhFixture() {
  final transport = _FixtureTransport(<String, String>{
    'search': '''
      <div class="classification"><a href="/book/ikmmh-fixture.html">IK fixture</a>
      <img data-src="https://fixture.test/ikmmh-cover.jpg"><p class="describe"><a>updated</a></p></div>
    ''',
    'detail': '''
      <h1 class="detail-title">IK fixture</h1><div class="banner-img"><img data-src="https://fixture.test/ikmmh-cover.jpg"></div>
      <p class="author">Fixture author</p><p class="ui-tag"><a>fixture</a></p>
      <div class="detail-desc">Fixture description</div><div class="detail-info"><div><span><b>2026-01-01</b></span></div></div>
      <ol class="chapter-list"><li data-chapter="ikmmh-episode"><a title="Chapter 1"></a></li></ol>
    ''',
    'images':
        '<img class="lazy" data-src="https://fixture.test/ikmmh-1.jpg"><img class="lazy" src="https://fixture.test/ikmmh-2.jpg">',
    'favorite': '{"code":0}',
  });
  final source = _source(
    name: 'IK fixture',
    key: 'ikmmh',
    version: '1.1.2',
    url:
        'https://raw.githubusercontent.com/liyw0205/pica_configs/master/ikmmh.js',
    transport: transport,
    comicId: 'https://fixture.test/book/ikmmh-fixture.html',
    episode: 'ikmmh-episode',
    search: (keyword, page) async {
      if (page > 1) return const Res(<BaseComic>[]);
      final document = html.parse(transport.get('search'));
      final element = document.querySelector('div.classification')!;
      final link = element.querySelector('a')!;
      final image = element.querySelector('img')!;
      return Res(<BaseComic>[
        _RemoteComic(
          'https://fixture.test${link.attributes['href']}',
          link.text.trim(),
          image.attributes['data-src']!,
          subTitle: element.querySelector('p.describe a')!.text.trim(),
        )
      ]);
    },
    detail: (id) async {
      final document = html.parse(transport.get('detail'));
      return Res(_detail(
        sourceKey: 'ikmmh',
        id: id,
        title: document.querySelector('h1.detail-title')!.text.trim(),
        cover: document
            .querySelector('div.banner-img img')!
            .attributes['data-src']!,
        chapterId: document
            .querySelector('ol.chapter-list li')!
            .attributes['data-chapter']!,
        chapterTitle:
            document.querySelector('ol.chapter-list a')!.attributes['title']!,
        thumbnails: <String>[
          document.querySelector('div.banner-img img')!.attributes['data-src']!
        ],
      ));
    },
    pages: (id, ep) async {
      final document = html.parse(transport.get('images'));
      return Res(document
          .querySelectorAll('img.lazy')
          .map(
            (e) => e.attributes['data-src'] ?? e.attributes['src']!,
          )
          .toList());
    },
    loadFavorites: (page, [folder]) async {
      if (page > 1) return const Res(<BaseComic>[]);
      return const Res(<BaseComic>[
        _RemoteComic(
          'https://fixture.test/book/ikmmh-fixture.html',
          'IK fixture',
          'https://fixture.test/ikmmh-cover.jpg',
        )
      ], subData: 1);
    },
    favorite: (id, folder, adding) async {
      expect(jsonDecode(transport.post('favorite'))['code'], 0);
      return const Res(true);
    },
  );
  return _RemoteFixture(
    name: 'IK fixture',
    key: 'ikmmh',
    version: '1.1.2',
    id: 'https://fixture.test/book/ikmmh-fixture.html',
    episode: 'ikmmh-episode',
    source: source,
    transport: transport,
  );
}

void main() {
  test('four remote source fixtures satisfy one shared offline contract',
      () async {
    final fixtures = <_RemoteFixture>[
      _copyMangaFixture(),
      _baoziFixture(),
      _komiicFixture(),
      _ikmmhFixture(),
    ];

    for (final fixture in fixtures) {
      expect(fixture.source.key, fixture.key);
      expect(fixture.source.version, fixture.version);
      expect(
          fixture.source.url,
          startsWith(
              'https://raw.githubusercontent.com/liyw0205/pica_configs/master/'));
      expect(ComicSourceContract.validateDefinition(fixture.source), isEmpty,
          reason: fixture.key);

      final report = await ComicSourceContract.verify(
        source: fixture.source,
        comicId: fixture.id,
        episode: fixture.episode,
        searchKeyword: 'fixture',
      );
      expect(report.isValid, isTrue,
          reason: '${fixture.key}: ${report.violations.join('\n')}');
      expect(report.pagesChecked, <int>[1, 2], reason: fixture.key);
      expect(report.emptyPages, <int>[2], reason: fixture.key);

      final home = await fixture.source.explorePages.single.loadMultiPart!();
      expect(home.success, isTrue, reason: '${fixture.key} home');
      expect(home.dataOrNull, hasLength(1), reason: '${fixture.key} home');
      expect(home.dataOrNull!.single.comics, isNotEmpty,
          reason: '${fixture.key} home cards');

      final favorite = fixture.source.favoriteData!;
      expect((await favorite.loadComic(1)).success, isTrue,
          reason: '${fixture.key} favorites');
      expect((await favorite.addOrDelFavorite!(fixture.id, '', true)).success,
          isTrue,
          reason: '${fixture.key} add favorite');
      expect((await favorite.addOrDelFavorite!(fixture.id, '', false)).success,
          isTrue,
          reason: '${fixture.key} remove favorite');
      expect(fixture.transport.requests, contains('GET:search'),
          reason: fixture.key);
      expect(fixture.transport.requests, contains('GET:detail'),
          reason: fixture.key);
      expect(fixture.transport.requests, contains('GET:images'),
          reason: fixture.key);
      expect(fixture.transport.requests, contains('POST:favorite'),
          reason: fixture.key);
    }
  });

  test('Komiic fixture keeps image ticket separate from page URLs', () async {
    final fixture = _komiicFixture();
    final config = await fixture.source.getImageLoadingConfig!(
        'https://komiic.com/api/image/kid-1', fixture.id, fixture.episode);
    expect(config['url'], 'https://cdn.fixture.test/kid-1');
    expect((config['headers'] as Map)['X-Image-Ticket'], 'fixture-ticket');
    expect(fixture.transport.requests, contains('GET:image-ticket'));
  });
}
