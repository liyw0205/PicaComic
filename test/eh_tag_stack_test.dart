import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/eh_network/tag_settings.dart';
import 'package:pica_comic/network/eh_network/tag_stack.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  AppTranslation.translations = const {};
  List<String> keywords(List<EhTagTerm>? terms) =>
      [for (final term in terms ?? const <EhTagTerm>[]) term.toKeyword()];

  test('parses quoted, exact, and excluded terms', () {
    final terms = ehTermsFromKeyword(
        r'language:chinese female:glasses$ female:"big breasts$" -male:yaoi')!;
    expect(
        terms.map(
            (term) => (term.namespace, term.value, term.exact, term.exclude)),
        [
          ('language', 'chinese', false, false),
          ('female', 'glasses', true, false),
          ('female', 'big breasts', true, false),
          ('male', 'yaoi', false, true),
        ]);
    expect(ehKeywordFromTerms(terms),
        r'language:chinese female:glasses$ female:"big breasts$" -male:yaoi');
  });

  test('free text and malformed terms do not stack', () {
    expect(ehTermsFromKeyword(''), isNull);
    expect(ehTermsFromKeyword('touhou'), isNull);
    expect(ehTermsFromKeyword('female:glasses touhou'), isNull);
    expect(ehTermsFromKeyword('female:'), isNull);
    expect(ehTermsFromKeyword(r'female:$'), isNull);
  });

  test('duplicate and language terms are handled predictably', () {
    final base = ehTermsFromKeyword('language:chinese female:glasses')!;
    final duplicate = ehStackAdd(base, const EhTagTerm('female', 'Glasses'));
    expect(duplicate.outcome, EhStackOutcome.duplicate);
    expect(duplicate.terms, same(base));

    final replacement =
        ehStackAdd(base, const EhTagTerm('language', 'english'));
    expect(keywords(replacement.terms), ['female:glasses', 'language:english']);

    final flag = ehStackAdd(base, const EhTagTerm('language', 'translated'));
    expect(keywords(flag.terms),
        ['language:chinese', 'female:glasses', 'language:translated']);
  });

  test('enforces the stack limit without mutating the base list', () {
    var terms = <EhTagTerm>[];
    for (var i = 0; i < ehTagStackLimit; i++) {
      final result = ehStackAdd(terms, EhTagTerm('female', 'tag$i'));
      expect(result.outcome, EhStackOutcome.added);
      terms = result.terms;
    }
    final result = ehStackAdd(terms, const EhTagTerm('female', 'one more'));
    expect(result.outcome, EhStackOutcome.limit);
    expect(result.terms, same(terms));
  });

  group('search page integration', () {
    late List<ComicSource> oldSources;
    late List<String> oldSettings;
    late List<String> oldSearchHistory;
    late Map<String, dynamic> sourceData;
    late List<String> requestedKeywords;
    late Map<String, dynamic>? Function() oldDataProvider;
    late Future<void> Function() oldSaver;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      oldSources = ComicSource.sources;
      oldSettings = List.of(appdata.settings);
      oldSearchHistory = List.of(appdata.searchHistory);
      oldDataProvider = EhTagSettings.dataProvider;
      oldSaver = EhTagSettings.saver;
      sourceData = {};
      requestedKeywords = [];
      appdata.settings[69] = '0';
      EhTagSettings.dataProvider = () => sourceData;
      EhTagSettings.saver = () async {};
      ComicSource.sources = [
        ComicSource.named(
          name: 'EH fixture',
          key: 'ehentai',
          filePath: 'test',
          searchPageData: SearchPageData.named(
            enableLanguageFilter: true,
            customResultsBuilder: (keyword, options, header) {
              requestedKeywords.add(keyword);
              return CustomScrollView(
                slivers: [
                  header,
                  SliverToBoxAdapter(child: Text(keyword)),
                ],
              );
            },
          ),
        ),
      ];
    });

    tearDown(() {
      ComicSource.sources = oldSources;
      appdata.settings = oldSettings;
      appdata.searchHistory = oldSearchHistory;
      EhTagSettings.dataProvider = oldDataProvider;
      EhTagSettings.saver = oldSaver;
    });

    testWidgets('stacked chips edit the query and retain its gallery context',
        (tester) async {
      const galleryUrl = 'https://e-hentai.org/g/1/abc/';
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: const SearchResultPage(
          keyword: 'language:chinese artist:fixture_artist',
          sourceKey: 'ehentai',
        ),
      ));

      expect(find.byType(InputChip), findsNWidgets(2));
      expect(find.widgetWithText(InputChip, 'fixture_artist'), findsOneWidget);
      expect(requestedKeywords.last, 'language:chinese artist:fixture_artist');

      SearchPageContext.onComicOpened('ehentai', galleryUrl);
      expect(SearchPageContext.keywordForComic('ehentai', galleryUrl),
          'language:chinese artist:fixture_artist');

      await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, 'fixture_artist'),
        matching: find.byTooltip('移除'),
      ));
      await tester.pump();

      expect(find.byType(InputChip), findsNothing);
      expect(appdata.searchHistory.last, 'language:chinese');
      expect(requestedKeywords.last, 'language:chinese');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(SearchPageContext.keywordForComic('ehentai', galleryUrl), isNull);
    });

    testWidgets('plain searches and disabled stacking have no chips',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: const SearchResultPage(
          keyword: 'female:glasses free text',
          sourceKey: 'ehentai',
        ),
      ));
      expect(find.byType(InputChip), findsNothing);

      sourceData['tagStackEnabled'] = false;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: const SearchResultPage(
          keyword: 'language:chinese female:glasses',
          sourceKey: 'ehentai',
        ),
      ));
      expect(find.byType(InputChip), findsNothing);
    });
  });
}
