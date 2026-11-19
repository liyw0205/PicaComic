import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TranslatedComic extends CustomComic {
  const _TranslatedComic(List<String> tags)
      : super('Title', 'Uploader', '', 'fixture', tags, '', 'fixture');

  @override
  bool get enableTagsTranslation => true;
}

class _BlockingTile extends ComicTile {
  const _BlockingTile(this.title, this.subTitle, this.tags);

  @override
  final String title;

  @override
  final String subTitle;

  @override
  final List<String> tags;

  @override
  String get description => '';

  @override
  Widget get image => const SizedBox.shrink();

  @override
  void onTap_() {}
}

class _BlockingPage extends ComicsPage<BaseComic> {
  const _BlockingPage(this.comics);

  final List<BaseComic> comics;

  @override
  String get sourceKey => 'blocking-fixture';

  @override
  String? get title => null;

  @override
  String get tag => 'blocking-fixture';

  @override
  Future<Res<List<BaseComic>>> getComics(int i) async =>
      Res(comics, subData: 1);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late List<String> previousKeywords;
  late List<String> previousSettings;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-blocking-');
    App.dataPath = directory.path;
    final translations = Uint8List.fromList(utf8.encode(jsonEncode({
      'male': {'focus': '其他词'},
      'female': {'focus': '限定词'},
    })));
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets',
        (message) async {
      expect(
          utf8.decode(message!.buffer
              .asUint8List(message.offsetInBytes, message.lengthInBytes)),
          startsWith('assets/tags'));
      return ByteData.sublistView(translations);
    });
    try {
      await TagsTranslation.readData();
    } finally {
      binding.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
    }
  });

  tearDownAll(() async {
    await DataMaintenance.waitForIdle();
    await directory.delete(recursive: true);
  });

  setUp(() {
    previousKeywords = appdata.blockingKeyword;
    previousSettings = List.of(appdata.settings);
    appdata.blockingKeyword = [];
    appdata.settings[45] = '';
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    StateController.remove<BlockingKeywordPageLogic>();
    appdata.blockingKeyword = previousKeywords;
    appdata.settings = previousSettings;
  });

  const comic = CustomComic('A title', 'An uploader', '', 'fixture',
      ['parody:series:part'], 'A description', 'fixture');

  test('blank imported rules do not block every comic', () {
    appdata.blockingKeyword = ['', ' ', '\t', '\n'];
    expect(isBlocked(comic), isNull);
  });

  test('surrounding whitespace is ignored while reporting the saved rule', () {
    appdata.blockingKeyword = ['  title  '];
    expect(isBlocked(comic), '  title  ');
  });

  test('title, uploader and description retain substring matching', () {
    for (final word in ['title', 'uploader', 'description']) {
      appdata.blockingKeyword = [word];
      expect(isBlocked(comic), word);
    }
    appdata.blockingKeyword = ['unmatched'];
    expect(isBlocked(comic), isNull);
  });

  test('tag matching removes only the first namespace separator', () {
    for (final word in ['parody:series:part', 'series:part']) {
      appdata.blockingKeyword = [word];
      expect(isBlocked(comic), word);
    }
    for (final word in ['series', 'part', 'erie']) {
      appdata.blockingKeyword = [word];
      expect(isBlocked(comic), isNull);
    }
  });

  test('Hitomi gender suffixes do not defeat exact tag rules', () {
    for (final tag in ['focus ♀', 'focus ♂', 'female:focus ♀', 'focus ♀ ♂']) {
      appdata.blockingKeyword = ['focus'];
      expect(isBlocked(_TranslatedComic([tag])), 'focus');
      appdata.blockingKeyword = [tag];
      expect(isBlocked(_TranslatedComic([tag])), tag);
    }
    appdata.blockingKeyword = ['focus'];
    expect(isBlocked(const _TranslatedComic(['focus ♀ variant'])), isNull);
  });

  test('tag translations preserve their namespace before matching', () {
    appdata.blockingKeyword = ['限定词'];
    expect(isBlocked(const _TranslatedComic(['female:focus'])), '限定词');
    expect(isBlocked(const _TranslatedComic(['female:focus ♀'])), '限定词');
    appdata.blockingKeyword = ['其他词'];
    expect(isBlocked(const _TranslatedComic(['female:focus'])), isNull);
  });

  test('sources can opt out of translated tag matching', () {
    appdata.blockingKeyword = ['限定词'];
    expect(
        isBlocked(const CustomComic(
            'Title', '', '', 'fixture', ['female:focus'], '', 'fixture')),
        isNull);
  });

  for (final mode in ['scroll', 'paged', 'sliver']) {
    for (final hide in [false, true]) {
      testWidgets('$mode list ${hide ? 'hides' : 'replaces'} blocked comics',
          (tester) async {
        final previousSources = ComicSource.sources;
        addTearDown(() => ComicSource.sources = previousSources);
        ComicSource.sources = [
          ComicSource.named(
            name: 'Blocking fixture',
            key: 'blocking-fixture',
            filePath: 'fixture',
            comicTileBuilderOverride: (_, comic, __) => Text(comic.title),
          ),
        ];
        appdata.settings[25] = mode == 'paged' ? '1' : '0';
        appdata.appSettings.fullyHideBlockedWorks = hide;
        appdata.blockingKeyword = ['', 'focus'];
        const comics = [
          CustomComic('Filtered comic', '', '', 'filtered', ['focus ♀'], '',
              'blocking-fixture'),
          CustomComic(
              'Visible comic', '', '', 'visible', [], '', 'blocking-fixture'),
        ];
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: mode == 'sliver'
                ? const CustomScrollView(slivers: [
                    SliverGridComics(
                        comics: comics, sourceKey: 'blocking-fixture'),
                  ])
                : const _BlockingPage(comics),
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.text('Visible comic'), findsOneWidget);
        expect(find.text('Filtered comic'), findsNothing);
        expect(find.text('屏蔽: focus'), hide ? findsNothing : findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    }
  }

  Future<void> showPane(WidgetTester tester, _BlockingTile tile) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: TextButton(
            onPressed: tile.showBlockPane, child: const Text('Open')),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final (label, tile, keyword) in [
    (
      'title',
      const _BlockingTile('Title: Part', 'Uploader', []),
      'Title: Part'
    ),
    (
      'uploader',
      const _BlockingTile('Title', 'Uploader: Team', []),
      'Uploader: Team'
    ),
    (
      'tag',
      const _BlockingTile('Title', 'Uploader', ['parody:Series: Part']),
      'Series: Part'
    ),
  ]) {
    testWidgets('blocking pane preserves colons in a $label', (tester) async {
      await showPane(tester, tile);
      final text = label == 'title'
          ? tile.title
          : label == 'uploader'
              ? tile.subTitle
              : tile.tags.single;
      await tester.tap(find.text(text));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '$keyword;');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('blocking pane trims input and ignores empty or duplicate rules',
      (tester) async {
    await showPane(tester, const _BlockingTile('Title', 'Uploader', []));
    await tester.enterText(find.byType(TextField), ' ; focus ; ; focus;  ');
    await tester.runAsync(() async {
      await tester.tap(find.text('提交'));
      await DataMaintenance.waitForIdle();
    });
    await tester.pumpAndSettle();
    expect(appdata.blockingKeyword, ['focus']);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('blockingKeyword'), ['focus']);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final keyboard in [false, true]) {
    testWidgets(
        'settings ${keyboard ? 'keyboard' : 'button'} normalizes blocking rules',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorKey: App.navigatorKey,
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: BlockingKeywordPage(),
      ));
      await tester.pumpAndSettle();

      Future<void> submit() async {
        await tester.runAsync(() async {
          if (keyboard) {
            await tester.testTextInput.receiveAction(TextInputAction.done);
          } else {
            await tester.tap(find.text('提交'));
          }
          await DataMaintenance.waitForIdle();
        });
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await submit();
      expect(appdata.blockingKeyword, isEmpty);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  focus  ');
      await submit();
      expect(appdata.blockingKeyword, ['focus']);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' focus ');
      await submit();
      expect(appdata.blockingKeyword, ['focus']);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('blockingKeyword'), ['focus']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
