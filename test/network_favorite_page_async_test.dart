import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/favorites/network_favorite_page.dart';
import 'package:pica_comic/pages/favorites/network_to_local.dart';
import 'package:pica_comic/tools/translations.dart';

class _UnusedCookieJar implements SingleInstanceCookieJar {
  @override
  List<Cookie> loadForRequest(Uri uri) => const [];

  @override
  void saveFromResponse(Uri uri, List<Cookie> cookies) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  AppTranslation.translations = const {};

  testWidgets('folder deletion refresh callback is ignored after page disposal',
      (tester) async {
    final deleteFolder = Completer<Res<bool>>();
    final data = FavoriteData(
      key: 'test',
      title: 'Test',
      multiFolder: true,
      loadComic: (page, [folder]) async => const Res([]),
      loadFolders: ([_]) async => const Res({'folder': 'Folder'}),
      deleteFolder: (_) => deleteFolder.future,
    );

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: NetworkFavoritePage(data),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_forever_outlined));
    await tester.pump();
    await tester.tap(find.text('确认'));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    deleteFolder.complete(const Res(true));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
  });

  testWidgets('synchronous folder loader failure does not set state in build',
      (tester) async {
    var requests = 0;
    final data = FavoriteData(
      key: 'test',
      title: 'Test',
      multiFolder: true,
      loadComic: (page, [folder]) async => const Res([]),
      loadFolders: ([_]) {
        requests++;
        if (requests == 1) throw StateError('sync loader failure');
        return Future.value(const Res({'folder': 'Folder'}));
      },
    );

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: NetworkFavoritePage(data),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(NetworkError), findsOneWidget);
    expect(requests, 1);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(requests, 2);
    expect(find.byType(NetworkError), findsNothing);
    expect(find.text('Folder'), findsOneWidget);
  });

  testWidgets('network-to-local continue is disabled until a folder is chosen',
      (tester) async {
    final previousSources = ComicSource.sources;
    final previousFavorites = appdata.settings[68];
    final previousCookieJar = SingleInstanceCookieJar.instance;
    final previousEhNetwork = EhNetwork.cache;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    EhNetwork.cache = null;
    ComicSource.sources = [
      ComicSource.named(
        name: 'Test source',
        key: 'test-source',
        filePath: 'test',
        favoriteData: FavoriteData(
          key: 'test-source',
          title: 'Test favorites',
          multiFolder: false,
          loadComic: (page, [folder]) async => const Res([]),
        ),
      ),
    ];
    appdata.settings[68] = 'test-source';

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      navigatorKey: App.navigatorKey,
      home: const Scaffold(
        body: Center(
          child: TextButton(
            onPressed: networkToLocal,
            child: Text('Open transfer'),
          ),
        ),
      ),
    ));

    try {
      await tester.tap(find.text('Open transfer'));
      await tester.pumpAndSettle();

      final continueButton = tester.widget<FilledButton>(find.ancestor(
        of: find.text('继续'),
        matching: find.byType(FilledButton),
      ));
      expect(continueButton.onPressed, isNull);
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Test favorites').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(RadioListTile<String?>));
      await tester.pump();
      final selectedButton = tester.widget<FilledButton>(find.ancestor(
        of: find.text('继续'),
        matching: find.byType(FilledButton),
      ));
      expect(selectedButton.onPressed, isNotNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      ComicSource.sources = previousSources;
      appdata.settings[68] = previousFavorites;
      EhNetwork.cache = previousEhNetwork;
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  for (final failed in [false, true]) {
    testWidgets(
        'late network-to-local folder response is ignored after dispose (failed=$failed)',
        (tester) async {
      final pendingFolders = Completer<Res<Map<String, String>>>();
      final previousSources = ComicSource.sources;
      final previousFavorites = appdata.settings[68];
      final previousCookieJar = SingleInstanceCookieJar.instance;
      final previousEhNetwork = EhNetwork.cache;
      SingleInstanceCookieJar.instance = _UnusedCookieJar();
      EhNetwork.cache = null;
      ComicSource.sources = [
        ComicSource.named(
          name: 'Test source',
          key: 'test-source',
          filePath: 'test',
          favoriteData: FavoriteData(
            key: 'test-source',
            title: 'Test favorites',
            multiFolder: true,
            loadComic: (page, [folder]) async => const Res([]),
            loadFolders: ([_]) => pendingFolders.future,
          ),
        ),
      ];
      appdata.settings[68] = 'test-source';

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        navigatorKey: App.navigatorKey,
        builder: (context, child) => OverlayWidget(child!),
        home: const Scaffold(
          body: Center(
            child: TextButton(
              onPressed: networkToLocal,
              child: Text('Open transfer'),
            ),
          ),
        ),
      ));

      try {
        await tester.tap(find.text('Open transfer'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Test favorites'));
        await tester.pump();

        App.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Open transfer'), findsOneWidget);
        expect(find.byType(OverlayWidget), findsOneWidget);
        pendingFolders.complete(failed
            ? const Res(null, errorMessage: 'Folder request failed')
            : const Res({'folder': 'Folder'}));
        await tester.pump();
        await tester.pump();
        expect(find.text('网络错误'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        OverlayWidget.removeAll();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        ComicSource.sources = previousSources;
        appdata.settings[68] = previousFavorites;
        EhNetwork.cache = previousEhNetwork;
        SingleInstanceCookieJar.instance = previousCookieJar;
      }
    });
  }
}
