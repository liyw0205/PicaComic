import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/network/download_progress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
