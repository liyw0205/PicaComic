import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  const cover =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
  late Directory directory;
  late DownloadManager manager;
  late String previousDownloadPath;

  setUp(() async {
    manager = DownloadManager();
    await manager.dispose();
    directory = await Directory.systemTemp.createTemp('pica-download-scroll-');
    previousDownloadPath = appdata.settings[22];
    appdata.settings[22] = directory.path;

    final db = sqlite3.open('${directory.path}/download.db');
    db.execute('''
      CREATE TABLE download (
        id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, time INTEGER,
        directory TEXT, size REAL, json TEXT
      )
    ''');
    for (var index = 0; index < 40; index++) {
      final id = 'fixture-$index';
      final itemDirectory = 'item-$index';
      final files = Directory('${directory.path}/$itemDirectory');
      await files.create(recursive: true);
      await File('${files.path}/cover.jpg').writeAsBytes(base64Decode(cover));
      final item = CustomDownloadedItem(
        1,
        [0],
        {'chapter-1': 'Chapter 1'},
        id,
        'Comic $index',
        'Author',
        const [],
        'fixture',
        'Fixture',
        '',
        'comic-$index',
      );
      db.execute('INSERT INTO download VALUES (?, ?, ?, ?, ?, ?, ?)', [
        item.id,
        item.name,
        item.subTitle,
        DateTime(2025, 1, index + 1).millisecondsSinceEpoch,
        itemDirectory,
        item.comicSize,
        jsonEncode(item.toJson()),
      ]);
    }
    db.dispose();

    manager.path = directory.path;
    await manager.init();
  });

  tearDown(() async {
    await manager.dispose();
    manager.path = null;
    appdata.settings[22] = previousDownloadPath;
    await directory.delete(recursive: true);
  });

  testWidgets('bulk deletion keeps the download list scroll position',
      (tester) async {
    expect(manager.getAll(), hasLength(40));
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const DownloadPage(),
    ));
    await tester.pumpAndSettle();

    final target = find.text('Comic 0');
    await tester.scrollUntilVisible(
      target,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(target, findsOneWidget);
    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    double scrollOffset() =>
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(scrollOffset(), greaterThan(0));

    await tester.longPress(target);
    await tester.pumpAndSettle();
    final logic = StateController.find<DownloadPageLogic>();
    expect(logic.selectedNum, 1);
    expect(logic.comics[logic.selected.indexOf(true)].id, 'fixture-0');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('要删除已选择的项目吗? 此操作无法撤销'), findsOneWidget);
    await tester.tap(find.text('确认').last);
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        if (await manager.getComicOrNull('fixture-0') == null) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(await manager.getComicOrNull('fixture-0'), isNull);
    expect(logic.loading, isFalse);
    expect(find.text('Comic 0'), findsNothing);
    expect(scrollOffset(), greaterThan(0));
  });
}
