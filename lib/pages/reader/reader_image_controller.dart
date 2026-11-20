import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';

typedef ReaderImageProviderBuilder = ImageProvider Function(
    int index, ImageTaskScope scope);

/// Keeps a fixed window around the visible spread and bounds speculative work.
class ReaderImageController {
  ReaderImageController({
    this.maxConcurrent = 3,
    this.stalledLoadTimeout = const Duration(seconds: 15),
  }) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final Duration stalledLoadTimeout;
  final _images = <int, _ReaderImage>{};
  final _active = <_ReaderImage>{};
  final _pendingReleases = <Future<void>>{};
  final _queue = <int>[];
  final _retryTimers = <int, Timer>{};
  final _retryCounts = <int, int>{};
  final _imageSizes = <int, Size>{};
  var _retained = <int>{};
  List<bool> requested = [];
  int generation = 0;
  int _firstVisible = 0;
  int _visibleCount = 1;
  int _preloadCount = 0;
  int _scrollDirection = 1;
  bool _isScrolling = false;
  bool _windowMovedWhileScrolling = false;
  bool _disposed = false;
  BuildContext? _context;
  ReaderImageProviderBuilder? _createProvider;
  VoidCallback? _onImagesChanged;

  int get activePreloads => _active.length;

  bool contains(int index) => _retained.contains(index);

  double pageHeight(int index, double width) {
    final size = _imageSizes[index];
    return size == null ? width * 1.2 : width * size.height / size.width;
  }

  void recordImageSize(int index, Size size, int requestGeneration) {
    if (_disposed || generation != requestGeneration) return;
    _imageSizes[index] = size;
  }

  void configure({
    required BuildContext context,
    required int imageCount,
    required int firstVisible,
    required int visibleCount,
    required int preloadCount,
    required ReaderImageProviderBuilder createProvider,
    VoidCallback? onImagesChanged,
  }) {
    if (_disposed) return;
    if (requested.length != imageCount) {
      reset();
      requested = List.filled(imageCount, false);
    }
    _context = context;
    _createProvider = createProvider;
    _onImagesChanged = onImagesChanged;
    _visibleCount = visibleCount;
    _preloadCount = preloadCount.clamp(0, 20);
    updateWindow(firstVisible);
  }

