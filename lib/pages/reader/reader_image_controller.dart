import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';

typedef ReaderImageProviderBuilder = ImageProvider Function(
    int index, ImageTaskScope scope);

/// Keeps a fixed window around the visible spread and bounds speculative work.
class ReaderImageController {
  ReaderImageController({this.maxConcurrent = 3}) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final _images = <int, _ReaderImage>{};
  final _active = <_ReaderImage>{};
  final _pendingReleases = <Future<void>>{};
  final _queue = <int>[];
  var _retained = <int>{};
  List<bool> requested = [];
  int generation = 0;
  int _firstVisible = 0;
  int _visibleCount = 1;
  int _preloadCount = 0;
  bool _disposed = false;
  BuildContext? _context;
  ReaderImageProviderBuilder? _createProvider;

  int get activePreloads => _active.length;

  bool contains(int index) => _retained.contains(index);

  void configure({
    required BuildContext context,
    required int imageCount,
    required int firstVisible,
    required int visibleCount,
    required int preloadCount,
    required ReaderImageProviderBuilder createProvider,
  }) {
    if (_disposed) return;
    if (requested.length != imageCount) {
      reset();
      requested = List.filled(imageCount, false);
    }
    _context = context;
    _createProvider = createProvider;
    _visibleCount = visibleCount;
    _preloadCount = preloadCount.clamp(0, 20);
    updateWindow(firstVisible);
  }

  void updateWindow(int firstVisible, {int? visibleCount}) {
    if (_disposed || requested.isEmpty) return;
    if (visibleCount != null) _visibleCount = visibleCount;
    _firstVisible = firstVisible.clamp(0, requested.length - 1);
    final visibleEnd =
        (_firstVisible + _visibleCount).clamp(0, requested.length);
    final preloadEnd = (visibleEnd + _preloadCount).clamp(0, requested.length);
    // Keep the neighboring spread mounted during a page turn, even at 0 preload.
    final start = (_firstVisible - _visibleCount).clamp(0, requested.length);
    final end = (visibleEnd +
            (_preloadCount > _visibleCount ? _preloadCount : _visibleCount))
        .clamp(0, requested.length);
    _retained = {for (var i = start; i < end; i++) i};
    for (final index in _images.keys.toList()) {
      if (!_retained.contains(index)) {
        final image = _images.remove(index)!;
        _active.remove(image);
        requested[index] = false;
        _release(image);
      }
    }
    _queue
      ..clear()
      ..addAll([
        for (var i = visibleEnd; i < preloadEnd; i++)
          if (!requested[i]) i,
      ]);
    _drain();
  }

  ImageProvider imageFor(int index) {
    return _imageFor(index).provider;
  }

  _ReaderImage _imageFor(int index) {
    return _images.putIfAbsent(index, () {
      final scope = ImageTaskScope(
          priority:
              index >= _firstVisible && index < _firstVisible + _visibleCount
                  ? 2
                  : 1);
      return _ReaderImage(index, scope, _createProvider!(index, scope));
    });
  }

  bool _isCurrent(_ReaderImage image, int requestGeneration) {
    return !_disposed &&
        generation == requestGeneration &&
        identical(_images[image.index], image);
  }

  void _drain() {
    final context = _context;
    if (context == null || !context.mounted || _disposed) return;
    while (_active.length < maxConcurrent && _queue.isNotEmpty) {
      final index = _queue.removeAt(0);
      if (!_retained.contains(index) || requested[index]) continue;
      final image = _imageFor(index);
      final requestGeneration = generation;
      requested[index] = true;
      _active.add(image);
      void failed(Object error, StackTrace? stackTrace) {
        if (_isCurrent(image, requestGeneration)) requested[index] = false;
      }

      void finished() {
        if (!_isCurrent(image, requestGeneration)) return;
        _active.remove(image);
        _drain();
      }

      try {
        unawaited(precacheImage(image.provider, context, onError: failed).then(
          (_) => finished(),
          onError: (Object error, StackTrace stackTrace) {
            failed(error, stackTrace);
            finished();
          },
        ));
      } catch (error, stackTrace) {
        failed(error, stackTrace);
        finished();
      }
    }
  }

  void _release(_ReaderImage image) {
    // Do not let a newly mounted image inherit the cancelled pending completer.
    final release = Future.wait<void>([
      image.scope.cancel(),
      image.provider.evict().then<void>((_) {}),
    ]);
    _pendingReleases.add(release);
    unawaited(release.then<void>(
      (_) => _pendingReleases.remove(release),
      onError: (Object _, StackTrace __) => _pendingReleases.remove(release),
    ));
  }

  /// Completes after releases started by [reset] or [dispose] have settled.
  Future<void> waitForIdle() async {
    while (_pendingReleases.isNotEmpty) {
      await Future.wait(_pendingReleases.toList());
    }
  }

  void reset() {
    generation++;
    for (final image in _images.values) {
      _release(image);
    }
    _images.clear();
    _active.clear();
    _queue.clear();
    _retained.clear();
    requested = [];
    _context = null;
    _createProvider = null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }
}

class _ReaderImage {
  const _ReaderImage(this.index, this.scope, this.provider);

  final int index;
  final ImageTaskScope scope;
  final ImageProvider provider;
}
