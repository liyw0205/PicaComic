import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/pages/image_favorites.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late String databasePath;
  late String previousSync;
  late HistoryManager? previousHistory;
  var databaseIndex = 0;

  setUpAll(() async {
    directory =
        await Directory.systemTemp.createTemp('image-favorite-removal-');
    App.dataPath = directory.path;
    await File('${directory.path}/fixture.png').writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='));
  });

  setUp(() async {
    previousSync = appdata.settings[45];
    previousHistory = HistoryManager.cache;
    appdata.settings[45] = '';
    HistoryManager.cache = HistoryManager.create();
    databasePath = '${directory.path}/${databaseIndex++}.db';
    await HistoryManager()
        .init(databasePath: databasePath, importLegacy: false);
    for (final id in ['second', 'first']) {
      await ImageFavoriteManager.add(ImageFavorite('nhentai-$id',
          '${directory.path}/fixture.png', '$id image', 1, 1, {}));
    }
    await DataMaintenance.waitForIdle();
  });

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    HistoryManager().close();
    HistoryManager.cache = previousHistory;
    appdata.settings[45] = previousSync;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<Route<void>> openFavorites(WidgetTester tester,
      {VoidCallback? onDeleted}) async {
    late Route<void> pageRoute;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () {
            pageRoute = MaterialPageRoute<void>(builder: (_) {
              if (onDeleted == null) return const ImageFavoritesPage();
              return Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 160,
                    height: 240,
                    child: FavoriteImageTile(
                      ImageFavoriteManager.getAll().first,
                      onDeleted: onDeleted,
                    ),
                  ),
                ),
              );
            });
            unawaited(Navigator.of(context).push(pageRoute));
          },
          child: const Text('Open images'),
        );
      })),
    ));
    addTearDown(() async {
      hideAllMessages();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
    await tester.tap(find.text('Open images'));
    await tester.pumpAndSettle();
    return pageRoute;
  }

  Finder firstImageAction() => find.descendant(
      of: find.byWidgetPredicate((widget) =>
          widget is FavoriteImageTile && widget.image.id == 'nhentai-first'),
      matching: find.byType(InkWell));

  Future<Route<dynamic>> openConfirmation(WidgetTester tester) async {
    await tester.longPress(firstImageAction());
    await tester.pumpAndSettle();
    return ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
  }

  VoidCallback confirm(WidgetTester tester) => tester
      .widget<TextButton>(find.widgetWithText(TextButton, '确认'))
      .onPressed!;

  Future<void> submit(WidgetTester tester) async {
    final action = confirm(tester);
    await tester.runAsync(() async => action());
    await tester.pump();
  }

  Future<({Completer<void> gate, Future<void> task})> blockMaintenance(
      WidgetTester tester) async {
    return (await tester.runAsync(() async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final task = DataMaintenance.run(() {
        started.complete();
        return gate.future;
      });
      await started.future;
      return (gate: gate, task: task);
    }))!;
  }

  Future<void> finishMaintenance(WidgetTester tester,
      ({Completer<void> gate, Future<void> task}) blocked) async {
    await tester.runAsync(() async {
      blocked.gate.complete();
      await blocked.task;
      await DataMaintenance.waitForIdle();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  void rejectDeletion(Database db) => db.execute('''
    create trigger reject_image_delete before delete on image_favorites
    begin select raise(abort, 'fixture image deletion failure'); end;
  ''');

  testWidgets('image deletion waits, prevents repeats and blocks back',
      (tester) async {
    var callbacks = 0;
    await openFavorites(tester, onDeleted: () => callbacks++);
    await openConfirmation(tester);
    final blocked = await blockMaintenance(tester);
    try {
      final action = confirm(tester);
      await tester.runAsync(() async {
        action();
        action();
      });
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(ImageFavoriteManager.length, 2);
      expect(callbacks, 0);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
              .onPressed,
          isNull);
      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
    } finally {
      await finishMaintenance(tester, blocked);
    }

    expect(callbacks, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(ImageFavoriteManager.exist('nhentai-first', 1, 1), isFalse);
    expect(ImageFavoriteManager.exist('nhentai-second', 1, 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('image deletion failure stays retryable and refreshes the count',
      (tester) async {
    await openFavorites(tester);
    await openConfirmation(tester);
    final db = sqlite3.open(databasePath);
    addTearDown(db.dispose);
    rejectDeletion(db);

    await submit(tester);
    await tester.pumpAndSettle();

    expect(ImageFavoriteManager.length, 2);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('操作失败')),
        findsOneWidget);
    expect(confirm(tester), isNotNull);
    expect(tester.takeException(), isNull);

    db.execute('drop trigger reject_image_delete');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(ImageFavoriteManager.length, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('first image'), findsNothing);
    expect(find.text('second image'), findsOneWidget);
    expect(find.text('图片收藏(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('image completion removes only its own confirmation route',
      (tester) async {
    await openFavorites(tester);
    final confirmation = await openConfirmation(tester);
    final blocked = await blockMaintenance(tester);
    try {
      await submit(tester);
      unawaited(showDialog<void>(
        context: App.globalContext!,
        builder: (_) => const AlertDialog(title: Text('Newer dialog')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      await finishMaintenance(tester, blocked);
    }

    expect(confirmation.isActive, isFalse);
    expect(find.text('Newer dialog'), findsOneWidget);
    expect(ImageFavoriteManager.exist('nhentai-first', 1, 1), isFalse);
    App.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('图片收藏(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('closed confirmation does not call a still-mounted image tile',
      (tester) async {
    var callbacks = 0;
    final page = await openFavorites(tester, onDeleted: () => callbacks++);
    final confirmation = await openConfirmation(tester);
    final blocked = await blockMaintenance(tester);
    try {
      await submit(tester);
      if (confirmation.isActive) {
        App.navigatorKey.currentState!.removeRoute(confirmation);
      }
      await tester.pumpAndSettle();
    } finally {
      await finishMaintenance(tester, blocked);
    }

    expect(page.isActive, isTrue);
    expect(ImageFavoriteManager.exist('nhentai-first', 1, 1), isFalse);
    expect(callbacks, 0);
    expect(find.text('删除成功'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('closed image page ignores late deletion (failure=$fail)',
        (tester) async {
      final page = await openFavorites(tester);
      final confirmation = await openConfirmation(tester);
      final blocked = await blockMaintenance(tester);
      final db = sqlite3.open(databasePath);
      addTearDown(db.dispose);
      try {
        if (fail) rejectDeletion(db);
        await submit(tester);
        final navigator = App.navigatorKey.currentState!;
        if (confirmation.isActive) navigator.removeRoute(confirmation);
        if (page.isActive) navigator.removeRoute(page);
        await tester.pumpAndSettle();
        unawaited(showDialog<void>(
          context: App.globalContext!,
          builder: (_) => const AlertDialog(title: Text('Another dialog')),
        ));
        await tester.pumpAndSettle();
      } finally {
        await finishMaintenance(tester, blocked);
      }

      expect(find.byType(ImageFavoritesPage), findsNothing);
      expect(find.text('Another dialog'), findsOneWidget);
      expect(find.text('删除成功'), findsNothing);
      expect(find.text('操作失败'), findsNothing);
      expect(ImageFavoriteManager.exist('nhentai-first', 1, 1), fail);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop image deletion confirms and can be cancelled',
      (tester) async {
    await openFavorites(tester);
    await tester.tap(firstImageAction(), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(ImageFavoriteManager.length, 2);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(ImageFavoriteManager.length, 2);
    expect(find.byType(ImageFavoritesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
