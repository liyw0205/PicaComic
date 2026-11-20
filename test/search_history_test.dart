import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/comic_source/built_in/picacg.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PicacgSearchNetwork extends PicacgNetwork {
  _PicacgSearchNetwork()
      : super.forTesting(cachedNetworkFactory: CachedNetwork.new);

  static const response = Res<Map<String, dynamic>>({
    'data': {
      'comics': {'pages': 3, 'docs': []},
    },
  });
  Future<Res<Map<String, dynamic>>> Function(String)? respond;
  final requests = <Uri>[];

  @override
  Future<Res<Map<String, dynamic>>> post(
      String url, Map<String, String>? data) async {
    requests.add(Uri.parse(url));
    return respond == null ? response : await respond!(data!['keyword']!);
  }
}

class _JmSearchNetwork extends JmNetwork {
  _JmSearchNetwork() : super.create();

  final requests = <Uri>[];
  bool malformed = false;

  @override
  Future<Res<dynamic>> get(String url,
      {Map<String, String>? header,
      CacheExpiredTime expiredTime = CacheExpiredTime.long,
      bool isRetry = false}) async {
    requests.add(Uri.parse(url));
    return Res(malformed ? {} : {'content': [], 'total': 0});
  }
}

class _HtSearchNetwork extends HtmangaNetwork {
  _HtSearchNetwork() : super.forTesting(dioFactory: Dio.new);

  final requests = <Uri>[];

  @override
  Future<Res<String>> get(String url,
      {bool cache = true, Map<String, String>? headers}) async {
    requests.add(Uri.parse(url));
    return const Res('<html></html>');
  }
}

class _EhSearchNetwork extends EhNetwork {
  _EhSearchNetwork() : super.create();

  final requests = <Uri>[];

  @override
  Future<String> getCookies(bool setNW, [String? url]) async => '';

  @override
  Future<Res<String>> request(String url,
      {Map<String, String>? headers,
      CacheExpiredTime expiredTime = CacheExpiredTime.short,
      bool setNW = true,
      CancelToken? cancelToken}) async {
    requests.add(Uri.parse(url));
    return const Res('<html></html>');
  }
}

class _UnusedCookieJar implements SingleInstanceCookieJar {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingHistoryData extends Appdata {
  @override
  Future<void> writeHistory() async {
    throw StateError('fixture preferences unavailable');
  }
}

class _SearchSettingsData extends Appdata {
  int settingsWrites = 0;

