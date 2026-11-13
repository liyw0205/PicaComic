import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/download_progress.dart';
import 'package:pica_comic/network/favorite_download.dart';
import 'package:pica_comic/tools/translations.dart';

class _TestDownloadingItem extends DownloadingItem {
  _TestDownloadingItem(String id, {DownloadProgressCallback? onFinish})
      : super(onFinish, null, null, id, type: DownloadType.favorite);

  int startCount = 0;
  int stopCount = 0;
  Completer<void>? onStarted;
  Completer<void>? onStopStarted;
  Completer<void>? stopGate;
  Completer<void>? onFinishCleanupStarted;
  Completer<void>? finishCleanupGate;
  Completer<CancelToken>? onCoverRequestStarted;
  Completer<void>? downloadedItemGate;
  DownloadedItem? downloadedItem;
  bool runBaseStart = false;
  String coverForTesting = '';
  Map<int, List<String>> linksForTesting = {};
  Stream<DownloadProgress> imageStream = const Stream.empty();

  @override
  void start() {
    startCount++;
    onStarted?.complete();
    if (runBaseStart) super.start();
  }

  @override
  Future<void> stop() async {
    stopCount++;
    await super.pause();
    onStopStarted?.complete();
    await stopGate?.future;
  }

  @override
  Future<void> downloadCover({
    bool Function()? shouldContinue,
    CancelToken? cancelToken,
  }) async {
    onCoverRequestStarted?.complete(cancelToken!);
    await super.downloadCover(
      shouldContinue: shouldContinue,
      cancelToken: cancelToken,
    );
  }

  @override
  String get cover => coverForTesting;

  @override
  Future<Map<int, List<String>>> getLinks() async => linksForTesting;

  @override
  Stream<DownloadProgress> downloadImage(String link) => imageStream;

  @override
  String get title => '';

  @override
  Map<String, dynamic> toMap() => toBaseMap();

  @override
  Future<void> waitForFinishCleanup() async {
    onFinishCleanupStarted?.complete();
    await finishCleanupGate?.future;
    await super.waitForFinishCleanup();
  }

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async {
    await downloadedItemGate?.future;
    return downloadedItem ?? (throw UnimplementedError());
  }
}

class _TestDownloadedItem implements DownloadedItem {
  @override
  double? comicSize;

  @override
  String? directory;

  @override
  List<int> get downloadedEps => const [];

  @override
  List<String> get eps => const [];

  @override
  String get id => 'fixture';

  @override
  String get name => 'fixture';

  @override
  String get subTitle => '';

  @override
  List<String> get tags => const [];

  @override
  DateTime? time;

  @override
  DownloadType get type => DownloadType.favorite;

