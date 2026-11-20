import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/state_controller.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/pages/reader/reader_image_controller.dart';

class _ControlledImageProvider extends ImageProvider<_ControlledImageProvider> {
  _ControlledImageProvider(this.result);

  final Completer<ImageInfo> result;
  int loads = 0;

  @override
  Future<_ControlledImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
      _ControlledImageProvider key, ImageDecoderCallback decode) {
    loads++;
    return OneFrameImageStreamCompleter(result.future);
  }
}

class _ReadingData extends PicacgReadingData {
  _ReadingData(this.provider) : super('Reader test', 'reader-test', []);

  ImageProvider provider;

  @override
  ImageProvider createImageProvider(int ep, int page, String url,
          {ImageTaskScope? taskScope}) =>
      provider;
}

class _ControlledReadingData extends _ReadingData {
  _ControlledReadingData(this.loadEpResult)
      : super(_ControlledImageProvider(Completer<ImageInfo>()));

  final Future<Res<List<String>>> loadEpResult;

  @override
  Future<Res<List<String>>> loadEp(int ep) => loadEpResult;
}

class _ChapterReadingData extends PicacgReadingData {
  _ChapterReadingData(this.provider)
      : super('Reader test', 'reader-test', ['Chapter 1', 'Chapter 2']);

  final ImageProvider provider;

  @override
  Future<Res<List<String>>> loadEp(int ep) async =>
      Res(List.generate(ep == 1 ? 4 : 2, (index) => 'page-$index'));

  @override
  ImageProvider createImageProvider(int ep, int page, String url,
          {ImageTaskScope? taskScope}) =>
      provider;
}

class _ContinuousReadingData extends _ReadingData {
  _ContinuousReadingData(this.providers) : super(providers.first);

  final List<ImageProvider> providers;

  @override
  ImageProvider createImageProvider(int ep, int page, String url,
          {ImageTaskScope? taskScope}) =>
      providers[page];
}

class _ReusableImageProvider extends ImageProvider<_ReusableImageProvider> {
  _ReusableImageProvider(this.result);

  Completer<ImageInfo> result;

  @override
  Future<_ReusableImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          _ReusableImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(result.future.then(
          (info) => ImageInfo(image: info.image.clone(), scale: info.scale)));
}

class _ScopedContinuousReadingData extends PicacgReadingData {
  _ScopedContinuousReadingData(this.createProvider)
      : super('Reader test', 'scoped-reader-test', []);

  final ReaderImageProviderBuilder createProvider;

  @override
  ImageProvider createImageProvider(int ep, int page, String url,
          {ImageTaskScope? taskScope}) =>
      createProvider(page, taskScope!);
}

