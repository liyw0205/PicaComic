import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/favorites/network_favorite_page.dart';
import 'package:pica_comic/tools/translations.dart';

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

    await tester.pumpWidget(MaterialApp(home: NetworkFavoritePage(data)));
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
}
