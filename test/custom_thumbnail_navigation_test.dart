import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _ThumbnailHistory extends HistoryManager {
  _ThumbnailHistory() : super.create();

  final added = <History>[];
  Future<void> Function()? save;

  @override
  Future<History?> find(String target) async => null;

  @override
  Future<void> addHistory(History item) async {
    added.add(item);
    await save?.call();
  }
}

class _ThumbnailImages implements ImageManager {
  final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');

  @override
  Stream<DownloadProgress> getCustomThumbnail(String url, String sourceKey,
      [Map<String, String>? headers]) async* {
    yield DownloadProgress(1, 1, url, '', pixel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReaderRoutes extends NavigatorObserver {
  final routes = <AppPageRoute>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is AppPageRoute) routes.add(route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late List<ComicSource> previousSources;
  late HistoryManager? previousHistory;
  late ImageManager? previousImages;
  late _ThumbnailHistory historyStore;
  late _ReaderRoutes observer;
  late ComicSource source;
  late BaseComicPage<ComicInfoData> page;
  late ComicPageLogic<ComicInfoData> logic;
  var pageLoads = 0;

  setUp(() {
    previousSources = ComicSource.sources;
    previousHistory = HistoryManager.cache;
    previousImages = ImageManager.cache;
    historyStore = _ThumbnailHistory();
    HistoryManager.cache = historyStore;
    ImageManager.cache = _ThumbnailImages();
    observer = _ReaderRoutes();
    pageLoads = 0;
    source = ComicSource.named(
      name: 'Thumbnail fixture',
      key: 'thumbnail-fixture',
      filePath: 'fixture.js',
      loadComicPages: (id, ep) async {
        pageLoads++;
        return const Res.error('Reader should not load in this fixture');
      },
    );
    ComicSource.sources = [source];
  });

  tearDown(() {
    hideAllMessages();
    ComicSource.sources = previousSources;
    HistoryManager.cache = previousHistory;
    ImageManager.cache = previousImages;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final reader = StateController.findOrNull<ComicReadingPageLogic>();
    if (reader != null) {
      reader.releaseImageTasks();
      reader.pageController.dispose();
      reader.scrollController.dispose();
      reader.focusNode.dispose();
      StateController.remove<ComicReadingPageLogic>();
    }
  });

  Future<void> open(WidgetTester tester,
      {Map<String, String>? chapters, bool withHistory = false}) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [observer],
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(body: Builder(builder: (context) {
        page = const ComicPage(sourceKey: 'thumbnail-fixture', id: 'comic')
            .build(context) as BaseComicPage<ComicInfoData>;
        final comic = ComicInfoData(
            'Comic',
            '',
            '',
            '',
            {},
            chapters,
            ['thumb-1', 'thumb-2', 'thumb-3'],
            null,
            1,
            null,
            source.key,
            'comic');
        logic = StateController.put(
          ComicPageLogic<ComicInfoData>()
            ..data = comic
            ..loading = false
            ..history = withHistory
                ? History.fromModel(model: comic, ep: 2, page: 64)
                : null
            ..thumbnailsData = ThumbnailsData(
                List.of(comic.thumbnails!), (_) async => const Res([]), 1),
          tag: page.tag,
        );
        return CustomScrollView(slivers: page.buildThumbnails(context));
      })),
    ));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      logic.controller.dispose();
      StateController.remove<ComicPageLogic<ComicInfoData>>(page.tag);
    });
  }

  Future<void> tapThird(WidgetTester tester) async {
    await tester.tap(find.byType(InkWell).at(2));
    await tester.idle();
  }

  Future<ComicReadingPage> destination(WidgetTester tester) async {
    expect(observer.routes, hasLength(1));
    // Inspect the real destination before rendering starts any reader I/O.
    final reader =
        observer.routes.single.builder(App.globalContext!) as ComicReadingPage;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(pageLoads, 0);
    return reader;
  }

  for (final chapters in <Map<String, String>?>[
    null,
    {},
    {'ep-a': 'First', 'ep-b': 'Second'},
  ]) {
    testWidgets('thumbnail opens selected page with chapters=$chapters',
        (tester) async {
      await open(tester, chapters: chapters, withHistory: true);
      await tapThird(tester);
      final reader = await destination(tester);

      expect(reader.initialPage, 3);
      expect(reader.initialEp, 2);
      final data = reader.readingData as CustomReadingData;
      expect(data.source, same(source));
      expect(data.sourceKey, source.key);
      expect(data.id, 'comic');
      expect(data.title, 'Comic');
      expect(data.eps, chapters?.isNotEmpty == true ? chapters : null);
      expect(historyStore.added, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('thumbnail waits for a new history record before opening',
      (tester) async {
    final saved = Completer<void>();
    historyStore.save = () => saved.future;
    await open(tester);
    await tapThird(tester);

    expect(historyStore.added, hasLength(1));
    expect(historyStore.added.single.target, 'comic');
    expect(historyStore.added.single.type.value, source.intKey);
    expect(observer.routes, isEmpty);
    saved.complete();
    await tester.idle();
    final reader = await destination(tester);
    expect(reader.initialPage, 3);
    expect(StateController.find<ComicReadingPageLogic>().order, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history write failure does not open the reader', (tester) async {
    historyStore.save = () async => throw StateError('History failed');
    await open(tester);
    await tapThird(tester);

    expect(historyStore.added, hasLength(1));
    expect(observer.routes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final close in [false, true]) {
    testWidgets(
        'thumbnail ignores pending history after ${close ? 'close' : 'refresh'}',
        (tester) async {
      final saved = Completer<void>();
      historyStore.save = () => saved.future;
      await open(tester);
      await tapThird(tester);
      expect(historyStore.added, hasLength(1));
      if (close) {
        logic.dispose();
      } else {
        logic.refresh_();
      }
      saved.complete();
      await tester.idle();

      expect(observer.routes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in ['thumbnail', 'read', 'episode']) {
    testWidgets('reading ignores pending history after cached reload ($action)',
        (tester) async {
      final saved = Completer<void>();
      historyStore.save = () => saved.future;
      await open(tester, chapters: {'ep-a': 'First', 'ep-b': 'Second'});
      final comic = logic.data!;
      switch (action) {
        case 'thumbnail':
          await tapThird(tester);
        case 'read':
          page.read(logic.history);
          await tester.idle();
        case 'episode':
          page.eps!.onTap(1);
          await tester.idle();
      }
      expect(historyStore.added, hasLength(1));
      logic.refresh_();
      final reloaded = logic.get(
          () async => Res(comic), (_) async => false, () => comic.comicId);
      await tester.pump(const Duration(milliseconds: 300));
      await reloaded;
      expect(logic.data, same(comic));
      expect(logic.loading, isFalse);
      saved.complete();
      await tester.idle();

      expect(observer.routes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('normal reading still resumes the saved page', (tester) async {
    await open(tester,
        chapters: {'ep-a': 'First', 'ep-b': 'Second'}, withHistory: true);
    page.read(logic.history);
    await tester.idle();
    final reader = await destination(tester);
    expect(reader.initialPage, 64);
    expect(reader.initialEp, 2);
    expect(tester.takeException(), isNull);
  });
}
