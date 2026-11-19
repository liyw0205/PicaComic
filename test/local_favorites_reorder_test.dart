import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:pica_comic/components/app_shortcuts.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/local_favorites.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/tools/mouse_listener.dart';
import 'package:sqlite3/sqlite3.dart';

class _BlockingReorderManager extends LocalFavoritesManager {
  _BlockingReorderManager() : super.create();

  Completer<void>? reorderStarted;
  Completer<void>? reorderRelease;
  Future<void>? pendingReorder;
  int reorderCalls = 0;

  @override
  Future<void> reorder(List<FavoriteItem> newFolder, String folder) {
    reorderCalls++;
    final started = reorderStarted;
    final release = reorderRelease;
    if (started == null || release == null) {
      return pendingReorder = super.reorder(newFolder, folder);
    }
    return pendingReorder =
        _reorderAfterRelease(newFolder, folder, started, release);
  }

  Future<void> _reorderAfterRelease(List<FavoriteItem> comics, String folder,
      Completer<void> started, Completer<void> release) async {
    started.complete();
    await release.future;
    await super.reorder(comics, folder);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  late Directory directory;
  late _BlockingReorderManager manager;
  late String folder;
  late String databasePath;
  late File cover;
  var databaseIndex = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-reorder-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    manager = _BlockingReorderManager();
    LocalFavoritesManager.cache = manager;
    databasePath = '${directory.path}/favorites-${databaseIndex++}.db';
    await manager.init(
      databasePath: databasePath,
      importLegacy: false,
    );
    folder = manager.createFolder('reorder');
    for (final (id, name, order) in [
      ('first', 'First comic', 0),
      ('second', 'Second comic', 1),
    ]) {
      await manager.addComic(
        folder,
        FavoriteItem(
          target: id,
          name: name,
          coverPath: '',
          author: '',
          type: FavoriteType.picacg,
          tags: const [],
        ),
        order,
        false,
      );
    }
    cover = File('${directory.path}/cover.png');
    await cover.writeAsBytes([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      1,
      8,
      6,
      0,
      0,
      0,
      31,
      21,
      196,
      137,
      0,
      0,
      0,
      13,
      73,
      68,
      65,
      84,
      8,
      215,
      99,
      248,
      207,
      192,
      240,
      31,
      0,
      5,
      0,
      1,
      255,
      137,
      153,
      61,
      29,
      0,
      0,
      0,
      0,
      73,
      69,
      78,
      68,
      174,
      66,
      96,
      130,
    ]);
    LocalFavoriteTile.cache
      ..clear()
      ..['first'] = cover
      ..['second'] = cover;
  });

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    manager.close();
    LocalFavoritesManager.cache = null;
  });

  tearDownAll(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> openChangedOrder(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => LocalFavoritesFolder(folder),
              ),
            ),
            child: const Text('Open reorder'),
          ),
        ),
      ),
    ));
    addTearDown(() async {
      hideAllMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });
    await tester.tap(find.text('Open reorder'));
    await tester.pumpAndSettle();
    tester.widget<ReorderableBuilder>(find.byType(ReorderableBuilder)).onReorder!(
        (items) => <FavoriteItem>[
              items[1] as FavoriteItem,
              items[0] as FavoriteItem,
            ]);
    await tester.pump();
  }

  testWidgets('saving order ignores duplicate back input and further drags',
      (tester) async {
    await openChangedOrder(tester);
    final release = Completer<void>();
    manager
      ..reorderStarted = Completer<void>()
      ..reorderRelease = release;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async => manager.pendingReorder);
    });

    await App.navigatorKey.currentState!.maybePop<void>();
    await tester.pump();
    await App.navigatorKey.currentState!.maybePop<void>();
    mouseSideButtonCallback();
    tester.widget<ReorderableBuilder>(find.byType(ReorderableBuilder)).onReorder!(
        (items) => <FavoriteItem>[
              items[1] as FavoriteItem,
              items[0] as FavoriteItem,
            ]);
    await tester.pump();
    expect(manager.reorderCalls, 1);
    expect(find.byType(LocalFavoritesFolder), findsOneWidget);

    release.complete();
    await tester.runAsync(() async => manager.pendingReorder);
    await tester.pumpAndSettle();
    expect(find.byType(LocalFavoritesFolder), findsNothing);
    expect(manager.getAllComics(folder).map((comic) => comic.target),
        ['second', 'first']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a database failure keeps the order page open for retry',
      (tester) async {
    await openChangedOrder(tester);
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    database.execute('''
      create trigger reject_reorder before update of display_order on "$folder"
      begin select raise(abort, 'injected reorder failure'); end;
    ''');

    await App.navigatorKey.currentState!.maybePop<void>();
    await tester.pump();
    expect(find.byType(LocalFavoritesFolder), findsOneWidget);
    expect(find.text('保存排序失败'), findsOneWidget);
    expect(manager.getAllComics(folder).map((comic) => comic.target),
        ['first', 'second']);

    database.execute('drop trigger reject_reorder;');
    await App.navigatorKey.currentState!.maybePop<void>();
    await tester.runAsync(() async => manager.pendingReorder);
    await tester.pumpAndSettle();
    expect(find.byType(LocalFavoritesFolder), findsNothing);
    expect(manager.reorderCalls, 2);
    expect(manager.getAllComics(folder).map((comic) => comic.target),
        ['second', 'first']);
    hideAllMessages();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('save completion removes its own route below a newer page',
      (tester) async {
    await openChangedOrder(tester);
    final release = Completer<void>();
    manager
      ..reorderStarted = Completer<void>()
      ..reorderRelease = release;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async => manager.pendingReorder);
    });
    await App.navigatorKey.currentState!.maybePop<void>();
    await tester.pump();
    App.navigatorKey.currentState!.push<void>(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('New page')),
    ));
    await tester.pumpAndSettle();

    release.complete();
    await tester.runAsync(() async => manager.pendingReorder);
    await tester.pumpAndSettle();
    expect(find.text('New page'), findsOneWidget);
    expect(
        find.byType(LocalFavoritesFolder, skipOffstage: false), findsNothing);
    expect(manager.getAllComics(folder).map((comic) => comic.target),
        ['second', 'first']);
    await App.navigatorKey.currentState!.maybePop<void>();
    await tester.pumpAndSettle();
    expect(find.text('Open reorder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('late save ignores a disposed route (failure: $fail)',
        (tester) async {
      await openChangedOrder(tester);
      final release = Completer<void>();
      manager
        ..reorderStarted = Completer<void>()
        ..reorderRelease = release;
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await tester.pump();
      });
      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pump();
      App.navigatorKey.currentState!.pop<void>();
      await tester.pumpAndSettle();
      showDialog<void>(
        context: App.globalContext!,
        builder: (_) => const AlertDialog(content: Text('New dialog')),
      );
      await tester.pumpAndSettle();

      if (fail) {
        release.completeError(StateError('injected late failure'));
      } else {
        release.complete();
      }
      await tester.runAsync(() async {
        try {
          await manager.pendingReorder;
        } catch (_) {
          if (!fail) rethrow;
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('New dialog'), findsOneWidget);
      expect(find.text('保存排序失败'), findsNothing);
      expect(manager.getAllComics(folder).map((comic) => comic.target),
          fail ? ['first', 'second'] : ['second', 'first']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('file import refreshes folders without a me page controller',
      (tester) async {
    final file = File('${directory.path}/imported.json');
    await tester.runAsync(() => file.writeAsString(jsonEncode({
          'name': 'Imported',
          'comics': [manager.getAllComics(folder).first.toJson()],
        })));
    const desktopChannel = MethodChannel('plugins.flutter.io/file_selector');
    const mobileChannel = MethodChannel('flutter_file_dialog');
    var picks = 0;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(desktopChannel, (call) async {
      expect(call.method, 'openFile');
      picks++;
      return [file.path];
    });
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(mobileChannel, (call) async {
      expect(call.method, 'pickFile');
      picks++;
      return file.path;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(desktopChannel, null);
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(mobileChannel, null);
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: StateBuilder<FavoritesPageController>(
          init: FavoritesPageController(),
          builder: (_) => Column(children: [
            Text('${manager.folderNames.length} folders'),
            Builder(
                builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const CreateFolderDialog(),
                      ),
                      child: const Text('Open folders'),
                    )),
          ]),
        ),
      ),
    ));
    await tester.tap(find.text('Open folders'));
    await tester.pumpAndSettle();
    expect(find.text('1 folders'), findsOneWidget);
    final submitImport = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '从文件导入'))
        .onPressed!;

    await tester.runAsync(() async => submitImport());
    await tester.pumpAndSettle();

    expect(picks, 1);
    expect(manager.folderNames, contains('Imported'));
    expect(manager.count('Imported'), 1);
    expect(find.text('2 folders'), findsOneWidget);
    expect(find.byType(CreateFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final input in ['navigator', 'escape', 'mouse', 'framework']) {
    testWidgets(
        'reorder page waits for persistence before returning via $input',
        (tester) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      manager
        ..reorderStarted = entered
        ..reorderRelease = release;
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await tester.pump();
      });

      Widget home = Scaffold(
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                    builder: (_) => LocalFavoritesFolder(folder))),
            child: const Text('Open reorder'),
          );
        }),
      );
      if (input == 'framework') {
        final previousNavigator = App.mainNavigatorKey;
        final childNavigator = GlobalKey<NavigatorState>();
        final observer = NaviObserver();
        final page = home;
        App.mainNavigatorKey = childNavigator;
        addTearDown(() => App.mainNavigatorKey = previousNavigator);
        home = NaviPane(
          paneItems: [
            PaneItemEntry(
              label: 'Library',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
          ],
          paneActions: const [],
          observer: observer,
          pageBuilder: (_) => Navigator(
            key: childNavigator,
            observers: [observer],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => page,
            ),
          ),
        );
      }
      await tester.pumpWidget(MaterialApp(
        navigatorKey: App.navigatorKey,
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: home,
        builder: (_, child) => AppShortcuts(
          child: Focus(autofocus: true, child: child!),
        ),
      ));
      await tester.tap(find.text('Open reorder'));
      await tester.pumpAndSettle();

      final reorder = tester.widget<ReorderableBuilder>(
        find.byType(ReorderableBuilder),
      );
      reorder.onReorder!((items) =>
          <FavoriteItem>[items[1] as FavoriteItem, items[0] as FavoriteItem]);
      await tester.pump();

      Future<bool>? popAttempt;
      if (input == 'navigator') {
        popAttempt = App.navigatorKey.currentState!.maybePop<void>();
      } else if (input == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else if (input == 'framework') {
        await tester.binding.handlePopRoute();
      } else {
        mouseSideButtonCallback();
      }
      await tester.pumpAndSettle();
      if (popAttempt != null) await popAttempt;
      expect(entered.isCompleted, isTrue);
      expect(find.byType(LocalFavoritesFolder), findsOneWidget);
      expect(manager.getAllComics(folder).map((comic) => comic.target),
          ['first', 'second']);

      release.complete();
      await tester.runAsync(() async {
        await manager.pendingReorder;
        await DataMaintenance.waitForIdle();
      });
      await tester.pumpAndSettle();

      expect(find.byType(LocalFavoritesFolder), findsNothing);
      expect(manager.getAllComics(folder).map((comic) => comic.target),
          ['second', 'first']);
      expect(tester.takeException(), isNull);
    });
  }
}
