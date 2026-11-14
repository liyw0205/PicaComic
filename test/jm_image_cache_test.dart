import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/image_loader/image_recombine.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serving;
  late ImageManager manager;
  late Uint8List responseBytes;
  final sourceBytes = Uint8List.fromList(
    image.encodePng(image.Image(width: 4, height: 20)),
  );
  final previousCookieJar = SingleInstanceCookieJar.instance;
  final previousManager = ImageManager.cache;
  final previousCache = CacheManager.instance;
  final previousProxy = proxyHttpOverrides;
  final settings = List<String>.from(appdata.settings);

  String url(String name) =>
      'http://${server.address.address}:${server.port}/$name.jpg';

  Stream<DownloadProgress> load(String name) => manager.getJmImage(
        url(name),
        null,
        epsId: '200000',
        scrambleId: '1',
        bookId: name,
      );

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('jm-image-cache-');
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
    manager = ImageManager();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serving = server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.contentLength = responseBytes.length;
      request.response.add(responseBytes);
      await request.response.close();
    });
  });

  setUp(() => responseBytes = sourceBytes);

  tearDownAll(() async {
    await JmRecombine.shutdown();
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
    await serving.cancel();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test('recombined JM cache contains exactly one copy of the returned image',
      () async {
    final completed = await load('single-copy').last;
    final bytes = completed.data!;

    expect(image.decodeJpg(bytes), isNotNull);
    expect(bytes, isNot(sourceBytes));
    expect(await completed.getFile().readAsBytes(), bytes,
        reason: 'only the cache writer may persist the recombined bytes');
    expect(
        await CacheManager().findCache(url('single-copy')), completed.savePath);
    expect(ImageManager.haveTask, isFalse);
  });

  test('cancelling before recombination cannot commit an image cache',
      () async {
    final filesBefore = await Directory(CacheManager.cachePath)
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File)
        .length;
    final owner = Object();
    final operation =
        ImageManager.withTaskOwner(load('cancelled'), owner).map((progress) {
      if (progress.currentBytes == sourceBytes.length &&
          progress.expectedBytes == (sourceBytes.length / 0.75).toInt()) {
        ImageManager.cancelTasksForOwner(owner);
      }
      return progress;
    }).toList();

    await expectLater(
      operation,
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );
    expect(await CacheManager().findCache(url('cancelled')), isNull);
    expect(ImageManager.haveTask, isFalse);
    final files = await Directory(CacheManager.cachePath)
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File)
        .length;
    expect(files, filesBefore, reason: 'cancelled writes must leave no file');
  });

  test('invalid JM bytes release the writer and allow same-key recovery',
      () async {
    responseBytes = Uint8List.fromList(<int>[1, 2, 3]);
    await expectLater(load('recovery').last, throwsA(isA<Exception>()));
    expect(await CacheManager().findCache(url('recovery')), isNull);
    expect(ImageManager.haveTask, isFalse);

    responseBytes = sourceBytes;
    final completed = await load('recovery').last;
    expect(await completed.getFile().readAsBytes(), completed.data);
    expect(ImageManager.haveTask, isFalse);
  });
}
