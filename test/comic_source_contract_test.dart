import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/contract.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/source_network_policy.dart';

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

ComicSource _fixtureSource({bool duplicatePage = false}) {
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
    loadComicInfo: (id) async => Res(
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
    ),
    loadComicPages: (id, ep) async => const Res([
      'https://fixture.test/image-1.jpg',
      'https://fixture.test/image-2.jpg',
    ]),
  );
}

void main() {
  test('built-in source definitions are valid without opening the network', () {
    final keys = <String>{};
    for (final source in ComicSource.builtIn) {
      expect(keys.add(source.key), isTrue,
          reason: 'duplicate built-in source key ${source.key}');
      expect(ComicSourceContract.validateDefinition(source), isEmpty,
          reason: source.key);
    }
  });

  test('offline contract accepts a terminal empty page and validates details',
      () async {
    final report = await ComicSourceContract.verify(
      source: _fixtureSource(),
      searchOptions: const ['all'],
      errorCases: [
        ComicSourceContractErrorCase(
          name: 'cancelled',
          operation: () async => throw const ComicSourceContractException(
              SourceNetworkErrorKind.cancelled),
          expectedKind: SourceNetworkErrorKind.cancelled,
        ),
        ComicSourceContractErrorCase(
          name: 'rate-limited',
          operation: () async => const Res.error('429 rate limit'),
          expectedKind: SourceNetworkErrorKind.rateLimited,
        ),
        ComicSourceContractErrorCase(
          name: 'authentication',
          operation: () async => const Res.error('403 authentication required'),
          expectedKind: SourceNetworkErrorKind.authentication,
        ),
        ComicSourceContractErrorCase(
          name: 'parse',
          operation: () async => const Res.error('invalid JSON payload'),
          expectedKind: SourceNetworkErrorKind.parse,
        ),
      ],
    );

    expect(report.isValid, isTrue,
        reason: report.violations.map((e) => e.toString()).join('\n'));
    expect(report.pagesChecked, [1, 2]);
    expect(report.emptyPages, [2]);
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
