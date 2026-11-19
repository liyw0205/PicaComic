import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/local_search_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _SearchStore extends LocalFavoritesManager {
  _SearchStore() : super.create();

  int saves = 0;
  Future<void>? beforeSave;
  bool rejectSecondInsert = false;

  @override
  Future<void> saveData() async {
    saves++;
    await beforeSave;
    await super.saveData();
  }

  @override
  bool comicExists(String folder, String target, int type) {
    if (rejectSecondInsert &&
        folder.startsWith('search result') &&
        target == '2') {
      throw StateError('Injected second insert failure');
    }
    return super.comicExists(folder, target, type);
  }

  @override
  Future<File> getCover(FavoriteItem item) =>
      Future.error(StateError('No cover in this offline fixture'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late _SearchStore store;
  late String databasePath;
  late String previousSync;
  var databaseIndex = 0;

  FavoriteItem item(String target, String title, [int type = 0]) =>
      FavoriteItem(
        target: target,
        name: title,
        coverPath: '',
        author: '',
        type: FavoriteType(type),
        tags: [],
      );

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-search-folder-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    previousSync = appdata.settings[45];
    appdata.settings[45] = '';
    store = _SearchStore();
    LocalFavoritesManager.cache = store;
    databasePath = '${directory.path}/${databaseIndex++}.db';
    await store.init(databasePath: databasePath, importLegacy: false);
    store.createFolder('Source');
    store.createFolder('Duplicate');
    await store.addComic('Source', item('1', 'Match one'), 0, false);
    await store.addComic('Source', item('2', 'Match two'), 1, false);
    await store.addComic('Source', item('3', 'Other'), 2, false);
    await store.addComic('Duplicate', item('1', 'Match one'), 0, false);
    await store.addComic(
        'Duplicate', item('1', 'Match other source', 1), 1, false);
    await DataMaintenance.waitForIdle();
    store.saves = 0;
  });

  tearDown(() {
    store.close();
    LocalFavoritesManager.cache = null;
    appdata.settings[45] = previousSync;
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<void> openSearch(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: const Scaffold(body: LocalSearchPage()),
    ));
    addTearDown(() async {
      hideAllMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Match');
    await tester.pumpAndSettle();
    expect(find.byTooltip('create folder'), findsOneWidget);
  }

  Future<void> openConfirmation(WidgetTester tester) async {
    await tester.tap(find.byTooltip('create folder'));
    await tester.pumpAndSettle();
    expect(find.text('从当前的搜索结果创建新的收藏夹'), findsOneWidget);
  }

  Future<void> submit(WidgetTester tester) async {
    final callback = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '确认'))
        .onPressed!;
    await tester.runAsync(() async => callback());
    await tester.pump();
  }

  Future<({Completer<void> release, Future<void> pending})> holdMaintenance(
      WidgetTester tester) async {
    late Completer<void> release;
    late Future<void> pending;
    await tester.runAsync(() async {
      final started = Completer<void>();
      release = Completer<void>();
      pending = DataMaintenance.run(() async {
        started.complete();
        await release.future;
      });
      await started.future;
    });
    return (release: release, pending: pending);
  }

  Future<void> finishMaintenance(WidgetTester tester,
      ({Completer<void> release, Future<void> pending}) maintenance) async {
    await tester.runAsync(() async {
      maintenance.release.complete();
      await maintenance.pending;
    });
    await tester.pumpAndSettle();
    await tester.runAsync(DataMaintenance.waitForIdle);
    await tester.pumpAndSettle();
  }

  testWidgets('search folder waits for publication and saves the batch once',
      (tester) async {
    await openSearch(tester);
    await openConfirmation(tester);
    late Completer<void> release;
    await tester.runAsync(() async {
      release = Completer<void>();
      store.beforeSave = release.future;
    });
    try {
      await submit(tester);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('从当前的搜索结果创建新的收藏夹'), findsOneWidget);
      expect(store.saves, 1);
      final comics = store.getAllComics('search result');
      expect(comics.map((comic) => (comic.target, comic.type.key)),
          [('1', 0), ('2', 0), ('1', 1)]);
    } finally {
      await tester.runAsync(() async {
        release.complete();
        await DataMaintenance.waitForIdle();
      });
      await tester.pumpAndSettle();
    }
    expect(find.text('从当前的搜索结果创建新的收藏夹'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'search folder queues the whole batch and prevents repeat confirms',
      (tester) async {
    await openSearch(tester);
    await openConfirmation(tester);
    final maintenance = await holdMaintenance(tester);
    try {
      final callback = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '确认'))
          .onPressed!;
      await tester.runAsync(() async {
        callback();
        callback();
      });
      await tester.pump();
      expect(store.folderNames, ['Source', 'Duplicate']);
      expect(store.saves, 0);
      expect(find.text('从当前的搜索结果创建新的收藏夹'), findsOneWidget);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
              .onPressed,
          isNull);
      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pump();
      expect(find.text('从当前的搜索结果创建新的收藏夹'), findsOneWidget);
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(store.count('search result'), 3);
    expect(store.saves, 1);
    expect(find.byType(LocalSearchPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated search exports choose an unused complete folder name',
      (tester) async {
    await openSearch(tester);
    for (final folder in [
      'search result',
      'search result0',
      'search result1'
    ]) {
      await openConfirmation(tester);
      await submit(tester);
      await tester.runAsync(DataMaintenance.waitForIdle);
      await tester.pumpAndSettle();
      expect(store.count(folder), 3);
    }
    expect(store.saves, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued search export rechecks case-equivalent folder names',
      (tester) async {
    await tester.runAsync(() async {
      store.createFolder('SEARCH RESULT');
      store.createFolder('search result0');
      store.createFolder('0');
      await DataMaintenance.waitForIdle();
      store.saves = 0;
    });
    await openSearch(tester);
    await openConfirmation(tester);
    final maintenance = await holdMaintenance(tester);
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    try {
      await submit(tester);
      database.execute('''
        create table "search result1" as select * from Source where 0;
      ''');
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(store.count('search result2'), 3);
    expect(store.count('SEARCH RESULT'), 0);
    expect(store.count('search result0'), 0);
    expect(store.count('search result1'), 0);
    expect(store.saves, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search confirmation retains its original database manager',
      (tester) async {
    await openSearch(tester);
    await openConfirmation(tester);
    final replacement = _SearchStore();
    await tester.runAsync(() => replacement.init(
        databasePath: '${directory.path}/replacement.db', importLegacy: false));
    try {
      LocalFavoritesManager.cache = replacement;
      await submit(tester);
      await tester.runAsync(DataMaintenance.waitForIdle);
      await tester.pumpAndSettle();
      expect(store.count('search result'), 3);
      expect(replacement.folderNames, isEmpty);
      expect(store.saves, 1);
      expect(replacement.saves, 0);
      expect(tester.takeException(), isNull);
    } finally {
      LocalFavoritesManager.cache = store;
      replacement.close();
    }
  });

  for (final failDuringInsert in [false, true]) {
    testWidgets(
        'search folder retries without partial data (insert=$failDuringInsert)',
        (tester) async {
      await openSearch(tester);
      await openConfirmation(tester);
      final database = sqlite3.open(databasePath);
      addTearDown(database.dispose);
      store.rejectSecondInsert = failDuringInsert;
      if (!failDuringInsert) database.execute('begin immediate;');
      try {
        await submit(tester);
        await tester.runAsync(DataMaintenance.waitForIdle);
        await tester.pumpAndSettle();
        expect(find.text('操作失败'), findsOneWidget);
        expect(find.text('从当前的搜索结果创建新的收藏夹'), findsOneWidget);
        expect(store.folderNames, ['Source', 'Duplicate']);
        expect(store.saves, 0);
      } finally {
        if (!failDuringInsert) database.execute('rollback;');
        store.rejectSecondInsert = false;
      }
      await submit(tester);
      await tester.runAsync(DataMaintenance.waitForIdle);
      await tester.pumpAndSettle();
      expect(store.count('search result'), 3);
      expect(store.saves, 1);
      expect(find.text('从当前的搜索结果创建新的收藏夹'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('confirmation captures results before the search changes',
      (tester) async {
    await openSearch(tester);
    await openConfirmation(tester);
    tester.widget<TextField>(find.byType(TextField)).onChanged!('Other');
    await tester.pumpAndSettle();
    await submit(tester);
    await tester.runAsync(DataMaintenance.waitForIdle);
    await tester.pumpAndSettle();
    expect(store.getAllComics('search result').map((comic) => comic.target),
        ['1', '2', '1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search export completion preserves a newer dialog',
      (tester) async {
    await openSearch(tester);
    await openConfirmation(tester);
    final maintenance = await holdMaintenance(tester);
    try {
      await submit(tester);
      unawaited(showDialog<void>(
        context: App.globalContext!,
        builder: (_) => const AlertDialog(content: Text('New dialog')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(find.text('New dialog'), findsOneWidget);
    expect(find.text('从当前的搜索结果创建新的收藏夹', skipOffstage: false), findsNothing);
    expect(store.count('search result'), 3);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('closed search export ignores late results (failure=$fail)',
        (tester) async {
      await openSearch(tester);
      await openConfirmation(tester);
      final maintenance = await holdMaintenance(tester);
      try {
        await submit(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        store.rejectSecondInsert = fail;
      } finally {
        await finishMaintenance(tester, maintenance);
      }
      expect(store.folderNames.contains('search result'), !fail);
      expect(store.saves, fail ? 0 : 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelled search export releases its input and focus',
      (tester) async {
    await openSearch(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    await openConfirmation(tester);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(store.folderNames, ['Source', 'Duplicate']);
    expect(store.saves, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(() => field.controller!.addListener(() {}), throwsFlutterError);
    expect(() => field.focusNode!.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });
}
