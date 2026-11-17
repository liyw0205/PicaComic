import 'dart:convert';
import 'dart:collection';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/contract.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/source_network_policy.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/custom_download_model.dart';

class _LastRandom implements math.Random {
  final List<int> bounds = [];

  @override
  int nextInt(int max) {
    bounds.add(max);
    return max - 1;
  }

  @override
  bool nextBool() => throw UnsupportedError('nextBool');

  @override
  double nextDouble() => throw UnsupportedError('nextDouble');
}

class _SinglePassTags extends Iterable<String> {
  _SinglePassTags(this.tags);

  final List<String> tags;
  int reads = 0;

  @override
  Iterator<String> get iterator {
    if (++reads > 1) throw StateError('Tags were read more than once');
    return tags.iterator;
  }
}

class _FixtureComic extends BaseComic {
  const _FixtureComic(this.id, this.title, this.cover);

  @override
  final String id;

  @override
  final String title;

  @override
  final String cover;

  @override
  String get subTitle => '';

  @override
  List<String> get tags => const [];

  @override
  String get description => 'fixture';
}

// These payloads contain only synthetic values. Keep all source error cases
// on the same redacted JSON shape so contract tests never depend on live data.
const _fixtureErrorJson = <String, String>{
  'rate-limited':
      '{"code":"RATE_LIMITED","message":"fixture rate","token":"<redacted>"}',
  'authentication':
      '{"code":"FORBIDDEN","message":"fixture auth","password":"<redacted>"}',
  'timeout': '{"code":"REQUEST_TIMEOUT","message":"fixture timeout"}',
  'cancelled': '{"code":"REQUEST_CANCELLED","message":"fixture cancelled"}',
  'parse': '{"code":"INVALID_JSON","message":"fixture parse"}',
};

Future<Res<ComicInfoData>> _fixtureDetail(String id) async => Res(
      ComicInfoData(
        'Fixture one',
        null,
        'https://fixture.test/cover-1.jpg',
        'fixture details',
        const {
          'tag': ['fixture']
        },
        const {'chapter 1': 'ep-1'},
        const ['https://fixture.test/thumb-1.jpg'],
        null,
        1,
        const [],
        'fixture_source',
        id,
      ),
    );

ComicSource _fixtureSource({
  bool duplicatePage = false,
  Future<Res<ComicInfoData>> Function(String id)? loadComicInfo,
}) {
  return ComicSource.named(
    name: 'Offline fixture',
    key: 'fixture_source',
    filePath: 'test-fixture',
    searchPageData: SearchPageData.named(
      loadPage: (keyword, page, options) async {
        expect(keyword, 'fixture');
        expect(options, const ['all']);
        if (page == 1) {
          return const Res([
            _FixtureComic(
                'comic-1', 'Fixture one', 'https://fixture.test/cover-1.jpg'),
          ], subData: 3);
        }
        if (page == 2) {
          if (duplicatePage) {
            return const Res([
              _FixtureComic(
                  'comic-1', 'Fixture one', 'https://fixture.test/cover-1.jpg'),
            ], subData: 3);
          }
          return const Res([], subData: 3);
        }
        return const Res([], subData: 3);
      },
    ),
    loadComicInfo: loadComicInfo ?? _fixtureDetail,
    loadComicPages: (id, ep) async => const Res([
      'https://fixture.test/image-1.jpg',
      'https://fixture.test/image-2.jpg',
    ]),
  );
}

