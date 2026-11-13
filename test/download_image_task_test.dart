import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/download_progress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancel waits for pending cache-file read before directory cleanup',
      () async {
    final temp = await Directory.systemTemp.createTemp('image-task-cancel-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final destination = Directory('${temp.path}/comic');
    await destination.create();
    final output = File('${destination.path}/0.png');
    final readStarted = Completer<void>();
    final readGate = Completer<List<int>>();
    final source = StreamController<DownloadProgress>();
    final cancelTask = createImageDownloadTaskCancelForTesting(
      source.stream,
      destination.path,
      '0',
      readData: (_) {
        readStarted.complete();
        return readGate.future;
      },
    );

    source.add(const DownloadProgress(1, 1, 'https://example.test/image', ''));
    await readStarted.future;

    var cleanupFinished = false;
    final cleanup = cancelTask().then((_) async {
      await destination.delete(recursive: true);
      cleanupFinished = true;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(cleanupFinished, isFalse,
          reason: 'cleanup must wait for the in-flight file read');
    } finally {
      if (!readGate.isCompleted) {
        readGate.complete(image.encodePng(image.Image(width: 1, height: 1)));
      }
    }

    await cleanup;
    await Future<void>.delayed(Duration.zero);
    expect(await output.exists(), isFalse);
    expect(await destination.exists(), isFalse,
        reason: 'a cancelled task must not recreate a deleted directory');
    await source.close();
  });
}
