import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/image_loader/file_image_loader.dart';
import 'package:pica_comic/network/download.dart';
import 'package:sqlite3/sqlite3.dart';

Future<(int, int)> readImage(ImageStream stream) {
  final result = Completer<(int, int)>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!result.isCompleted) {
        result.complete((info.image.width, info.image.height));
      }
      info.dispose();
    },
    onError: (Object error, StackTrace? stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return result.future
      .timeout(const Duration(seconds: 8))
      .whenComplete(() => stream.removeListener(listener));
}

Future<Object> readError(ImageStream stream) {
  final result = Completer<Object>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      info.dispose();
      if (!result.isCompleted) {
        result.completeError(StateError('Expected image loading to fail'));
      }
    },
    onError: (Object error, StackTrace? stack) {
      if (!result.isCompleted) result.complete(error);
    },
  );
  stream.addListener(listener);
  return result.future
      .timeout(const Duration(seconds: 8))
      .whenComplete(() => stream.removeListener(listener));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  late Directory root;
  late DownloadManager manager;
  late String previousPath;

  setUp(() async {
    manager = DownloadManager();
    await manager.dispose();
    root = await Directory.systemTemp.createTemp('pica-file-provider-');
    previousPath = appdata.settings[22];
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await manager.dispose();
    manager.path = null;
    appdata.settings[22] = previousPath;
    await root.delete(recursive: true);
  });

  Future<File> createImage(String id, String directory, int episode,
      {bool empty = false, bool longParent = false}) async {
    final parent = longParent
        ? '${root.path}/download-${List.filled(48, 'p').join()}'
        : root.path;
    appdata.settings[22] = parent;
    await manager.init();
    final db = sqlite3.open('$parent/download.db');
    try {
      db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)',
          [id, 'Fixture comic', '', 0, directory, 1, '{}']);
    } finally {
      db.dispose();
    }
    final path = episode == 0
        ? '$parent/$directory/0.png'
        : '$parent/$directory/$episode/0.png';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(empty ? [] : png);
    return file;
  }

  test('downloaded image loads from the single-chapter layout', () async {
    await createImage('short-image', 'short-directory', 0);
    const provider = FileImageProvider('short-image', 0, 0);

    expect(await readImage(provider.resolve(ImageConfiguration.empty)), (1, 1));
  });

  test('downloaded chapter image loads through a long Unicode path', () async {
    final directory = '${List.filled(190, 'x').join()}-\u6f2b\u753b-\u{1f4da}';
    final file =
        await createImage('unicode-image', directory, 1, longParent: true);
    expect(file.path.length, greaterThan(260));
    expect(file.path.runes.any((rune) => rune > 127), isTrue);
    const provider = FileImageProvider('unicode-image', 1, 0);

    expect(await readImage(provider.resolve(ImageConfiguration.empty)), (1, 1));
  });

  test('an empty downloaded file can recover with the same image key',
      () async {
    final file =
        await createImage('recover-image', 'recover-directory', 0, empty: true);
    const provider = FileImageProvider('recover-image', 0, 0);

    expect(await readError(provider.resolve(ImageConfiguration.empty)),
        isA<StateError>());
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);

    await file.writeAsBytes(png);

    expect(await readImage(provider.resolve(ImageConfiguration.empty)), (1, 1));
  });
}
