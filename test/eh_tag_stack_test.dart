import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/eh_network/tag_settings.dart';
import 'package:pica_comic/network/eh_network/tag_stack.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
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

  group('stack setting persistence', () {
    late Map<String, dynamic> sourceData;
    late Map<String, dynamic>? Function() oldDataProvider;
    late Future<void> Function() oldSaver;

    setUp(() {
      oldDataProvider = EhTagSettings.dataProvider;
      oldSaver = EhTagSettings.saver;
      sourceData = {};
      EhTagSettings.dataProvider = () => sourceData;
    });

    tearDown(() {
      EhTagSettings.dataProvider = oldDataProvider;
      EhTagSettings.saver = oldSaver;
    });

    test('failed save restores the prior value and notifies listeners',
        () async {
      final previousChanges = EhTagSettings.changes.value;
      EhTagSettings.saver = () async => throw StateError('write failed');

      await expectLater(
        EhTagSettings.setStackEnabled(false),
        throwsA(isA<StateError>()),
      );

      expect(sourceData, isEmpty);
      expect(EhTagSettings.stackEnabled, isTrue);
      expect(EhTagSettings.changes.value, previousChanges + 2);
    });

    test('overlapping failed saves roll back to the persisted baseline',
        () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final secondStarted = Completer<void>();
      var saves = 0;
      EhTagSettings.saver = () async {
        saves++;
        if (saves == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        } else {
          secondStarted.complete();
        }
        throw StateError('write $saves failed');
      };

      final first = EhTagSettings.setStackEnabled(false);
      await firstStarted.future;
      final second = EhTagSettings.setStackEnabled(false);
      await Future<void>.delayed(Duration.zero);
      expect(saves, 1, reason: 'writes should be serialized');

      releaseFirst.complete();
      await expectLater(first, throwsA(isA<StateError>()));
      await secondStarted.future;
      await expectLater(second, throwsA(isA<StateError>()));

      expect(sourceData, isEmpty);
      expect(EhTagSettings.stackEnabled, isTrue);
      expect(saves, 2);
    });

    testWidgets('settings switch handles a failed write', (tester) async {
      EhTagSettings.saver = () async => throw StateError('write failed');
      await tester.pumpWidget(const MaterialApp(
        home: OverlayWidget(
          Scaffold(
            body: SingleChildScrollView(child: EhSettings(false)),
          ),
        ),
      ));

      final tile = find.ancestor(
        of: find.text('点标签时叠加到当前标签'),
        matching: find.byType(ListTile),
      );
      final stackSwitch = find.descendant(
        of: tile,
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(stackSwitch).value, isTrue);

      tester.widget<Switch>(stackSwitch).onChanged!(false);
      await tester.pump();
      await tester.pump();

      expect(tester.widget<Switch>(stackSwitch).value, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
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
