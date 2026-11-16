import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/network/nhentai_network/models.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/category_comics_page.dart';
import 'package:pica_comic/pages/nhentai/comic_page.dart';
import 'package:pica_comic/pages/nhentai/tag_stack_bar.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
  }
}

void main() {
  AppTranslation.translations = const {};
  const chinese = NhentaiTagTerm('language', 'chinese');
  const glasses = NhentaiTagTerm('tag', 'glasses');
  const comic = NhentaiComicBrief('Gallery', '', '123', 'Chinese', []);
  late List<ComicSource> previousSources;
  late List<String> previousSettings;
  late ComicSource source;
  late List<NhentaiTagTerm> tileTerms;
  late List<(String?, List<String>, int)> requests;

  setUp(() {
    previousSources = ComicSource.sources;
    previousSettings = List.of(appdata.settings);
    appdata.settings[25] = '0';
    appdata.settings[69] = '0';
    appdata.settings[50] = 'en';
    tileTerms = [];
    requests = [];
    source = ComicSource.named(
      name: 'nhentai',
      key: 'nhentai',
      filePath: 'test',
      categoryData: nhentai.categoryData,
      categoryComicsData: CategoryComicsData.named(
        load: (_, param, options, page) async {
          requests.add((param, List.of(options), page));
          return const Res([comic], subData: 1);
        },
        options: [
          CategoryComicsOptions.named(
              options: LinkedHashMap.of({'': 'Recent', 'popular': 'Popular'})),
        ],
      ),
      searchPageData: SearchPageData.named(
        enableLanguageFilter: true,
        loadPage: (_, __, ___) async => const Res([comic], subData: 1),
      ),
      comicTileBuilderOverride: (context, comic, options) {
        tileTerms = NhentaiTagScope.termsOf(context);
        return const Text('Gallery');
      },
    );
    ComicSource.sources = [source];
  });

  tearDown(() {
    ComicSource.sources = previousSources;
    appdata.settings = previousSettings;
  });

  testWidgets(
      'removing a stacked tag keeps sorting and narrows the tile context',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CategoryComicsPage(
        category: 'glasses',
        categoryKey: 'nhentai',
        param: nhentaiStackParam(const [chinese, glasses]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tileTerms, const [chinese, glasses]);
    expect(requests.single.$3, 1);
    await tester.tap(find.text('Popular'));
    await tester.pumpAndSettle();
    expect(requests.last.$2, ['popular']);

    final bar =
        tester.widget<NhentaiTagStackBar>(find.byType(NhentaiTagStackBar));
    bar.onRemove(chinese);
    await tester.pumpAndSettle();
    expect(requests.last.$1, '/tag/glasses');
    expect(requests.last.$2, ['popular']);
    expect(tileTerms, const [glasses]);
    expect(find.byType(NhentaiTagStackBar), findsNothing);

    source.data['tagStackEnabled'] = false;
    NhentaiTagSettings.changes.value++;
    await tester.pumpAndSettle();
    expect(tileTerms, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    NhentaiTagSettings.changes.value++;
    expect(tester.takeException(), isNull);
  });

  testWidgets('only explicit tag searches pass filters to their comic tiles',
      (tester) async {
    for (final keyword in ['tag:glasses', 'title tag:glasses']) {
      await tester.pumpWidget(MaterialApp(
        home: SearchResultPage(
          key: ValueKey(keyword),
          keyword: keyword,
          sourceKey: 'nhentai',
        ),
      ));
      await tester.pumpAndSettle();
      expect(tileTerms, keyword == 'tag:glasses' ? const [glasses] : isEmpty);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the built-in tile passes a snapshot into the opened gallery',
      (tester) async {
    final previousKey = App.mainNavigatorKey;
    App.mainNavigatorKey = App.navigatorKey;
    addTearDown(() => App.mainNavigatorKey = previousKey);
    final observer = _RouteObserver();
    ComicTile? tile;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [observer],
      home: NhentaiTagScope(
        terms: const [chinese, glasses],
        child: Builder(builder: (context) {
          tile = nhentai.comicTileBuilderOverride!(context, comic, null)
              as ComicTile;
          return TextButton(
              onPressed: () => tile!.onTap_(), child: const Text('Open'));
        }),
      ),
    ));
    await tester.tap(find.text('Open'));
    final route = observer.latest! as AppPageRoute;
    final page = route.builder(App.mainNavigatorKey!.currentContext!)
        as NhentaiComicPage;
    expect(page.tagTerms, const [chinese, glasses]);
    expect(() => page.tagTerms.add(glasses), throwsUnsupportedError);
    // Inspect the route before rendering its network-backed details page.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('default exclusions editor rejects text and persists tag filters',
      (tester) async {
    final previousSaver = NhentaiTagSettings.saver;
    var saves = 0;
    NhentaiTagSettings.saver = () async => saves++;
    addTearDown(() => NhentaiTagSettings.saver = previousSaver);
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: NhSettings(false))));
    await tester.tap(find.text('默认排除标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'free text');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('标签格式无效'), findsOneWidget);
    expect(saves, 0);

    await tester.enterText(find.byType(TextFormField), '-tag:yaoi');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(source.data['multiTagDefaultExcludes'], '-tag:"yaoi"');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
