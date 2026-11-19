import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_task_scope.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';

Future<void> _decode(ImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final received = Completer<void>();
  final listener = ImageStreamListener((info, _) {
    info.dispose();
    if (!received.isCompleted) received.complete();
  }, onError: (Object error, StackTrace? stack) {
    if (!received.isCompleted) received.completeError(error, stack);
  });
  stream.addListener(listener);
  try {
    await received.future.timeout(const Duration(seconds: 5));
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serving;
  final network = NhentaiNetwork();
  final requests = <String>[];
  var online = true;
  late String origin;
  final png = image.encodePng(image.Image(width: 2, height: 3));

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('nh-reader-cache-');
    App.cachePath = root.path;
    App.dataPath = root.path;
    CacheManager.instance = null;
    SingleInstanceCookieJar('${root.path}/cookies.sqlite');
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://${server.address.address}:${server.port}';
    serving = server.listen((request) async {
      requests.add(request.uri.path);
      if (!online) {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html>offline fixture</html>');
      } else if (request.uri.path == '/page.png') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'id': 42,
          'media_id': 4129181,
          'english_title': 'Cache fixture',
          'pages': [
            {'path': '$origin/page.png'},
          ],
        }));
      }
      await request.response.close();
    });
    network.baseUrl = origin;
    await network.init();
  });

  setUp(() async {
    online = true;
    requests.clear();
    await CacheManager().clear();
    BaseImageProvider.clearCache();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDownAll(() async {
    network.dio.close(force: true);
    ImageManager.cache?.dio.close(force: true);
    await serving.cancel();
    await server.close(force: true);
    await CacheManager().clear();
    SingleInstanceCookieJar.instance?.dispose();
    CacheManager.instance = null;
    ImageManager.cache = null;
    await root.delete(recursive: true);
  });

  test('reader reopens from persisted page list without network', () async {
    final first = await network.getImages('42');
    expect(first.success, isTrue);
    expect(first.data, ['$origin/page.png']);
    online = false;
    requests.clear();
    CacheManager.instance = null;
    await network.init();

    final reopened = await network.getImages('42');
    expect(reopened.success, isTrue);
    expect(reopened.data, first.data);
    expect(requests, isEmpty);
  });

  test('invalid and expired page lists are fetched again', () async {
    final key = 'nhentai-reader-pages:$origin:42';
    for (final contents in [
      '{broken',
      '[]',
      '["file:///invalid"]',
      '["https:///missing-host"]',
      '[null]',
    ]) {
      await CacheManager().writeCache(key, utf8.encode(contents));
      requests.clear();
      final result = await network.getImages('42');
      expect(result.success, isTrue);
      expect(result.data, ['$origin/page.png']);
      expect(requests, ['/api/v2/galleries/42']);
    }
    await CacheManager()
        .writeCache(key, utf8.encode(jsonEncode(['$origin/expired.png'])), -1);
    requests.clear();
    final result = await network.getImages('42');
    expect(result.data, ['$origin/page.png']);
    expect(requests, ['/api/v2/galleries/42']);
  });

  test('reader page lists are isolated by gallery and origin', () async {
    await network.getImages('42');
    requests.clear();
    await network.getImages('43');
    expect(requests, ['/api/v2/galleries/43']);
    network.baseUrl = '$origin/alternate';
    try {
      requests.clear();
      await network.getImages('42');
      expect(requests, ['/alternate/api/v2/galleries/42']);
    } finally {
      network.baseUrl = origin;
    }
  });

  test('completed reader image survives release and loss of network', () async {
    final manager = ImageManager();
    final url = '$origin/page.png';
    final firstScope = ImageTaskScope();
    final first = StreamImageProvider(() => manager.getImage(url), url,
        taskScope: firstScope);
    await _decode(first);
    await firstScope.cancel();
    await first.evict();
    BaseImageProvider.clearCache();
    expect(await CacheManager().findCache(url), isNotNull);
    online = false;
    requests.clear();
    CacheManager.instance = null;
    final secondScope = ImageTaskScope();
    final second = StreamImageProvider(() => manager.getImage(url), url,
        taskScope: secondScope);
    await _decode(second);
    await secondScope.cancel();
    await second.evict();
    expect(requests, isEmpty,
        reason:
            'the second decode must use disk, not the byte or Flutter cache');
    expect(ImageManager.haveTask, isFalse);
  });
}
