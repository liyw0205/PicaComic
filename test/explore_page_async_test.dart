import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/explore_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  final exploreKey = GlobalKey();

  void configure(List<String> pages) {
    final oldSources = ComicSource.sources;
    final oldPages = List<String>.from(appdata.appSettings.explorePages);
    ComicSource.sources = [
      ComicSource.named(
        name: 'test',
        key: 'explore-settings-test',
        filePath: 'test',
        explorePages: [
          for (final title in ['Page A', 'Page B', 'Page C'])
            ExplorePageData.named(
              title: title,
              type: ExplorePageType.override,
              overridePageBuilder: (_) => Center(child: Text('Content $title')),
            ),
        ],
      ),
    ];
    appdata.appSettings.explorePages = pages;
    addTearDown(() {
      ComicSource.sources = oldSources;
      appdata.appSettings.explorePages = oldPages;
    });
  }

  Widget host() => MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: ExplorePage(key: exploreKey)),
      );

  testWidgets('refresh ignores stale multipart results', (tester) async {
    final requests = <Completer<Res<List<ExplorePagePart>>>>[];
    var calls = 0;
    final source = ComicSource.named(
      name: 'test',
      key: 'explore-async-test',
      filePath: 'test',
      explorePages: [
        ExplorePageData.named(
          title: 'Async Explore',
          type: ExplorePageType.singlePageWithMultiPart,
          loadMultiPart: () {
            calls++;
            final request = Completer<Res<List<ExplorePagePart>>>();
            requests.add(request);
            return request.future;
          },
        ),
      ],
    );
    final oldSources = ComicSource.sources;
    final oldPages = List<String>.from(appdata.appSettings.explorePages);
    ComicSource.sources = [source];
    appdata.appSettings.explorePages = ['Async Explore'];
    addTearDown(() {
      ComicSource.sources = oldSources;
      appdata.appSettings.explorePages = oldPages;
    });

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const ExplorePage(),
    ));
    await tester.pump();
    expect(calls, 1);

    await tester.tap(find.byKey(const Key('FAB')));
    await tester.pump();
    expect(calls, 2);

    requests[0].complete(const Res([
      ExplorePagePart('stale', [], null),
    ]));
    await tester.pump();
    expect(find.text('stale'), findsNothing);

    requests[1].complete(const Res([
      ExplorePagePart('fresh', [], null),
    ]));
    await tester.pump();
    expect(find.text('fresh'), findsOneWidget);
  });

  testWidgets('explore tabs follow same-length settings reorder',
      (tester) async {
    configure(['Page A', 'Page B']);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ExplorePage));
    expect(
      tester.getTopLeft(find.text('Page A')).dx,
      lessThan(tester.getTopLeft(find.text('Page B')).dx),
    );

    await tester.tap(find.text('Page B'));
    await tester.pumpAndSettle();
    expect(find.text('Content Page B'), findsOneWidget);

    appdata.appSettings.explorePages = ['Page B', 'Page A'];
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Page B')).dx,
      lessThan(tester.getTopLeft(find.text('Page A')).dx),
    );
    expect(tester.state(find.byType(ExplorePage)), same(state));
    expect(tester.widget<TabBarView>(find.byType(TabBarView)).controller!.index,
        0);
    expect(find.text('Content Page B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty explore configuration has no refresh action',
      (tester) async {
    configure([]);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('FAB')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explore settings can become populated and empty again',
      (tester) async {
    configure([]);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    appdata.appSettings.explorePages = ['Page A', 'Page B'];
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Content Page A'), findsOneWidget);
    expect(find.byKey(const Key('FAB')), findsOneWidget);

    await tester.tap(find.text('Page B'));
    await tester.pumpAndSettle();
    expect(find.text('Content Page B'), findsOneWidget);

    appdata.appSettings.explorePages = [];
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Page A'), findsNothing);
    expect(find.text('Page B'), findsNothing);
    expect(find.byKey(const Key('FAB')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the selected explore tab selects an available page',
      (tester) async {
    configure(['Page A', 'Page B']);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Page B'));
    await tester.pumpAndSettle();

    appdata.appSettings.explorePages = ['Missing page', 'Page A'];
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('Missing page'), findsNothing);
    expect(find.text('Page B'), findsNothing);
    expect(find.text('Content Page A'), findsOneWidget);
    expect(tester.widget<TabBarView>(find.byType(TabBarView)).controller!.index,
        0);
    await tester.tap(find.byKey(const Key('FAB')));
    await tester.pumpAndSettle();
    expect(find.text('Content Page A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explore can reorder during a tab animation and then close',
      (tester) async {
    configure(['Page A', 'Page B']);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Page B'));
    await tester.pump(const Duration(milliseconds: 50));

    appdata.appSettings.explorePages = ['Page B', 'Page A'];
    await tester.pumpWidget(host());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
