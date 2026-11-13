import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/download_progress.dart';
import 'package:pica_comic/tools/translations.dart';

class _RetryFixture extends DownloadingItem {
  _RetryFixture(String id, {this.failOnStart = false})
      : super(null, null, null, id, type: DownloadType.favorite) {
    directory = id;
  }

  final bool failOnStart;
  int startCount = 0;
  final retryWaitStarted = Completer<void>();
  final retryWaitGate = Completer<void>();

  @override
  void start() {
    startCount++;
    if (failOnStart && startCount == 1) super.start();
  }

  @override
  Future<void> waitBeforeRetry(Duration duration) {
    if (!retryWaitStarted.isCompleted) retryWaitStarted.complete();
    return retryWaitGate.future;
  }

  @override
  Future<void> stop() => super.pause();

  @override
  String get cover => '';

  @override
  Future<Map<int, List<String>>> getLinks() async =>
      throw StateError('fixture download failure');

  @override
  Stream<DownloadProgress> downloadImage(String link) => const Stream.empty();

  @override
  String get title => id;

  @override
  Map<String, dynamic> toMap() => toBaseMap();

  @override
  FutureOr<DownloadedItem> toDownloadedItem() => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  late DownloadManager manager;
  late Directory temp;
  late String? oldPath;
  late bool oldIsDownloading;
  late List<DownloadingItem> oldQueue;

  setUp(() async {
    manager = DownloadManager();
    oldPath = manager.path;
    oldIsDownloading = manager.isDownloading;
    oldQueue = manager.downloading.toList();
    manager.downloading.clear();
    manager.isDownloading = false;
    temp = await Directory.systemTemp.createTemp('download-retry-test-');
    manager.path = temp.path;
  });

  tearDown(() async {
    manager.downloading.clear();
    manager.downloading.addAll(oldQueue);
    manager.path = oldPath;
    manager.isDownloading = oldIsDownloading;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<_RetryFixture> beginFailingItem() async {
    final item = _RetryFixture('retry-item', failOnStart: true);
    manager.downloading.add(item);
    manager.isDownloading = true;
    item.start();
    await item.retryWaitStarted.future;
    return item;
  }

  test('pause during retry backoff prevents the item from restarting',
      () async {
    final item = await beginFailingItem();

    await manager.pause();
    item.retryWaitGate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(item.startCount, 1);
    expect(manager.isDownloading, isFalse);
  });

  test('cancel during retry backoff does not restart the removed item',
      () async {
    final item = await beginFailingItem();
    final next = _RetryFixture('next-item');
    manager.downloading.add(next);

    await manager.cancel(item.id);
    expect(manager.downloading.first, same(next));
    expect(next.startCount, 1);

    item.retryWaitGate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(item.startCount, 1);
    expect(manager.downloading.first, same(next));
  });

  test('retry does not restart after the queue head has been replaced',
      () async {
    final item = await beginFailingItem();
    final replacement = _RetryFixture('replacement');
    manager.downloading
      ..removeFirst()
      ..addFirst(replacement);

    item.retryWaitGate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(item.startCount, 1);
    expect(manager.downloading.first, same(replacement));
    expect(replacement.startCount, 0);
  });
}
