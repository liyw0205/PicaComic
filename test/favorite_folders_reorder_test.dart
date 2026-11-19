import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late LocalFavoritesManager manager;
  late String databasePath;
  var databaseIndex = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-folder-order-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    manager = LocalFavoritesManager.create();
    LocalFavoritesManager.cache = manager;
    databasePath = '${directory.path}/${databaseIndex++}.db';
    await manager.init(databasePath: databasePath, importLegacy: false);
    manager.createFolder('First');
    manager.createFolder('Second');
    manager.updateOrder({'First': 0, 'Second': 1});
  });

  tearDown(() {
    StateController.remove<FavoritesPageController>();
    manager.close();
    LocalFavoritesManager.cache = null;
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<void> openChangedOrder(WidgetTester tester) async {
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
    await tester.tap(find.text('排序'));
    await tester.pumpAndSettle();
    tester
            .widget<ReorderableBuilder>(find.byType(ReorderableBuilder))
            .onReorder!(
        (items) => <String>[items[1] as String, items[0] as String]);
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

  testWidgets('folder order waits for persistence and ignores repeated input',
      (tester) async {
    await openChangedOrder(tester);
    final maintenance = await holdMaintenance(tester);
    try {
      await tester
          .runAsync(() => App.navigatorKey.currentState!.maybePop<void>());
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableBuilder), findsOneWidget);
      expect(manager.folderNames, ['First', 'Second']);
      await tester
          .runAsync(() => App.navigatorKey.currentState!.maybePop<void>());
      tester
              .widget<ReorderableBuilder>(find.byType(ReorderableBuilder))
              .onReorder!(
          (items) => <String>[items[1] as String, items[0] as String]);
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(find.byType(ReorderableBuilder), findsNothing);
    expect(manager.folderNames, ['Second', 'First']);
    final visible =
        tester.widgetList<Text>(find.byType(Text)).map((e) => e.data);
    expect(visible.where((e) => e == 'First' || e == 'Second'),
        ['Second', 'First']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder order rolls back every row on failure and permits retry',
      (tester) async {
    await openChangedOrder(tester);
    final database = sqlite3.open(databasePath);
    addTearDown(database.dispose);
    database.execute('''
      create trigger reject_folder_order before insert on folder_order
      when new.folder_name = 'First'
      begin select raise(abort, 'injected folder order failure'); end;
    ''');

    await tester
        .runAsync(() => App.navigatorKey.currentState!.maybePop<void>());
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableBuilder), findsOneWidget);
    expect(find.text('保存排序失败'), findsOneWidget);
    final rows = database.select(
        'select folder_name, order_value from folder_order order by order_value');
    expect(rows.map((row) => [row['folder_name'], row['order_value']]), [
      ['First', 0],
      ['Second', 1],
    ]);

    database.execute('drop trigger reject_folder_order;');
    await tester
        .runAsync(() => App.navigatorKey.currentState!.maybePop<void>());
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableBuilder), findsNothing);
    expect(manager.folderNames, ['Second', 'First']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder order completion preserves a newer dialog',
      (tester) async {
    await openChangedOrder(tester);
    final maintenance = await holdMaintenance(tester);
    try {
      await tester
          .runAsync(() => App.navigatorKey.currentState!.maybePop<void>());
      await tester.pump();
      unawaited(showDialog<void>(
        context: App.navigatorKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('New dialog')),
      ));
      await tester.pumpAndSettle();
    } finally {
      await finishMaintenance(tester, maintenance);
    }
    expect(find.text('New dialog'), findsOneWidget);
    expect(find.byType(ReorderableBuilder, skipOffstage: false), findsNothing);
    expect(manager.folderNames, ['Second', 'First']);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('removed folder order ignores late completion (failure=$fail)',
        (tester) async {
      await openChangedOrder(tester);
      final maintenance = await holdMaintenance(tester);
      final route =
          ModalRoute.of(tester.element(find.byType(ReorderableBuilder)))!;
      final database = sqlite3.open(databasePath);
      addTearDown(database.dispose);
      try {
        await tester
            .runAsync(() => App.navigatorKey.currentState!.maybePop<void>());
        await tester.pump();
        App.navigatorKey.currentState!.removeRoute(route);
        await tester.pumpAndSettle();
        StateController.remove<FavoritesPageController>();
        if (fail) {
          database.execute('''
            create trigger reject_folder_order before insert on folder_order
            begin select raise(abort, 'injected late failure'); end;
          ''');
        }
      } finally {
        await finishMaintenance(tester, maintenance);
      }
      expect(find.text('保存排序失败'), findsNothing);
      expect(manager.folderNames,
          fail ? ['First', 'Second'] : ['Second', 'First']);
      expect(tester.takeException(), isNull);
    });
  }
}
