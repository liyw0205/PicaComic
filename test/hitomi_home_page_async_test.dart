import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/hitomi/hitomi_home_page.dart';
import 'package:pica_comic/pages/hitomi/hitomi_search.dart';
import 'package:pica_comic/tools/translations.dart';

HitomiComicBrief _brief(int id) => HitomiComicBrief(
      'Comic $id',
      'Type',
      'Language',
      [],
      'Time',
      'Artist',
      'https://hitomi.la/galleries/$id.html',
      'https://example.test/$id.webp',
    );

ComicList _list(Iterable<int> ids, {int total = 100}) {
  final comics = ComicList('fixture')..total = total;
  comics.comicIds.addAll(ids);
  return comics;
}

class _TileRequests {
  final ids = <String>[];
  final responses = <Completer<Res<HitomiComicBrief>>>[];

  Future<Res<HitomiComicBrief>> load(String id) {
    ids.add(id);
    final response = Completer<Res<HitomiComicBrief>>();
    responses.add(response);
    return response.future;
  }

  Future<void> show(WidgetTester tester, int id) =>
      tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Center(
          child: SizedBox(
            width: 360,
            height: 180,
            child: HitomiComicTileDynamicLoading(id, loadComicInfoBrief: load),
          ),
        ),
      ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  test('initial request is coalesced while loading', () async {
    final response = Completer<Res<ComicList>>();
    var calls = 0;
    final logic = HitomiHomePageLogic(
      loadComics: (_) {
        calls++;
        return response.future;
      },
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    final first = logic.get('fixture');
    final duplicate = logic.get('fixture');
    expect(calls, 1);

    response.complete(Res(_list([1], total: 1)));
    await Future.wait([first, duplicate]);

    expect(logic.loading, isFalse);
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/1.html',
    ]);
  });

  test('refresh ignores an older request and keeps only the fresh result',
      () async {
    final requests = <Completer<Res<ComicList>>>[];
    final logic = HitomiHomePageLogic(
      loadComics: (_) {
        final request = Completer<Res<ComicList>>();
        requests.add(request);
        return request.future;
      },
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    final stale = logic.get('fixture');
    logic.refresh_();
    final fresh = logic.get('fixture');
    expect(requests, hasLength(2));

    requests[0].complete(Res(_list([1], total: 1)));
    await stale;
    expect(logic.loading, isTrue);
    expect(logic.hitomiComics, isEmpty);

    requests[1].complete(Res(_list([2], total: 1)));
    await fresh;
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/2.html',
    ]);
  });

  test('pagination coalesces duplicate tail requests', () async {
    final list = _list([1], total: 2);
    list.toLoad = 1;
    final nextPage = Completer<Res<bool>>();
    var nextCalls = 0;
    final logic = HitomiHomePageLogic(
      loadComics: (_) async => Res(list),
      loadNextPage: (current) {
        nextCalls++;
        current.comicIds.add(2);
        current.toLoad = 2;
        return nextPage.future;
      },
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    await logic.get('fixture');
    final first = logic.loadNextPage('fixture');
    final duplicate = logic.loadNextPage('fixture');
    expect(nextCalls, 1);

    nextPage.complete(const Res(true));
    await Future.wait([first, duplicate]);
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/1.html',
      'https://hitomi.la/galleries/2.html',
    ]);

    await logic.loadNextPage('fixture');
    expect(nextCalls, 1);
  });

  test('pagination restores its cursor when brief parsing fails', () async {
    final list = _list([1], total: 2);
    list.toLoad = 1;
    var nextCalls = 0;
    var briefCalls = 0;
    final logic = HitomiHomePageLogic(
      loadComics: (_) async => Res(list),
      loadNextPage: (current) async {
        nextCalls++;
        current.comicIds.add(2);
        current.toLoad = 2;
        return const Res(true);
      },
      loadComicInfoBrief: (id) async {
        if (id == '2' && briefCalls++ == 0) {
          return const Res.error('temporary failure');
        }
        return Res(_brief(int.parse(id)));
      },
    );

    await logic.get('fixture');
    await logic.loadNextPage('fixture');
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/1.html',
    ]);
    expect(list.toLoad, 1);
    expect(list.comicIds, isEmpty);

    await logic.loadNextPage('fixture');
    expect(nextCalls, 2);
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/1.html',
      'https://hitomi.la/galleries/2.html',
    ]);
  });

  test('disposed request cannot publish its result', () async {
    final response = Completer<Res<ComicList>>();
    final logic = HitomiHomePageLogic(
      loadComics: (_) => response.future,
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    final request = logic.get('fixture');
    logic.dispose();
    response.complete(Res(_list([1], total: 1)));
    await request;

    expect(logic.loading, isTrue);
    expect(logic.hitomiComics, isEmpty);
  });

  group('Hitomi dynamic tiles', () {
    late List<ComicSource> oldSources;
    late List<String> oldSettings;
    late List<String> oldBlockingKeywords;

    setUp(() {
      oldSources = ComicSource.sources;
      oldSettings = List.of(appdata.settings);
      oldBlockingKeywords = appdata.blockingKeyword;
      appdata.settings[44] = '0';
      appdata.blockingKeyword = [];
      ComicSource.sources = [
        ComicSource.named(
          name: 'Hitomi fixture',
          key: 'hitomi',
          filePath: 'test',
          comicTileBuilderOverride: (_, comic, __) => Text(comic.title),
        ),
      ];
    });

    tearDown(() {
      ComicSource.sources = oldSources;
      appdata.settings = oldSettings;
      appdata.blockingKeyword = oldBlockingKeywords;
    });

    testWidgets('ID changes load immediately and ignore all stale responses',
        (tester) async {
      final requests = _TileRequests();
      await requests.show(tester, 910001);
      final state = tester.state(find.byType(HitomiComicTileDynamicLoading));
      for (final id in [910002, 910003, 910004]) {
        await requests.show(tester, id);
        expect(tester.state(find.byType(HitomiComicTileDynamicLoading)),
            same(state));
      }
      expect(requests.ids, ['910001', '910002', '910003', '910004']);

      requests.responses[0].complete(Res(_brief(910001)));
      requests.responses[1].complete(const Res.error('stale failure'));
      requests.responses[2].completeError(StateError('stale exception'));
      await tester.pump();
      expect(find.byType(ComicTilePlaceholder), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.text('Comic 910001'), findsNothing);

      requests.responses[3].complete(Res(_brief(910004)));
      await tester.pump();
      expect(find.text('Comic 910004'), findsOneWidget);
      expect(find.byType(ComicTilePlaceholder), findsNothing);

      // An ignored success must not populate the shared cache.
      await requests.show(tester, 910001);
      expect(requests.ids, hasLength(5));
      requests.responses[4].complete(const Res.error('current failure'));
      await tester.pump();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('retry repaints, coalesces requests and preserves the new load',
        (tester) async {
      final requests = _TileRequests();
      await requests.show(tester, 920001);
      requests.responses[0].complete(const Res.error('temporary failure'));
      await tester.pump();
      final retry =
          tester.widget<IconButton>(find.byType(IconButton)).onPressed!;

      await tester.tap(find.byIcon(Icons.refresh));
      retry();
      await tester.pump();
      expect(requests.ids, ['920001', '920001']);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byType(ComicTilePlaceholder), findsOneWidget);

      requests.responses[1].completeError(StateError('temporary exception'));
      await tester.pump();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(requests.ids, hasLength(3));

      await requests.show(tester, 920002);
      expect(requests.ids.last, '920002');
      requests.responses[2].complete(Res(_brief(920001)));
      await tester.pump();
      retry();
      expect(requests.ids, hasLength(4));
      expect(find.byType(ComicTilePlaceholder), findsOneWidget);

      requests.responses[3].complete(Res(_brief(920002)));
      await tester.pump();
      expect(find.text('Comic 920002'), findsOneWidget);
      await requests.show(tester, 920002);
      expect(requests.ids, hasLength(4));

      await requests.show(tester, 920003);
      await requests.show(tester, 920002);
      expect(requests.ids, hasLength(5));
      expect(find.text('Comic 920002'), findsOneWidget);
      requests.responses[4].completeError(StateError('late cached transition'));
      await tester.pump();
      expect(find.text('Comic 920002'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('disposed tiles ignore success and thrown failures',
        (tester) async {
      final requests = _TileRequests();
      for (final id in [930001, 930002]) {
        await requests.show(tester, id);
        await tester.pumpWidget(const SizedBox.shrink());
        final response = requests.responses.last;
        if (id == 930001) {
          response.complete(Res(_brief(id)));
        } else {
          response.completeError(StateError('disposed failure'));
        }
        await tester.pump();
        final count = requests.ids.length;
        await requests.show(tester, id);
        expect(requests.ids, hasLength(count + 1));
        await tester.pumpWidget(const SizedBox.shrink());
        requests.responses.last.complete(const Res.error('disposed result'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });
  });
}
