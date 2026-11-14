import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/contract.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/source_network_policy.dart';
import 'package:pica_comic/foundation/def.dart';

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
            throw const ComicSourceContractException(
                SourceNetworkErrorKind.cancelled);
          case 'rate-limited':
            return const Res.error('429 rate limit');
          case 'authentication':
            return const Res.error('403 authentication required');
          case 'timeout':
            throw TimeoutException('fixture request timed out');
          case 'parse':
            return const Res.error('invalid JSON payload');
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
}