  bool updateWindow(int firstVisible, {int? visibleCount}) {
    if (_disposed || requested.isEmpty) return false;
    final previousVisibleCount = _visibleCount;
    if (visibleCount != null) _visibleCount = visibleCount;
    final nextFirstVisible = firstVisible.clamp(0, requested.length - 1);
    if (_isScrolling &&
        (nextFirstVisible != _firstVisible ||
            _visibleCount != previousVisibleCount)) {
      _windowMovedWhileScrolling = true;
    }
    if (nextFirstVisible != _firstVisible) {
      _scrollDirection = nextFirstVisible > _firstVisible ? 1 : -1;
    }
    _firstVisible = nextFirstVisible;
    final visibleEnd =
        (_firstVisible + _visibleCount).clamp(0, requested.length);
    final retainedPadding =
        _preloadCount > _visibleCount ? _preloadCount : _visibleCount;
    // Keep the neighboring spread mounted during a page turn, even at 0 preload.
    final start = (_firstVisible - retainedPadding).clamp(0, requested.length);
    final end = (visibleEnd + retainedPadding).clamp(0, requested.length);
    final retained = {for (var i = start; i < end; i++) i};
    var changed = !setEquals(_retained, retained);
    _retained = retained;
    for (final index in _images.keys.toList()) {
      if (!_retained.contains(index)) {
        final image = _images.remove(index)!;
        _active.remove(image);
        requested[index] = false;
        _retryTimers.remove(index)?.cancel();
        _retryCounts.remove(index);
        _release(image);
      }
    }
    final candidates = _scrollDirection > 0
        ? [
            for (var i = visibleEnd;
                i < (visibleEnd + _preloadCount).clamp(0, requested.length);
                i++)
              i,
          ]
        : [
            for (var i = _firstVisible - 1;
                i >= (_firstVisible - _preloadCount).clamp(0, requested.length);
                i--)
              i,
          ];
    final visible = {
      for (var i = _firstVisible; i < visibleEnd; i++) i,
    };
    final candidateSet = candidates.toSet();
    for (final image in _active.toList()) {
      if (visible.contains(image.index) || candidateSet.contains(image.index)) {
        continue;
      }
      _active.remove(image);
      _images.remove(image.index);
      changed = true;
      requested[image.index] = false;
      _retryTimers.remove(image.index)?.cancel();
      _retryCounts.remove(image.index);
      _release(image);
    }
    _queue.clear();
    _queue.addAll([
      for (final index in candidates)
        if (!requested[index] && (_retryCounts[index] ?? 0) <= 1) index,
    ]);
    _drain();
    return changed;
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

  bool setScrolling(bool scrolling) {
    final changedState = _isScrolling != scrolling;
    _isScrolling = scrolling;
    if (changedState) {
      _windowMovedWhileScrolling = false;
      for (final image in _active) {
        image.stallTimer?.cancel();
        image.stallTimer = null;
      }
      if (scrolling) {
        for (final index in _retained) {
          _retryCounts.remove(index);
        }
      }
    }
    if (scrolling) return false;
    final changed = updateWindow(_firstVisible, visibleCount: _visibleCount);
    if (changedState) {
      for (final image in _active) {
        _armStallTimer(image, generation);
      }
    }
    return changed;
  }

  void _drain() {
    final context = _context;
    if (context == null ||
        !context.mounted ||
        _disposed ||
        (_isScrolling && _windowMovedWhileScrolling)) {
      return;
    }
    while (_active.length < maxConcurrent && _queue.isNotEmpty) {
      final index = _queue.removeAt(0);
      if (!_retained.contains(index) || requested[index]) continue;
      final image = _imageFor(index);
      final requestGeneration = generation;
      requested[index] = true;
      _active.add(image);
      var didFail = false;
      void failed(Object error, StackTrace? stackTrace) {
        if (!_isCurrent(image, requestGeneration)) return;
        didFail = true;
        requested[index] = false;
        final failures = (_retryCounts[index] ?? 0) + 1;
        _retryCounts[index] = failures;
        if (!_isScrolling && failures == 1 && _isPreloadCandidate(index)) {
          _retryTimers.remove(index)?.cancel();
          _retryTimers[index] = Timer(const Duration(milliseconds: 250), () {
            _retryTimers.remove(index);
            if (!_isCurrent(image, requestGeneration) ||
                requested[index] ||
                _isScrolling ||
                !_isPreloadCandidate(index)) {
              return;
            }
            if (!_queue.contains(index)) _queue.add(index);
            _drain();
          });
        }
      }

      void finished() {
        if (!_isCurrent(image, requestGeneration)) return;
        image.stallTimer?.cancel();
        image.stallTimer = null;
        _active.remove(image);
        if (!didFail) {
          _retryCounts.remove(index);
          _retryTimers.remove(index)?.cancel();
        }
        _drain();
      }

      try {
        final stream = image.provider.resolve(
          createLocalImageConfiguration(context),
        );
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              info.dispose();
              _removeListener(image, stream, listener);
            });
          },
          onChunk: (event) {
            if (_isCurrent(image, requestGeneration)) {
              if (event.cumulativeBytesLoaded > image.lastLoadedBytes) {
                image.lastLoadedBytes = event.cumulativeBytesLoaded;
                image.lastProgressAt = DateTime.now();
              }
              _armStallTimer(image, requestGeneration);
            }
          },
          onError: (error, stackTrace) {
            if (_isCurrent(image, requestGeneration)) {
              failed(error, stackTrace);
            }
            _removeListener(image, stream, listener);
          },
        );
        image.stream = stream;
        image.listener = listener;
        stream.addListener(listener);
        unawaited(precacheImage(
          image.provider,
          context,
          onError: (_, __) {},
        ).then(
          (_) => finished(),
          onError: (Object error, StackTrace stackTrace) {
            failed(error, stackTrace);
            finished();
          },
        ));
        _armStallTimer(image, requestGeneration);
      } catch (error, stackTrace) {
        failed(error, stackTrace);
        finished();
        final stream = image.stream;
        final listener = image.listener;
        if (stream != null && listener != null) {
          _removeListener(image, stream, listener);
        }
      }
    }
  }

  bool _isPreloadCandidate(int index) {
    final visibleEnd =
        (_firstVisible + _visibleCount).clamp(0, requested.length);
    if (_scrollDirection > 0) {
      final preloadEnd =
          (visibleEnd + _preloadCount).clamp(0, requested.length);
      return index >= visibleEnd && index < preloadEnd;
    }
    final preloadStart =
        (_firstVisible - _preloadCount).clamp(0, requested.length);
    return index >= preloadStart && index < _firstVisible;
  }

  void _armStallTimer(_ReaderImage image, int requestGeneration) {
    image.stallTimer?.cancel();
    image.stallTimer = null;
    if (_isScrolling ||
        !_isCurrent(image, requestGeneration) ||
        !_active.contains(image)) {
      return;
    }
    final elapsed = DateTime.now().difference(
      image.lastProgressAt ?? image.startedAt,
    );
    final remaining = stalledLoadTimeout - elapsed;
    image.stallTimer =
        Timer(remaining.isNegative ? Duration.zero : remaining, () {
      image.stallTimer = null;
      if (!_isCurrent(image, requestGeneration) || _isScrolling) return;
      _recoverStalledPreload(image, requestGeneration);
    });
  }

  void _recoverStalledPreload(_ReaderImage image, int requestGeneration) {
    final index = image.index;
    if (!_isCurrent(image, requestGeneration) || !_active.contains(image)) {
      return;
    }
    final retries = _retryCounts[index] ?? 0;
    _retryCounts[index] = retries + 1;
    _active.remove(image);
    _images.remove(index);
    requested[index] = false;
    _release(image);
    if (retries == 0 &&
        _retained.contains(index) &&
        _isPreloadCandidate(index) &&
        !_queue.contains(index)) {
      _queue.insert(0, index);
    }
    _drain();
    _onImagesChanged?.call();
  }

  void _removeListener(
      _ReaderImage image, ImageStream stream, ImageStreamListener listener) {
    if (!identical(image.stream, stream) ||
        !identical(image.listener, listener)) {
      return;
    }
    image.stream = null;
    image.listener = null;
    stream.removeListener(listener);
  }

  void _release(_ReaderImage image) {
    // Do not let a newly mounted image inherit the cancelled pending completer.
    image.stallTimer?.cancel();
    image.stallTimer = null;
    final stream = image.stream;
    final listener = image.listener;
    image.stream = null;
    image.listener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
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
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _retryCounts.clear();
    _isScrolling = false;
    _firstVisible = 0;
    _visibleCount = 1;
    _preloadCount = 0;
    _scrollDirection = 1;
    _imageSizes.clear();
    _windowMovedWhileScrolling = false;
    _retained.clear();
    requested = [];
    _context = null;
    _createProvider = null;
    _onImagesChanged = null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }
}

class _ReaderImage {
  _ReaderImage(this.index, this.scope, this.provider);

  final int index;
  final ImageTaskScope scope;
  final ImageProvider provider;
  final DateTime startedAt = DateTime.now();
  DateTime? lastProgressAt;
  int lastLoadedBytes = 0;
  ImageStream? stream;
  ImageStreamListener? listener;
  Timer? stallTimer;
}