  @override
  Future<void> updateSettings([bool syncData = true]) async {
    settingsWrites++;
  }
}

void main() {
  AppTranslation.translations = const {};
  late List<ComicSource> savedSources;
  late List<String> savedSettings;
  late List<String> savedHistory;
  late GlobalKey<NavigatorState>? savedNavigator;
  late ComicSource source;
  final requests = <(String, int)>[];
  late Future<Res<List<BaseComic>>> Function(String, int) load;

  setUp(() {
    savedSources = ComicSource.sources;
    savedSettings = List.of(appdata.settings);
    savedHistory = List.of(appdata.searchHistory);
    savedNavigator = App.mainNavigatorKey;
    App.mainNavigatorKey = App.navigatorKey;
    appdata.searchHistory = ['query', 'newer'];
    SharedPreferences.setMockInitialValues({
      'search': List.of(appdata.searchHistory),
    });
    appdata.settings[69] = '1';
    appdata.settings[25] = '0';
    requests.clear();
    load = (_, __) async => const Res([]);
    source = ComicSource.named(
      name: 'Search fixture',
      key: 'search-history-fixture',
      filePath: 'test',
      searchPageData: SearchPageData.named(
        enableLanguageFilter: true,
        loadPage: (query, page, options) {
          requests.add((query, page));
          return load(query, page);
        },
      ),
    );
    ComicSource.sources = [source];
    appdata.appSettings.initialSearchTarget = source.key;
  });

  tearDown(() {
    ComicSource.sources = savedSources;
    appdata.settings = savedSettings;
    appdata.searchHistory = savedHistory;
    App.mainNavigatorKey = savedNavigator;
    for (final controller in StateController.findAll<PreSearchController>()) {
      controller.dispose();
    }
  });

  Future<void> open(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: page,
    ));
    await tester.pumpAndSettle();
  }

  Future<void> expectHistory(List<String> expected) async {
    expect(appdata.searchHistory, expected);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('search'), expected);
  }

  test('presearch fallback only selects sources that support search', () {
    final unsupported = ComicSource.named(
      name: 'No search',
      key: 'no-search-fixture',
      filePath: 'test',
    );
    ComicSource.sources = [unsupported, source];
    final original = appdata;
    final settings = _SearchSettingsData()
      ..settings = List.of(original.settings);
    appdata = settings;
    addTearDown(() => appdata = original);

    for (final initial in ['removed-source', unsupported.key]) {
      appdata.appSettings.initialSearchTarget = initial;
      final controller = PreSearchController();
      expect(controller.target, source.key);
      expect(controller.searchPageData, same(source.searchPageData));
      expect(appdata.appSettings.initialSearchTarget, source.key);
      controller.dispose();
    }
    expect(settings.settingsWrites, 2);
  });

  test('presearch clears options when the next source has no options', () {
    final withOptions = ComicSource.named(
      name: 'With options',
      key: 'search-options-fixture',
      filePath: 'test',
      searchPageData: SearchPageData.named(searchOptions: [
        SearchOptions(
            LinkedHashMap.of({'newest': 'Newest', 'oldest': 'Oldest'}), 'Sort'),
      ]),
    );
    ComicSource.sources = [withOptions, source];
    appdata.appSettings.initialSearchTarget = withOptions.key;
    final controller = PreSearchController();
    expect(controller.options, ['newest']);
    controller.updateTarget(source.key);
    expect(controller.options, isEmpty);
    controller.dispose();
  });

  testWidgets(
      'presearch hides an automatically applied source language without shifting options',
      (tester) async {
    final languageSource = ComicSource.named(
      name: 'Language options fixture',
      key: 'language-options-fixture',
      filePath: 'test',
      searchPageData: SearchPageData.named(
        enableLanguageFilter: true,
        searchOptions: [
          SearchOptions(
              LinkedHashMap.of({'recent': 'Recent', 'popular': 'Popular'}),
              'Sort'),
          SearchOptions(LinkedHashMap.of({'chinese': 'Source Chinese'}), '语言'),
          SearchOptions(
              LinkedHashMap.of({'low': 'Low quality', 'high': 'High quality'}),
              'Quality'),
        ],
      ),
    );
    ComicSource.sources = [languageSource];
    appdata.appSettings.initialSearchTarget = languageSource.key;
    appdata.settings[69] = '1';
    final page = PreSearchPage();
    await open(
        tester, Scaffold(body: Builder(builder: page.buildSearchOptions)));

    expect(find.text('Source Chinese'), findsNothing);
    expect(find.text('语言'), findsOneWidget,
        reason: 'the pre-search language selector remains available');
    expect(find.text('Quality'), findsOneWidget);
    await tester.tap(find.text('High quality'));
    expect(page.searchController.options, ['recent', 'chinese', 'high']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('presearch keeps the source language option for invalid defaults',
      (tester) async {
    final languageSource = ComicSource.named(
      name: 'Language options fixture',
      key: 'language-options-fixture',
      filePath: 'test',
      searchPageData: SearchPageData.named(
        enableLanguageFilter: true,
        searchOptions: [
          SearchOptions(LinkedHashMap.of({'chinese': 'Source Chinese'}), '语言'),
        ],
      ),
    );
    ComicSource.sources = [languageSource];
    appdata.appSettings.initialSearchTarget = languageSource.key;
    appdata.settings[69] = '4';
    final page = PreSearchPage();
    await open(
        tester, Scaffold(body: Builder(builder: page.buildSearchOptions)));

    expect(find.text('Source Chinese'), findsOneWidget);
    expect(find.text('语言'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final hasUnsupportedSource in [false, true]) {
    testWidgets(
        'presearch handles no searchable sources (nonsearch source: $hasUnsupportedSource)',
        (tester) async {
      ComicSource.sources = hasUnsupportedSource
          ? [
              ComicSource.named(
                  name: 'No search',
                  key: 'no-search-fixture',
                  filePath: 'test'),
            ]
          : [];
      final initialTarget = appdata.appSettings.initialSearchTarget;
      final page = PreSearchPage();
      await open(tester, OverlayWidget(page));
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
      expect(page.searchController.searchPageData, isNull);
      expect(appdata.appSettings.initialSearchTarget, initialTarget);

      await tester.enterText(find.byType(TextField), 'offline query');
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      expect(find.byType(SearchResultPage), findsNothing);
      expect(requests, isEmpty);
      await expectHistory(['query', 'newer']);
      expect(page.controller.text, 'offline query');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));

      await tester.enterText(
          find.byType(TextField), 'https://hitomi.la/galleries/123.html');
      await tester.pump();
      expect(page.searchController.suggestions.single.left, '**URL**');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('presearch ignores a source removed while the page is open',
      (tester) async {
    final page = PreSearchPage();
    page.searchController.language = 'chinese';
    await open(tester, OverlayWidget(page));
    ComicSource.sources = [];
    page.searchController.update();
    await tester.pumpAndSettle();
    expect(find.text('Search fixture'), findsNothing);
    expect(find.text('没有可用的搜索源'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.byType(SearchResultPage), findsNothing);
    expect(requests, isEmpty);
    await expectHistory(['query', 'newer']);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final optionKind in ['standard', 'custom', 'none']) {
    testWidgets('saved tag uses target source options ($optionKind)',
        (tester) async {
      final searches = <(String, int, List<String>)>[];
      final target = ComicSource.named(
        name: 'Saved tag source',
        key: 'saved-tag-fixture',
        filePath: 'test',
        searchPageData: SearchPageData.named(
          searchOptions: optionKind == 'standard'
              ? [
                  SearchOptions(
                      LinkedHashMap.of({'target-sort': 'Target sort'}), 'Sort'),
                ]
              : null,
          customOptionsBuilder: optionKind == 'custom'
              ? (_, __, ___) => const SizedBox.shrink()
              : null,
          loadPage: (query, page, options) async {
            searches.add((query, page, List.of(options)));
            return const Res([]);
          },
        ),
      );
      ComicSource.sources = [source, target];
      final page = PreSearchPage();
      page.searchController.options = ['active-sort'];
      page.searchController.language = 'japanese';
      await open(
          tester,
          Scaffold(
            body: page.buildFavoriteItem(
                '${target.key}:artist:saved tag', page.searchController),
          ));
      await tester.tap(find.text('artist:saved tag'));
      await tester.pumpAndSettle();

      expect(searches, hasLength(1));
      expect(searches.single.$1, 'artist:saved tag');
      expect(searches.single.$2, 1);
      expect(searches.single.$3,
          optionKind == 'standard' ? ['target-sort'] : <String>[]);
      expect(page.searchController.target, source.key);
      expect(page.searchController.options, ['active-sort']);
      expect(page.searchController.language, 'japanese');
      await expectHistory(['query', 'newer', 'artist:saved tag']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('saved tag for the selected source keeps user options',
      (tester) async {
    final searches = <List<String>>[];
    source = ComicSource.named(
      name: 'Picacg fixture',
      key: 'picacg',
      filePath: 'test',
      searchPageData: SearchPageData.named(
        searchOptions: [
          SearchOptions(
              LinkedHashMap.of({'dd': 'Newest', 'da': 'Oldest'}), 'Sort'),
        ],
        loadPage: (query, page, options) async {
          searches.add(List.of(options));
          return const Res([]);
        },
      ),
    );
    ComicSource.sources = [source];
    appdata.appSettings.initialSearchTarget = source.key;
    final page = PreSearchPage();
    page.searchController.options = ['da'];
    await open(
        tester,
        Scaffold(
          body:
              page.buildFavoriteItem('Picacg:saved tag', page.searchController),
        ));
    await tester.tap(find.text('saved tag'));
    await tester.pumpAndSettle();

    expect(searches, [
      ['da'],
    ]);
    expect(page.searchController.options, ['da']);
    await expectHistory(['query', 'newer', 'saved tag']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search submission takes a snapshot of selected options',
      (tester) async {
    final searches = <List<String>>[];
    source = ComicSource.named(
      name: 'Options fixture',
      key: source.key,
      filePath: 'test',
      searchPageData: SearchPageData.named(
        searchOptions: [
          SearchOptions(
              LinkedHashMap.of({'first': 'First', 'next': 'Next'}), 'Sort'),
        ],
        loadPage: (query, page, options) async {
          searches.add(List.of(options));
          return const Res([]);
        },
      ),
    );
    ComicSource.sources = [source];
    final page = PreSearchPage();
    await open(tester, page);
    page.search('snapshot query');
    page.searchController.options[0] = 'next';
    await tester.pumpAndSettle();

    expect(searches, [
      ['first'],
    ]);
    expect(page.searchController.options, ['next']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('custom search options survive showing and hiding suggestions',
      (tester) async {
    source = ComicSource.named(
      name: 'EH options fixture',
      key: source.key,
      filePath: 'test',
      searchPageData: SearchPageData.named(
        customOptionsBuilder: ehentai.searchPageData!.customOptionsBuilder,
        loadPage: (_, __, ___) async => const Res([]),
      ),
    );
    ComicSource.sources = [source];
    final page = PreSearchPage();
    await open(tester, page);
    await tester.enterText(find.byType(TextField).at(1), '12');
    await tester.enterText(find.byType(TextField).at(2), '98');
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('98'), findsOneWidget);
    expect(page.searchController.options.sublist(1, 3), ['12', '98']);
    expect(page.searchController.options.last, '1');

    await tester.enterText(
        find.byType(TextField).first, 'https://hitomi.la/galleries/123.html');
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('98'), findsOneWidget);
    expect(page.searchController.options.sublist(1, 3), ['12', '98']);
    expect(page.searchController.options.last, '1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('EH search dialog restores page bounds before editing them',
      (tester) async {
    final searches = <List<String>>[];
    source = ComicSource.named(
      name: 'EH options fixture',
      key: source.key,
      filePath: 'test',
      searchPageData: SearchPageData.named(
        customOptionsBuilder: ehentai.searchPageData!.customOptionsBuilder,
        loadPage: (_, __, options) async {
          searches.add(List.of(options));
          return const Res([]);
        },
      ),
    );
    ComicSource.sources = [source];
    await open(
        tester,
        SearchResultPage(
          keyword: 'query',
          sourceKey: source.key,
          options: const ['0', '12', '98', '3', '1'],
        ));
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    expect(find.text('98'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

    final fields = find.descendant(
        of: find.byType(ContentDialog), matching: find.byType(TextField));
    await tester.enterText(fields.first, '');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(searches.last, ['0', 'null', '98', '3', '1']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fails in [false, true]) {
    testWidgets(
        'custom source records raw query before ${fails ? 'failure' : 'success'}',
        (tester) async {
      load = (_, __) async =>
          fails ? const Res.error('fixture offline') : const Res([]);
      await open(tester, PreSearchPage());
      await tester.enterText(find.byType(TextField), '  query  ');
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(requests, [('query language:chinese', 1)]);
      await expectHistory(['newer', 'query']);
      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('query'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('explicit language selection remains in history', (tester) async {
    final page = PreSearchPage();
    page.searchController.language = 'japanese';
    await open(tester, page);
    await tester.enterText(find.byType(TextField), 'query language:english');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(requests, [('query language:japanese', 1)]);
    await expectHistory(['query', 'newer', 'query language:japanese']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyboard and search button move new queries to the latest entry',
      (tester) async {
    await open(
        tester, SearchResultPage(keyword: 'query', sourceKey: source.key));
    await expectHistory(['newer', 'query']);

    await tester.enterText(find.byType(TextField), ' next language:japanese ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(requests.last, ('next language:japanese', 1));
    await expectHistory(['newer', 'query', 'next language:japanese']);

    await tester.enterText(find.byType(TextField), 'query');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await expectHistory(['newer', 'next language:japanese', 'query']);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await expectHistory(['newer', 'next language:japanese', 'query']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final override in [false, true]) {
    testWidgets(
        '${override ? 'override' : 'custom'} results record raw queries',
        (tester) async {
      Widget results(String query, List<String> options) => Text(query);
      source = ComicSource.named(
        name: 'Builder fixture',
        key: source.key,
        filePath: 'test',
        searchPageData: SearchPageData.named(
          enableLanguageFilter: true,
          overrideSearchResultBuilder: override ? results : null,
          customResultsBuilder: override
              ? null
              : (query, options, header) => CustomScrollView(slivers: [
                    header,
                    SliverToBoxAdapter(child: results(query, options)),
                  ]),
        ),
      );
      ComicSource.sources = [source];
      await open(
          tester, SearchResultPage(keyword: 'query', sourceKey: source.key));
      expect(find.text('query language:chinese'), findsOneWidget);
      await expectHistory(['newer', 'query']);

      appdata.searchHistory.add('later');
      await appdata.writeHistory();
      SearchResultPage.updateDefaultLanguage(2);
      await tester.pumpAndSettle();
      expect(find.text('query language:english'), findsOneWidget);
      await expectHistory(['newer', 'query', 'later']);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('late responses and retries preserve later search history',
      (tester) async {
    final pending = Completer<Res<List<BaseComic>>>();
    load = (_, __) => pending.future;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: SearchResultPage(keyword: 'query', sourceKey: source.key),
    ));
    await tester.pump();
    await expectHistory(['newer', 'query']);

    appdata.searchHistory.add('later');
    await appdata.writeHistory();
    pending.complete(const Res.error('fixture offline'));
    await tester.pumpAndSettle();
    await expectHistory(['newer', 'query', 'later']);

    load = (_, __) async => const Res([]);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    await expectHistory(['newer', 'query', 'later']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty searches never enter history', (tester) async {
    await open(tester, SearchResultPage(keyword: '  ', sourceKey: source.key));
    expect(requests, [('language:chinese', 1)]);
    await expectHistory(['query', 'newer']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('switching to an override builder preserves later history',
      (tester) async {
    final other = ComicSource.named(
      name: 'Override fixture',
      key: 'override-fixture',
      filePath: 'test',
      searchPageData: SearchPageData.named(
        enableLanguageFilter: true,
        overrideSearchResultBuilder: (query, options) => Text(query),
      ),
    );
    ComicSource.sources = [source, other];
    await open(
        tester, SearchResultPage(keyword: 'query', sourceKey: source.key));
    appdata.searchHistory.add('later');
    await appdata.writeHistory();
    await tester.tap(find.byIcon(Icons.dataset_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Override fixture'));
    await tester.pump();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(find.text('query language:chinese'), findsOneWidget);
    await expectHistory(['newer', 'query', 'later']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('history storage failure does not block results or history UI',
      (tester) async {
    final original = appdata;
    appdata = _FailingHistoryData()
      ..settings = List.of(original.settings)
      ..searchHistory = List.of(original.searchHistory);
    addTearDown(() => appdata = original);
    await open(tester, PreSearchPage());
    await tester.enterText(find.byType(TextField), 'saved in memory');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(requests, [('saved in memory language:chinese', 1)]);
    expect(appdata.searchHistory.last, 'saved in memory');
    App.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('saved in memory'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('PICACG source pagination does not record queries', () async {
    final original = PicacgNetwork.cache;
    final network = _PicacgSearchNetwork();
    PicacgNetwork.cache = network;
    addTearDown(() => PicacgNetwork.cache = original);
    for (final page in [1, 2]) {
      final response =
          await picacg.searchPageData!.loadPage!('query', page, ['dd']);
      expect(response.success, isTrue);
      expect(network.requests.last.queryParameters['page'], '$page');
    }
    await expectHistory(['query', 'newer']);
  });

  test('PICACG explicit opt-in records submission order before responses',
      () async {
    final network = _PicacgSearchNetwork();
    final first = Completer<Res<Map<String, dynamic>>>();
    final second = Completer<Res<Map<String, dynamic>>>();
    network.respond =
        (keyword) => keyword == 'first' ? first.future : second.future;
    final firstRequest = network.search('first', 'dd', 1, addToHistory: true);
    final secondRequest = network.search('second', 'dd', 1, addToHistory: true);
    expect(appdata.searchHistory, ['query', 'newer', 'first', 'second']);

    second.complete(_PicacgSearchNetwork.response);
    expect((await secondRequest).success, isTrue);
    first.complete(_PicacgSearchNetwork.response);
    expect((await firstRequest).success, isTrue);
    await expectHistory(['query', 'newer', 'first', 'second']);
    final response = await network.search('query', 'dd', 2, addToHistory: true);
    expect(response.success, isTrue);
    await expectHistory(['query', 'newer', 'first', 'second']);
  });

  test('JM search pages preserve history and encoded query parameters',
      () async {
    final network = _JmSearchNetwork();
    for (final page in [1, 2]) {
      final response = await network.searchNew(
          ' query word ', page, ComicsOrder.totalRanking);
      expect(response.success, isTrue);
      final query = network.requests.last.queryParameters;
      expect(query['search_query'], 'query word');
      expect(query['o'], 'mv');
      expect(query['page'], page == 1 ? null : '$page');
    }
    network.malformed = true;
    expect((await network.searchNew('bad data', 1, ComicsOrder.latest)).error,
        isTrue);
    await expectHistory(['query', 'newer']);
  });

  test('WNACG pagination preserves history and search parameters', () async {
    final network = _HtSearchNetwork();
    for (final page in [1, 2]) {
      final response = await network.search('query', page);
      expect(response.success, isTrue);
      final query = network.requests.last.queryParameters;
      expect(query['q'], 'query');
      expect(query['p'], page == 1 ? null : '$page');
    }
    await expectHistory(['query', 'newer']);
  });

  test('EH background search preserves history and language options', () async {
    final original = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    addTearDown(() => SingleInstanceCookieJar.instance = original);
    final network = _EhSearchNetwork();
    final response = await network.search('query', fCats: 2, minStars: 3);
    expect(response.success, isTrue);
    expect(network.requests.single.queryParameters, {
      'f_search': 'query language:chinese',
      'f_cats': '2',
      'f_srdd': '3',
    });
    await expectHistory(['query', 'newer']);
  });
}
