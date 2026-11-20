import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
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
import 'package:pica_comic/network/source_network_policy.dart';
import 'package:pica_comic/pages/reader/reader_image_controller.dart';

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
  final blockedResponses =
      <String, ({Completer<void> started, Completer<void> release})>{};
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
      final blocked = blockedResponses[request.uri.path];
      if (blocked != null) {
        blocked.started.complete();
        await blocked.release.future;
        try {
          await request.response.close();
        } on IOException {
          // Cancellation may already have closed the client connection.
        }
        return;
      }
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

  test('repeated reader cancellation leaves budget for the current page',
      () async {
    final key = 'host:${server.address.address}';
    SourceNetworkPolicy.instance.configure(
        key,
        const SourceNetworkConfig(
            maxConcurrent: 1, minInterval: Duration.zero));
    final manager = ImageManager();
    final scopes = <ImageTaskScope>[];
    final completions = <Future<void>>[];
    try {
      for (var i = 0; i < 6; i++) {
        final path = '/pending-$i.png';
        final blocked =
            (started: Completer<void>(), release: Completer<void>());
        blockedResponses[path] = blocked;
        final scope = ImageTaskScope();
        scopes.add(scope);
        final provider = StreamImageProvider(
            () => manager.getImage('$origin$path'), '$origin$path',
            taskScope: scope);
        final decoded = expectLater(
            _decode(provider),
            throwsA(anyOf(
                isA<ImageTaskCancelledException>(),
                isA<DioException>().having(
                    (error) => error.type, 'type', DioExceptionType.cancel))));
        completions.add(decoded);
        await blocked.started.future.timeout(const Duration(seconds: 3));
        await scope.cancel();
        await decoded;
        await provider.evict();
        expect(ImageManager.haveTask, isFalse);
      }
      // None of the cancelled server requests have returned yet.
      final currentScope = ImageTaskScope();
      scopes.add(currentScope);
      final current = StreamImageProvider(
          () => manager.getImage('$origin/page.png'), '$origin/page.png',
          taskScope: currentScope);
      await _decode(current);
      await currentScope.cancel();
      await current.evict();
      expect(requests.where((path) => path.startsWith('/pending-')).length, 6);
      expect(requests.last, '/page.png');
      expect(await CacheManager().findCache('$origin/page.png'), isNotNull);
      expect(ImageManager.haveTask, isFalse);
    } finally {
      for (final blocked in blockedResponses.values) {
        blocked.release.complete();
      }
      for (final scope in scopes) {
        await scope.cancel();
      }
      await Future.wait(completions);
      blockedResponses.clear();
      SourceNetworkPolicy.instance.configure(key);
    }
  });

  test('same reader URL can restart while the cancelled response is pending',
      () async {
    final manager = ImageManager();
    const path = '/page.png';
    final url = '$origin$path';
    final blocked = (started: Completer<void>(), release: Completer<void>());
    blockedResponses[path] = blocked;
    final firstScope = ImageTaskScope();
    final first = StreamImageProvider(() => manager.getImage(url), url,
        taskScope: firstScope);
    final firstDecode = _decode(first);

    try {
      await blocked.started.future.timeout(const Duration(seconds: 3));
      await firstScope.cancel();
      await expectLater(
        firstDecode,
        throwsA(anyOf(
          isA<ImageTaskCancelledException>(),
          isA<DioException>()
              .having((error) => error.type, 'type', DioExceptionType.cancel),
        )),
      );
      await first.evict();

      // Keep the old server handler blocked while the replacement starts.
      blockedResponses.remove(path);
      final secondScope = ImageTaskScope();
      final second = StreamImageProvider(() => manager.getImage(url), url,
          taskScope: secondScope);
      try {
        await _decode(second).timeout(const Duration(seconds: 5));
        expect(requests.where((request) => request == path), hasLength(2));
        expect(await CacheManager().findCache(url), isNotNull);
        expect(ImageManager.haveTask, isFalse);
      } finally {
        await secondScope.cancel();
        await second.evict();
      }
    } finally {
      blockedResponses.remove(path);
      if (!blocked.release.isCompleted) blocked.release.complete();
      await firstScope.cancel();
      await first.evict();
    }
  });

  test('cancelling a reader waiter for the same URL reports cancellation',
      () async {
    final manager = ImageManager();
    const path = '/page.png';
    final url = '$origin$path';
    final blocked = (started: Completer<void>(), release: Completer<void>());
    blockedResponses[path] = blocked;
    final activeScope = ImageTaskScope();
    final activeProvider = StreamImageProvider(
      () => manager.getImage(url),
      url,
      taskScope: activeScope,
    );
    final activeDecode = _decode(activeProvider);
    final waiterScope = ImageTaskScope();
    final waiterProvider = StreamImageProvider(
      () => manager.getImage(url),
      url,
      taskScope: waiterScope,
    );
    final waiterDecode = expectLater(
      _decode(waiterProvider),
      throwsA(anyOf(
        isA<ImageTaskCancelledException>(),
        isA<DioException>()
            .having((error) => error.type, 'type', DioExceptionType.cancel),
      )),
    );

    try {
      await blocked.started.future.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await waiterScope.cancel();
      await waiterDecode.timeout(const Duration(seconds: 3));
      await activeScope.cancel();
      await expectLater(
        activeDecode,
        throwsA(anyOf(
          isA<ImageTaskCancelledException>(),
          isA<DioException>()
              .having((error) => error.type, 'type', DioExceptionType.cancel),
        )),
      );
    } finally {
      blockedResponses.remove(path);
      if (!blocked.release.isCompleted) blocked.release.complete();
      await waiterScope.cancel();
      await activeScope.cancel();
      await activeProvider.evict();
      await waiterProvider.evict();
    }
  });

  testWidgets(
      'reader window release restarts the same URL through ImageManager',
      (tester) async {
    final controller = ReaderImageController();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));

    await tester.runAsync(() async {
      const path = '/page.png';
      final url = '$origin$path';
      final blocked = (started: Completer<void>(), release: Completer<void>());
      blockedResponses[path] = blocked;
      final manager = ImageManager();
      controller.configure(
        context: context,
        imageCount: 30,
        firstVisible: 0,
        visibleCount: 1,
        preloadCount: 0,
        createProvider: (_, scope) => StreamImageProvider(
          () => manager.getImage(url),
          url,
          taskScope: scope,
        ),
      );
      final oldProvider = controller.imageFor(0);
      final oldCancelled = expectLater(
        _decode(oldProvider),
        throwsA(anyOf(
          isA<ImageTaskCancelledException>(),
          isA<DioException>()
              .having((error) => error.type, 'type', DioExceptionType.cancel),
        )),
      );

      try {
        await blocked.started.future.timeout(const Duration(seconds: 3));
        controller.updateWindow(20);
        controller.updateWindow(0);
        final newProvider = controller.imageFor(0);
        blockedResponses.remove(path);

        await oldCancelled;
        await _decode(newProvider).timeout(const Duration(seconds: 5));
        expect(requests.where((request) => request == path), hasLength(2));
        expect(await CacheManager().findCache(url), isNotNull);
        expect(ImageManager.haveTask, isFalse);
      } finally {
        blockedResponses.remove(path);
        if (!blocked.release.isCompleted) blocked.release.complete();
      }
    });

    controller.dispose();
    await controller.waitForIdle();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test('same URL starts a new stream while the cancelled completer is live',
      () async {
    const path = '/page.png';
    final url = '$origin$path';
    final blocked = (started: Completer<void>(), release: Completer<void>());
    blockedResponses[path] = blocked;
    final manager = ImageManager();
    final oldScope = ImageTaskScope();
    final oldProvider = StreamImageProvider(
      () => manager.getImage(url),
      url,
      taskScope: oldScope,
    );
    final newScope = ImageTaskScope();
    final newProvider = StreamImageProvider(
      () => manager.getImage(url),
      url,
      taskScope: newScope,
    );
    final oldStream = oldProvider.resolve(ImageConfiguration.empty);
    final newStream = newProvider.resolve(ImageConfiguration.empty);
    final oldListener = ImageStreamListener(
      (info, _) => info.dispose(),
      onError: (_, __) {},
    );
    final received = Completer<void>();
    final newListener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!received.isCompleted) received.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!received.isCompleted) received.completeError(error, stack);
      },
    );

    try {
      oldStream.addListener(oldListener);
      await blocked.started.future.timeout(const Duration(seconds: 3));

      final oldRelease = oldScope.cancel();
      blockedResponses.remove(path);
      newStream.addListener(newListener);
      expect(newStream.completer, isNot(same(oldStream.completer)));
      for (var attempt = 0;
          attempt < 300 &&
              requests.where((request) => request == path).length < 2;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.where((request) => request == path), hasLength(2));
      await received.future.timeout(const Duration(seconds: 3));
      await oldRelease.timeout(const Duration(seconds: 3));

      expect(oldProvider, isNot(newProvider));
      expect(await CacheManager().findCache(url), isNotNull);
      expect(ImageManager.haveTask, isFalse);
    } finally {
      blockedResponses.remove(path);
      if (!blocked.release.isCompleted) blocked.release.complete();
      oldStream.removeListener(oldListener);
      newStream.removeListener(newListener);
      await oldScope.cancel();
      await newScope.cancel();
      await oldProvider.evict();
      await newProvider.evict();
    }
  });
}
