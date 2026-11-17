import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/built_in/hitomi.dart';
import 'package:pica_comic/comic_source/contract.dart';
import 'package:pica_comic/network/hitomi_network/search_sort.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/search_language.dart';
import 'package:pica_comic/pages/hitomi/hitomi_search.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/translations.dart';

Future<void> _finishSearchTransition(WidgetTester tester) async {
  // Start the route ticker before advancing time; the loading spinner prevents
  // pumpAndSettle from finishing while a search response is still pending.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  AppTranslation.translations = const {};
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

  group('Hitomi shared search controls', () {
    late List<ComicSource> oldSources;
    late List<String> oldSettings;
    final calls = <(String, HitomiSearchSort)>[];
    late Future<Res<List<int>>> Function(String, HitomiSearchSort) loader;
    late ComicSource source;

    setUp(() {
      oldSources = ComicSource.sources;
      oldSettings = List.of(appdata.settings);
      appdata.settings[69] = '0';
      calls.clear();
      loader = (_, __) async => const Res([]);
      source = ComicSource.named(
        name: 'Hitomi fixture',
        key: 'hitomi',
        filePath: 'test',
        searchPageData: SearchPageData.named(
          enableLanguageFilter: true,
          searchOptions: hitomi.searchPageData!.searchOptions,
          customResultsBuilder: (keyword, options, header) => HitomiSearchResults(
            keyword: keyword,
            sort: HitomiSearchSort.fromOption(options.firstOrNull),
            header: header,
            loadResults: (query, sort) {
              calls.add((query, sort));
              return loader(query, sort);
            },
          ),
        ),
      );
      ComicSource.sources = [source];
    });

    tearDown(() {
      ComicSource.sources = oldSources;
      appdata.settings = oldSettings;
    });

    test('built-in source supplies all seven sorts and shared results body', () {
      final data = hitomi.searchPageData!;
      expect(data.overrideSearchResultBuilder, isNull);
      expect(data.searchOptions!.single.options.keys,
          HitomiSearchSort.values.map((sort) => sort.name));
      final results = data.customResultsBuilder!(
          'title language:chinese', ['year'], const SliverToBoxAdapter());
      expect(results, isA<HitomiSearchResults>());
      expect((results as HitomiSearchResults).keyword, 'title language:chinese');
      expect(results.sort, HitomiSearchSort.year);
      expect(ComicSourceContract.validateDefinition(hitomi), isEmpty);
    });

    testWidgets('mobile menu keeps controls available through loading and failure',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<Res<List<int>>>();
      loader = (_, __) => pending.future;
      await tester.pumpWidget(const MaterialApp(
        home: SearchResultPage(keyword: 'title', sourceKey: 'hitomi'),
      ));
      await tester.pump();
      expect(calls, [('title', HitomiSearchSort.dateAdded)]);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await _finishSearchTransition(tester);
      expect(find.text('切换源'), findsOneWidget);
      await tester.tap(find.text('搜索选项'));
      await _finishSearchTransition(tester);
      await tester.tap(find.text('本年热门'));
      await tester.tap(find.text('确认'));
      await _finishSearchTransition(tester);
      expect(calls.last, ('title', HitomiSearchSort.year));
      pending.complete(const Res.error('fixture offline'));
      await tester.pumpAndSettle();
      expect(find.text('fixture offline'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      loader = (_, __) async => const Res([]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('没有找到漫画'), findsOneWidget);
      expect(calls.last, ('title', HitomiSearchSort.year));
      final requestsBeforeResize = calls.length;
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.tune), findsOneWidget);
      expect(calls.length, requestsBeforeResize);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('sorting, language and source changes preserve the raw keyword',
        (tester) async {
      final otherCalls = <(String, List<String>)>[];
      final other = ComicSource.named(
        name: 'Other fixture',
        key: 'other_fixture',
        filePath: 'test',
        searchPageData: SearchPageData.named(
          searchOptions: hitomi.searchPageData!.searchOptions,
          customResultsBuilder: (query, options, header) {
            otherCalls.add((query, List.of(options)));
            return CustomScrollView(slivers: [
              header,
              const SliverToBoxAdapter(child: Text('Other results')),
            ]);
          },
        ),
      );
      ComicSource.sources = [source, other];
      final pending = Completer<Res<List<int>>>();
      loader = (_, sort) => sort == HitomiSearchSort.dateAdded
          ? pending.future
          : Future.value(const Res([]));
      await tester.pumpWidget(const MaterialApp(
        home: SearchResultPage(keyword: 'title', sourceKey: 'hitomi'),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.tune));
      await _finishSearchTransition(tester);
      await tester.tap(find.text('随机'));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(calls.last, ('title', HitomiSearchSort.random));
      pending.complete(const Res.error('stale response'));
      await tester.pumpAndSettle();
      expect(find.text('stale response'), findsNothing);
      final count = calls.length;
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本年热门'));
      Navigator.of(tester.element(find.text('搜索选项'))).pop();
      await tester.pumpAndSettle();
      expect(calls, hasLength(count));
      appdata.settings[69] = '1';
      SearchResultPage.updateDefaultLanguage(1);
      await tester.pumpAndSettle();
      expect(calls.last, ('title language:chinese', HitomiSearchSort.random));
      await tester.enterText(find.byType(TextField), 'next language:japanese');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(calls.last, ('next language:japanese', HitomiSearchSort.random));
      await tester.tap(find.byIcon(Icons.dataset_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other fixture'));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(otherCalls.last.$1, 'next language:japanese');
      expect(otherCalls.last.$2, ['dateAdded']);
      expect(find.text('Other results'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
