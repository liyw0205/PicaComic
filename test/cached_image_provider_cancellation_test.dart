import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling a cached image completer releases its image task', () async {
    final root = await Directory.systemTemp.createTemp('cached-image-cancel-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    final serving = server.listen((request) async {
      if (!requestStarted.isCompleted) requestStarted.complete();
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.contentLength = 1024 * 1024;
      request.response.bufferOutput = false;
      request.response.add(Uint8List.fromList(<int>[0x89]));
      await request.response.flush();
      try {
        await releaseResponse.future;
      } finally {
        try {
          await request.response.close();
        } on HttpException {
          // The client is expected to close the response when cancellation wins.
        }
      }
    });

    final previousManager = ImageManager.cache;
    final previousCache = CacheManager.instance;
    final previousCookieJar = SingleInstanceCookieJar.instance;
    final previousProxy = proxyHttpOverrides;
    final settings = List<String>.from(appdata.settings);

    App.cachePath = root.path;
    App.dataPath = root.path;
    CacheManager.instance = null;
    ImageManager.cache = null;
    if (previousCookieJar == null) {
      SingleInstanceCookieJar('${root.path}/cookies.sqlite');
    }
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    proxyHttpOverrides = null;

    final manager = ImageManager();
    final url =
        'http://${server.address.address}:${server.port}/pending-cover.png';
    final provider = CachedImageProvider(url);
    final completer = provider.loadImage(
      provider,
      (buffer, {getTargetSize}) =>
          PaintingBinding.instance.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: getTargetSize,
      ),
    );
    final listener = ImageStreamListener(
      (info, _) => info.dispose(),
      onError: (_, __) {},
    );

    try {
      completer.addListener(listener);
      await requestStarted.future.timeout(const Duration(seconds: 5));
      completer.removeListener(listener);

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (ImageManager.haveTask && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(ImageManager.haveTask, isFalse,
          reason: 'removing the last image listener must cancel the source');
    } finally {
      releaseResponse.complete();
      completer.maybeDispose();
      await serving.cancel();
      await server.close(force: true);
      manager.dio.close(force: true);
      await CacheManager().clear();
      ImageManager.cache = previousManager;
      CacheManager.instance = previousCache;
      appdata.settings = settings;
      proxyHttpOverrides = previousProxy;
      if (previousCookieJar == null) {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
      }
      BaseImageProvider.clearCache();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await root.delete(recursive: true);
    }
  });
}