void main() {
  tearDown(() {
    ComicImage.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  for (final fixture in [
    (name: 'final chapter', chapters: true, ep: 2, page: 2, count: 2),
    (name: 'middle chapter', chapters: true, ep: 1, page: 2, count: 3),
    (name: 'first page', chapters: true, ep: 1, page: 1, count: 2),
    (name: 'single gallery', chapters: false, ep: 1, page: 3, count: 3),
  ]) {
    test('reader history persists ${fixture.name} and resumes after reopening',
        () async {
      final root = await Directory.systemTemp.createTemp('reader-history-');
      final databasePath = '${root.path}/history.db';
      final previousHistory = HistoryManager.cache;
      final previousSync = appdata.settings[45];
      final store = HistoryManager.create();
      HistoryManager.cache = store;
      appdata.settings[45] = '';
      addTearDown(() async {
        await DataMaintenance.waitForIdle();
        store.close();
        HistoryManager.cache = previousHistory;
        appdata.settings[45] = previousSync;
        await root.delete(recursive: true);
      });
      await store.init(databasePath: databasePath, importLegacy: false);
      await store.addHistory(History(
        fixture.chapters ? HistoryType.picacg : HistoryType.nhentai,
        DateTime(2026, 1, 1),
        'Reader history fixture',
        '',
        '',
        0,
        0,
        'reader-history',
      ));
      final ReadingData data = fixture.chapters
          ? PicacgReadingData(
              'Reader history fixture', 'reader-history', ['First', 'Last'])
          : NhentaiReadingData('Reader history fixture', 'reader-history');

      void releaseReader() {
        final logic = StateController.findOrNull<ComicReadingPageLogic>();
        if (logic == null) return;
        logic.releaseImageTasks();
        logic.pageController.dispose();
        logic.scrollController.dispose();
        logic.focusNode.dispose();
        logic.clearPhotoViewControllers();
        StateController.remove<ComicReadingPageLogic>();
      }

      addTearDown(releaseReader);
      ComicReadingPage(data, 1, 1);
      StateController.find<ComicReadingPageLogic>()
        ..order = fixture.ep
        ..urls = List.generate(fixture.count, (index) => 'page-$index')
        ..index = fixture.page;
      await DataMaintenance.waitForIdle();
      releaseReader();
      store.close();
      await store.init(databasePath: databasePath, importLegacy: false);

      final saved = store.findSync('reader-history')!;
      final isFirstPage = fixture.ep == 1 && fixture.page == 1;
      expect(saved.ep, isFirstPage ? 0 : fixture.ep);
      expect(saved.page, isFirstPage ? 0 : fixture.page);
      expect(saved.maxPage, fixture.count);

      final reopened = ComicReadingPage(data, saved.page, saved.ep);
      final resumed = StateController.find<ComicReadingPageLogic>();
      expect(resumed.order, fixture.ep);
      expect(resumed.index, fixture.page);
      expect(reopened.history!.page, saved.page);
    });
  }

  testWidgets(
      'continuous reader keeps unloaded pages during backward scrolling',
      (tester) async {
    final oldMode = appdata.settings[9];
    final oldPreload = appdata.settings[28];
    appdata.settings[9] = '4';
    appdata.settings[28] = '0';
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      appdata.settings[9] = oldMode;
      appdata.settings[28] = oldPreload;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.red, BlendMode.src);
    final picture = recorder.endRecording();
    final info = ImageInfo(image: picture.toImageSync(100, 150));
    picture.dispose();
    addTearDown(info.dispose);
    final tallRecorder = ui.PictureRecorder();
    ui.Canvas(tallRecorder).drawColor(Colors.green, BlendMode.src);
    final tallPicture = tallRecorder.endRecording();
    final tallInfo = ImageInfo(image: tallPicture.toImageSync(100, 800));
    tallPicture.dispose();
    addTearDown(tallInfo.dispose);
    final results = List.generate(15, (_) => Completer<ImageInfo>());
    for (final index in [0, 1, 10, 11, 12, 13, 14]) {
      results[index].complete(info);
    }
    final imageProviders = <_ReusableImageProvider>[
      for (final result in results) _ReusableImageProvider(result),
    ];
    final data = _ContinuousReadingData(imageProviders);
    final page = ComicReadingPage(data, 1, 1);
    final registered = StateController.find<ComicReadingPageLogic>();
    registered.releaseImageTasks();
    registered.pageController.dispose();
    registered.scrollController.dispose();
    StateController.remove<ComicReadingPageLogic>();
    final logic = ComicReadingPageLogic(1, data, 11, () {})
      ..urls = List.generate(15, (index) => 'page-$index');
    addTearDown(() async {
      logic.releaseImageTasks();
      await logic.readerImages.waitForIdle();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.clearPhotoViewControllers();
    });
    await tester.pumpWidget(MaterialApp(
      home: StateBuilder<ComicReadingPageLogic>(
        init: logic,
        builder: (value) => Builder(
          builder: (context) => Stack(children: [
            page.buildComicView(value, context, data.id),
          ]),
        ),
      ),
    ));
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    logic.scrollController.jumpTo(5040);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(logic.index, 11);
    }
    expect(results.take(2).every((result) => result.isCompleted), isTrue);
    expect(
      results.skip(2).take(8).every((result) => !result.isCompleted),
      isTrue,
    );
    expect(
      results.skip(10).every((result) => result.isCompleted),
      isTrue,
    );
    expect(logic.readerImages.pageHeight(10, 400), 600);
    for (var index = 2; index < 10; index++) {
      expect(logic.readerImages.pageHeight(index, 400), 480);
    }

    final gesture = await tester.startGesture(const Offset(200, 250));
    final dragging = <int>[];
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(const Offset(0, 70));
      await tester.pump(const Duration(milliseconds: 16));
      dragging.add(logic.index);
    }
    await gesture.up();
    final pageBeforeImageArrives = logic.index;
    expect(pageBeforeImageArrives, 9);
    results[9].complete(tallInfo);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(logic.index, inInclusiveRange(8, 10));
    expect(logic.readerImages.pageHeight(9, 400), 3200);
    final pages = <int>[];
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      pages.add(logic.index);
    }
    expect(dragging, everyElement(inInclusiveRange(9, 11)),
        reason: '$dragging');
    expect(pages, everyElement(inInclusiveRange(9, 12)), reason: '$pages');
    expect(pages.skip(10).toSet(), hasLength(1), reason: '$pages');
    logic.jumpToPage(1);
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(logic.readerImages.contains(10), isFalse);
    expect(logic.readerImages.pageHeight(10, 400), 600);
    logic.jumpToPage(11);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(logic.index, 11);
    }
    expect(tester.takeException(), isNull);
    logic.releaseImageTasks();
    await logic.readerImages.waitForIdle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('continuous reader resumes visible streams after rapid reversals',
      (tester) async {
    final oldMode = appdata.settings[9];
    final oldPreload = appdata.settings[28];
    appdata.settings[9] = '4';
    appdata.settings[28] = '3';
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    final loads = <({
      int index,
      ImageTaskScope scope,
      StreamController<DownloadProgress> source,
    })>[];
    final data = _ScopedContinuousReadingData((index, scope) {
      return StreamImageProvider(() {
        final source = StreamController<DownloadProgress>();
        loads.add((index: index, scope: scope, source: source));
        return source.stream;
      }, 'rapid-reversal-$index', taskScope: scope);
    });
    final page = ComicReadingPage(data, 1, 1);
    final registered = StateController.find<ComicReadingPageLogic>();
    registered.releaseImageTasks();
    registered.pageController.dispose();
    registered.scrollController.dispose();
    registered.focusNode.dispose();
    StateController.remove<ComicReadingPageLogic>();
    final logic = ComicReadingPageLogic(1, data, 1, () {})
      ..urls = List.generate(40, (index) => 'page-$index');
    addTearDown(() async {
      logic.releaseImageTasks();
      await logic.readerImages.waitForIdle();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.clearPhotoViewControllers();
      logic.focusNode.dispose();
      StateController.remove<ComicReadingPageLogic>();
      for (final load in loads) {
        unawaited(load.source.close());
      }
      appdata.settings[9] = oldMode;
      appdata.settings[28] = oldPreload;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      BaseImageProvider.clearCache();
    });
    await tester.pumpWidget(MaterialApp(
      home: StateBuilder<ComicReadingPageLogic>(
        init: logic,
        builder: (value) => Builder(
          builder: (context) => Stack(
            children: [page.buildComicView(value, context, data.id)],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (var turn = 0; turn < 3; turn++) {
      final gesture = await tester.startGesture(const Offset(200, 400));
      for (var step = 0; step < 16; step++) {
        await gesture.moveBy(const Offset(0, -280));
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (var step = 0; step < 15; step++) {
        await gesture.moveBy(const Offset(0, 280));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }
    expect(loads.any((load) => load.scope.isCancelled), isTrue,
        reason: 'the gestures must release real reader requests');
    final (first, count) = logic.visibleImageRange;
    expect(count, greaterThan(0));
    for (var index = first; index < first + count; index++) {
      expect(
        loads.any((load) => load.index == index && load.scope.isCancelled),
        isTrue,
        reason: 'visible page $index must revisit a cancelled request',
      );
      expect(
        loads.any((load) =>
            load.index == index &&
            !load.scope.isCancelled &&
            load.source.hasListener),
        isTrue,
        reason: 'visible page $index must have a live download after stopping',
      );
    }
    final bytes = Uint8List.fromList(
        image.encodePng(image.Image(width: 400, height: 480)));
    for (final load in loads.toList()) {
      if (load.scope.isCancelled || !load.source.hasListener) continue;
      load.source.add(DownloadProgress(1, 1, '', '', bytes));
      unawaited(load.source.close());
    }
    for (var frame = 0; frame < 30; frame++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    for (var index = first; index < first + count; index++) {
      final provider = logic.readerImages.imageFor(index);
      final widget = find.byWidgetPredicate((widget) =>
          widget is ComicImage && identical(widget.image, provider));
      expect(widget, findsOneWidget);
      final rendered =
          find.descendant(of: widget, matching: find.byType(RawImage));
      expect(rendered, findsOneWidget,
          reason: 'visible page $index must render the completed download');
      expect(tester.widget<RawImage>(rendered).image, isNotNull);
    }
    expect(tester.takeException(), isNull);
    logic.releaseImageTasks();
    await logic.readerImages.waitForIdle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long page keeps its ratio while reloading and after an error',
      (tester) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final info = ImageInfo(image: picture.toImageSync(100, 400));
    picture.dispose();
    addTearDown(info.dispose);
    final provider = _ReusableImageProvider(Completer<ImageInfo>());
    Widget view(double width) => MaterialApp(
          home: SingleChildScrollView(
            child: Center(
              child: ComicImage(
                image: provider,
                width: width,
                height: width * 1.2,
              ),
            ),
          ),
        );
    await tester.pumpWidget(view(200));
    expect(tester.getSize(find.byType(ComicImage)).height, 240);
    provider.result.complete(info);
    await tester.pump();
    expect(tester.getSize(find.byType(ComicImage)).height, 800);

    await tester.pumpWidget(const SizedBox());
    await provider.evict();
    provider.result = Completer<ImageInfo>();
    await tester.pumpWidget(view(200));
    expect(tester.getSize(find.byType(ComicImage)).height, 800);
    provider.result.completeError(StateError('reload failed'));
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.getSize(find.byType(ComicImage)).height, 800);
    await tester.pumpWidget(view(100));
    expect(tester.getSize(find.byType(ComicImage)).height, 400);

    await provider.evict();
    provider.result = Completer<ImageInfo>();
    await tester.tap(find.text('Retry'));
    provider.result.complete(info);
    await tester.pump();
    expect(find.text('Retry'), findsNothing);
    expect(tester.getSize(find.byType(ComicImage)).height, 400);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed precache clears its marker so a later build can retry',
      (tester) async {
    final oldCount = appdata.settings[28];
    appdata.settings[28] = '1';
    addTearDown(() => appdata.settings[28] = oldCount);
    final result = Completer<ImageInfo>();
    final data = _ReadingData(_ControlledImageProvider(result));
    final page = ComicReadingPage(data, 1, 1);
    final logic = ComicReadingPageLogic(1, data, 1, () {})
      ..urls = ['first', 'second'];
    addTearDown(() {
      logic.releaseImageTasks();
      StateController.remove<ComicReadingPageLogic>();
    });
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));

    page.precacheComicImage(logic, context, 1, data.id);
    expect(logic.requestedLoadingItems[1], isTrue);
    logic.readerImages.setScrolling(true);
    result.completeError(StateError('First image request failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    expect(logic.requestedLoadingItems[1], isFalse);
  });

  testWidgets('scroll end retries a failed preload in the retained window',
      (tester) async {
    final oldMode = appdata.settings[9];
    final oldPreload = appdata.settings[28];
    appdata.settings[9] = '4';
    appdata.settings[28] = '1';
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      appdata.settings[9] = oldMode;
      appdata.settings[28] = oldPreload;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final bytes = Uint8List.fromList(
      image.encodePng(image.Image(width: 400, height: 480)),
    );
    final visibleProviders = [
      _RetryBaseImageProvider(bytes, id: 'visible-0', failFirst: false),
      _RetryBaseImageProvider(bytes, id: 'visible-1', failFirst: false),
    ];
    final failGate = Completer<void>();
    final retryProvider = _RetryBaseImageProvider(
      bytes,
      id: 'preload-2',
      firstLoadGate: failGate,
    );
    final data = _ContinuousReadingData([
      ...visibleProviders,
      retryProvider,
      _RetryBaseImageProvider(bytes, id: 'page-3', failFirst: false),
      _RetryBaseImageProvider(bytes, id: 'page-4', failFirst: false),
    ]);
    final page = ComicReadingPage(data, 1, 1);
    final logic = StateController.find<ComicReadingPageLogic>()
      ..urls = List.generate(5, (index) => 'page-$index');
    addTearDown(() {
      logic.releaseImageTasks();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.clearPhotoViewControllers();
      StateController.remove<ComicReadingPageLogic>();
    });
    await tester.pumpWidget(MaterialApp(
      home: StateBuilder<ComicReadingPageLogic>(
        init: logic,
        builder: (value) => Builder(
          builder: (context) => Stack(
            children: [page.buildComicView(value, context, data.id)],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(retryProvider.loads, 1);
    expect(logic.requestedLoadingItems[2], isTrue);

    final imageElement = tester.element(find.byType(ComicImage).first);
    ScrollEndNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 0,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: imageElement,
    ).dispatch(imageElement);
    failGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(retryProvider.loads, 2);
    expect(logic.requestedLoadingItems[2], isTrue);
    expect(tester.takeException(), isNull);
    logic.releaseImageTasks();
    await logic.readerImages.waitForIdle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('preloads pages in the current scroll direction', (tester) async {
    final controller = ReaderImageController(maxConcurrent: 4);
    addTearDown(() async {
      controller.dispose();
      await controller.waitForIdle();
    });
    final providers = <int, _ControlledImageProvider>{};
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));

    controller.configure(
      context: context,
      imageCount: 40,
      firstVisible: 10,
      visibleCount: 1,
      preloadCount: 4,
      createProvider: (index, _) => providers.putIfAbsent(
        index,
        () => _ControlledImageProvider(Completer<ImageInfo>()),
      ),
    );
    expect(providers.keys, orderedEquals([11, 12, 13, 14]));

    controller.setScrolling(true);
    controller.updateWindow(8);

    expect(controller.contains(4), isTrue);
    expect(controller.activePreloads, 0,
        reason: 'obsolete forward preloads must release their slots');
    expect(providers.keys, orderedEquals([11, 12, 13, 14]),
        reason: 'new speculative loads wait until scrolling stops');

    controller.setScrolling(false);
    expect(providers.keys, orderedEquals([11, 12, 13, 14, 7, 6, 5, 4]));
    expect(controller.activePreloads, 4);

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.red, BlendMode.src);
    final picture = recorder.endRecording();
    final info = ImageInfo(image: picture.toImageSync(1, 1));
    picture.dispose();
    for (final provider in providers.values) {
      provider.result.complete(info.clone());
    }
    await tester.pumpAndSettle();
    expect(controller.activePreloads, 0);
    controller.dispose();
    await controller.waitForIdle();
    info.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('window reports cancelled providers inside the retained range',
      (tester) async {
    final controller = ReaderImageController();
    final scopes = <int, ImageTaskScope>{};
    final sources = <int, StreamController<DownloadProgress>>{};
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    addTearDown(() async {
      controller.dispose();
      await controller.waitForIdle();
      for (final source in sources.values) {
        await source.close();
      }
      await tester.pumpWidget(const SizedBox());
    });

    controller.configure(
      context: context,
      imageCount: 5,
      firstVisible: 1,
      visibleCount: 1,
      preloadCount: 3,
      createProvider: (index, scope) => StreamImageProvider(() {
        scopes[index] = scope;
        final source = StreamController<DownloadProgress>();
        sources[index] = source;
        return source.stream;
      }, 'retained-window-$index', taskScope: scope),
    );
    await tester.pump();
    expect(scopes.keys, unorderedEquals([2, 3, 4]));
    final previousProvider = controller.imageFor(2);
    final previousScope = scopes[2]!;

    controller.setScrolling(true);
    final changed = controller.updateWindow(3);

    expect(controller.contains(2), isTrue,
        reason: 'the page remains in the retained range');
    expect(previousScope.isCancelled, isTrue,
        reason: 'the page is no longer visible or a directional candidate');
    expect(controller.imageFor(2), isNot(same(previousProvider)),
        reason: 'a replacement scope is required when the page is revisited');
    expect(changed, isTrue,
        reason: 'callers must rebuild after an active provider is cancelled');
  });

  testWidgets('stalled preload retries once after scrolling stops',
      (tester) async {
    final controller = ReaderImageController(
      maxConcurrent: 1,
      stalledLoadTimeout: const Duration(seconds: 15),
    );
    final scopes = <ImageTaskScope>[];
    final sources = <StreamController<DownloadProgress>>[];
    final loads = <int, int>{};
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    addTearDown(() async {
      controller.dispose();
      await controller.waitForIdle();
    });

    controller.configure(
      context: context,
      imageCount: 4,
      firstVisible: 1,
      visibleCount: 1,
      preloadCount: 1,
      createProvider: (index, scope) {
        scopes.add(scope);
        return StreamImageProvider(() {
          loads[index] = (loads[index] ?? 0) + 1;
          final source = StreamController<DownloadProgress>();
          sources.add(source);
          return source.stream;
        }, 'stalled-preload-$index', taskScope: scope);
      },
    );
    await tester.pump();
    expect(loads[2], 1);

    controller.setScrolling(true);
    await tester.pump(const Duration(seconds: 30));
    expect(loads[2], 1,
        reason: 'preloads must not restart while the reader is moving');
    sources.first.add(DownloadProgress.inProgress(10, 100, '', ''));
    await tester.pump();

    controller.setScrolling(false);
    await tester.pump(const Duration(seconds: 14));
    expect(loads[2], 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(loads[2], 2);
    expect(scopes.first.isCancelled, isTrue);
    expect(scopes.last.isCancelled, isFalse);
    expect(controller.requested[2], isTrue);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(loads[2], 2,
        reason: 'one stalled recovery per idle cycle must remain bounded');
    expect(controller.requested[2], isFalse);
    expect(controller.activePreloads, 0);

    controller.setScrolling(true);
    controller.setScrolling(false);
    await tester.pump();
    expect(loads[2], 3,
        reason: 'a later user scroll must rearm the bounded recovery');
    expect(tester.takeException(), isNull);
    final bytes = Uint8List.fromList(
      image.encodePng(image.Image(width: 1, height: 1)),
    );
    sources.last
        .add(DownloadProgress(bytes.length, bytes.length, '', '', bytes));
    unawaited(sources.last.close());
    for (var frame = 0; frame < 20 && controller.activePreloads > 0; frame++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
    expect(controller.activePreloads, 0);
    controller.dispose();
    await controller.waitForIdle();
  });

  testWidgets('stalled preload replaces the mounted image provider',
      (tester) async {
    final providers = <_ControlledImageProvider>[];
    final scopes = <ImageTaskScope>[];
    final data = _ReadingData(_ControlledImageProvider(Completer<ImageInfo>()));
    final logic = ComicReadingPageLogic(1, data, 1, () {})
      ..urls = ['visible', 'preload'];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      logic.releaseImageTasks();
      await logic.readerImages.waitForIdle();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.focusNode.dispose();
      StateController.remove<ComicReadingPageLogic>();
    });

    await tester.pumpWidget(MaterialApp(
      home: StateBuilder<ComicReadingPageLogic>(
        init: logic,
        builder: (value) => Builder(builder: (context) {
          value.readerImages.configure(
            context: context,
            imageCount: value.urls.length,
            firstVisible: 0,
            visibleCount: 1,
            preloadCount: 1,
            onImagesChanged: value.update,
            createProvider: (index, scope) {
              final provider = _ControlledImageProvider(Completer<ImageInfo>());
              providers.add(provider);
              scopes.add(scope);
              return provider;
            },
          );
          return ComicImage(
            key: const ValueKey('mounted-preload'),
            image: value.readerImages.imageFor(1),
            width: 100,
            height: 120,
          );
        }),
      ),
    ));
    expect(providers, hasLength(1));
    final previousProvider = logic.readerImages.imageFor(1);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();

    expect(providers, hasLength(2));
    expect(providers.first.loads, 1);
    expect(providers.last.loads, 1);
    expect(scopes.first.isCancelled, isTrue);
    expect(scopes.last.isCancelled, isFalse);
    final currentProvider = logic.readerImages.imageFor(1);
    expect(currentProvider, isNot(same(previousProvider)));
    expect(
      tester
          .widget<ComicImage>(find.byKey(const ValueKey('mounted-preload')))
          .image,
      same(currentProvider),
      reason: 'the mounted image must switch to the replacement scope',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    logic.releaseImageTasks();
    await logic.readerImages.waitForIdle();
  });

  testWidgets('twenty builds schedule three concurrent preloads once',
      (tester) async {
    final controller = ReaderImageController();
    addTearDown(() async {
      controller.dispose();
      await controller.waitForIdle();
    });
    final providers = <int, _ControlledImageProvider>{};
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    for (var i = 0; i < 20; i++) {
      controller.configure(
        context: context,
        imageCount: 40,
        firstVisible: 0,
        visibleCount: 1,
        preloadCount: 15,
        createProvider: (index, _) => providers.putIfAbsent(
            index, () => _ControlledImageProvider(Completer<ImageInfo>())),
      );
    }

    expect(controller.activePreloads, 3);
    expect(providers.keys, orderedEquals([1, 2, 3]));
    expect(providers.values.map((provider) => provider.loads), everyElement(1));
    expect(controller.contains(16), isFalse);
    expect(controller.contains(15), isTrue);

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.red, BlendMode.src);
    final picture = recorder.endRecording();
    final info = ImageInfo(image: picture.toImageSync(1, 1));
    picture.dispose();
    for (final provider in providers.values) {
      provider.result.complete(info.clone());
    }
    await tester.pump();
    controller.dispose();
    await controller.waitForIdle();
    info.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retry after an image failure reaches the provider again',
      (tester) async {
    final controller = ReaderImageController(maxConcurrent: 1);
    addTearDown(() async {
      controller.dispose();
      await controller.waitForIdle();
    });
    final provider = _RetryBaseImageProvider(
      Uint8List.fromList(image.encodePng(image.Image(width: 1, height: 1))),
    );
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    void configure() => controller.configure(
          context: context,
          imageCount: 2,
          firstVisible: 0,
          visibleCount: 1,
          preloadCount: 1,
          createProvider: (_, __) => provider,
        );
    configure();
    controller.setScrolling(true);
    await tester.pumpAndSettle();
    expect(controller.requested[1], isFalse);

    configure();
    await tester.pumpAndSettle();
    expect(provider.loads, 2);
    expect(controller.requested[1], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old chapter failure cannot clear the new chapter marker',
      (tester) async {
    final controller = ReaderImageController(maxConcurrent: 1);
    addTearDown(() async {
      controller.dispose();
      await controller.waitForIdle();
    });
    final previous = Completer<ImageInfo>();
    final next = Completer<ImageInfo>();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    void configure(Completer<ImageInfo> result) => controller.configure(
          context: context,
          imageCount: 2,
          firstVisible: 0,
          visibleCount: 1,
          preloadCount: 1,
          createProvider: (_, __) => _ControlledImageProvider(result),
        );
    configure(previous);
    final previousGeneration = controller.generation;
    controller.reset();
    configure(next);
    previous.completeError(StateError('old chapter fails late'));
    await tester.pump();

    expect(controller.generation, greaterThan(previousGeneration));
    expect(controller.requested[1], isTrue);
    expect(controller.activePreloads, 1);

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.red, BlendMode.src);
    final picture = recorder.endRecording();
    next.complete(ImageInfo(image: picture.toImageSync(1, 1)));
    picture.dispose();
    await tester.pump();
    controller.dispose();
    await controller.waitForIdle();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test('dual page resume uses the spread containing the requested image', () {
    final previousMode = appdata.settings[9];
    final previousFirst = appdata.implicitData[1];
    addTearDown(() {
      appdata.settings[9] = previousMode;
      appdata.implicitData[1] = previousFirst;
    });
    final data = _ReadingData(_ControlledImageProvider(Completer<ImageInfo>()));
    for (final mode in ['5', '6']) {
      appdata.settings[9] = mode;
      for (final firstSingle in [false, true]) {
        appdata.implicitData[1] = firstSingle ? '1' : '0';
        for (var requested = 1; requested <= 6; requested++) {
          final logic = ComicReadingPageLogic(1, data, requested, () {});
          final (first, count) = logic.visibleImageRange;
          expect(requested - 1, inInclusiveRange(first, first + count - 1));
          expect(logic.pageController.initialPage,
              firstSingle ? requested ~/ 2 + 1 : (requested + 1) ~/ 2);
          logic.releaseImageTasks();
          logic.pageController.dispose();
        }
      }
    }
  });

  test('previous chapter transition records the end-page intent', () {
    final oldMode = appdata.settings[9];
    addTearDown(() => appdata.settings[9] = oldMode);
    appdata.settings[9] = '1';
    final data =
        PicacgReadingData('Reader test', 'reader-test', ['one', 'two']);
    final logic = ComicReadingPageLogic(2, data, 1, () {})..isLoading = false;
    addTearDown(() {
      logic.releaseImageTasks();
      logic.pageController.dispose();
    });

    logic.jumpToLastChapter(jumpToLast: true);
    expect(logic.order, 1);
    expect(logic.jumpToLastPageOnChapterLoad, isTrue);

    // A normal chapter selection must clear a stale request.
    logic.jumpToChapter(2);
    expect(logic.jumpToLastPageOnChapterLoad, isFalse);
  });

  for (final forward in [true, false]) {
    test(
        'chapter changes ignore repeated ${forward ? 'next' : 'previous'} input',
        () async {
      final oldMode = appdata.settings[9];
      addTearDown(() => appdata.settings[9] = oldMode);
      appdata.settings[9] = '1';
      final result = Completer<Res<List<String>>>();
      final data = _ControlledReadingData(result.future)
        ..eps.addAll({
          for (final name in ['one', 'two', 'three', 'four']) name: name
        });
      final startingChapter = forward ? 2 : 3;
      final page = ComicReadingPage(data, 1, startingChapter);
      final registered = StateController.find<ComicReadingPageLogic>();
      registered.releaseImageTasks();
      registered.pageController.dispose();
      registered.scrollController.dispose();
      registered.focusNode.dispose();
      StateController.remove<ComicReadingPageLogic>();
      final logic = ComicReadingPageLogic(startingChapter, data, 1, () {})
        ..isLoading = false
        ..urls = ['old-page'];
      final controllers = <PageController>{logic.pageController};
      Future<void>? pending;
      addTearDown(() async {
        logic.releaseImageTasks();
        if (!result.isCompleted) result.complete(const Res(<String>[]));
        await pending;
        for (final controller in controllers) {
          controller.dispose();
        }
        logic.scrollController.dispose();
        logic.focusNode.dispose();
        logic.clearPhotoViewControllers();
      });

      void changeChapter() {
        if (forward) {
          logic.jumpToNextChapter();
        } else {
          logic.jumpToLastChapter();
        }
        controllers.add(logic.pageController);
      }

      changeChapter();
      final target = forward ? 3 : 2;
      final controller = logic.pageController;
      final generation = logic.loadGeneration;
      changeChapter();
      expect(logic.order, target);
      expect(logic.pageController, same(controller));
      expect(logic.loadGeneration, generation);

      pending = page.loadInfo(logic);
      expect(logic.loadInFlight, isTrue);
      changeChapter();
      expect(logic.order, target);
      result.complete(const Res(<String>['loaded-1', 'loaded-2']));
      await pending;

      expect(logic.urls, ['loaded-1', 'loaded-2']);
      expect(logic.order, target);
      expect(logic.isLoading, isFalse);
      expect(logic.loadInFlight, isFalse);

      if (forward) {
        logic.jumpToLastChapter();
      } else {
        logic.jumpToNextChapter();
      }
      controllers.add(logic.pageController);
      expect(logic.order, startingChapter);
      expect(logic.isLoading, isTrue);
    });
  }

  testWidgets('previous chapter opens on its last page after loading',
      (tester) async {
    final oldMode = appdata.settings[9];
    final oldPreload = appdata.settings[28];
    appdata.settings[9] = '1';
    appdata.settings[28] = '0';
    addTearDown(() {
      appdata.settings[9] = oldMode;
      appdata.settings[28] = oldPreload;
    });

    final data =
        _ChapterReadingData(_ControlledImageProvider(Completer<ImageInfo>()));
    final page = ComicReadingPage(data, 1, 2);
    final registered = StateController.find<ComicReadingPageLogic>();
    registered.releaseImageTasks();
    registered.pageController.dispose();
    StateController.remove<ComicReadingPageLogic>();
    final logic = ComicReadingPageLogic(2, data, 1, () {});
    addTearDown(() {
      logic.releaseImageTasks();
      logic.pageController.dispose();
      logic.clearPhotoViewControllers();
      StateController.remove<ComicReadingPageLogic>();
    });

    await page.loadInfo(logic);
    await tester.pumpWidget(MaterialApp(
      home: StateBuilder<ComicReadingPageLogic>(
        init: logic,
        builder: (value) => Builder(builder: (context) {
          if (value.isLoading || value.urls.isEmpty) {
            return const SizedBox();
          }
          return Stack(children: [
            page.buildComicView(value, context, data.id),
          ]);
        }),
      ),
    ));
    expect(logic.index, 1);

    final previousController = logic.pageController;
    logic.jumpToLastChapter(jumpToLast: true);
    await tester.pump();
    previousController.dispose();

    await page.loadInfo(logic);
    await tester.pump();

    expect(logic.order, 1);
    expect(logic.index, 4);
    expect(logic.pageController.page, 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('chapter loading exposes completion to lifecycle callers', () async {
    final result = Completer<Res<List<String>>>();
    final data = _ControlledReadingData(result.future);
    final page = ComicReadingPage(data, 1, 1);
    final logic = StateController.find<ComicReadingPageLogic>();
    addTearDown(() {
      logic.releaseImageTasks();
      logic.pageController.dispose();
      StateController.remove<ComicReadingPageLogic>();
    });

    final pending = page.loadInfo(logic);
    expect(logic.loadInFlight, isTrue);
    result.complete(const Res<List<String>>(<String>['one', 'two']));

    await pending;

    expect(logic.urls, ['one', 'two']);
    expect(logic.isLoading, isFalse);
    expect(logic.loadInFlight, isFalse);
  });

  test('chapter loading ignores a response after lifecycle invalidation',
      () async {
    final result = Completer<Res<List<String>>>();
    final data = _ControlledReadingData(result.future);
    final page = ComicReadingPage(data, 1, 1);
    final logic = StateController.find<ComicReadingPageLogic>();
    addTearDown(() {
      logic.releaseImageTasks();
      logic.pageController.dispose();
      StateController.remove<ComicReadingPageLogic>();
    });

    final pending = page.loadInfo(logic);
    logic.resetPreloadState();
    result.complete(const Res<List<String>>(<String>['stale']));

    await pending;

    expect(logic.urls, isEmpty);
    expect(logic.isLoading, isTrue);
    expect(logic.loadInFlight, isFalse);
  });
}

class _RetryBaseImageProvider
    extends BaseImageProvider<_RetryBaseImageProvider> {
  _RetryBaseImageProvider(this.bytes,
      {this.id = 'reader-retry-provider',
      this.failFirst = true,
      this.firstLoadGate});

  final Uint8List bytes;
  final String id;
  final bool failFirst;
  final Completer<void>? firstLoadGate;
  int loads = 0;

  @override
  String get key => id;

  @override
  Future<_RetryBaseImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    loads++;
    if (failFirst && loads == 1) {
      await firstLoadGate?.future;
      throw StateError('Maximum image loading limit reached');
    }
    return bytes;
  }
}
