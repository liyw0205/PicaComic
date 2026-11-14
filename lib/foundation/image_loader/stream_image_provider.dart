import 'dart:async' show Future, StreamController;
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
    chunkEvents.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 0, expectedTotalBytes: 100));
    DownloadProgress? finishProgress;

    final stream = taskScope?.bind(streamBuilder) ?? streamBuilder();
    await for (var progress in stream) {
      if (progress.currentBytes == progress.expectedBytes) {
        finishProgress = progress;
      }
      chunkEvents.add(ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.expectedBytes));
    }
    if (taskScope?.isCancelled ?? false) {
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
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }
}
