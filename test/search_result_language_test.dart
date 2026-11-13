import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/pages/search_result_page.dart';

void main() {
  final source = ComicSource.named(
    name: 'test',
    key: 'search-language-test',
    filePath: 'test',
    searchPageData: SearchPageData.named(
      enableLanguageFilter: true,
      overrideSearchResultBuilder: (keyword, options) => Text(keyword),
    ),
  );
  late List<ComicSource> oldSources;
  late String oldLanguage;

  setUp(() {
    oldSources = ComicSource.sources;
    oldLanguage = appdata.settings[69];
    ComicSource.sources = [source];
    appdata.settings[69] = '0';
  });

  tearDown(() {
    ComicSource.sources = oldSources;
    appdata.settings[69] = oldLanguage;
  });

  testWidgets('changing the default language rebuilds the active query',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SearchResultPage(
        keyword: 'artist:test',
        sourceKey: source.key,
      ),
    ));
    expect(find.text('artist:test'), findsOneWidget);

    appdata.settings[69] = '1';
    SearchResultPage.updateDefaultLanguage(1);
    await tester.pump();
    expect(find.text('artist:test language:chinese'), findsOneWidget);

    appdata.settings[69] = '2';
    SearchResultPage.updateDefaultLanguage(2);
    await tester.pump();
    expect(find.text('artist:test language:english'), findsOneWidget);
  });

  testWidgets(
      'an explicit language remains authoritative after a setting change',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SearchResultPage(
        keyword: 'artist:test language:japanese',
        sourceKey: source.key,
      ),
    ));
    expect(find.text('artist:test language:japanese'), findsOneWidget);

    appdata.settings[69] = '1';
    SearchResultPage.updateDefaultLanguage(1);
    await tester.pump();
    expect(find.text('artist:test language:japanese'), findsOneWidget);
  });
}
