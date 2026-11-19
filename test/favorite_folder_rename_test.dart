import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/local_favorites.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

class _RenameStore extends LocalFavoritesManager {
  _RenameStore() : super.create();

  final renames = <(String, String)>[];
  Future<void>? beforeWrite;
  Future<void>? pendingWrite;

  @override
  Future<void> rename(String before, String after) {
    renames.add((before, after));
    return pendingWrite = _rename(before, after);
  }

  Future<void> _rename(String before, String after) async {
    await beforeWrite;
    await super.rename(before, after);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late _RenameStore store;
  late String databasePath;
  late String previousSync;
  late String previousImplicit;
  var databaseIndex = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-folder-rename-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousSync = appdata.settings[45];
    previousImplicit = appdata.implicitData[0];
    appdata.settings[45] = '';
    appdata.implicitData[0] = '1;;';
    store = _RenameStore();
    LocalFavoritesManager.cache = store;
    databasePath = '${directory.path}/${databaseIndex++}.db';
    await store.init(databasePath: databasePath, importLegacy: false);
    store.createFolder('Before');
    store.createFolder('Other');
    store.updateOrder({'Before': 0, 'Other': 1});
  });

  tearDown(() {
    StateController.remove<FavoritesPageController>();
    store.close();
    LocalFavoritesManager.cache = null;
    appdata.settings[45] = previousSync;
    appdata.implicitData[0] = previousImplicit;
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<FavoritesPageController> openRename(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: Scaffold(body: FavoritesPage()),
    ));
    addTearDown(() async {
      hideAllMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });
    await tester.longPress(find.text('Before'));
    await tester.pumpAndSettle();
    final controller = StateController.find<FavoritesPageController>();
    controller
      ..current = 'Before'
      ..isNetwork = false;
    await tester.tap(find.widgetWithText(PopupMenuItem, '重命名'));
    await tester.pumpAndSettle();
    expect(find.byType(RenameFolderDialog), findsOneWidget);
    return controller;
  }

  Future<void> submit(WidgetTester tester) async {
    final callback = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '提交'))
        .onPressed!;
    await tester.runAsync(() async => callback());
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
        // The dialog owns error presentation; the fixture waits for the write.
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('rename merges keyboard and button submissions while waiting',
      (tester) async {
    await openRename(tester);
    await tester.enterText(find.byType(TextField), 'After');
    final release = await blockWrite(tester);
    try {
      final field = tester.widget<TextField>(find.byType(TextField));
      final button = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '提交'))
          .onPressed!;
      await tester.runAsync(() async {
        field.onEditingComplete!();
        button();
      });
      await tester.pump();
      expect(store.renames, [('Before', 'After')]);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pump();
      expect(find.byType(RenameFolderDialog), findsOneWidget);
      expect(store.folderNames, ['Before', 'Other']);
    } finally {
      await finishWrite(tester, release);
    }
    expect(store.folderNames, ['After', 'Other']);
    expect(find.byType(RenameFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful rename updates the active local folder',
      (tester) async {
    final controller = await openRename(tester);
    appdata.implicitData[0] = '0;0;Before';
    await tester.enterText(find.byType(TextField), 'After');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.folderNames, ['After', 'Other']);
    expect(controller.current, 'After');
    expect(controller.isNetwork, isFalse);
    expect(appdata.implicitData[0], '0;0;After');
    final preferences = await tester.runAsync(SharedPreferences.getInstance);
    expect(preferences!.getStringList('implicitData')!.first, '0;0;After');
    expect(find.text('Before'), findsNothing);
    expect(find.text('After'), findsWidgets);
    expect(find.byType(RenameFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rename failure preserves input and selection for retry',
      (tester) async {
    final controller = await openRename(tester);
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    database.execute('''
      create trigger reject_folder_rename before update on folder_order
      begin select raise(abort, 'injected rename failure'); end;
    ''');
    await tester.enterText(find.byType(TextField), 'After');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(find.byType(RenameFolderDialog), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'After');
    expect(controller.current, 'Before');
    expect(store.folderNames, ['Before', 'Other']);
    expect(
        tester.widget<TextField>(find.byType(TextField)).enabled, isNot(false));

    database.execute('drop trigger reject_folder_rename;');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.renames.length, 2);
    expect(store.folderNames, ['After', 'Other']);
    expect(controller.current, 'After');
    expect(find.byType(RenameFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rename completion preserves newer dialogs and folder selection',
      (tester) async {
    final controller = await openRename(tester);
    await tester.enterText(find.byType(TextField), 'After');
    final release = await blockWrite(tester);
    try {
      await submit(tester);
      controller.current = 'Other';
      appdata.implicitData[0] = '0;0;Other';
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
    expect(find.byType(RenameFolderDialog, skipOffstage: false), findsNothing);
    expect(controller.current, 'Other');
    expect(appdata.implicitData[0], '0;0;Other');
    expect(store.folderNames, ['After', 'Other']);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('removed rename ignores late result (failure=$fail)',
        (tester) async {
      final controller = await openRename(tester);
      await tester.enterText(find.byType(TextField), 'After');
      final field = tester.widget<TextField>(find.byType(TextField));
      final release = await blockWrite(tester);
      try {
        await submit(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        StateController.remove<FavoritesPageController>();
        expect(controller.isDisposed, isTrue);
        StateController.put(FavoritesPageController()..current = 'Replacement');
        if (fail) {
          final database = sqlite3.open(databasePath);
          database.execute('''
            create trigger reject_folder_rename before update on folder_order
            begin select raise(abort, 'injected late rename failure'); end;
          ''');
          database.dispose();
        }
      } finally {
        await finishWrite(tester, release);
      }
      expect(
          store.folderNames, fail ? ['Before', 'Other'] : ['After', 'Other']);
      expect(StateController.find<FavoritesPageController>().current,
          'Replacement');
      expect(() => field.controller!.addListener(() {}), throwsFlutterError);
      expect(() => field.focusNode!.addListener(() {}), throwsFlutterError);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unchanged rename closes without a database write',
      (tester) async {
    await openRename(tester);
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.renames, isEmpty);
    expect(store.folderNames, ['Before', 'Other']);
    expect(find.byType(RenameFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rename keeps its draft and focus controller across rebuilds',
      (tester) async {
    await openRename(tester);
    await tester.enterText(find.byType(TextField), 'Draft');
    final field = tester.widget<TextField>(find.byType(TextField));
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    final rebuilt = tester.widget<TextField>(find.byType(TextField));
    expect(rebuilt.controller, same(field.controller));
    expect(rebuilt.focusNode, same(field.focusNode));
    expect(rebuilt.controller!.text, 'Draft');
    await App.navigatorKey.currentState!.maybePop<void>();
    await tester.pumpAndSettle();
    expect(store.renames, isEmpty);
    expect(() => field.controller!.addListener(() {}), throwsFlutterError);
    expect(() => field.focusNode!.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });
}