void main() {
  test('random categories bound the sample and include the final legal start',
      () {
    final tags = List.generate(4, (index) => 'tag$index');
    for (final count in [1, 3]) {
      final fixedRandom = _LastRandom();
      final runtimeRandom = _LastRandom();
      final fixed = RandomCategoryPart('tags', tags, count, 'search',
          random: fixedRandom);
      final runtime = RandomCategoryPartWithRuntimeData(
          'tags', () => tags, count, 'search',
          random: runtimeRandom);
      final expected = tags.sublist(tags.length - count);
      expect(fixed.categories, expected);
      expect(runtime.categories, expected);
      expect(fixedRandom.bounds, [tags.length - count + 1]);
      expect(runtimeRandom.bounds, fixedRandom.bounds);
      expect(runtime.categoryParams, isNull);
    }
  });

  test('random categories handle empty, non-positive, and oversized samples',
      () {
    for (final tags in [
      <String>[],
      ['one', 'two']
    ]) {
      for (final count in [-1, 0, tags.length, tags.length + 1]) {
        final random = _LastRandom();
        final fixed =
            RandomCategoryPart('tags', tags, count, 'search', random: random);
        final runtime = RandomCategoryPartWithRuntimeData(
            'tags', () => tags, count, 'search',
            random: random);
        final expected = count <= 0 ? <String>[] : tags;
        expect(fixed.categories, expected);
        expect(runtime.categories, expected);
        expect(random.bounds, isEmpty);
      }
    }
  });

  test('runtime categories read each iterable only once per refresh', () {
    final samples = <_SinglePassTags>[];
    final part = RandomCategoryPartWithRuntimeData('tags', () {
      final tags = _SinglePassTags(['one', 'two', 'three']);
      samples.add(tags);
      return tags;
    }, 2, 'category', random: _LastRandom(), buildParam: (tag) => '/tag/$tag');
    expect(part.categories, ['two', 'three']);
    expect(part.categoryParams, ['/tag/two', '/tag/three']);
    expect(part.categoryParams, ['/tag/two', '/tag/three']);
    expect(samples, hasLength(1));
    expect(part.categories, ['two', 'three']);
    expect(samples, hasLength(2));
    expect(samples.map((sample) => sample.reads), [1, 1]);
  });

  test('runtime parameters keep their label snapshot until the next refresh',
      () {
    var tags = ['one', 'two'];
    var loads = 0;
    final part = RandomCategoryPartWithRuntimeData('tags', () {
      loads++;
      return tags;
    }, 2, 'category', buildParam: (tag) => '/tag/$tag');
    final labels = part.categories;
    tags = ['three', 'four'];
    labels.clear();
    final params = part.categoryParams!;
    expect(params, ['/tag/one', '/tag/two']);
    params.clear();
    expect(part.categoryParams, ['/tag/one', '/tag/two']);
    expect(loads, 1);
    expect(part.categories, ['three', 'four']);
    expect(part.categoryParams, ['/tag/three', '/tag/four']);
    expect(loads, 2);
  });

  test('an empty runtime snapshot does not reload while building parameters',
      () {
    var loads = 0;
    final part = RandomCategoryPartWithRuntimeData('tags', () {
      loads++;
      return [];
    }, 50, 'category', buildParam: (tag) => '/tag/$tag');
    expect(part.categoryParams, isEmpty);
    expect(part.categoryParams, isEmpty);
    expect(loads, 1);
    expect(part.categories, isEmpty);
    expect(part.categoryParams, isEmpty);
    expect(loads, 2);
  });

  test('full random samples do not expose the source list to display edits',
      () {
    final tags = ['one', 'two'];
    final part = RandomCategoryPart('tags', tags, 50, 'search');
    part.categories.clear();
    expect(tags, ['one', 'two']);
    expect(part.categories, tags);
  });

  test('Hitomi and Htmanga parsers accept current source URL variants', () {
    final gallery = HiNetwork.decodeGalleryJson('''
      var galleryinfo = {"title":"fixture","type":"manga",
        "language":"chinese","galleryurl":"/galleries/42.html",
        "tags":[{"tag":"female:fixture","female":"1","url":"/tag/fixture.html"}],
        "artists":null};
    ''');
    final brief = HiNetwork.briefFromGalleryJson('42', gallery);
    expect(brief.title, 'fixture');
    expect(brief.link, 'https://hitomi.la/galleries/42.html');
    expect(brief.tags, ['female:fixture ♀']);
    expect(brief.tagList.single.link, 'https://hitomi.la/tag/fixture.html');
    expect(brief.subTitle, 'N/A');
    expect(
      HitomiFile('01.webp', 'hash', false, true, 1, 1, '42').preferredExtension,
      'avif',
    );

    expect(
      HtmangaNetwork.resolveUrl('//img.fixture.test/cover.jpg',
          base: 'https://www.wnacg.com'),
      'https://img.fixture.test/cover.jpg',
    );
    expect(
      HtmangaNetwork.resolveUrl('https://img.fixture.test/cover.jpg',
          base: 'https://www.wnacg.com'),
      'https://img.fixture.test/cover.jpg',
    );
    expect(
      HtmangaNetwork.detailUrls('405320', base: 'https://www.wnacg.com/'),
      [
        'https://www.wnacg.com/photos-index-page-1-aid-405320.html',
        'https://www.wnacg.com/photos-index-aid-405320.html',
      ],
    );
    // A 200 response is not sufficient: a WNACG error page can still use
    // the successful transport status and must allow the URL fallback.
    expect(
      HtmangaNetwork.isDetailPage(
          '<div class="userwrap"><h2>fixture detail</h2></div>'),
      isTrue,
    );
    expect(HtmangaNetwork.isDetailPage('<div>fixture error</div>'), isFalse);
    for (final info in [
      '2026-01-01, 12頁',
      '12页，2026-01-01',
      '2026-01-01, 12',
      '章節：6 話，2026-09-25',
    ]) {
      expect(HtmangaNetwork.parsePages(info), info.contains('6 話') ? 6 : 12);
      expect(HtmangaNetwork.parseTime(info),
          info.contains('6 話') ? '2026-09-25' : '2026-01-01');
    }

    const seriesHtml = '''
      <div id="sr_pub">
        <a class="tagshow" data-chid="218635"
          href="/photos-slide-aid-218635-sid-405320.html"
          title="第1話 29P">第1話 第一章</a>
        <a class="tagshow" data-chid="268347"
          href="/photos-slide-aid-268347-sid-405320.html">第2話 第二章</a>
      </div>
    ''';
    expect(HtmangaNetwork.parseChapterLinks(seriesHtml), {
      '218635': '第1話 第一章',
      '268347': '第2話 第二章',
    });
    expect(
        HtmangaNetwork.parseChapterLinks('<div>single gallery</div>'), isNull);

    final series = HtComicInfo(
      '405320',
      'https://fixture.test/cover.jpg',
      'fixture series',
      '合集',
      2,
      const {},
      '',
      'uploader',
      '',
      1,
      const [],
      chapters: const {'218635': '第1话 第一章', '268347': '第2话 第二章'},
    );
    final restored = HtComicInfo.fromJson(series.toJson());
    expect(restored.chapters, series.chapters);

    final downloaded = DownloadedHtComic(restored, 12.5);
    expect(downloaded.eps, ['第1话 第一章', '第2话 第二章']);
    expect(downloaded.downloadedEps, [0, 1]);
    downloaded.downloadedEps.remove(0);
    final partial = DownloadedHtComic.fromJson(downloaded.toJson());
    expect(partial.downloadedEps, [1]);
    final downloading =
        DownloadingHtComic(series, null, null, null, 'Ht405320');
    expect(downloading.haveEps, isTrue);

    const singleEpisode = ComicInfoData(
      'single episode',
      null,
      'https://fixture.test/cover.jpg',
      null,
      <String, List<String>>{},
      null,
      null,
      null,
      1,
      null,
      'fixture_source',
      'single-episode',
    );
    final restoredSingleEpisode =
        ComicInfoData.fromJson(jsonDecode(jsonEncode(singleEpisode.toJson())));
    expect(restoredSingleEpisode.chapters, isNull);
    final legacyDownloaded = CustomDownloadedItem.fromJson({
      'comicSize': null,
      'downloadedEps': <int>[0],
      'chapters': null,
      'id': 'Other-single-episode',
      'name': 'single episode',
      'subTitle': '',
      'tags': <String>[],
      'sourceKey': 'fixture_source',
      'sourceName': 'Fixture source',
      'cover': 'https://fixture.test/cover.jpg',
      'comicId': 'single-episode',
    });
    expect(legacyDownloaded.chapters, isNull);

    expect(
      HtmangaNetwork.parseImageList(
        r'''document.writeln("var imglist = [{ url: fast_img_host+\"//img.example/data/01.jpg?verify=token&sig=abc\", caption: \"[01]\"}];");''',
      ),
      ['https://img.example/data/01.jpg?verify=token&sig=abc'],
    );
    expect(
      HtmangaNetwork.parseImageList(
        'var imglist = [{url: "//img.example/data/[02].jpg"}];',
      ),
      ['https://img.example/data/[02].jpg'],
    );
    expect(
      HtmangaNetwork.parseImageList('//img.example/data/03.jpg'),
      ['https://img.example/data/03.jpg'],
    );
    expect(
      HtmangaNetwork.firstNonEmptyText(['', '  \n ', '简介：样本内容']),
      '简介：样本内容',
    );
    expect(HtmangaNetwork.firstNonEmptyText(const []), '');
  });

  test('built-in source definitions are valid without opening the network', () {
    final keys = <String>{};
    expect(ComicSource.builtIn.map((source) => source.key).toSet(),
        containsAll(builtInSources));
    for (final source in ComicSource.builtIn) {
      expect(keys.add(source.key), isTrue,
          reason: 'duplicate built-in source key ${source.key}');
      expect(ComicSourceContract.validateDefinition(source), isEmpty,
          reason: source.key);
    }
  });

  test('offline contract accepts a terminal empty page and validates details',
      () async {
    final source = _fixtureSource(
      loadComicInfo: (id) async {
        switch (id) {
          case 'cancelled':
            return Res.error(_fixtureErrorJson['cancelled']!);
          case 'rate-limited':
            return Res.error(_fixtureErrorJson['rate-limited']!);
          case 'authentication':
            return Res.error(_fixtureErrorJson['authentication']!);
          case 'timeout':
            return Res.error(_fixtureErrorJson['timeout']!);
          case 'parse':
            return Res.error(_fixtureErrorJson['parse']!);
          case 'wrapped-parse':
            throw DioException(
              requestOptions: RequestOptions(path: 'https://fixture.test'),
              error: const FormatException('fixture JSON'),
            );
          default:
            return _fixtureDetail(id);
        }
      },
    );
    final report = await ComicSourceContract.verify(
      source: source,
      searchOptions: const ['all'],
      errorCases: [
        ComicSourceContractErrorCase(
          name: 'cancelled',
          operation: () => source.loadComicInfo!('cancelled'),
          expectedKind: SourceNetworkErrorKind.cancelled,
        ),
        ComicSourceContractErrorCase(
          name: 'rate-limited',
          operation: () => source.loadComicInfo!('rate-limited'),
          expectedKind: SourceNetworkErrorKind.rateLimited,
        ),
        ComicSourceContractErrorCase(
          name: 'authentication',
          operation: () => source.loadComicInfo!('authentication'),
          expectedKind: SourceNetworkErrorKind.authentication,
        ),
        ComicSourceContractErrorCase(
          name: 'timeout',
          operation: () => source.loadComicInfo!('timeout'),
          expectedKind: SourceNetworkErrorKind.timeout,
        ),
        ComicSourceContractErrorCase(
          name: 'parse',
          operation: () => source.loadComicInfo!('parse'),
          expectedKind: SourceNetworkErrorKind.parse,
        ),
        ComicSourceContractErrorCase(
          name: 'wrapped-parse',
          operation: () => source.loadComicInfo!('wrapped-parse'),
          expectedKind: SourceNetworkErrorKind.parse,
        ),
      ],
    );

    expect(report.isValid, isTrue,
        reason: report.violations.map((e) => e.toString()).join('\n'));
    expect(report.pagesChecked, [1, 2]);
    expect(report.emptyPages, [2]);
  });

  test('definition rejects metadata that page UIs cannot consume', () {
    final source = ComicSource.named(
      name: 'Invalid fixture',
      key: 'invalid_fixture',
      filePath: 'test-fixture',
      searchPageData: SearchPageData.named(
        searchOptions: [
          SearchOptions.named(
            options: LinkedHashMap<String, String>(),
            label: 'sort',
          ),
        ],
        loadPage: (keyword, page, options) async => const Res([]),
      ),
      categoryData: const CategoryData(
        title: 'Invalid fixture',
        key: 'invalid_fixture',
        categories: [],
        enableRankingPage: true,
      ),
      categoryComicsData: CategoryComicsData.named(
        options: [
          CategoryComicsOptions.named(
            options: LinkedHashMap<String, String>(),
          ),
        ],
        load: (category, param, options, page) async => const Res([]),
      ),
    );

    final codes = ComicSourceContract.validateDefinition(source)
        .map((violation) => violation.code)
        .toSet();
    expect(
        codes,
        containsAll(<String>[
          'empty-search-options',
          'empty-category-options',
          'missing-ranking-loader',
        ]));
    expect(codes, isNot(contains('missing-search-loader')));
  });

  test('definition reports every required ranking and favorite boundary', () {
    final rankingWithoutData = ComicSource.named(
      name: 'Missing category fixture',
      key: 'missing_category_fixture',
      filePath: 'test-fixture',
      categoryData: const CategoryData(
        title: 'Missing category fixture',
        key: 'missing_category_fixture',
        categories: [],
        enableRankingPage: true,
      ),
    );
    final emptyRanking = ComicSource.named(
      name: 'Empty ranking fixture',
      key: 'empty_ranking_fixture',
      filePath: 'test-fixture',
      categoryData: const CategoryData(
        title: 'Empty ranking fixture',
        key: 'empty_ranking_fixture',
        categories: [],
        enableRankingPage: true,
      ),
      categoryComicsData: CategoryComicsData.named(
        load: (category, param, options, page) async => const Res([]),
        rankingData: RankingData.named(
          options: const {},
          load: (option, page) async => const Res([]),
        ),
      ),
    );
    final mismatchedFavorite = ComicSource.named(
      name: 'Mismatched favorite fixture',
      key: 'favorite_fixture',
      filePath: 'test-fixture',
      favoriteData: FavoriteData(
        key: 'other_fixture',
        title: 'Other fixture',
        multiFolder: false,
        loadComic: (page, [folder]) async => const Res([]),
      ),
    );

    expect(
        ComicSourceContract.validateDefinition(rankingWithoutData)
            .map((violation) => violation.code),
        contains('missing-category-comics'));
    expect(
        ComicSourceContract.validateDefinition(emptyRanking)
            .map((violation) => violation.code),
        contains('empty-ranking-options'));
    expect(
        ComicSourceContract.validateDefinition(mismatchedFavorite)
            .map((violation) => violation.code),
        contains('favorite-key-mismatch'));
  });

  test('offline contract reports duplicate pages and invalid image data',
      () async {
    final source = ComicSource.named(
      name: 'Broken fixture',
      key: 'broken_fixture',
      filePath: 'test-fixture',
      searchPageData: SearchPageData.named(
        loadPage: (keyword, page, options) async {
          return const Res([
            _FixtureComic('same', 'same', 'https://fixture.test/cover.jpg'),
          ]);
        },
      ),
      loadComicInfo: (id) async => Res(
        ComicInfoData(
          'Broken',
          null,
          'https://fixture.test/cover.jpg',
          null,
          const {},
          null,
          const ['bad thumbnail\n'],
          null,
          1,
          null,
          'broken_fixture',
          id,
        ),
      ),
      loadComicPages: (id, ep) async => const Res(['not a url\n']),
    );

    final report = await ComicSourceContract.verify(
      source: source,
      maxPages: 2,
    );
    final codes = report.violations.map((violation) => violation.code).toSet();
    expect(codes, contains('duplicate-comic'));
    expect(codes, contains('thumbnail-url-invalid'));
    expect(codes, contains('image-url-invalid'));
  });

  test('oversized custom source is rejected before evaluation', () async {
    final source = 'x' * (ComicSourceParser.maxSourceBytes + 1);
    await expectLater(
      ComicSourceParser().parse(source, 'oversized.js'),
      throwsA(isA<ComicSourceParseException>()),
    );
  });

  test('custom source size gate uses normalized UTF-8 bytes', () {
    final withinLimit = 'x\r\n' * (ComicSourceParser.maxSourceBytes ~/ 2);
    expect(() => ComicSourceParser.validateSourceSize(withinLimit),
        returnsNormally);

    final oversizedAfterNormalization =
        'x' * (ComicSourceParser.maxSourceBytes + 1);
    expect(
      () => ComicSourceParser.validateSourceSize(oversizedAfterNormalization),
      throwsA(isA<ComicSourceParseException>()),
    );
  });
}
