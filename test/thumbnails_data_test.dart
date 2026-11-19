import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/state_controller.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _ThumbnailHistory extends HistoryManager {
  _ThumbnailHistory() : super.create();

  @override
  Future<History?> find(String target) async => null;
}

class _ThumbnailPage extends BaseComicPage<List<String>> {
  const _ThumbnailPage(this.load, this.loadMore);

  final List<String> Function() load;
  final Future<Res<List<String>>> Function(int) loadMore;

  @override
  String get tag => 'thumbnail-detail-fixture';

  @override
  String get id => 'comic';

  @override
  Future<Res<List<String>>> loadData() async => Res(load());

  @override
  Future<bool> loadFavorite(List<String> data) async => false;

  @override
  ThumbnailsData get thumbnailsCreator => ThumbnailsData(data!, loadMore, 2);

  @override
  Widget thumbnailImageBuilder(int index, String imageUrl) => Text(imageUrl);

  @override
  Widget buildLoading(BuildContext context) => const Text('Loading');

  @override
  Widget buildTitle(ComicPageLogic<List<String>> logic) =>
      const SliverToBoxAdapter(child: SizedBox.shrink());

  @override
  Widget buildComicInfo(
          ComicPageLogic<List<String>> logic, BuildContext context,
          [bool loaded = true]) =>
      const SliverToBoxAdapter(child: SizedBox.shrink());

  @override
  Widget buildTags(ComicPageLogic logic, BuildContext context) =>
      const SliverToBoxAdapter(child: SizedBox.shrink());

  @override
  List<Widget> buildEpisodeInfo(BuildContext context) => [];

  @override
  List<Widget> buildIntroduction(BuildContext context) => [];

  @override
  List<Widget> buildRecommendation(BuildContext context) => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  test('thumbnail decode dimensions follow display size and pixel ratio', () {
    expect(thumbnailCacheDimension(double.infinity, 120, 2), 240);
    expect(thumbnailCacheDimension(double.infinity, 80, 2), 160);
    expect(thumbnailCacheDimension(96, 120, 1.5), 144);
    expect(
        thumbnailCacheDimension(double.infinity, double.infinity, 2), isNull);
    expect(thumbnailCacheDimension(120, 80, double.nan), isNull);
  });

  test('thumbnail request failure releases the retry guard', () async {
    final requests = <int>[];
    var fail = true;
    final thumbnails = ThumbnailsData([], (page) async {
      requests.add(page);
      if (fail) {
        fail = false;
        throw StateError('temporary failure');
      }
      return const Res(['thumbnail'], subData: 2);
    }, 2);

    await expectLater(thumbnails.get(() {}), throwsStateError);
    expect(thumbnails.isGetting, isFalse);

    await thumbnails.get(() {});
    expect(requests, [2, 2]);
    expect(thumbnails.thumbnails, ['thumbnail']);
    expect(thumbnails.current, 2);
  });

  group('detail thumbnail lifecycle', () {
    late HistoryManager? previousHistory;
    late List<String> firstPage;
    late List<Completer<Res<List<String>>>> requests;
    late _ThumbnailPage page;

    setUp(() {
      previousHistory = HistoryManager.cache;
      HistoryManager.cache = _ThumbnailHistory();
      firstPage = ['Old first page'];
      requests = [];
      page = _ThumbnailPage(() => firstPage, (page) {
        expect(page, 2);
        final request = Completer<Res<List<String>>>();
        requests.add(request);
        return request.future;
      });
    });

    tearDown(() => HistoryManager.cache = previousHistory);

    Future<void> load(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: page,
      ));
      await load(tester);
      expect(requests, hasLength(1));
      final logic =
          StateController.find<ComicPageLogic<List<String>>>(tag: page.tag);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        logic.controller.dispose();
      });
    }

    void refresh() =>
        StateController.find<ComicPageLogic<List<String>>>(tag: page.tag)
            .refresh_();

    testWidgets('pagination appends without modifying the detail response',
        (tester) async {
      firstPage = const ['Immutable first page'];
      await open(tester);
      requests.single.complete(const Res(['Second page']));
      await tester.pump();

      expect(find.text('Immutable first page'), findsOneWidget);
      expect(find.text('Second page'), findsOneWidget);
      expect(firstPage, ['Immutable first page']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh replaces already loaded thumbnails', (tester) async {
      await open(tester);
      requests.single.complete(const Res(['Old second page']));
      await tester.pump();
      expect(find.text('Old second page'), findsOneWidget);
      firstPage = ['Fresh first page'];
      refresh();
      await load(tester);

      expect(find.text('Fresh first page'), findsOneWidget);
      expect(find.text('Old first page'), findsNothing);
      expect(find.text('Old second page'), findsNothing);
      expect(requests, hasLength(2));
      requests.last.complete(const Res(['Fresh second page']));
      await tester.pump();
      expect(find.text('Fresh second page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh can paginate before the previous page finishes',
        (tester) async {
      await open(tester);
      final oldPage = requests.single;
      firstPage = ['Fresh first page'];
      refresh();
      await load(tester);
      expect(requests, hasLength(2));
      oldPage.complete(const Res(['Stale second page']));
      await tester.pump();
      expect(find.text('Fresh first page'), findsOneWidget);
      expect(find.text('Stale second page'), findsNothing);
      requests.last.complete(const Res(['Fresh second page']));
      await tester.pump();
      expect(find.text('Fresh second page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('page request exceptions stay handled and retryable',
        (tester) async {
      await open(tester);
      requests.single.completeError(StateError('Thumbnail failed'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      StateController.find<ComicPageLogic<List<String>>>(tag: page.tag)
          .update();
      await tester.pump();
      expect(requests, hasLength(2));
      requests.last.complete(const Res(['Retried second page']));
      await tester.pump();
      expect(find.text('Retried second page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('late pages after closing leave source data untouched',
        (tester) async {
      await open(tester);
      final initial = firstPage;
      await tester.pumpWidget(const SizedBox.shrink());
      requests.single.complete(const Res(['Late second page']));
      await tester.pump();

      expect(initial, ['Old first page']);
      expect(find.text('Late second page'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
