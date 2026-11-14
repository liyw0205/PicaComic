import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../image_manager.dart';
import 'base_image_provider.dart';
import 'cached_image.dart' as image_provider;
import 'image_task_scope.dart';

/// Function which is called after loading the image failed.
typedef ErrorListener = void Function();

class CachedImageProvider
    extends BaseImageProvider<image_provider.CachedImageProvider> {
  /// Image provider for normal image.
  const CachedImageProvider(this.url, {this.headers, this.sourceKey});

  final String url;

  final Map<String, String>? headers;

  final String? sourceKey;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    return loadWithCancellation(chunkEvents, ImageLoadCancellation());
  }

  @override
  Future<Uint8List> loadWithCancellation(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageLoadCancellation cancellation,
  ) async {
    chunkEvents.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 0, expectedTotalBytes: 100));
    var manager = ImageManager();
    DownloadProgress? finishProgress;

    var stream = sourceKey == null
        ? manager.getImage(url, headers)
        : manager.getCustomThumbnail(url, sourceKey!);

    final owner = Object();
    final iterator = StreamIterator(
      ImageManager.withTaskOwner(stream, owner),
    );
    cancellation.register(() async {
      ImageManager.cancelTasksForOwner(owner);
      await iterator.cancel();
    });

    try {
      while (await iterator.moveNext()) {
        final progress = iterator.current;
        if (progress.currentBytes == progress.expectedBytes) {
          finishProgress = progress;
        }
        chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.expectedBytes));
      }
    } finally {
      await iterator.cancel();
    }

    if (cancellation.isCancelled) {
      throw const ImageTaskCancelledException();
    }

    if (finishProgress == null) {
      throw StateError('Image stream ended without a completed image');
    }
    if (finishProgress.data != null) {
      return finishProgress.data!;
    }

    var file = finishProgress.getFile();
    return await file.readAsBytes();
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => url;
}
