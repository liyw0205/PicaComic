import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/pdf.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUp(RuntimeMetrics.reset);

  Future<Directory> createComic() async {
    final root = await Directory.systemTemp.createTemp('pica-pdf-');
    // A tiny PNG is sufficient for pdf's image decoder and keeps this test
    // independent of platform image encoders.
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final bytes = <int>[..._decodeBase64(png)];
    await File('${root.path}/cover.png').writeAsBytes(bytes);
    await File('${root.path}/0.png').writeAsBytes(bytes);
    await File('${root.path}/1.png').writeAsBytes(bytes);
    final rotated = image.Image(width: 2, height: 3);
    rotated.exif.imageIfd.orientation = 6;
    await File('${root.path}/2.jpg')
        .writeAsBytes(image.encodeJpg(rotated, quality: 90));
    return root;
  }

  Future<ByteData> loadFont() async {
    final file = File('fonts/NotoSansSC-Regular.ttf');
    expect(await file.exists(), isTrue,
        reason: 'the project font is required by the PDF export contract');
    return ByteData.sublistView(await file.readAsBytes());
  }

  Future<bool> supportsFullLengthName(Directory directory) async {
    final probe = File('${directory.path}/${List.filled(255, 'p').join()}');
    try {
      await probe.writeAsBytes([]);
      await probe.delete();
      return true;
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 36) rethrow;
      markTestSkipped('The test runtime rejects 255-byte file names.');
      return false;
    }
  }

  test('cancellation between pages leaves the previous target intact',
      () async {
    final comic = await createComic();
    addTearDown(() => comic.delete(recursive: true));
    final output = File('${comic.path}/result.pdf');
    await output.writeAsString('previous complete PDF');
    final cancellation = PdfExportCancellation();

    await expectLater(
      createPdfFromComic(
        title: 'cancel test',
        comicPath: comic.path,
        savePath: output.path,
        font: await loadFont(),
        cancellation: cancellation,
        onProgress: (progress) {
          if (progress.completedPages == 1) cancellation.cancel();
        },
      ),
      throwsA(isA<PdfExportCancelledException>()),
    );
    expect(await output.readAsString(), 'previous complete PDF');
    final leftovers = await comic
        .list()
        .where((entry) => entry.path.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
    expect(RuntimeMetrics.snapshot()['pdf.export']?.cancelled, 1);
  });

  test('rejects an oversized page before decoding and preserves the target',
      () async {
    final comic = await createComic();
    addTearDown(() => comic.delete(recursive: true));
    final output = File('${comic.path}/result.pdf');
    await output.writeAsString('previous complete PDF');
    final oversized = File('${comic.path}/0.png');
    await oversized.writeAsBytes(List<int>.filled(257, 0));

    await expectLater(
      createPdfFromComic(
        title: 'large image test',
        comicPath: comic.path,
        savePath: output.path,
        font: await loadFont(),
        maxImageBytes: 256,
      ),
      throwsA(isA<PdfExportImageTooLargeException>()),
    );
    expect(await output.readAsString(), 'previous complete PDF');
    final leftovers = await comic
        .list()
        .where((entry) => entry.path.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
    expect(RuntimeMetrics.snapshot()['pdf.export']?.failure, 1);
  });

  test('rejects an oversized decoded image by pixel count', () async {
    final comic = await createComic();
    addTearDown(() => comic.delete(recursive: true));
    final output = File('${comic.path}/result.pdf');

    await expectLater(
      createPdfFromComic(
        title: 'pixel limit test',
        comicPath: comic.path,
        savePath: output.path,
        font: await loadFont(),
        maxImagePixels: 2,
      ),
      throwsA(isA<PdfExportImageTooLargeException>()),
    );
    expect(await output.exists(), isFalse);
  });

  test('successful export reports pages and installs a complete PDF', () async {
    final comic = await createComic();
    addTearDown(() => comic.delete(recursive: true));
    final output = File('${comic.path}/result.pdf');
    final progress = <PdfExportProgress>[];

    await createPdfFromComic(
      title: 'success test',
      comicPath: comic.path,
      savePath: output.path,
      font: await loadFont(),
      onProgress: progress.add,
      batchSize: 1,
    );

    final bytes = await output.readAsBytes();
    expect(bytes.take(5), <int>[37, 80, 68, 70, 45]);
    expect(progress.first.completedPages, 0);
    expect(progress.last.completedPages, 4);
    expect(progress.last.totalPages, 4);
    final metric = RuntimeMetrics.snapshot()['pdf.export']!;
    expect(metric.success, 1);
    expect(metric.bytes, greaterThan(0));
  });

  for (final length in [254, 255]) {
    test('PDF atomic output supports a $length-byte file name', () async {
      final comic = await createComic();
      addTearDown(() => comic.delete(recursive: true));
      if (length == 255 && !await supportsFullLengthName(comic)) return;
      final name = '${List.filled(length - 4, 'x').join()}.pdf';
      final output = File('${comic.path}/$name');

      await createPdfFromComic(
        title: 'Long file name',
        comicPath: comic.path,
        savePath: output.path,
        font: await loadFont(),
      );

      expect((await output.readAsBytes()).take(5), [37, 80, 68, 70, 45]);
      expect(
          await comic
              .list()
              .where((entry) =>
                  entry.path != output.path &&
                  (entry.name.startsWith('.pica-') ||
                      entry.name.endsWith('.tmp')))
              .toList(),
          isEmpty);
    });
  }

  test('cancelled isolate export records a parent metric', () async {
    final cancellation = PdfExportCancellation()..cancel();
    await expectLater(
      createPdfFromComicWithIsolate(
        title: 'cancelled isolate',
        comicPath: '/missing/comic',
        savePath: '/missing/output.pdf',
        cancellation: cancellation,
      ),
      throwsA(isA<PdfExportCancelledException>()),
    );

    final metric = RuntimeMetrics.snapshot()['pdf.export']!;
    expect(metric.cancelled, 1);
    expect(metric.active, 0);
  });

  group('download PDF file names', () {
    late Directory root;
    late String previousDownloadPath;
    final manager = DownloadManager();

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('pdf-file-names-');
      App.dataPath = root.path;
      App.cachePath = '${root.path}/cache';
      await Directory(App.cachePath).create();
      await File('fonts/NotoSansSC-Regular.ttf').copy('${root.path}/font.ttf');
      previousDownloadPath = appdata.settings[22];
      appdata.settings[22] = '${root.path}/downloads';
      await Directory(appdata.settings[22]).create();
      final comic = await createComic();
      await comic.rename('${appdata.settings[22]}/comic');
      final db = sqlite3.open('${appdata.settings[22]}/download.db');
      db.execute('''
        create table download (
          id text primary key, title text, subtitle text, time int,
          directory text, size int, json text
        )
      ''');
      db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)',
          ['nhentai123', 'Fixture', '', 0, 'comic', 1, '{}']);
      db.dispose();
      await manager.init();
      AppTranslation.translations = const {};
    });

    tearDownAll(() async {
      await manager.dispose();
      manager.path = null;
      appdata.settings[22] = previousDownloadPath;
      await root.delete(recursive: true);
    });

    for (final fixture in [
      (name: 'ASCII', title: List.filled(255, 'x').join()),
      (name: 'Unicode', title: '${List.filled(83, '\u4e2d').join()}\u{1f600}'),
    ]) {
      testWidgets(
          'exports a long ${fixture.name} title through the download page',
          (tester) async {
        if (fixture.name == 'ASCII') {
          final supported =
              await tester.runAsync(() => supportsFullLengthName(root));
          if (supported != true) return;
        }
        final output = File('${root.path}/${fixture.name}.pdf');
        var saves = 0;
        const channels = [
          MethodChannel('plugins.flutter.io/file_selector'),
          MethodChannel('plugins.flutter.dev/file_selector_linux'),
          MethodChannel('flutter_file_dialog'),
        ];
        for (final channel in channels) {
          tester.binding.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
            saves++;
            final args = call.arguments as Map;
            final sourcePath = args['sourceFilePath'] as String?;
            final name = sourcePath == null
                ? args['suggestedName'] as String
                : File(sourcePath).name;
            expect(name, endsWith('.pdf'));
            expect(utf8.encode(name).length, lessThanOrEqualTo(255));
            expect(utf8.decode(utf8.encode(name)), name);
            final source = File(sourcePath ?? '${App.cachePath}/$name');
            expect((await source.readAsBytes()).take(5), [37, 80, 68, 70, 45]);
            if (sourcePath != null) await source.copy(output.path);
            return output.path;
          });
        }
        addTearDown(() {
          for (final channel in channels) {
            tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }
          hideAllMessages();
        });
        await tester.pumpWidget(MaterialApp(
          navigatorKey: App.navigatorKey,
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const OverlayWidget(Scaffold(body: SizedBox())),
        ));

        await tester.runAsync(() => const DownloadPage().exportAsPdf(
            NhentaiDownloadedComic('nhentai123', fixture.title, 1, '', []),
            DownloadPageLogic()));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));

        expect(saves, 1);
        final bytes = await tester.runAsync(output.readAsBytes);
        expect(bytes!.take(5), [37, 80, 68, 70, 45]);
        final leftovers = await tester
            .runAsync(() => Directory(App.cachePath).list().toList());
        expect(leftovers, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });
}

List<int> _decodeBase64(String value) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final output = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit == 61) break;
    final index = alphabet.indexOf(String.fromCharCode(codeUnit));
    if (index < 0) continue;
    buffer = (buffer << 6) | index;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      output.add((buffer >> bits) & 255);
    }
  }
  return output;
}
