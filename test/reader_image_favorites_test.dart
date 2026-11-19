import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/components/scrollable_list/src/item_positions_listener.dart';
import 'package:pica_comic/components/scrollable_list/src/item_positions_notifier.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/network/download_progress.dart';
import 'package:pica_comic/pages/image_favorites.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/save_image.dart';
import 'package:pica_comic/tools/translations.dart';

class _FavoriteReadingData extends JmReadingData {
  _FavoriteReadingData(this.file, {bool singleChapter = false})
      : super('Favorite fixture', '123', singleChapter ? [] : ['ep-1', 'ep-2'],
            singleChapter ? [] : ['Chapter 1', 'Chapter 2']);

  final File file;
  Completer<void>? release;
  Object? error;
  int loadCount = 0;
  final started = Completer<(int, int, String)>();

  @override
  Stream<DownloadProgress> loadImage(int ep, int page, String url) async* {
    loadCount++;
    if (!started.isCompleted) started.complete((ep, page, url));
    if (release != null) await release!.future;
    if (error != null) throw error!;
    yield DownloadProgress(1, 1, url, file.path);
  }
}

class _SelectedReadingPage extends ComicReadingPage {
  _SelectedReadingPage(ReadingData data, this.selectedPage) : super(data, 1, 1);

  final int? selectedPage;

  @override
  Future<int?> selectImage() async => selectedPage;
}

class _FavoriteHtReadingData extends HtReadingData {
  _FavoriteHtReadingData(this.file)
      : super('WNACG fixture', 'series',
            {'chapter-1': 'Chapter 1', 'chapter-2': 'Chapter 2'});

  final File file;

