import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/pages/reader/reader_image_controller.dart';

class _ImmediateImageProvider
    extends BaseImageProvider<_ImmediateImageProvider> {
  _ImmediateImageProvider(this.index, this.bytes);

  final int index;
  final Uint8List bytes;

  @override
  String get key => 'reader-owner-immediate-$index';

  @override
  Future<_ImmediateImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async =>
      bytes;
}

class _LateErrorCompleter extends ImageStreamCompleter {
  ImageStreamListener? listener;

  @override
  void addListener(ImageStreamListener value) {
    listener = value;
  }

  @override
  void removeListener(ImageStreamListener value) {}

  void emitError() {
    listener?.onError
        ?.call(StateError('late image failure'), StackTrace.current);
  }
}

class _LateErrorImageProvider extends ImageProvider<_LateErrorImageProvider> {
  final completer = _LateErrorCompleter();

  @override
  Future<_LateErrorImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _LateErrorImageProvider key, ImageDecoderCallback decode) {
    return completer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling a scope closes its source without touching background work',
      () async {
    final scope = ImageTaskScope();
    var cancelled = false;
    var backgroundCancelled = false;
    final source = StreamController<int>(onCancel: () => cancelled = true);
    final background =
        StreamController<int>(onCancel: () => backgroundCancelled = true);
    final backgroundSubscription =
        ImageManager.withTaskOwner(background.stream, Object()).listen((_) {});
    final completed = Completer<void>();
    final subscription = scope
        .bind(() => source.stream)
        .listen((_) {}, onDone: completed.complete);
    await Future<void>.delayed(Duration.zero);

    await scope.cancel();

    await completed.future;
    expect(cancelled, isTrue);
    expect(backgroundCancelled, isFalse);
    await subscription.cancel();
    await backgroundSubscription.cancel();
    await source.close();
    await background.close();
  });

  test('one subscription ending does not cancel another in the same scope',
      () async {
    final scope = ImageTaskScope();
    var secondCancelled = false;
    final first = StreamController<int>();
    final second =
        StreamController<int>(onCancel: () => secondCancelled = true);
    final firstSubscription = scope.bind(() => first.stream).listen((_) {});
    final secondSubscription = scope
        .bind(() => second.stream)
        .listen((_) {}, onError: (Object error) {});
    await Future<void>.delayed(Duration.zero);

    await firstSubscription.cancel();
    expect(secondCancelled, isFalse);
    await scope.cancel();
    expect(secondCancelled, isTrue);
    await secondSubscription.cancel();
    await first.close();
    await second.close();
  });

  test('cancelling a stream image provider closes its source stream', () async {
    var sourceCancelled = false;
    final source = StreamController<DownloadProgress>(
      onCancel: () => sourceCancelled = true,
    );
    final provider = StreamImageProvider(
      () => source.stream,
      'stream-image-cancellation',
    );
    final cancellation = ImageLoadCancellation();
    final chunks = StreamController<ImageChunkEvent>();
    final chunkSubscription = chunks.stream.listen((_) {});
    final load = provider.loadWithCancellation(chunks, cancellation);
    final loadExpectation = expectLater(
      load,
      throwsA(isA<ImageTaskCancelledException>()),
    );

    try {
      await Future<void>.delayed(Duration.zero);
      await cancellation.cancel();
      await cancellation.cancel();

      await loadExpectation;
      expect(sourceCancelled, isTrue);
    } finally {
      await chunks.close();
      await chunkSubscription.cancel();
      await source.close();
    }
  });

  test('cancelling one owned image stream does not cancel another', () async {
    var firstCancelled = false;
    var secondCancelled = false;
    final first = StreamController<int>(
      onCancel: () => firstCancelled = true,
    );
    final second = StreamController<int>(
      onCancel: () => secondCancelled = true,
    );
    final firstSubscription =
        ImageManager.withTaskOwner(first.stream, Object()).listen((_) {});
    final secondSubscription =
        ImageManager.withTaskOwner(second.stream, Object()).listen((_) {});

    await firstSubscription.cancel();

    expect(firstCancelled, isTrue);
    expect(secondCancelled, isFalse);
    await secondSubscription.cancel();
    expect(secondCancelled, isTrue);
  });

  test('scope cancellation is recognised with a live load cancellation token',
      () async {
    final scope = ImageTaskScope();
    final source = StreamController<DownloadProgress>();
    final provider = StreamImageProvider(
      () => source.stream,
      'scope-cancelled-stream',
      taskScope: scope,
    );
    final chunks = StreamController<ImageChunkEvent>();
    final events = chunks.stream.listen((_) {});
    final result = expectLater(
      provider.loadWithCancellation(chunks, ImageLoadCancellation()),
      throwsA(isA<ImageTaskCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);
    await scope.cancel();
    await result;
    await source.close();
    await chunks.close();
    await events.cancel();
  });

  testWidgets('rapid return starts a new load before old release finishes',
      (tester) async {
    final controller = ReaderImageController();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    await tester.runAsync(() async {
      final release = Completer<void>();
      final oldSource = StreamController<DownloadProgress>(
        onCancel: () => release.future,
      );
      final newSource = StreamController<DownloadProgress>();
      var builds = 0;
      controller.configure(
        context: context,
        imageCount: 40,
        firstVisible: 0,
        visibleCount: 1,
        preloadCount: 0,
        createProvider: (index, scope) => StreamImageProvider(
          () => builds++ == 0 ? oldSource.stream : newSource.stream,
          'rapid-return-$index',
          taskScope: scope,
        ),
      );
      final oldStream =
          controller.imageFor(0).resolve(ImageConfiguration.empty);
      final oldListener =
          ImageStreamListener((info, _) => info.dispose(), onError: (_, __) {});
      oldStream.addListener(oldListener);
      await Future<void>.delayed(Duration.zero);
      controller.updateWindow(20);
      controller.updateWindow(0);
      final provider = controller.imageFor(0);
      final newStream = provider.resolve(ImageConfiguration.empty);
      final received = Completer<void>();
      final newListener = ImageStreamListener((info, _) {
        info.dispose();
        if (!received.isCompleted) received.complete();
      }, onError: (Object error, StackTrace? stack) {
        if (!received.isCompleted) received.completeError(error, stack);
      });
      newStream.addListener(newListener);
      try {
        expect(newStream.completer, isNot(same(oldStream.completer)),
            reason: 'the new reader scope must not inherit cancelled work');
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await controller.waitForIdle();
        final bytes = Uint8List.fromList(
            image.encodePng(image.Image(width: 1, height: 1)));
        newSource.add(DownloadProgress(1, 1, '', '', bytes));
        await newSource.close();
        await received.future.timeout(const Duration(seconds: 5));
        expect(provider.resolve(ImageConfiguration.empty).completer,
            same(newStream.completer));
      } finally {
        if (!release.isCompleted) release.complete();
        oldStream.removeListener(oldListener);
        newStream.removeListener(newListener);
        controller.dispose();
        await controller.waitForIdle();
        await oldSource.close();
        await newSource.close();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        BaseImageProvider.clearCache();
      }
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mounted image resumes after leaving and returning before rebuild',
      (tester) async {
    final controller = ReaderImageController();
    final oldSource = StreamController<DownloadProgress>();
    final newSource = StreamController<DownloadProgress>();
    var loads = 0;
    var configured = false;
    Widget view() => MaterialApp(home: Builder(builder: (context) {
          if (!configured) {
            configured = true;
            controller.configure(
              context: context,
              imageCount: 40,
              firstVisible: 0,
              visibleCount: 1,
              preloadCount: 0,
              createProvider: (index, scope) => StreamImageProvider(
                () => loads++ == 0 ? oldSource.stream : newSource.stream,
                'mounted-rapid-return-$index',
                taskScope: scope,
              ),
            );
          }
          return ComicImage(
            image: controller.imageFor(0),
            width: 100,
            height: 120,
          );
        }));
    addTearDown(() async {
      controller.dispose();
      unawaited(oldSource.close());
      unawaited(newSource.close());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      BaseImageProvider.clearCache();
    });
    await tester.pumpWidget(view());
    expect(loads, 1);
    final originalState = tester.state(find.byType(ComicImage));

    controller.updateWindow(20);
    controller.updateWindow(0);
    await tester.pumpWidget(view());

    expect(tester.state(find.byType(ComicImage)), same(originalState));
    expect(loads, 2,
        reason: 'the mounted widget must resolve the replacement reader scope');
    expect(newSource.hasListener, isTrue);
    final bytes = Uint8List.fromList(
        image.encodePng(image.Image(width: 100, height: 120)));
    newSource.add(DownloadProgress(1, 1, '', '', bytes));
    unawaited(newSource.close());
    for (var frame = 0;
        frame < 20 && find.byType(RawImage).evaluate().isEmpty;
        frame++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.text('Retry'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('late image error after widget disposal is ignored',
      (tester) async {
    final provider = _LateErrorImageProvider();
    await tester.pumpWidget(MaterialApp(home: ComicImage(image: provider)));
    expect(provider.completer.listener, isNotNull);

    await tester.pumpWidget(const SizedBox());
    provider.completer.emitError();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  test('releasing a pending reader image has no unhandled cancellation',
      () async {
    final source = StreamController<DownloadProgress>();
    final scope = ImageTaskScope();
    final provider = StreamImageProvider(
      () => source.stream,
      'reader-unmounted-cancellation',
      taskScope: scope,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener =
        ImageStreamListener((info, _) => info.dispose(), onError: (_, __) {});
    stream.addListener(listener);
    await Future<void>.delayed(Duration.zero);
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      stream.removeListener(listener);
      await scope.cancel();
      await provider.evict();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(errors, isEmpty);
    } finally {
      FlutterError.onError = previousHandler;
      await source.close();
    }
  });

  testWidgets('jump and exit release obsolete preloads without automatic retry',
      (tester) async {
    final controller = ReaderImageController(maxConcurrent: 2);
    final bytes = Uint8List.fromList(
      image.encodePng(image.Image(width: 1, height: 1)),
    );
    var schedules = 0;
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    controller.configure(
      context: context,
      imageCount: 50,
      firstVisible: 0,
      visibleCount: 1,
      preloadCount: 10,
      createProvider: (index, _) {
        schedules++;
        return _ImmediateImageProvider(index, bytes);
      },
    );
    await tester.pumpAndSettle();
    expect(schedules, 2);
    controller.updateWindow(30);
    await tester.pumpAndSettle();
    expect(controller.contains(0), isFalse);
    expect(schedules, 4);

    controller.dispose();
    await controller.waitForIdle();
    expect(controller.activePreloads, 0);
    expect(schedules, 4,
        reason: 'cancelled BaseImageProvider loads must not retry');
    expect(tester.takeException(), isNull);
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });
}
