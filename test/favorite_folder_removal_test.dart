import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _FolderStore extends LocalFavoritesManager {
  _FolderStore() : super.create();

  int removals = 0;
  Future<void>? beforeWrite;
  Future<void>? pendingWrite;

  @override
  Future<void> deleteFolder(String name) {
    removals++;
    return pendingWrite = _delete(name);
  }

  Future<void> _delete(String name) async {
    await beforeWrite;
    await super.deleteFolder(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late _FolderStore store;
  late String databasePath;
  late String previousSync;
  var databaseIndex = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-folder-removal-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    previousSync = appdata.settings[45];
    appdata.settings[45] = '';
    store = _FolderStore();
    LocalFavoritesManager.cache = store;
    databasePath = '${directory.path}/${databaseIndex++}.db';
    await store.init(databasePath: databasePath, importLegacy: false);
    store.createFolder('Delete folder');
    store.createFolder('Other folder');
    store.updateOrder({'Delete folder': 0, 'Other folder': 1});
  });

  tearDown(() {
    StateController.remove<FavoritesPageController>();
    store.close();
    LocalFavoritesManager.cache = null;
    appdata.settings[45] = previousSync;
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<FavoritesPageController> openConfirmation(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: Scaffold(
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                  builder: (_) => Scaffold(body: FavoritesPage())),
            ),
            child: const Text('Open favorites'),
          );
        }),
      ),
    ));
    addTearDown(() async {
      hideAllMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });
    await tester.tap(find.text('Open favorites'));
    await tester.pumpAndSettle();
    final controller = StateController.find<FavoritesPageController>();
    controller
      ..current = 'Delete folder'
      ..isNetwork = false;
    // Keep the content empty while exercising a selected folder's deletion.
    await tester.longPress(find.text('Delete folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除'), findsOneWidget);
    return controller;
  }

  Future<void> submit(WidgetTester tester) async {
    final onConfirm = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '确认'))
        .onPressed!;
    await tester.runAsync(() async => onConfirm());
    await tester.pump();
  }

  Future<Completer<void>> blockWrite(WidgetTester tester) async {
    late Completer<void> release;
    await tester.runAsync(() async {
      release = Completer<void>();
      store.beforeWrite = release.future;
    });
    return release;
  }

  Future<void> finishWrite(WidgetTester tester, Completer<void> release) async {
    await tester.runAsync(() async {
      release.complete();
      try {
        await store.pendingWrite;
      } catch (_) {
        // The dialog handles persistence failures; still wait for completion.
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('folder deletion waits, prevents repeats, and preserves its page',
      (tester) async {
    final controller = await openConfirmation(tester);
    final release = await blockWrite(tester);
    try {
      final confirm = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '确认'))
          .onPressed!;
      await tester.runAsync(() async {
        confirm();
        confirm();
      });
      await tester.pump();
      expect(store.removals, 1);
      expect(find.text('确认删除'), findsOneWidget);
      expect(controller.current, 'Delete folder');
      expect(store.folderNames, contains('Delete folder'));
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
              .onPressed,
          isNull);
      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pump();
      expect(find.text('确认删除'), findsOneWidget);
    } finally {
      await finishWrite(tester, release);
    }
    expect(find.text('确认删除'), findsNothing);
    expect(find.byType(FavoritesPage), findsOneWidget);
    expect(controller.current, isNull);
    expect(controller.isNetwork, isNull);
    expect(controller.selectingFolder, isTrue);
    expect(store.folderNames, ['Other folder']);
    expect(find.text('Delete folder'), findsNothing);
    expect(find.text('Other folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder deletion failure keeps the selection and permits retry',
      (tester) async {
    final controller = await openConfirmation(tester);
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    database.execute('''
      create trigger reject_folder_delete before delete on folder_order
      when old.folder_name = 'Delete folder'
      begin select raise(abort, 'injected folder deletion failure'); end;
    ''');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(find.text('操作失败'), findsOneWidget);
    expect(find.text('确认删除'), findsOneWidget);
    expect(controller.current, 'Delete folder');
    expect(store.folderNames, contains('Delete folder'));

    database.execute('drop trigger reject_folder_delete;');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.removals, 2);
    expect(store.folderNames, ['Other folder']);
    expect(controller.current, isNull);
    expect(find.byType(FavoritesPage), findsOneWidget);
    expect(find.text('确认删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder deletion completion only closes its confirmation route',
      (tester) async {
    final controller = await openConfirmation(tester);
    final release = await blockWrite(tester);
    try {
      await submit(tester);
      controller.current = 'Other folder';
      unawaited(showDialog<void>(
        context: App.globalContext!,
        builder: (_) => const AlertDialog(content: Text('New dialog')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      await finishWrite(tester, release);
    }
    expect(find.text('New dialog'), findsOneWidget);
    expect(find.text('确认删除', skipOffstage: false), findsNothing);
    expect(find.byType(FavoritesPage, skipOffstage: false), findsOneWidget);
    expect(controller.current, 'Other folder');
    expect(controller.isNetwork, isFalse);
    expect(store.folderNames, ['Other folder']);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('removed folder dialog ignores late result (failure=$fail)',
        (tester) async {
      final controller = await openConfirmation(tester);
      final release = await blockWrite(tester);
      final database = sqlite3.open(databasePath);
      addTearDown(database.dispose);
      try {
        await submit(tester);
        final route = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
        App.navigatorKey.currentState!.removeRoute(route);
        await tester.pumpAndSettle();
        StateController.remove<FavoritesPageController>();
        expect(controller.isDisposed, isTrue);
        if (fail) {
          database.execute('''
            create trigger reject_folder_delete before delete on folder_order
            begin select raise(abort, 'injected late deletion failure'); end;
          ''');
        }
      } finally {
        await finishWrite(tester, release);
      }
      expect(find.text('操作失败'), findsNothing);
      expect(store.folderNames.contains('Delete folder'), fail);
      expect(tester.takeException(), isNull);
    });
  }
}
