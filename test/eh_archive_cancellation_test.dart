import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelled archive link resolution does not send its POST', () async {
    final root = await Directory.systemTemp.createTemp('eh-link-cancel-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serving = server.listen((request) async {
      requestCount++;
      request.response.contentLength = 0;
      await request.response.close();
    });
    final settings = List<String>.from(appdata.settings);
    final previousProxy = proxyHttpOverrides;
    final previousCookieJar = SingleInstanceCookieJar.instance;
    if (previousCookieJar == null) {
      SingleInstanceCookieJar('${root.path}/cookies.sqlite');
    }
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    proxyHttpOverrides = null;
    final token = CancelToken()..cancel('archive task stopped');

    try {
      final network = EhNetwork.create();
      await expectLater(
        network.getArchiveDownloadLink(
          'http://${server.address.address}:${server.port}/archive',
          0,
          cancelToken: token,
        ),
        throwsA(isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        )),
      );
      expect(requestCount, 0);
    } finally {
      appdata.settings = settings;
      proxyHttpOverrides = previousProxy;
      if (previousCookieJar == null) {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
      }
      await serving.cancel();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });

  test('stop while resolving proxy prevents the archive worker from spawning',
      () async {
    final root = await Directory.systemTemp.createTemp('eh-archive-spawn-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serving = server.listen((request) async {
      requestCount++;
      request.response.contentLength = 0;
      await request.response.close();
    });
    final proxy = Completer<String?>();
    final downloader = EhArchiveDownloader(
      'http://${server.address.address}:${server.port}/archive.zip',
      '${root.path}/comic',
      (_, __, ___) {},
      () => fail('a cancelled worker must not report an error'),
      () => fail('a cancelled worker must not finish'),
      proxyProvider: () => proxy.future,
    );

    try {
      final starting = downloader.start();
      await Future<void>.delayed(Duration.zero);
      await downloader.stop();
      proxy.complete(null);
      await starting;

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requestCount, 0);
      expect(await Directory('${root.path}/comic').exists(), isFalse);
    } finally {
      if (!proxy.isCompleted) proxy.complete(null);
      await serving.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('stop during archive transfer waits before deleting its output folder',
      () async {
    final root = await Directory.systemTemp.createTemp('eh-archive-stop-');
    final saveDirectory = Directory('${root.path}/comic');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodyStarted = Completer<void>();
    final bodyGate = Completer<void>();
    final serving = server.listen((request) async {
      final response = request.response;
      if (request.method == 'HEAD') {
        response.contentLength = 1024 * 1024;
        await response.close();
        return;
      }

      response.statusCode = HttpStatus.ok;
      response.contentLength = 1024 * 1024;
      response.add(List<int>.filled(64 * 1024, 0x41));
      await response.flush();
      if (!bodyStarted.isCompleted) bodyStarted.complete();
      await bodyGate.future;
      try {
        response.add(List<int>.filled(64 * 1024, 0x42));
        await response.close();
      } on HttpException {
        // The client closes the response stream when cancellation reaches Dio.
      }
    });
    var errors = 0;
    var finishes = 0;
    final downloader = EhArchiveDownloader(
      'http://${server.address.address}:${server.port}/archive.zip',
      saveDirectory.path,
      (_, __, ___) {},
      () => errors++,
      () => finishes++,
      proxyProvider: () async => null,
    );

    try {
      final starting = downloader.start();
      await bodyStarted.future.timeout(const Duration(seconds: 5));
      final archiveFile = File('${saveDirectory.path}/temp.zip');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await archiveFile.exists() || await archiveFile.length() == 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
              'archive transfer did not write its first chunk');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await stopAndDeleteEhArchiveDirectory(
        path: saveDirectory.path,
        stopWorker: downloader.stop,
      ).timeout(const Duration(seconds: 8));
      expect(await saveDirectory.exists(), isFalse);

      bodyGate.complete();
      await starting.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(await saveDirectory.exists(), isFalse,
          reason:
              'a stopped worker must not recreate its deleted output folder');
      expect(errors, 0);
      expect(finishes, 0);
    } finally {
      if (!bodyGate.isCompleted) bodyGate.complete();
      await serving.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}
