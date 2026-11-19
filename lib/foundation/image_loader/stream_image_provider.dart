import 'dart:async' show Future, StreamController, StreamIterator;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../image_manager.dart';
import 'base_image_provider.dart';
import 'image_task_scope.dart';

/// Function which is called after loading the image failed.
typedef ErrorListener = void Function();

class StreamImageProvider extends BaseImageProvider<StreamImageProvider> {
  /// Image provider with [Stream<DownloadProgress>].
  const StreamImageProvider(this.streamBuilder, this.key, {this.taskScope});

  final Stream<DownloadProgress> Function() streamBuilder;

  final ImageTaskScope? taskScope;

  @override
  final String key;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    return _loadFromStream(chunkEvents, null);
  }

  @override
  Future<Uint8List> loadWithCancellation(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageLoadCancellation cancellation,
  ) =>
      _loadFromStream(chunkEvents, cancellation);

  Future<Uint8List> _loadFromStream(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageLoadCancellation? cancellation,
  ) async {
    chunkEvents.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 0, expectedTotalBytes: 100));
    DownloadProgress? finishProgress;

    final stream = taskScope?.bind(streamBuilder) ?? streamBuilder();
    final iterator = StreamIterator(stream);
    Future<void>? iteratorCancel;
    Future<void> cancelIterator() => iteratorCancel ??= iterator.cancel();
    cancellation?.register(cancelIterator);
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
      if ((cancellation?.isCancelled ?? false) ||
          taskScope?.isCancelled == true) {
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
    } finally {
      await cancelIterator();
    }
  }

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }
}
