import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/pages/favorites/local_favorites.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late LocalFavoritesManager manager;
  var databaseIndex = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-folder-menu-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    manager = LocalFavoritesManager.create();
    LocalFavoritesManager.cache = manager;
    await manager.init(
        databasePath: '${directory.path}/${databaseIndex++}.db',
        importLegacy: false);
    manager.createFolder('Menu folder');
  });

  tearDown(() {
    StateController.remove<FavoritesPageController>();
    manager.close();
    LocalFavoritesManager.cache = null;
  });

  tearDownAll(() => directory.delete(recursive: true));

  for (final action in ['排序', '重命名', '删除']) {
    testWidgets('folder menu $action keeps the originating favorites route',
        (tester) async {
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
      await tester.longPress(find.text('Menu folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem, action));
      await tester.pumpAndSettle();

      switch (action) {
        case '排序':
          expect(find.byType(LocalFavoritesFolder), findsOneWidget);
        case '重命名':
          expect(find.byType(RenameFolderDialog), findsOneWidget);
        case '删除':
          expect(find.text('确认删除'), findsOneWidget);
      }
      expect(find.byType(PopupMenuItem), findsNothing);
      expect(find.byType(FavoritesPage, skipOffstage: false), findsOneWidget);

      await App.navigatorKey.currentState!.maybePop<void>();
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesPage), findsOneWidget);
      expect(find.text('Menu folder'), findsOneWidget);
      expect(find.text('Open favorites'), findsNothing);
      expect(manager.folderNames, ['Menu folder']);
      expect(tester.takeException(), isNull);
    });
  }
}
