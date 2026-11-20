import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/js_engine.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/pages/image_favorites.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serving;
  late String origin;
  final requests = <Map<String, String>>[];
  final png = image.encodePng(image.Image(width: 8, height: 12));
  final previousSources = ComicSource.sources;
  final previousManager = ImageManager.cache;
  final previousCache = CacheManager.instance;
  final previousCookieJar = SingleInstanceCookieJar.instance;
  final previousProxy = proxyHttpOverrides;
  final settings = List<String>.from(appdata.settings);

  void clearImages() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    BaseImageProvider.clearCache();
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('image-favorite-recovery-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    CacheManager.instance = null;
    ImageManager.cache = null;
    SingleInstanceCookieJar('${root.path}/cookies.sqlite');
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    proxyHttpOverrides = null;
    await JsEngine().init(throwOnError: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://${server.address.address}:${server.port}';
    serving = server.listen((request) async {
      requests.add({
        'path': request.uri.path,
        'method': request.method,
        'comic': request.headers.value('x-comic') ?? '',
        'chapter': request.headers.value('x-chapter') ?? '',
        'image': request.headers.value('x-image') ?? '',
        'body': await utf8.decoder.bind(request).join(),
      });
      if (request.uri.path == '/configured' && request.method == 'POST') {
        request.response.headers.contentType = ContentType.binary;
        request.response.add([0, ...png]);
      } else if (request.uri.path == '/plain.png') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      } else {
        request.response.statusCode = HttpStatus.forbidden;
      }
      await request.response.close();
    });
  });

  setUp(() async {
    clearImages();
    await CacheManager().clear();
    requests.clear();
    ComicSource.sources = [];
    JsEngine().runCode('ComicSource.sources = {};');
  });

  tearDownAll(() async {
    clearImages();
    JsEngine().dispose();
    ImageManager.cache?.dio.close(force: true);
    await serving.cancel();
    await server.close(force: true);
    await CacheManager().clear();
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = previousCookieJar;
    CacheManager.instance = previousCache;
    ImageManager.cache = previousManager;
    ComicSource.sources = previousSources;
    proxyHttpOverrides = previousProxy;
    appdata.settings = settings;
    await root.delete(recursive: true);
  });

  Future<void> configureSource(
      {String responseHandler = 'bytes => bytes.slice(1)'}) async {
    final source = await ComicSourceParser().parse('''
class FavoriteRecoveryFixture extends ComicSource {
  name = "Favorite recovery fixture"
  key = "favorite_recovery"
  version = "1.0.0"
  comic = {
    onImageLoad: (url, comic, chapter) => ({
      url: ${jsonEncode('$origin/configured')},
      method: "POST",
      data: "fixture-body",
      headers: {"x-comic": comic, "x-chapter": chapter, "x-image": url},
      onResponse: $responseHandler
    })
  }
}
''', 'fixture/favorite-recovery.js');
    ComicSource.sources = [source];
  }

  test('custom image response callback receives one byte buffer', () async {
    await configureSource();

    final completed = await ImageManager()
        .getCustomImage('$origin/blocked.png', 'comic-with-dashes', 'second',
            'favorite_recovery')
        .last;

    expect(completed.data, png);
    expect(await completed.getFile().readAsBytes(), png);
    expect(ImageManager.haveTask, isFalse);
  });

  for (final invalid in [false, true]) {
    test(
        'custom response ${invalid ? 'invalid result' : 'exception'} releases resources',
        () async {
      await configureSource(
          responseHandler: invalid
              ? 'bytes => 42'
              : 'bytes => { throw new Error("fixture transform failure"); }');
      final result = ImageManager()
          .getCustomImage('$origin/blocked.png', 'comic-with-dashes', 'second',
              'favorite_recovery')
          .last;

      await expectLater(
          result,
          throwsA(predicate((error) => error.toString().contains(invalid
              ? 'onImageLoad.onResponse return invalid type'
              : 'fixture transform failure'))));

      expect(ImageManager.haveTask, isFalse);
      expect(
          await CacheManager().findCache(
              'favorite_recoverycomic-with-dashessecond$origin/blocked.png'),
          isNull);
    });
  }

  Future<void> showFavorite(WidgetTester tester, ImageFavorite favorite) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            height: 240,
            child: FavoriteImageTile(favorite, key: UniqueKey()),
          ),
        ),
      ));
      final element = tester.element(find.byType(AnimatedImage));
      final provider =
          tester.widget<AnimatedImage>(find.byType(AnimatedImage)).image;
      final stream = provider.resolve(createLocalImageConfiguration(element));
      final loaded = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!loaded.isCompleted) loaded.complete();
      }, onError: (Object error, StackTrace? stack) {
        if (!loaded.isCompleted) loaded.completeError(error, stack);
      });
      stream.addListener(listener);
      try {
        await loaded.future.timeout(const Duration(seconds: 5));
      } finally {
        stream.removeListener(listener);
      }
    });
    await tester.pump();
    final rendered = find.descendant(
        of: find.byType(FavoriteImageTile), matching: find.byType(RawImage));
    expect(rendered, findsOneWidget);
    expect(tester.widget<RawImage>(rendered).image, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  }

  final chapterCases = [
    (
      name: 'map',
      eps: <String, String>{'first': 'One', 'second': 'Two'},
      ep: 2,
      expected: 'second'
    ),
    (
      name: 'legacy list',
      eps: <String>['first', 'second'],
      ep: 2,
      expected: 'second'
    ),
    (name: 'single chapter', eps: null, ep: 1, expected: 'comic-with-dashes'),
    (
      name: 'empty map',
      eps: <String, String>{},
      ep: 1,
      expected: 'comic-with-dashes'
    ),
    (name: 'empty list', eps: <String>[], ep: 1, expected: 'comic-with-dashes'),
    (
      name: 'missing chapter',
      eps: <String, String>{'first': 'One'},
      ep: 4,
      expected: 'comic-with-dashes'
    ),
  ];
  for (final fixture in chapterCases) {
    testWidgets('missing custom favorite recovers with ${fixture.name}',
        (tester) async {
      await tester.runAsync(configureSource);
      final favorite = ImageFavorite(
        'favorite_recovery-comic-with-dashes',
        'recovered-${fixture.name}.png',
        'Custom fixture',
        fixture.ep,
        3,
        {'url': '$origin/blocked.png', 'eps': fixture.eps},
      );

      await showFavorite(tester, favorite);

      expect(requests, [
        {
          'path': '/configured',
          'method': 'POST',
          'comic': 'comic-with-dashes',
          'chapter': fixture.expected,
          'image': '$origin/blocked.png',
          'body': 'fixture-body',
        }
      ]);
      await tester.runAsync(() async {
        expect(
            await File('${root.path}/images/${favorite.imagePath}')
                .readAsBytes(),
            png);
      });

      // Reopen without the source or either memory/disk download cache.
      clearImages();
      await tester.runAsync(() => CacheManager().clear());
      ComicSource.sources = [];
      requests.clear();
      await showFavorite(tester, favorite);
      expect(requests, isEmpty);
    });
  }

  for (final type in ['picacg', 'nhentai', 'htmanga', 'htManga']) {
    testWidgets('$type missing favorite keeps the ordinary image loader',
        (tester) async {
      ComicSource.sources = [
        ComicSource.named(
          name: 'Built-in fixture',
          key: type,
          filePath: 'fixture/built-in',
          getImageLoadingConfig: (_, __, ___) =>
              throw StateError('Built-in image must not use custom loading'),
        ),
      ];
      final favorite = ImageFavorite('$type-series', '$type.png', 'Built-in', 1,
          1, {'url': '$origin/plain.png'});

      await showFavorite(tester, favorite);

      expect(requests.single['path'], '/plain.png');
      expect(requests.single['method'], 'GET');
      await tester.runAsync(() async {
        expect(await File('${root.path}/images/$type.png').readAsBytes(), png);
      });
    });
  }

  testWidgets('custom favorite without request hooks still recovers',
      (tester) async {
    ComicSource.sources = [
      ComicSource.named(
          name: 'Plain fixture', key: 'plain_fixture', filePath: 'fixture'),
    ];
    final favorite = ImageFavorite('plain_fixture-series', 'custom-plain.png',
        'Custom plain', 1, 1, {'url': '$origin/plain.png'});

    await showFavorite(tester, favorite);

    expect(requests.single['path'], '/plain.png');
    expect(requests.single['method'], 'GET');
  });

  for (final absolute in [false, true]) {
    testWidgets(
        'existing ${absolute ? 'absolute' : 'relative'} favorite stays local',
        (tester) async {
      final path = absolute ? '${root.path}/absolute.png' : 'relative.png';
      final file = File(absolute ? path : '${root.path}/images/$path');
      await tester.runAsync(() async {
        await file.create(recursive: true);
        await file.writeAsBytes(png);
      });
      final favorite = ImageFavorite('removed_source-series', path, 'Local', 1,
          1, {'url': '$origin/blocked.png'});

      await showFavorite(tester, favorite);

      expect(requests, isEmpty);
    });
  }
}
