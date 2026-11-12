import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';

class _UnusedCookieJar implements SingleInstanceCookieJar {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GalleryAdapter implements HttpClientAdapter {
  _GalleryAdapter(this.gallery);

  final Map<String, dynamic> gallery;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(
      jsonEncode({
        'result': [gallery],
        'num_pages': 1,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('API gallery page count is separate from listing pagination', () async {
    final network = NhentaiNetwork();
    final savedCookieJar = network.cookieJar;
    final savedSettings = List<String>.from(appdata.settings);
    final savedOverrides = HttpOverrides.current;
    final savedProxyOverrides = proxyHttpOverrides;
    final dio = Dio()
      ..httpClientAdapter = _GalleryAdapter({
        'id': 123,
        'english_title': 'Test gallery',
        'thumbnail': 'galleries/456/thumb.jpg',
        'tag_ids': [29963],
        'num_pages': 106,
      });
    network.cookieJar = _UnusedCookieJar();
    network.dio = dio;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    appdata.settings[69] = '1';
    appdata.settings[91] = '0';
    addTearDown(() {
      network.cookieJar = savedCookieJar;
      appdata.settings = savedSettings;
      HttpOverrides.global = savedOverrides;
      proxyHttpOverrides = savedProxyOverrides;
      dio.close();
    });

    final result = await network.getHomePage(1);

    expect(result.success, isTrue);
    expect(result.data.latest.single.pages, 106);
    expect(result.data.latest.single.lang, isNot('Unknown'));
  });

  test('HTML page count remains optional', () {
    NhentaiComicBrief parse(String attributes) {
      final document = html.parse('''
        <div class="gallery" $attributes>
          <a href="/g/123/"><img src="thumb.jpg"></a>
          <div class="caption">Test gallery</div>
        </div>
      ''');
      return NhentaiNetwork().parseComic(document.querySelector('.gallery')!);
    }

    expect(parse('data-pages="106"').pages, 106);
    expect(parse('').pages, isNull);
    expect(parse('data-pages="invalid"').pages, isNull);
  });

  testWidgets('page count uses the slot above language', (tester) async {
    late ComicTile tile;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        tile = nhentai.comicTileBuilderOverride!(
          context,
          const NhentaiComicBrief(
              'Test gallery', '', '123', 'English', [], 106),
          null,
        ) as ComicTile;
        return Column(children: [
          tile.buildSubDescription(context)!,
          Text(tile.description),
        ]);
      }),
    ));

    expect(find.text('106P'), findsOneWidget);
    expect(tester.getBottomLeft(find.text('106P')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('English')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing and invalid page counts are hidden', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        for (final pages in [null, 0, -1]) {
          final tile = nhentai.comicTileBuilderOverride!(
            context,
            NhentaiComicBrief(
                'Test gallery', '', '123', 'English', const [], pages),
            null,
          ) as ComicTile;
          expect(tile.buildSubDescription(context), isNull);
          expect(tile.description, 'English');
        }
        return const SizedBox();
      }),
    ));
    expect(tester.takeException(), isNull);
  });
}
