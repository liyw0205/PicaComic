import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';
import 'package:pica_comic/foundation/image_manager.dart';
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
