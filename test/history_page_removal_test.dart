import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/pages/history_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _HistoryStore extends HistoryManager {
  _HistoryStore() : super.create();

  int removals = 0;
  int clears = 0;
  int saves = 0;
  Future<void>? beforeWrite;
  Future<void>? write;

  Future<void> _write(Future<void> Function() action) async {
    await beforeWrite;
    await action();
  }

  @override
  Future<void> remove(String id) {
    removals++;
    return write = _write(() => super.remove(id));
  }

  @override
  Future<void> clearHistory() {
    clears++;
    return write = _write(super.clearHistory);
  }

  @override
  Future<void> saveData() {
    saves++;
    return super.saveData();
  }
}

class _HistoryImages extends Fake implements ImageManager {
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');

  @override
  Stream<DownloadProgress> getImage(String url,
          [Map<String, String>? headers]) =>
      Stream.value(DownloadProgress(1, 1, url, '', png));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory dataDirectory;
  late Directory directory;
  late _HistoryStore store;
  late HistoryManager? previousHistory;
  late HistoryManager previousAppHistory;
  late ImageManager? previousImages;
  late String previousSync;

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp('pica-history-data-');
    App.dataPath = dataDirectory.path;
  });

  tearDownAll(() async {
    await dataDirectory.delete(recursive: true);
  });

  setUp(() async {
    previousHistory = HistoryManager.cache;
    previousAppHistory = appdata.history;
    previousImages = ImageManager.cache;
    previousSync = appdata.settings[45];
    directory = await Directory.systemTemp.createTemp('pica-history-page-');
    appdata.settings[45] = '';
    store = _HistoryStore();
    HistoryManager.cache = store;
    appdata.history = store;
    ImageManager.cache = _HistoryImages();
    await store.init(
        databasePath: '${directory.path}/history.db', importLegacy: false);
    for (final (id, title, year) in [
      ('first', 'First comic', 2026),
      ('second', 'Second comic', 2025),
    ]) {
      await store.addHistory(History(const HistoryType(99), DateTime(year),
          title, '', 'cover-$id', 1, 1, id));
    }
    await DataMaintenance.waitForIdle();
    store.saves = 0;
  });

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    store.close();
    HistoryManager.cache = previousHistory;
    appdata.history = previousAppHistory;
    ImageManager.cache = previousImages;
    appdata.settings[45] = previousSync;
    await directory.delete(recursive: true);
  });

  Future<void> openHistory(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const HistoryPage())),
          child: const Text('Open history'),
        );
      })),
    ));
    await tester.tap(find.text('Open history'));
    await tester.pumpAndSettle();
  }

  Future<void> confirmRemoval(WidgetTester tester, bool clear) async {
    if (clear) {
      await tester.tap(find.byTooltip('清除'));
    } else {
      await tester.longPress(find.text('First comic'));
    }
    await tester.pumpAndSettle();
  }

  Finder submit(bool clear) =>
      find.widgetWithText(TextButton, clear ? '清除' : '删除');

  Future<void> startRemoval(WidgetTester tester, bool clear) async {
    final confirm = tester.widget<TextButton>(submit(clear)).onPressed!;
    await tester.runAsync(() async => confirm());
    await tester.pump();
  }

  Future<void> finishRemoval(WidgetTester tester,
      [Completer<void>? gate]) async {
    await tester.runAsync(() async {
      gate?.complete();
      try {
        await store.write;
      } catch (_) {
        // The dialog owns presentation of the database error.
      }
    });
    await tester.pumpAndSettle();
  }

  for (final clear in [false, true]) {
    testWidgets(
        'history ${clear ? 'clear' : 'remove'} waits for the database and refreshes the page',
        (tester) async {
      await openHistory(tester);
      await confirmRemoval(tester, clear);
      final gate = Completer<void>();
      store.beforeWrite = gate.future;
      await tester.pump();
      final confirm = tester.widget<TextButton>(submit(clear)).onPressed!;
      await startRemoval(tester, clear);
      final dialogWhilePending = find.byType(AlertDialog).evaluate().length;
      final countWhilePending = store.count();
      if (find.byType(AlertDialog).evaluate().isNotEmpty) {
        await tester.runAsync(() async => confirm());
      }
      await tester.pump();
      await finishRemoval(tester, gate);

      expect(dialogWhilePending, 1);
      expect(countWhilePending, 2);
      expect(clear ? store.clears : store.removals, 1);
      expect(store.count(), clear ? 0 : 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('First comic'), findsNothing);
      expect(find.text('历史记录(${clear ? 0 : 1})'), findsOneWidget);
      expect(tester.takeException(), isNull);
      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(store.saves, 1);
    });

    testWidgets(
        'history ${clear ? 'clear' : 'remove'} keeps a failed action retryable',
        (tester) async {
      final db = sqlite3.open('${directory.path}/history.db');
      db.execute('''
        create trigger reject_history_delete before delete on history
        begin select raise(abort, 'fixture deletion failure'); end;
      ''');
      db.dispose();
      await openHistory(tester);
      await confirmRemoval(tester, clear);
      await startRemoval(tester, clear);
      await finishRemoval(tester);
      expect(store.count(), 2);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('操作失败'), findsOneWidget);
      expect(tester.widget<TextButton>(submit(clear)).onPressed, isNotNull);
      expect(tester.takeException(), isNull);

      final retryDb = sqlite3.open('${directory.path}/history.db');
      retryDb.execute('drop trigger reject_history_delete');
      retryDb.dispose();
      await startRemoval(tester, clear);
      await finishRemoval(tester);
      expect(store.count(), clear ? 0 : 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('First comic'), findsNothing);
    });
  }

  testWidgets(
      'history removal keeps the selected target across a search reload',
      (tester) async {
    await openHistory(tester);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Second');
    tester.widget<NormalComicTile>(find.byKey(const Key('first'))).onLongTap!();
    await tester.pumpAndSettle();
    await startRemoval(tester, false);
    await finishRemoval(tester);

    expect(store.findSync('first'), isNull);
    expect(store.findSync('second'), isNotNull);
    expect(find.text('Second comic'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'late history removal does not update a closed page or close another dialog',
      (tester) async {
    await openHistory(tester);
    await confirmRemoval(tester, false);
    final gate = Completer<void>();
    store.beforeWrite = gate.future;
    await tester.pump();
    await startRemoval(tester, false);
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      App.navigatorKey.currentState!.pop();
    }
    App.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
      context: App.navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(title: Text('Another dialog')),
    ));
    await tester.pumpAndSettle();
    await finishRemoval(tester, gate);

    expect(store.findSync('first'), isNull);
    expect(find.byType(HistoryPage), findsNothing);
    expect(find.text('Another dialog'), findsOneWidget);
    expect(store.saves, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history completion removes its own dialog below a newer route',
      (tester) async {
    await openHistory(tester);
    await confirmRemoval(tester, false);
    final confirmationRoute =
        ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
    final gate = Completer<void>();
    store.beforeWrite = gate.future;
    await startRemoval(tester, false);
    unawaited(showDialog<void>(
      context: App.navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(title: Text('Newer dialog')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await finishRemoval(tester, gate);

    expect(confirmationRoute.isActive, isFalse);
    expect(find.text('Newer dialog'), findsOneWidget);
    expect(store.findSync('first'), isNull);
    App.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('历史记录(1)'), findsOneWidget);
    expect(find.text('First comic'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
