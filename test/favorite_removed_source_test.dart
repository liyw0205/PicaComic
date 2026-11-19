import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/pages/favorites/local_favorites.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _Routes extends NavigatorObserver {
  final pages = <AppPageRoute>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is AppPageRoute) pages.add(route);
  }
}

class _ReadTrackingTile extends LocalFavoriteTile {
  _ReadTrackingTile(FavoriteItem comic) : super(comic, 'Folder', () {}, true);
  final reads = <Object>[];
  @override
  VoidCallback get read => () => reads.add(Object());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late DownloadManager manager;
  late Directory root;
  late Directory tempDir;
  late String? previousPath;
  late String previousDownloadSetting;
  late String previousTapSetting;
  late String previousSyncSetting;
  late List<ComicSource> previousSources;
  late GlobalKey<NavigatorState>? previousMainNavigator;

  const sourceKey = 'removed-source-alpha';
  const comicId = 'same-comic-id';
  const matchingId = '$sourceKey-$comicId';
  const otherSourceKey = 'removed-source-beta';
  const otherId = '$otherSourceKey-$comicId';
  const chapters = {'chapter-1': 'Chapter 1', 'chapter-2': 'Chapter 2'};

  CustomDownloadedItem download(
          {String key = sourceKey,
          String target = comicId,
          String? id,
          Map<String, String>? eps = chapters}) =>
      CustomDownloadedItem(
          1.5,
          eps == null ? [] : [0, 1],
          eps,
          id ?? '$key-$target',
          'Fixture comic',
          'Author',
          const [],
          key,
          'Removed source',
          'cover.jpg',
          target);

  FavoriteItem favorite({String key = sourceKey, String target = comicId}) =>
      FavoriteItem(
          target: target,
          name: 'Fixture comic',
          coverPath: '',
          author: 'Author',
          type: FavoriteType(key.hashCode),
          tags: const []);

