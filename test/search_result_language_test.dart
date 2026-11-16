import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/search_language.dart';
import 'package:pica_comic/pages/search_result_page.dart';

void main() {
  test('defaults apply to initial, repeated and empty searches', () {
    for (final keyword in ['first', 'second', '']) {
      expect(withDefaultSearchLanguage(keyword, 1),
          '$keyword language:chinese'.trim());
    }
  });

  test('explicit language wins over the default, without duplicates', () {
    expect(withDefaultSearchLanguage('tag Language:japanese', 1),
        'tag Language:japanese');
    final query = withDefaultSearchLanguage('tag', 1);
    expect(withDefaultSearchLanguage(query, 1), query);
  });

  test('a query snapshot follows a changed default language', () {
    const keyword = 'artist:test';
    expect(withDefaultSearchLanguage(keyword, 0), keyword);
    expect(withDefaultSearchLanguage(keyword, 1), '$keyword language:chinese');
    expect(withDefaultSearchLanguage(keyword, 2), '$keyword language:english');
  });

  test('negative and ordinary language words do not disable the default', () {
    expect(withDefaultSearchLanguage('language_school -language:english', 1),
        'language_school -language:english language:chinese');
  });

  test('unsupported sources and invalid settings do not add a filter', () {
    expect(withDefaultSearchLanguage('tag', 1, enabled: false), 'tag');
    for (final index in [-1, 0, 4, 99]) {
      expect(withDefaultSearchLanguage('tag', index), 'tag');
    }
  });

  group('SearchResultPage', () {
    final source = ComicSource.named(
      name: 'test',
      key: 'search-language-test',
      filePath: 'test',
      searchPageData: SearchPageData.named(
        enableLanguageFilter: true,
        overrideSearchResultBuilder: (keyword, options) => Text(keyword),
      ),
    );
    late List<ComicSource> oldSources;
    late String oldLanguage;

    setUp(() {
      oldSources = ComicSource.sources;
      oldLanguage = appdata.settings[69];
      ComicSource.sources = [source];
      appdata.settings[69] = '0';
    });

    tearDown(() {
      ComicSource.sources = oldSources;
      appdata.settings[69] = oldLanguage;
    });

    testWidgets('changing the default language rebuilds the active query',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SearchResultPage(
          keyword: 'artist:test',
          sourceKey: source.key,
        ),
      ));
      expect(find.text('artist:test'), findsOneWidget);

      appdata.settings[69] = '1';
      SearchResultPage.updateDefaultLanguage(1);
      await tester.pump();
      expect(find.text('artist:test language:chinese'), findsOneWidget);

      appdata.settings[69] = '2';
      SearchResultPage.updateDefaultLanguage(2);
      await tester.pump();
      expect(find.text('artist:test language:english'), findsOneWidget);
    });

    testWidgets(
        'an explicit language remains authoritative after a setting change',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SearchResultPage(
          keyword: 'artist:test language:japanese',
          sourceKey: source.key,
        ),
      ));
      expect(find.text('artist:test language:japanese'), findsOneWidget);

      appdata.settings[69] = '1';
      SearchResultPage.updateDefaultLanguage(1);
      await tester.pump();
      expect(find.text('artist:test language:japanese'), findsOneWidget);
    });
  });
}
