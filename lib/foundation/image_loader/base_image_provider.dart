import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/byte_lru_cache.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'image_task_scope.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    final cancellation = ImageLoadCancellation();
    try {
      int retryTime = 1;

      bool stop = false;

      chunkEvents.onCancel = () {
        stop = true;
        return cancellation.cancel();
      };

      Uint8List? data;

      while (data == null && !stop) {
        try {
          final cached = _cache.get(key.key);
          if (cached != null) {
            data = cached;
          } else {
            data = await loadWithCancellation(chunkEvents, cancellation);
          }
        } catch (e) {
          if (e is ImageTaskCancelledException ||
              (e is DioException && CancelToken.isCancel(e))) {
            rethrow;
          }
          if (e.toString().contains("Maximum image loading limit reached")) {
            rethrow;
          }
          if (e.toString().contains("Your IP address")) {
            rethrow;
          }
          if (e is BadRequestException) {
            rethrow;
          }
          if (e.toString().contains("handshake")) {
            if (retryTime < 5) {
              retryTime = 5;
            }
          }
          retryTime <<= 1;
          if (retryTime > (1 << 3) || stop) {
            rethrow;
          }
          await Future.delayed(Duration(seconds: retryTime));
        }
      }

      if (stop) {
        throw Exception("Image loading is stopped");
      }

      if (data!.isEmpty) {
        throw Exception("Empty image data");
      }

      try {
        final buffer = await ImmutableBuffer.fromUint8List(data);
        final codec = await decode(buffer);
        _cache.put(key.key, data);
        return codec;
      } catch (e) {
        final cached = _cache.peek(key.key);
        final hasConcurrentCache = cached != null && !identical(cached, data);
        _cache.remove(key.key, onlyIfIdentical: data);
        if (!hasConcurrentCache) await CacheManager().delete(this.key);
        Object error = e;
        if (data.length < 2 * 1024) {
          // data is too short, it's likely that the data is text, not image
          try {
            var text =
                const Utf8Codec(allowMalformed: false).decoder.convert(data);
            error = Exception("Expected image data, but got text: $text");
          } catch (e) {
            // ignore
          }
        }
        throw error;
      }
    } catch (e) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  static final ByteLruCache _cache = ByteLruCache(limit: 50 * 1024 * 1024);

  static void clearCache() {
    _cache.clear();
  }

  static void setCacheSizeLimit(int size) {
    _cache.limit = size;
  }

  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents);

  /// Loads bytes while allowing a completer that lost its listeners to stop
  /// an underlying stream. Existing providers can keep implementing [load];
  /// providers backed by a cancellable stream may override this method.
  Future<Uint8List> loadWithCancellation(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageLoadCancellation cancellation,
  ) =>
      load(chunkEvents);

  String get key;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);

/// Cancellation hooks owned by one BaseImageProvider load.
///
/// A [MultiFrameImageStreamCompleter] cancels its chunk-event subscription when
/// the last listener is removed. Provider implementations register the actual
/// source subscription here so that cancellation reaches the network task.
class ImageLoadCancellation {
  bool _cancelled = false;
  final _callbacks = <FutureOr<void> Function()>{};

  bool get isCancelled => _cancelled;

  void register(FutureOr<void> Function() callback) {
    if (_cancelled) {
      unawaited(_run(callback));
      return;
    }
    _callbacks.add(callback);
  }

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = List<FutureOr<void> Function()>.of(_callbacks);
    _callbacks.clear();
    for (final callback in callbacks) {
      await _run(callback);
    }
  }

  Future<void> _run(FutureOr<void> Function() callback) async {
    try {
      await callback();
    } catch (_) {
      // Cancellation is best effort. The load itself reports its source error.
    }
  }
}