  Future<void> seed(List<CustomDownloadedItem> items,
      {List<(String, String)> invalidRows = const []}) async {
    final db = sqlite3.open('${tempDir.path}/download.db');
    try {
      db.execute('''create table download (
        id text primary key, title text, subtitle text, time int,
        directory text, size real, json text);''');
      for (final row in invalidRows) {
        db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)',
            [row.$1, 'Invalid', '', 0, 'invalid', 0.0, row.$2]);
      }
      for (final item in items) {
        final directory = 'book-${items.indexOf(item)}';
        await Directory('${tempDir.path}/$directory').create();
        db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)', [
          item.id,
          item.name,
          item.subTitle,
          1,
          directory,
          item.comicSize,
          jsonEncode(item.toJson()),
        ]);
      }
    } finally {
      db.dispose();
    }
    await manager.init();
  }

  Future<_Routes> mount(WidgetTester tester) async {
    final observer = _Routes();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [observer],
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const OverlayWidget(Scaffold(body: SizedBox.shrink())),
    ));
    App.mainNavigatorKey = App.navigatorKey;
    return observer;
  }

  Future<ComicReadingPage> destination(
      WidgetTester tester, _Routes observer) async {
    expect(observer.pages, hasLength(1));
    final reader =
        observer.pages.single.builder(App.globalContext!) as ComicReadingPage;
    // Exercise local data without mounting the complete reader.
    await tester.pumpWidget(const SizedBox.shrink());
    return reader;
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-removed-source-');
    App.dataPath = root.path;
  });
  setUp(() async {
    manager = DownloadManager();
    previousPath = manager.path;
    previousDownloadSetting = appdata.settings[22];
    previousTapSetting = appdata.settings[60];
    previousSyncSetting = appdata.settings[45];
    previousSources = ComicSource.sources;
    previousMainNavigator = App.mainNavigatorKey;
    await manager.dispose();
    ComicSource.sources = [];
    tempDir = await root.createTemp('downloads-');
    manager.path = tempDir.path;
    appdata.settings[22] = tempDir.path;
    appdata.settings[45] = '';
    await HistoryManager()
        .init(databasePath: '${tempDir.path}/history.db', importLegacy: false);
  });
  tearDown(() async {
    hideAllMessages();
    final logic = StateController.findOrNull<ComicReadingPageLogic>();
    if (logic != null) {
      logic.releaseImageTasks();
      await logic.readerImages.waitForIdle();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.focusNode.dispose();
      StateController.remove<ComicReadingPageLogic>();
    }
    await manager.dispose();
    HistoryManager().close();
    manager.path = previousPath;
    appdata.settings[22] = previousDownloadSetting;
    appdata.settings[60] = previousTapSetting;
    appdata.settings[45] = previousSyncSetting;
    ComicSource.sources = previousSources;
    App.mainNavigatorKey = previousMainNavigator;
    await tempDir.delete(recursive: true);
  });
  tearDownAll(() => root.delete(recursive: true));

  test('removed sources resolve the exact copy and invalidate deleted entries',
      () async {
    await seed([download(), download(key: otherSourceKey)]);
    final item = favorite();
    expect(item.available, isFalse);
    expect(item.toDownloadId(), matchingId);
    expect(favorite(key: otherSourceKey).toDownloadId(), otherId);
    await manager.delete([matchingId]);
    expect(item.toDownloadId(), '**Invalid ID**');
    expect(manager.isExists(otherId), isTrue);
    expect(favorite(key: otherSourceKey).toDownloadId(), otherId);
  });

  test('installed sources retain their brief ID normalization', () async {
    await seed([download(id: '$sourceKey-42')]);
    ComicSource.sources = [
      ComicSource.named(
          name: 'Fixture',
          key: sourceKey,
          filePath: 'fixture',
          matchBriefIdReg: r'/book/(\d+)')
    ];
    final item = favorite(target: 'https://fixture.invalid/book/42');
    expect(item.available, isTrue);
    expect(item.toDownloadId(), '$sourceKey-42');
  });

  test('unavailable storage returns no recovered copy', () async {
    await seed([download()]);
    expect(favorite().toDownloadId(), matchingId);
    await manager.dispose();
    expect(favorite().toDownloadId(), '**Invalid ID**');
  });

  test('root changes do not reuse a copy from the previous root', () async {
    await seed([download()]);
    expect(favorite().toDownloadId(), matchingId);
    await manager.dispose();
    final next = await tempDir.createTemp('next-root-');
    manager.path = next.path;
    appdata.settings[22] = next.path;
    await manager.init();
    expect(favorite().toDownloadId(), '**Invalid ID**');
  });

  test('record updates invalidate the recovered source identity', () async {
    await seed([download()]);
    expect(favorite().toDownloadId(), matchingId);
    manager.updateComic(
        matchingId, (_) => download(key: otherSourceKey, id: matchingId));
    expect(favorite().toDownloadId(), '**Invalid ID**');
    expect(favorite(key: otherSourceKey).toDownloadId(), matchingId);
  });

  test('invalid matching metadata cannot hide the valid downloaded copy',
      () async {
    await seed([
      download()
    ], invalidRows: [
      ('bad-json', '{'),
      ('partial-row', jsonEncode({'sourceKey': sourceKey, 'comicId': comicId})),
      (
        'wrong-row-id',
        jsonEncode(download(id: 'different-payload-id').toJson())
      ),
    ]);
    expect(favorite().toDownloadId(), matchingId);
  });

  test('multiple copies with the same stored identity are ambiguous', () async {
    await seed([download(), download(id: 'second-copy')]);
    expect(favorite().toDownloadId(), '**Invalid ID**');
  });

  for (final singleChapter in [false, true]) {
    testWidgets('removed source reads local pages (single: $singleChapter)',
        (tester) async {
      final item = download(eps: singleChapter ? null : chapters);
      final bytes = [10, 20, 30, 40];
      await tester.runAsync(() async {
        await seed([item]);
        final path = '${tempDir.path}/book-0/${singleChapter ? '' : '2/'}0.jpg';
        await File(path).create(recursive: true);
        await File(path).writeAsBytes(bytes);
        await File('${tempDir.path}/book-0/cover.jpg').writeAsBytes(bytes);
        await HistoryManager().addHistory(History(
            HistoryType(sourceKey.hashCode),
            DateTime.now(),
            item.name,
            '',
            '',
            singleChapter ? 1 : 2,
            1,
            comicId));
      });
      final observer = await mount(tester);
      await tester.runAsync(() async {
        final stored = (await manager.getComicOrNull(item.id))!;
        await stored.read();
      });
      final reader = await destination(tester, observer);
      final data = reader.readingData;
      expect(reader.initialEp, singleChapter ? 1 : 2);
      expect(reader.initialPage, 1);
      expect(data.id, comicId);
      expect(data.sourceKey, sourceKey);
      expect(data.favoriteType, FavoriteType(sourceKey.hashCode));
      expect(data.downloadId, matchingId);
      expect(data.downloaded, isTrue);
      final ep = singleChapter ? 1 : 2;
      final pages = await tester.runAsync(() => data.loadEp(ep));
      expect(pages!.error, isFalse);
      expect(pages.data, ['']);
      final image = await tester.runAsync(() => data.loadImage(ep, 0, '').last);
      expect(
          await tester.runAsync(() => image!.getFile().readAsBytes()), bytes);
      expect((await data.loadEpNetwork(ep)).error, isTrue);
    });
  }

  testWidgets('download reading preserves the original unnormalized comic ID',
      (tester) async {
    const target = 'https://fixture.invalid/book/42';
    final item = download(target: target, id: '$sourceKey-42');
    await tester.runAsync(() => seed([item]));
    final observer = await mount(tester);
    await tester.runAsync(() => item.read());
    final reader = await destination(tester, observer);
    expect(reader.readingData.id, target);
    expect(reader.readingData.downloadId, item.id);
    expect(HistoryManager().findSync(target), isNotNull);
    expect(HistoryManager().findSync('42'), isNull);
  });

  for (final tapSetting in ['0', '1']) {
    testWidgets('removed downloaded favorite permits offline tap ($tapSetting)',
        (tester) async {
      await tester.runAsync(() => seed([download()]));
      appdata.settings[60] = tapSetting;
      await mount(tester);
      final tile = _ReadTrackingTile(favorite());
      tile.onTap_();
      expect(tile.reads, hasLength(1));
      expect(tile.badge, '已下载');
    });
  }

  testWidgets('removed favorite without a local copy stays unavailable',
      (tester) async {
    await tester.runAsync(() => seed([]));
    await mount(tester);
    final tile = _ReadTrackingTile(favorite());
    tile.onTap_();
    await tester.pump();
    expect(tile.reads, isEmpty);
    expect(tile.badge, isNull);
    expect(find.text('无效的漫画'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('removed source details report unavailable without throwing',
      (tester) async {
    await tester.runAsync(() => seed([download()]));
    final observer = await mount(tester);
    final tile = LocalFavoriteTile(favorite(), 'Folder', () {}, true);
    expect(tile.showInfo, returnsNormally);
    await tester.pump();
    expect(observer.pages, isEmpty);
    expect(find.text('无效的漫画'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
