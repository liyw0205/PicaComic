import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';
import 'package:pica_comic/foundation/state_controller.dart';
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

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
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
    result.completeError(StateError('First image request failed'));
    await tester.pump();
    // The old precache implementation reports this through FlutterError.
    tester.takeException();

    expect(logic.requestedLoadingItems[1], isFalse);
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
}

class _RetryBaseImageProvider
    extends BaseImageProvider<_RetryBaseImageProvider> {
  _RetryBaseImageProvider(this.bytes);

  final Uint8List bytes;
  int loads = 0;

  @override
  String get key => 'reader-retry-provider';

  @override
  Future<_RetryBaseImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    loads++;
    if (loads == 1) {
      throw StateError('Maximum image loading limit reached');
    }
    return bytes;
  }
}
