import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';

const List<int> _validPng = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x06,
  0x62,
  0x4b,
  0x47,
  0x44,
  0x00,
  0xff,
  0x00,
  0xff,
  0x00,
  0xff,
  0xa0,
  0xbd,
  0xa7,
  0x93,
  0x00,
  0x00,
  0x00,
  0x09,
  0x70,
  0x48,
  0x59,
  0x73,
  0x00,
  0x00,
  0x0b,
  0x13,
  0x00,
  0x00,
  0x0b,
  0x13,
  0x01,
  0x00,
  0x9a,
  0x9c,
  0x18,
  0x00,
  0x00,
  0x00,
  0x07,
  0x74,
  0x49,
  0x4d,
  0x45,
  0x07,
  0xe6,
  0x03,
  0x10,
  0x17,
  0x07,
  0x1d,
  0x2e,
  0x5e,
  0x30,
  0x9b,
  0x00,
  0x00,
  0x00,
  0x0b,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xd7,
  0x63,
  0x60,
  0x00,
  0x02,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0xe2,
  0x26,
  0x05,
  0x9b,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

class _TestImageProvider extends BaseImageProvider<_TestImageProvider> {
  _TestImageProvider(this.key, this.readBytes);

  @override
  final String key;

  final Future<Uint8List> Function() readBytes;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) =>
      readBytes();

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_TestImageProvider>(this);
}

Future<Object> _expectError(ImageStream stream) {
  final result = Completer<Object>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, synchronousCall) {
      info.dispose();
      if (!result.isCompleted) {
        result.completeError(StateError('Expected the image load to fail'));
      }
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!result.isCompleted) result.complete(error);
    },
  );
  stream.addListener(listener);
  return result.future.whenComplete(() => stream.removeListener(listener));
}

Future<void> _expectImage(ImageStream stream) {
  final result = Completer<void>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, synchronousCall) {
      info.dispose();
      if (!result.isCompleted) result.complete();
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!result.isCompleted) {
        result.completeError(error, stackTrace ?? StackTrace.current);
      }
    },
  );
  stream.addListener(listener);
  return result.future.whenComplete(() => stream.removeListener(listener));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invalid image bytes are not retained and the same key can recover',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-image-cache-');
    App.cachePath = root.path;
    App.dataPath = root.path;
    CacheManager.instance = null;
    BaseImageProvider.clearCache();
    final cache = CacheManager();
    const key = 'https://example.invalid/image';
    final invalidBytes = Uint8List.fromList(utf8.encode('<html>error</html>'));
    await cache.writeCache(key, invalidBytes);
    expect(await cache.findCache(key), isNotNull);

    var firstLoadCount = 0;
    final invalidProvider = _TestImageProvider(key, () async {
      firstLoadCount++;
      return invalidBytes;
    });

    try {
      await _expectError(invalidProvider.resolve(ImageConfiguration.empty))
          .timeout(const Duration(seconds: 8));
      expect(firstLoadCount, 1,
          reason: 'the initial request should load the invalid response once');
      expect(await cache.findCache(key), isNull,
          reason: 'decoding failure must delete the persisted response');

      var recoveryLoadCount = 0;
      final recoveryProvider = _TestImageProvider(key, () async {
        recoveryLoadCount++;
        return Uint8List.fromList(_validPng);
      });
      await _expectImage(
        recoveryProvider.resolve(ImageConfiguration.empty),
      ).timeout(const Duration(seconds: 8));
      expect(recoveryLoadCount, 1,
          reason: 'a same-key request must reach the source again');
    } finally {
      BaseImageProvider.clearCache();
      await cache.clear();
      CacheManager.instance = null;
      await root.delete(recursive: true);
    }
  });
}
