import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/local_favorites.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _CreationStore extends LocalFavoritesManager {
  _CreationStore() : super.create();

  int saves = 0;
  Future<void>? beforeSave;
  Future<void>? pendingSave;

  @override
  Future<void> saveData() {
    saves++;
    return pendingSave = _save();
  }

  Future<void> _save() async {
    await beforeSave;
    await super.saveData();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late _CreationStore store;
  late String databasePath;
  late String previousSync;
  late String previousImplicit;
  var databaseIndex = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-folder-creation-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    previousSync = appdata.settings[45];
    previousImplicit = appdata.implicitData[0];
    appdata.settings[45] = '';
    appdata.implicitData[0] = '1;;';
    store = _CreationStore();
    LocalFavoritesManager.cache = store;
    databasePath = '${directory.path}/${databaseIndex++}.db';
    await store.init(databasePath: databasePath, importLegacy: false);
    store.createFolder('Existing');
    await store.pendingSave;
    store.saves = 0;
  });

  tearDown(() {
    StateController.remove<FavoritesPageController>();
    store.close();
    LocalFavoritesManager.cache = null;
    appdata.settings[45] = previousSync;
    appdata.implicitData[0] = previousImplicit;
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<void> openCreation(WidgetTester tester) async {
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
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    expect(find.byType(CreateFolderDialog), findsOneWidget);
  }

  Future<void> submit(WidgetTester tester) async {
    final callback = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '提交'))
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
  }

  testWidgets('creation waits for queued writes and merges duplicate input',
      (tester) async {
    await openCreation(tester);
    await tester.enterText(find.byType(TextField), 'Created');
    final maintenance = await holdMaintenance(tester);
    try {
      final field = tester.widget<TextField>(find.byType(TextField));
      final button = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交'))
          .onPressed!;
      await tester.runAsync(() async {
        field.onEditingComplete!();
        button();
      });
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(CreateFolderDialog), findsOneWidget);
      expect(store.folderNames, ['Existing']);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      for (final label in ['从文件导入', '从网络导入']) {
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, label))
                .onPressed,
            isNull);
      }
      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pump();
      expect(find.byType(CreateFolderDialog), findsOneWidget);
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(store.folderNames, contains('Created'));
    expect(store.saves, 1);
    expect(find.byType(CreateFolderDialog), findsNothing);
    expect(find.text('Created'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation waits for publication before closing', (tester) async {
    await openCreation(tester);
    await tester.enterText(find.byType(TextField), 'Created');
    late Completer<void> release;
    await tester.runAsync(() async {
      release = Completer<void>();
      store.beforeSave = release.future;
    });
    try {
      await submit(tester);
      await tester.pump(const Duration(milliseconds: 350));
      expect(store.folderNames, contains('Created'));
      expect(find.byType(CreateFolderDialog), findsOneWidget);
      expect(store.saves, 1);
    } finally {
      await tester.runAsync(() async {
        release.complete();
        await store.pendingSave;
      });
      await tester.pumpAndSettle();
    }
    expect(find.byType(CreateFolderDialog), findsNothing);
    expect(find.text('Created'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation retries database failures without losing the draft',
      (tester) async {
    await openCreation(tester);
    await tester.enterText(find.byType(TextField), 'Created');
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    database.execute('begin immediate;');
    try {
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CreateFolderDialog), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Created');
      expect(field.enabled, isNot(false));
      expect(store.folderNames, ['Existing']);
      expect(store.saves, 0);
    } finally {
      database.execute('rollback;');
    }
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.folderNames, contains('Created'));
    expect(store.saves, 1);
    expect(find.byType(CreateFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued creation rechecks names and allows a new name on failure',
      (tester) async {
    await openCreation(tester);
    await tester.enterText(find.byType(TextField), 'Created');
    final maintenance = await holdMaintenance(tester);
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    try {
      await submit(tester);
      database.execute('create table Created (target text);');
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(find.byType(CreateFolderDialog), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Created');
    expect(store.saves, 0);
    await tester.enterText(find.byType(TextField), 'Another');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.folderNames, containsAll(['Created', 'Another']));
    expect(find.byType(CreateFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation rolls back the table if index creation fails',
      (tester) async {
    await openCreation(tester);
    await tester.enterText(find.byType(TextField), 'Created');
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    database.execute('''
      create table pica_favorites_Created_display_order_target_type (target text);
    ''');
    try {
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CreateFolderDialog), findsOneWidget);
      expect(store.folderNames, isNot(contains('Created')));
      expect(store.saves, 0);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Created');
    } finally {
      database.execute('''
        drop table pica_favorites_Created_display_order_target_type;
      ''');
    }
    await submit(tester);
    await tester.pumpAndSettle();
    expect(store.folderNames, contains('Created'));
    expect(store.saves, 1);
    expect(database.select('''
          select name from sqlite_master
          where type = 'index' and tbl_name = 'Created';
        ''').map((row) => row['name']),
        contains('pica_favorites_Created_display_order_target_type'));
    expect(find.byType(CreateFolderDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation completion preserves a newer dialog', (tester) async {
    await openCreation(tester);
    await tester.enterText(find.byType(TextField), 'Created');
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
    expect(find.byType(CreateFolderDialog, skipOffstage: false), findsNothing);
    expect(store.folderNames, contains('Created'));
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('removed creation ignores late result (failure=$fail)',
        (tester) async {
      await openCreation(tester);
      await tester.enterText(find.byType(TextField), 'Created');
      final field = tester.widget<TextField>(find.byType(TextField));
      final maintenance = await holdMaintenance(tester);
      final database = sqlite3.open(databasePath);
      addTearDown(database.dispose);
      try {
        await submit(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        StateController.remove<FavoritesPageController>();
        if (fail) database.execute('create table Created (target text);');
      } finally {
        await finishMaintenance(tester, maintenance);
      }
      expect(store.folderNames, contains('Created'));
      expect(store.saves, fail ? 0 : 1);
      expect(() => field.controller!.addListener(() {}), throwsFlutterError);
      expect(() => field.focusNode!.addListener(() {}), throwsFlutterError);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('creation keeps drafts across rebuilds and releases controllers',
      (tester) async {
    await openCreation(tester);
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
    expect(store.saves, 0);
    expect(() => field.controller!.addListener(() {}), throwsFlutterError);
    expect(() => field.focusNode!.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });
}