  @override
  Map<String, dynamic> toJson() => const {};
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
    temp = await Directory.systemTemp.createTemp('favorite-download-test-');
    manager.path = temp.path;
  });

  tearDown(() async {
    manager.downloading.clear();
    manager.downloading.addAll(oldQueue);
    manager.path = oldPath;
    manager.isDownloading = oldIsDownloading;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  FavoriteDownloading createFavorite(
    Future<DownloadingItem> Function() load,
  ) {
    final favorite = FavoriteItem(
      target: 'fixture',
      name: 'fixture',
      coverPath: '',
      author: '',
      type: FavoriteType.picacg,
      tags: const [],
    );
    final item = FavoriteDownloading(
      favorite,
      () {},
      () {},
      () async {},
      'fixture',
      loadDownloadLogic: load,
    )..directory = 'fixture';
    return item;
  }

  test('duplicate start calls share one details request and start once',
      () async {
    final loadResult = Completer<DownloadingItem>();
    final started = Completer<void>();
    var loadCount = 0;
    final logic = _TestDownloadingItem('fixture')..onStarted = started;
    final favorite = createFavorite(() {
      loadCount++;
      return loadResult.future;
    });
    manager.downloading.add(favorite);
    manager.isDownloading = true;

    favorite.start();
    favorite.start();
    await Future<void>.delayed(Duration.zero);
    expect(loadCount, 1);

    loadResult.complete(logic);
    await started.future;
    expect(manager.downloading.first, same(logic));
    expect(logic.startCount, 1);
  });

  test('a changed queue head is not replaced after details load', () async {
    final loadResult = Completer<DownloadingItem>();
    var loadCount = 0;
    final logic = _TestDownloadingItem('fixture');
    final favorite = createFavorite(() {
      loadCount++;
      return loadResult.future;
    });
    final other = _TestDownloadingItem('fixture');
    manager.downloading.add(favorite);
    manager.isDownloading = true;

    favorite.start();
    await Future<void>.delayed(Duration.zero);
    expect(loadCount, 1);

    manager.downloading.removeFirst();
    manager.downloading.addFirst(other);
    loadResult.complete(logic);
    await Future<void>.delayed(Duration.zero);

    expect(manager.downloading.first, same(other));
    expect(logic.startCount, 0);
  });

  test('start during cancellation waits for stop before starting next item',
      () async {
    final stopStarted = Completer<void>();
    final stopGate = Completer<void>();
    final first = _TestDownloadingItem('first')
      ..onStopStarted = stopStarted
      ..stopGate = stopGate;
    final next = _TestDownloadingItem('next');
    manager.downloading
      ..add(first)
      ..add(next);
    manager.isDownloading = true;

    final cancellation = manager.cancel('first');
    try {
      await stopStarted.future;
      manager.start();
      expect(first.startCount, 0);
      expect(manager.isDownloading, isFalse);

      stopGate.complete();
      await cancellation;
      expect(manager.downloading.first, same(next));
      expect(first.startCount, 0);
      expect(next.startCount, 1);
      expect(manager.isDownloading, isTrue);
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await cancellation;
    }
  });

  test('pause during cancellation suppresses automatic queue restart',
      () async {
    final stopStarted = Completer<void>();
    final stopGate = Completer<void>();
    final first = _TestDownloadingItem('first')
      ..onStopStarted = stopStarted
      ..stopGate = stopGate;
    final next = _TestDownloadingItem('next');
    manager.downloading
      ..add(first)
      ..add(next);
    manager.isDownloading = true;

    final cancellation = manager.cancel('first');
    try {
      await stopStarted.future;
      await manager.pause();
      stopGate.complete();
      await cancellation;
      expect(manager.downloading.first, same(next));
      expect(next.startCount, 0);
      expect(manager.isDownloading, isFalse);
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await cancellation;
    }
  });

  test('pause cancels an in-flight cover request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<HttpResponse>();
    final serving = server.listen((request) {
      if (!requestStarted.isCompleted) {
        requestStarted.complete(request.response);
      }
    });
    final coverStarted = Completer<CancelToken>();
    final item = _TestDownloadingItem('cover-cancel')
      ..directory = 'cover-cancel'
      ..runBaseStart = true
      ..coverForTesting =
          'http://${server.address.address}:${server.port}/cover.jpg'
      ..onCoverRequestStarted = coverStarted;
    manager.downloading.add(item);
    manager.isDownloading = true;

    try {
      item.start();
      final token =
          await coverStarted.future.timeout(const Duration(seconds: 5));
      await requestStarted.future.timeout(const Duration(seconds: 5));

      await item.pause();

      expect(token.isCancelled, isTrue);
      expect(await File('${item.path}/cover.jpg').exists(), isFalse);
    } finally {
      if (requestStarted.isCompleted) {
        final response = await requestStarted.future;
        try {
          await response.close();
        } catch (_) {}
      }
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('cancel during finish cleanup cannot finish the next queue item',
      () async {
    final finishCleanupStarted = Completer<void>();
    final finishCleanupGate = Completer<void>();
    final stopStarted = Completer<void>();
    final stopGate = Completer<void>();
    var finishCalls = 0;
    final firstDirectory = Directory('${temp.path}/first');
    await firstDirectory.create();
    await File('${firstDirectory.path}/cover.jpg').writeAsBytes([1]);

    final first = _TestDownloadingItem('first', onFinish: () {
      finishCalls++;
      manager.downloading.removeFirst();
    })
      ..directory = 'first'
      ..runBaseStart = true
      ..linksForTesting = {
        0: ['page']
      }
      ..imageStream = Stream.value(DownloadProgress(
          1,
          1,
          'https://example.test/page',
          '',
          Uint8List.fromList(image.encodePng(image.Image(width: 1, height: 1))),
          null,
          'page',
          true))
      ..onFinishCleanupStarted = finishCleanupStarted
      ..finishCleanupGate = finishCleanupGate
      ..onStopStarted = stopStarted
      ..stopGate = stopGate;
    final next = _TestDownloadingItem('next');
    manager.downloading
      ..add(first)
      ..add(next);
    manager.isDownloading = true;

    first.start();
    final cancellation = () async {
      await finishCleanupStarted.future;
      final cancel = manager.cancel('first');
      await stopStarted.future;
      stopGate.complete();
      await cancel;
    }();

    try {
      await cancellation;
      expect(manager.downloading.first, same(next));
      expect(next.startCount, 1);

      finishCleanupGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(finishCalls, 0);
      expect(manager.downloading.single, same(next));
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      if (!finishCleanupGate.isCompleted) finishCleanupGate.complete();
      await cancellation;
    }
  });

  test('canceling the new queue head during finish persistence starts once',
      () async {
    final oldDownloadPath = appdata.settings[22];
    appdata.settings[22] = temp.path;
    await manager.init();

    final persisted = Completer<void>();
    final first = FavoriteItem(
      target: 'fixture',
      name: 'fixture',
      coverPath: '',
      author: '',
      type: FavoriteType.picacg,
      tags: const [],
    );
    manager.isDownloading = true;
    manager.addFavoriteDownload(first);
    final logic = _TestDownloadingItem('fixture')
      ..downloadedItem = _TestDownloadedItem()
      ..downloadedItemGate = persisted;
    final completed = manager.downloading.first as FavoriteDownloading
      ..directory = 'fixture'
      ..downloadLogic = logic;
    final canceledHead = _TestDownloadingItem('canceled-head');
    final next = _TestDownloadingItem('next');
    manager.downloading
      ..add(canceledHead)
      ..add(next);

    try {
      completed.onFinish!.call();
      await Future<void>.delayed(Duration.zero);
      expect(manager.downloading.first, same(canceledHead));

      await manager.cancel(canceledHead.id);
      expect(manager.downloading.first, same(next));
      expect(next.startCount, 1);

      final finishSaveStarted = Completer<void>();
      void onSave() {
        if (!finishSaveStarted.isCompleted) finishSaveStarted.complete();
      }

      manager.addListener(onSave);
      persisted.complete();
      try {
        await finishSaveStarted.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } finally {
        manager.removeListener(onSave);
      }
      expect(next.startCount, 1);
    } finally {
      if (!persisted.isCompleted) persisted.complete();
      manager.downloading.clear();
      await manager.dispose();
      appdata.settings[22] = oldDownloadPath;
    }
  });
}