  @override
  Stream<DownloadProgress> loadImage(int ep, int page, String url) async* {
    yield DownloadProgress(1, 1, url, file.path);
  }
}

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory root;
  late File source;
  late String oldReadingMode;
  late String oldSync;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-reader-favorites-');
    App.dataPath = root.path;
    source = File('${root.path}/fixture-image.png');
    await source.writeAsBytes([1, 2, 3, 4]);
  });

  setUp(() async {
    oldReadingMode = appdata.settings[9];
    oldSync = appdata.settings[45];
    appdata.settings[9] = '1';
    appdata.settings[45] = '';
    await HistoryManager().init(importLegacy: false);
  });

  tearDown(() async {
    hideAllMessages();
    final logic = StateController.findOrNull<ComicReadingPageLogic>();
    if (logic != null) {
      logic.releaseImageTasks();
      await logic.readerImages.waitForIdle();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.focusNode.dispose();
      StateController.remove<ComicReadingPageLogic>();
    }
    HistoryManager().close();
    await File('${root.path}/history.db').delete();
    appdata.settings[9] = oldReadingMode;
    appdata.settings[45] = oldSync;
  });

  tearDownAll(() => root.delete(recursive: true));

  Future<ComicReadingPageLogic> openToolbar(
      WidgetTester tester, ReadingData data,
      {int? selectedPage}) async {
    final page = _SelectedReadingPage(data, selectedPage);
    final initial = StateController.find<ComicReadingPageLogic>();
    initial.releaseImageTasks();
    initial.pageController.dispose();
    initial.scrollController.dispose();
    initial.focusNode.dispose();
    StateController.remove<ComicReadingPageLogic>();
    final logic = StateController.put(ComicReadingPageLogic(1, data, 1, () {})
      ..tools = true
      ..urls = ['url-1', 'url-2', 'url-3']);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: OverlayWidget(Scaffold(body: Builder(builder: (context) {
        return Stack(children: [page.buildBottomToolBar(logic, context, true)]);
      }))),
    ));
    return logic;
  }

  Future<void> pressFavorite(WidgetTester tester) async {
    final action = tester.widget<IconButton>(find.ancestor(
      of: find.byIcon(Icons.favorite_outline),
      matching: find.byType(IconButton),
    ));
    await (action.onPressed! as Future<void> Function())();
  }

  Future<ComicReadingPage> reopenFavorite(
      WidgetTester tester, ImageFavorite favorite) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [observer],
      home: const SizedBox.shrink(),
    ));
    FavoriteImageTile(favorite).onTap();
    final route = observer.latest! as AppPageRoute;
    // Inspect the destination before it starts loading remote chapter data.
    final page = route.builder(App.globalContext!) as ComicReadingPage;
    await tester.pumpWidget(const SizedBox.shrink());
    return page;
  }

  test('persisted images with the same download filename remain distinct',
      () async {
    final first = File('${root.path}/comic-a/1/0.jpg');
    final second = File('${root.path}/comic-b/2/0.jpg');
    await first.create(recursive: true);
    await second.create(recursive: true);
    await first.writeAsBytes([1, 2, 3]);
    await second.writeAsBytes([4, 5, 6]);

    final firstPath = await persistentCurrentImage(first);
    final secondPath = await persistentCurrentImage(second);

    expect(firstPath, isNot(secondPath));
    expect(await File(firstPath).readAsBytes(), [1, 2, 3]);
    expect(await File(secondPath).readAsBytes(), [4, 5, 6]);
    expect(await first.readAsBytes(), [1, 2, 3]);
    expect(await second.readAsBytes(), [4, 5, 6]);
  });

  test(
      'persisted images reuse identical bytes without overwriting legacy files',
      () async {
    final legacy = File('${root.path}/images/legacy.jpg');
    await legacy.create(recursive: true);
    await legacy.writeAsBytes([9, 9, 9]);
    final image = File('${root.path}/comic-c/legacy.jpg');
    await image.create(recursive: true);
    await image.writeAsBytes([7, 8, 9]);

    final saved = await persistentCurrentImage(image);

    expect(saved, isNot(legacy.path));
    expect(await File(saved).readAsBytes(), [7, 8, 9]);
    expect(await persistentCurrentImage(image), saved);
    expect(await legacy.readAsBytes(), [9, 9, 9]);
  });

  testWidgets('JM single chapter can be favorited and removed from the toolbar',
      (tester) async {
    final data = _FavoriteReadingData(source, singleChapter: true);
    await openToolbar(tester, data);
    await tester.runAsync(() => pressFavorite(tester));

    final favorite = ImageFavoriteManager.getAll().single;
    expect(favorite.id, 'jm-123');
    expect(favorite.ep, 1);
    expect(favorite.page, 1);
    expect(favorite.otherInfo['epsId'], '123');
    expect(favorite.otherInfo['url'], 'url-1');
    expect(
        await tester.runAsync(() =>
            File('${root.path}/images/${favorite.imagePath}').readAsBytes()),
        [1, 2, 3, 4]);

    await tester.runAsync(() => pressFavorite(tester));
    expect(ImageFavoriteManager.getAll(), isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('continuous selection stores the selected page and URL',
      (tester) async {
    appdata.settings[9] = '4';
    final data = _FavoriteReadingData(source);
    await openToolbar(tester, data, selectedPage: 2);
    await tester.runAsync(() => pressFavorite(tester));

    final favorite = ImageFavoriteManager.getAll().single;
    expect(await data.started.future, (1, 2, 'url-3'));
    expect(favorite.ep, 1);
    expect(favorite.page, 3);
    expect(favorite.otherInfo['url'], 'url-3');
    expect(favorite.otherInfo['epsId'], 'ep-1');
    await tester.pump(const Duration(seconds: 3));
  });

  test('continuous selection ignores stale visible image indexes', () async {
    final page = ComicReadingPage(_FavoriteReadingData(source), 1, 1);
    final logic = StateController.find<ComicReadingPageLogic>();
    logic.urls = ['url-1', 'url-2', 'url-3'];
    final positions = logic.itemScrollListener as ItemPositionsNotifier;

    positions.itemPositions.value = const [
      ItemPosition(index: 5, itemLeadingEdge: 0, itemTrailingEdge: 1),
    ];
    expect(await page.selectImage(), isNull);

    positions.itemPositions.value = const [
      ItemPosition(index: 1, itemLeadingEdge: 0, itemTrailingEdge: 1),
      ItemPosition(index: 6, itemLeadingEdge: 1, itemTrailingEdge: 2),
    ];
    expect(await page.selectImage(), 1);
  });

  testWidgets('turning a page while loading retains the saved image position',
      (tester) async {
    final data = (await tester.runAsync(() async =>
        _FavoriteReadingData(source)..release = Completer<void>()))!;
    final logic = await openToolbar(tester, data);
    await tester.runAsync(() async {
      final favorite = pressFavorite(tester);
      await data.started.future;
      logic.index = 2;
      data.release!.complete();
      await favorite;
    });

    final favorite = ImageFavoriteManager.getAll().single;
    expect(favorite.page, 1);
    expect(favorite.otherInfo['url'], 'url-1');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('repeated favorite actions share one pending operation',
      (tester) async {
    final data = (await tester.runAsync(() async =>
        _FavoriteReadingData(source)..release = Completer<void>()))!;
    await openToolbar(tester, data);
    await tester.runAsync(() async {
      final first = pressFavorite(tester);
      await data.started.future;
      final repeated = pressFavorite(tester);
      await Future<void>.delayed(Duration.zero);
      data.release!.complete();
      await Future.wait([first, repeated]);
    });

    expect(data.loadCount, 1);
    expect(ImageFavoriteManager.getAll(), hasLength(1));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('failed favorite action can retry without leaving a record',
      (tester) async {
    final data = _FavoriteReadingData(source)..error = StateError('fixture');
    await openToolbar(tester, data);
    await tester.runAsync(() => pressFavorite(tester));
    expect(ImageFavoriteManager.getAll(), isEmpty);

    data.error = null;
    await tester.runAsync(() => pressFavorite(tester));
    expect(data.loadCount, 2);
    expect(ImageFavoriteManager.getAll(), hasLength(1));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('reload permits a new favorite while an old image is pending',
      (tester) async {
    final data = (await tester.runAsync(() async =>
        _FavoriteReadingData(source)..release = Completer<void>()))!;
    final logic = await openToolbar(tester, data);
    await tester.runAsync(() async {
      final release = data.release!;
      final old = pressFavorite(tester);
      await data.started.future;
      logic.resetPreloadState();
      logic.index = 2;
      data.release = null;
      await pressFavorite(tester);
      release.complete();
      await old;
    });

    expect(data.loadCount, 2);
    final favorite = ImageFavoriteManager.getAll().single;
    expect(favorite.page, 2);
    expect(favorite.otherInfo['url'], 'url-2');
    await tester.pump(const Duration(seconds: 3));
  });

  for (final transition in ['chapter', 'reload', 'exit']) {
    testWidgets('$transition ignores a late favorite image error',
        (tester) async {
      final data =
          (await tester.runAsync(() async => _FavoriteReadingData(source)
            ..release = Completer<void>()
            ..error = StateError('late image fixture')))!;
      final logic = await openToolbar(tester, data);
      await tester.runAsync(() async {
        final pending = pressFavorite(tester);
        await data.started.future;
        switch (transition) {
          case 'chapter':
            logic.order = 2;
          case 'reload':
            logic.resetPreloadState();
          case 'exit':
            logic.dispose();
        }
        data.release!.complete();
        await pending;
      });
      await tester.pump();

      expect(ImageFavoriteManager.getAll(), isEmpty);
      expect(find.textContaining('late image fixture'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('WNACG favorites retain chapter IDs and names', (tester) async {
    final data = _FavoriteHtReadingData(source);
    final logic = await openToolbar(tester, data);
    logic.order = 2;
    await tester.runAsync(() => pressFavorite(tester));

    final favorite = ImageFavoriteManager.getAll().single;
    expect(favorite.ep, 2);
    expect(favorite.otherInfo['eps'], data.eps);
    await tester.pump(const Duration(seconds: 3));
  });

  for (final key in ['htManga', 'htmanga']) {
    for (final legacyList in [false, true]) {
      testWidgets('WNACG $key reopens saved chapter (legacy: $legacyList)',
          (tester) async {
        final chapters = {'chapter-1': 'Chapter 1', 'chapter-2': 'Chapter 2'};
        final favorite = ImageFavorite('$key-series', 'fixture.png', 'Series',
            2, 7, {'eps': legacyList ? chapters.keys.toList() : chapters});

        final page = await reopenFavorite(tester, favorite);
        expect(page.initialEp, 2);
        expect(page.initialPage, 7);
        expect(page.readingData.id, 'series');
        expect(page.readingData.hasEp, isTrue);
        expect(page.readingData.eps?.keys.toList(), chapters.keys.toList());
        if (!legacyList) expect(page.readingData.eps, chapters);
      });
    }
  }

  for (final eps in [
    null,
    <String, String>{},
    {'chapter': 'Chapter 1'}
  ]) {
    testWidgets('custom source favorites reopen with chapters $eps',
        (tester) async {
      final previousSources = ComicSource.sources;
      final source =
          ComicSource.named(name: 'Fixture', key: 'fixture', filePath: 'test');
      ComicSource.sources = [source];
      addTearDown(() => ComicSource.sources = previousSources);
      final favorite = ImageFavorite(
          'fixture-comic', 'fixture.png', 'Custom', 1, 4, {'eps': eps});

      final page = await reopenFavorite(tester, favorite);
      expect(page.initialPage, 4);
      expect(page.readingData.hasEp, eps?.isNotEmpty == true);
      expect(page.readingData.eps, eps?.isNotEmpty == true ? eps : null);
      expect((page.readingData as CustomReadingData).source, same(source));
    });
  }

  testWidgets('legacy WNACG single chapter favorite still reopens',
      (tester) async {
    const favorite = ImageFavorite(
        'htManga-comic', 'fixture.png', 'Single', 1, 4, {'eps': []});

    final page = await reopenFavorite(tester, favorite);
    expect(page.initialPage, 4);
    expect(page.readingData.hasEp, isFalse);
    expect(page.readingData.eps, isNull);
  });

  for (final transition in ['chapter', 'reload', 'exit']) {
    testWidgets('$transition during image loading does not create a favorite',
        (tester) async {
      final data = (await tester.runAsync(() async =>
          _FavoriteReadingData(source)..release = Completer<void>()))!;
      final logic = await openToolbar(tester, data);
      await tester.runAsync(() async {
        final favorite = pressFavorite(tester);
        await data.started.future;
        switch (transition) {
          case 'chapter':
            logic.order = 2;
          case 'reload':
            logic.resetPreloadState();
          case 'exit':
            logic.dispose();
        }
        data.release!.complete();
        await favorite;
      });

      expect(ImageFavoriteManager.getAll(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final selectedPage in [null, -1, 99]) {
    testWidgets('cancelled or invalid selection $selectedPage is ignored',
        (tester) async {
      appdata.settings[9] = '4';
      final data = _FavoriteReadingData(source);
      await openToolbar(tester, data, selectedPage: selectedPage);
      await tester.runAsync(() => pressFavorite(tester));

      expect(ImageFavoriteManager.getAll(), isEmpty);
      expect(data.started.isCompleted, isFalse);
    });
  }
}
