import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/download_progress.dart';

import 'file_downloader_regression.dart';

class _LinksFixtureDownloadingItem extends DownloadingItem {
  _LinksFixtureDownloadingItem(this._responses)
      : super(null, null, null, 'links-fixture', type: DownloadType.other);

  final List<Map<int, List<String>>> _responses;
  int fetchCount = 0;

  @override
  Future<Map<int, List<String>>> getLinks() async {
    return _responses[fetchCount++];
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) => const Stream.empty();

  @override
  String get cover => '';

  @override
  String get title => 'links fixture';

  @override
  Map<String, dynamic> toMap() => const {};

  @override
  Future<DownloadedItem> toDownloadedItem() => throw UnimplementedError();
}

void main() {
  for (final scenario in fileDownloadCases) {
    test(scenario, () async {
      final overrides = HttpOverrides.current;
      addTearDown(() => HttpOverrides.global = overrides);
      await HttpOverrides.runZoned(() => verifyFileDownload(scenario));
    });
  }

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

  test('image task waits for asynchronous completion callback', () async {
    final temp = await Directory.systemTemp.createTemp('image-task-finish-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final callbackStarted = Completer<void>();
    final callbackGate = Completer<void>();
    final source = Stream<DownloadProgress>.value(
      const DownloadProgress(
        1,
        1,
        'https://example.test/image',
        '',
      ),
    );
    final completion = runImageDownloadTaskForTesting(
      source,
      temp.path,
      '0',
      readData: (_) async => image.encodePng(image.Image(width: 1, height: 1)),
      onFinished: () async {
        callbackStarted.complete();
        await callbackGate.future;
      },
    );

    await callbackStarted.future;
    var completed = false;
    completion.whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    callbackGate.complete();
    expect(await completion, isNull);
    expect(completed, isTrue);
  });

  test('image task exposes completion callback errors', () async {
    final temp = await Directory.systemTemp.createTemp('image-task-error-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final error = await runImageDownloadTaskForTesting(
      Stream<DownloadProgress>.value(
        const DownloadProgress(1, 1, 'https://example.test/image', ''),
      ),
      temp.path,
      '0',
      readData: (_) async => image.encodePng(image.Image(width: 1, height: 1)),
      onFinished: () => throw StateError('finish callback failed'),
    );

    expect(error, isA<StateError>());
  });

  test('download progress reserves completion for a separate event', () {
    final exactLength =
        DownloadProgress.inProgress(128, 128, 'image', '/tmp/image');
    expect(exactLength.finished, isFalse);
    expect(exactLength.expectedBytes, 129);

    final overrun =
        DownloadProgress.inProgress(129, 128, 'image', '/tmp/image');
    expect(overrun.finished, isFalse);

    final unknownLength =
        DownloadProgress.inProgress(128, null, 'image', '/tmp/image');
    expect(unknownLength.finished, isFalse);

    const completed = DownloadProgress(128, 128, 'image', '/tmp/image');
    expect(completed.finished, isTrue);

    const validated = DownloadProgress(
        128, 128, 'image', '/tmp/image', null, null, 'image', true);
    expect(validated.imageValidated, isTrue);
  });

  test('empty page links cannot be accepted as a completed download', () async {
    final item = _LinksFixtureDownloadingItem([
      <int, List<String>>{},
      <int, List<String>>{
        0: ['page']
      },
    ]);

    await expectLater(
      item.ensureDownloadLinksForTesting(),
      throwsA(isA<FormatException>()),
    );
    expect(item.links, isNull);

    await item.ensureDownloadLinksForTesting();
    expect(item.fetchCount, 2);
    expect(item.links, <int, List<String>>{
      0: ['page']
    });
  });

  test('a chapter with no pages is not a valid download snapshot', () async {
    final item = _LinksFixtureDownloadingItem([
      <int, List<String>>{
        0: ['page'],
        1: <String>[]
      },
    ]);

    await expectLater(
      item.ensureDownloadLinksForTesting(),
      throwsA(isA<FormatException>()),
    );
    expect(item.links, isNull);
  });
}
