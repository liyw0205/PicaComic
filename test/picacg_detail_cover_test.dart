import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/picacg/comic_page.dart';
import 'package:pica_comic/pages/show_image_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _CoverImages implements ImageManager {
  final requests = <(String, String)>[];
  final pixel = image.encodePng(image.Image(width: 2, height: 3));

  @override
  Stream<DownloadProgress> getCustomThumbnail(String url, String sourceKey,
      [Map<String, String>? headers]) async* {
    requests.add((url, sourceKey));
    yield DownloadProgress(1, 1, url, '', pixel);
  }

  @override
  Stream<DownloadProgress> getImage(String url,
      [Map<String, String>? headers]) async* {
    yield DownloadProgress(1, 1, url, '', pixel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ComicItem _detail() => ComicItem.fromJson({
      'creator': {
        'id': 'uploader',
        'title': '',
        'email': '',
        'name': 'Uploader',
        'exp': 0,
        'level': 1,
        'avatarUrl': '',
      },
      'id': 'comic',
      'title': 'Cover fixture',
      'description': '',
      'thumbUrl': 'https://fixture.test/detail-cover.png',
      'author': 'Author',
      'chineseTeam': '',
      'categories': <String>[],
      'tags': <String>[],
      'likes': 0,
      'comments': 0,
      'isLiked': false,
      'isFavourite': false,
      'epsCount': 1,
      'time': '',
      'pagesCount': 1,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  for (final initialCover in [null, 'https://fixture.test/list-cover.png']) {
    testWidgets(
        'Picacg detail ${initialCover == null ? 'loads a missing cover after details arrive' : 'preserves its supplied cover'}',
        (tester) async {
      final previousImages = ImageManager.cache;
      final images = _CoverImages();
      ImageManager.cache = images;
      final page = PicacgComicPage('comic', initialCover);
      final logic =
          StateController.put(ComicPageLogic<ComicItem>(), tag: page.tag);
      addTearDown(() {
        logic.controller.dispose();
        StateController.remove<ComicPageLogic<ComicItem>>(page.tag);
        ImageManager.cache = previousImages;
        BaseImageProvider.clearCache();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
      });
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: App.navigatorKey,
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return Center(child: page.buildCover(context, logic, 136, 102));
        })),
      ));
      expect(find.byType(Image),
          initialCover == null ? findsNothing : findsOneWidget);

      rebuild(() => logic.data = _detail());
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      for (var i = 0;
          i < 30 &&
              tester.widget<RawImage>(find.byType(RawImage)).image == null;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      final expectedCover = initialCover ?? _detail().thumbUrl;
      expect(images.requests, [(expectedCover, 'picacg')]);
      await tester.tap(find.byType(Image));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
          tester
              .widget<ShowImagePageWithHero>(find.byType(ShowImagePageWithHero))
              .url,
          expectedCover);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
}
