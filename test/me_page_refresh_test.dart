import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/pages/accounts_page.dart';
import 'package:pica_comic/pages/me_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _Images extends Fake implements ImageManager {
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
  late Directory root;
  late String previousDownloadPath;
  late HistoryManager store;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-me-refresh-');
    App.dataPath = root.path;
    previousDownloadPath = appdata.settings[22];
    appdata.settings[22] = '${root.path}/downloads';
    await DownloadManager().init();
    store = HistoryManager.create();
    await store.init(
        databasePath: '${root.path}/history.db', importLegacy: false);
    HistoryManager.cache = store;
    appdata.history = store;
    ImageManager.cache = _Images();
    ComicSource.sources = [];
  });

  tearDownAll(() async {
    await DataMaintenance.waitForIdle();
    store.close();
    await DownloadManager().dispose();
    DownloadManager().path = null;
    appdata.settings[22] = previousDownloadPath;
    await root.delete(recursive: true);
  });

  Future<void> openMe(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const Scaffold(body: MePage()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('history notifications refresh the mounted me page',
      (tester) async {
    await openMe(tester);
    expect(find.text('历史记录(0)'), findsOneWidget);
    await tester.runAsync(() => store.addHistory(History(const HistoryType(99),
        DateTime(2026), 'Third comic', '', 'cover-third', 1, 1, 'third')));
    await tester.pump();
    expect(find.text('历史记录(0)'), findsOneWidget);

    await tester
        .runAsync(() => store.saveReadHistory(store.findSync('third')!));
    await tester.pump();
    expect(find.text('历史记录(1)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(StateController.findOrNull(tag: 'me_page'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download count updates on insert and delete without leaving me',
      (tester) async {
    final manager = DownloadManager();
    final db = sqlite3.open('${manager.path}/download.db');
    addTearDown(() {
      db.execute('delete from download where id = ?', ['me-page-download']);
      db.dispose();
    });
    await openMe(tester);
    expect(find.text('共 0 部漫画'), findsOneWidget);
    db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)', [
      'me-page-download',
      'Fixture',
      '',
      1,
      'me-page-download',
      0,
      '{}',
    ]);
    manager.notifyListeners();
    await tester.pump();
    expect(find.text('共 1 部漫画'), findsOneWidget);
    await tester.runAsync(() => manager.delete(['me-page-download']));
    await tester.pump();
    expect(find.text('共 0 部漫画'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    manager.notifyListeners();
    expect(tester.takeException(), isNull);
  });

  for (final logout in [false, true]) {
    testWidgets(
        'me account count refreshes after ${logout ? 'logout' : 'login'}',
        (tester) async {
      final previousSources = ComicSource.sources;
      addTearDown(() => ComicSource.sources = previousSources);
      late ComicSource source;
      source = ComicSource.named(
        name: 'Fixture account',
        key: 'me-page-account',
        filePath: 'built-in',
        account: AccountConfig.named(
          onLogin: (_) async => source.data['account'] = ['user', 'password'],
          logout: () {},
        ),
      );
      if (logout) source.data['account'] = ['user', 'password'];
      ComicSource.sources = [source];
      await openMe(tester);
      expect(find.text('已登录 ${logout ? 1 : 0} 个账号'), findsOneWidget);
      await tester.tap(find.text('账号管理'));
      await tester.pumpAndSettle();
      final action = tester
          .widget<ListTile>(
              find.widgetWithText(ListTile, logout ? '退出登录' : '登录'))
          .onTap!;
      await tester.runAsync(() async => action());
      await tester.pumpAndSettle();
      expect(source.isLogin, !logout);
      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(AccountsPage), findsNothing);
      expect(find.text('已登录 ${logout ? 0 : 1} 个账号'), findsOneWidget);
      expect(
          find.text('Fixture account'), logout ? findsNothing : findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });
  }
}
