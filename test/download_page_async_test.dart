import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

class _PicacgChapterNetwork extends PicacgNetwork {
  _PicacgChapterNetwork()
      : super.forTesting(cachedNetworkFactory: CachedNetwork.new);
  final response = Completer<Res<List<String>>>();
  final requests = <String>[];

  @override
  Future<Res<List<String>>> getEps(String id) {
    requests.add(id);
    return response.future;
  }
}

class _JmChapterNetwork extends JmNetwork {
  _JmChapterNetwork() : super.create();
  final response = Completer<Res<JmComicInfo>>();
  final requests = <String>[];

  @override
  Future<Res<JmComicInfo>> getComicInfo(String id) {
    requests.add(id);
    return response.future;
  }
}

void main() {
  AppTranslation.translations = const {};
  test('font download treats Dio cancellation as a normal result', () async {
    final cancelToken = CancelToken();

    final completed = await runFontDownload((token) async {
      token.cancel('user stopped');
      throw DioException(
        requestOptions: RequestOptions(path: '/font.ttf'),
        type: DioExceptionType.cancel,
      );
    }, cancelToken);

    expect(completed, isFalse);
  });

  test('font download propagates non-cancellation errors', () async {
    final failure = StateError('font server failed');

    await expectLater(
      runFontDownload((_) async => throw failure, CancelToken()),
      throwsA(same(failure)),
    );
  });

  test('font download future waits for the underlying operation', () async {
    final gate = Completer<void>();
    var settled = false;
    final future = runFontDownload((_) => gate.future, CancelToken());
    future.then((_) => settled = true);

    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    gate.complete();
    expect(await future, isTrue);
    expect(settled, isTrue);
  });

  group('downloaded chapter refresh', () {
    late Directory directory;
    late DownloadManager manager;
    late String previousDownloadPath;
    late List<ComicSource> previousSources;
    late DownloadedItem initial;
    late DownloadPageLogic logic;
    late Completer<Res<ComicInfoData>> response;
    var calls = 0;

    const chapters = {
      'chapter-1': 'Chapter 1',
      'chapter-2': 'Chapter 2',
      'chapter-3': 'Chapter 3',
    };
    const detail = ComicInfoData('Fixture', '', '', '', {}, chapters, null,
        null, 0, null, 'fixture_source', 'comic-1');

    setUp(() async {
      manager = DownloadManager();
      await manager.dispose();
      directory =
          await Directory.systemTemp.createTemp('pica-chapter-refresh-');
      previousDownloadPath = appdata.settings[22];
      appdata.settings[22] = directory.path;
      previousSources = ComicSource.sources;
      response = Completer<Res<ComicInfoData>>();
      calls = 0;
      ComicSource.sources = [
        ComicSource.named(
          name: 'Fixture source',
          key: 'fixture_source',
          filePath: 'fixture',
          loadComicInfo: (_) {
            calls++;
            return response.future;
          },
        ),
      ];
      initial = CustomDownloadedItem(
          2,
          [0],
          {'chapter-1': 'Chapter 1', 'chapter-2': 'Chapter 2'},
          'fixture_source-comic-1',
          'Fixture',
          '',
          [],
          'fixture_source',
          'Fixture source',
          '',
          'comic-1');
      final db = sqlite3.open('${directory.path}/download.db');
      db.execute('''
        create table download (
          id text primary key, title text, subtitle text, time int,
          directory text, size int, json text
        )
      ''');
      db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)', [
        initial.id,
        initial.name,
        initial.subTitle,
        DateTime(2025, 1, 1).millisecondsSinceEpoch,
        'stable-directory',
        2,
        jsonEncode(initial.toJson()),
      ]);
      db.dispose();
      await manager.init();
      initial =
          (await manager.getComicOrNull(initial.id))! as CustomDownloadedItem;
      logic = DownloadPageLogic()
        ..comics = [initial]
        ..baseComics = [initial];
    });

    tearDown(() async {
      hideAllMessages();
      await manager.dispose();
      manager.path = null;
      appdata.settings[22] = previousDownloadPath;
      ComicSource.sources = previousSources;
      await directory.delete(recursive: true);
    });

    Future<void> openDetails(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: OverlayWidget(Scaffold(
              body: DownloadedComicInfoView(initial, logic),
            )),
          ),
        );

    testWidgets(
        'refresh keeps concurrent completion and synchronizes both lists',
        (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.pump();
      expect(calls, 1);
      expect(
          tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);

      manager.updateComic(
          initial.id,
          (latest) => CustomDownloadedItem(
              4,
              [0, 1],
              (latest as CustomDownloadedItem).chapters,
              latest.id,
              latest.name,
              latest.subTitle,
              latest.tags,
              latest.sourceKey,
              latest.sourceName,
              latest.cover,
              latest.comicId));
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();

      final restored = (await manager.getComicOrNull(initial.id))!;
      expect(restored.downloadedEps, [0, 1]);
      expect(restored.comicSize, 4);
      expect(restored.eps, chapters.values.toList());
      expect(restored.time, initial.time);
      expect(restored.directory, initial.directory);
      expect(logic.comics.single.downloadedEps, [0, 1]);
      expect(logic.baseComics.single.eps, chapters.values.toList());
      expect(find.text('Chapter 3'), findsOneWidget);
      expect(find.text('章节信息已更新'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      response = Completer<Res<ComicInfoData>>();
      await tester.tap(find.byTooltip('刷新章节'));
      response.complete(const Res(detail));
      await tester.pumpAndSettle();
      expect(find.text('章节信息没有变化'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a disposed details view ignores its pending refresh',
        (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.pump();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect((await manager.getComicOrNull(initial.id))!.eps, initial.eps);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh failure keeps local chapters and allows retry',
        (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.runAsync(() async {
        response.complete(const Res.error('fixture refresh failed'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('fixture refresh failed'), findsOneWidget);
      expect((await manager.getComicOrNull(initial.id))!.eps, initial.eps);
      expect(logic.comics.single, same(initial));
      expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed,
          isNotNull);
      await tester.pump(const Duration(seconds: 3));

      response = Completer<Res<ComicInfoData>>();
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect((await manager.getComicOrNull(initial.id))!.eps,
          chapters.values.toList());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('refresh preserves a completion queued after the source reply',
        (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        scheduleMicrotask(() {
          final db = sqlite3.open('${directory.path}/download.db');
          try {
            final row = db.select(
                'select json from download where id = ?', [initial.id]).single;
            final data =
                jsonDecode(row['json'] as String) as Map<String, dynamic>;
            data['downloadedEps'] = [0, 1];
            data['comicSize'] = 4.0;
            db.execute('update download set json = ?, size = ? where id = ?',
                [jsonEncode(data), 4, initial.id]);
          } finally {
            db.dispose();
          }
        });
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      final stored = (await manager.getComicOrNull(initial.id))!;
      expect(stored.downloadedEps, [0, 1]);
      expect(stored.comicSize, 4);
      expect(stored.eps, chapters.values.toList());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('refresh rejects a replaced source and keeps local chapters',
        (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      ComicSource.sources = [];
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect((await manager.getComicOrNull(initial.id))!.eps, initial.eps);
      expect(find.text('请先添加对应漫画源'), findsOneWidget);
      expect(find.text('章节信息已更新'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    for (final mismatchedField in ['source', 'comic']) {
      testWidgets('refresh rejects a detail with a different $mismatchedField',
          (tester) async {
        await openDetails(tester);
        await tester.tap(find.byTooltip('刷新章节'));
        await tester.runAsync(() async {
          response.complete(Res(ComicInfoData(
            'Other comic',
            '',
            '',
            '',
            {},
            chapters,
            null,
            null,
            0,
            null,
            mismatchedField == 'source' ? 'other_source' : detail.sourceKey,
            mismatchedField == 'comic' ? 'other-comic' : detail.comicId,
          )));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect((await manager.getComicOrNull(initial.id))!.eps, initial.eps);
        expect(logic.comics.single, same(initial));
        expect(find.text('章节信息已更新'), findsNothing);
        await tester.pump(const Duration(seconds: 3));
      });
    }

    testWidgets('refresh cannot restore a deleted download', (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.runAsync(() => manager.delete([initial.id]));
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(await manager.getComicOrNull(initial.id), isNull);
      expect(find.text('章节信息已更新'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a database write failure leaves chapters and UI unchanged',
        (tester) async {
      final db = sqlite3.open('${directory.path}/download.db');
      db.execute('''
        create trigger fail_refresh before insert on download begin
          select raise(ABORT, 'fixture write failed');
        end
      ''');
      db.dispose();
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      await tester.runAsync(() async {
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect((await manager.getComicOrNull(initial.id))!.eps, initial.eps);
      expect(logic.comics.single, same(initial));
      expect(logic.baseComics.single, same(initial));
      expect(find.text('刷新章节失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    for (final source in ['PICACG', 'JM']) {
      for (final reordered in [false, true]) {
        testWidgets(
            '$source refresh ${reordered ? 'rejects a reorder' : 'appends chapters'}',
            (tester) async {
          final picacgNetwork = _PicacgChapterNetwork();
          final jmNetwork = _JmChapterNetwork();
          final savedPicacgNetwork = PicacgNetwork.cache;
          final savedJmNetwork = JmNetwork.cache;
          PicacgNetwork.cache = picacgNetwork;
          JmNetwork.cache = jmNetwork;
          addTearDown(() {
            PicacgNetwork.cache = savedPicacgNetwork;
            JmNetwork.cache = savedJmNetwork;
          });
          JmComicInfo jmComic(Map<int, String> series, List<String> names) =>
              JmComicInfo('JM fixture', '123', [], '', 0, 0, series, [], [], [],
                  [], false, false, 0, names);
          final names = ['Chapter 1', 'Chapter 2'];
          final DownloadedItem item = source == 'PICACG'
              ? DownloadedComic(
                  ComicItem(
                      Profile('creator', '', '', 0, 0, 'author', '', false,
                          null, null),
                      'PICACG fixture',
                      '',
                      '',
                      'author',
                      '',
                      [],
                      [],
                      0,
                      0,
                      false,
                      false,
                      2,
                      'abcdef1234567890abcdef12',
                      0,
                      '',
                      [],
                      []),
                  names,
                  2,
                  [1])
              : DownloadedJmComic(
                  jmComic({1: 'ep-1', 2: 'ep-2'}, names), 2, [1]);
          final db = sqlite3.open('${directory.path}/download.db');
          db.execute('delete from download');
          db.execute('insert into download values (?, ?, ?, ?, ?, ?, ?)', [
            item.id,
            item.name,
            item.subTitle,
            initial.time!.millisecondsSinceEpoch,
            initial.directory,
            2,
            jsonEncode(item.toJson()),
          ]);
          db.dispose();
          initial = (await manager.getComicOrNull(item.id))!;
          logic.comics = [initial];
          logic.baseComics = [initial];
          await openDetails(tester);
          await tester.tap(find.byTooltip('刷新章节'));
          await tester.runAsync(() async {
            final nextNames = reordered
                ? ['Chapter 2', 'Chapter 1']
                : [...names, 'Chapter 3'];
            if (source == 'PICACG') {
              picacgNetwork.response.complete(Res(nextNames));
            } else {
              jmNetwork.response.complete(Res(jmComic(
                  reordered
                      ? {1: 'ep-2', 2: 'ep-1'}
                      : {1: 'ep-1', 2: 'ep-2', 3: 'ep-3'},
                  nextNames)));
            }
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pumpAndSettle();
          final stored = (await manager.getComicOrNull(initial.id))!;
          expect(stored.eps, reordered ? names : [...names, 'Chapter 3']);
          expect(stored.downloadedEps, [1]);
          expect(stored.time, initial.time);
          expect(stored.directory, initial.directory);
          expect(logic.comics.single.eps, stored.eps);
          expect(
              picacgNetwork.requests, source == 'PICACG' ? [initial.id] : []);
          expect(jmNetwork.requests, source == 'JM' ? ['123'] : []);
          expect(
              find.text('章节信息已更新'), reordered ? findsNothing : findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 3));
        });
      }
    }

    testWidgets('refresh cannot modify the same ID in another download root',
        (tester) async {
      await openDetails(tester);
      await tester.tap(find.byTooltip('刷新章节'));
      late Directory secondRoot;
      await tester.runAsync(() async {
        secondRoot = await Directory.systemTemp
            .createTemp('pica-chapter-refresh-other-');
        addTearDown(() async {
          await manager.dispose();
          await secondRoot.delete(recursive: true);
        });
        await manager.dispose();
        await File('${directory.path}/download.db')
            .copy('${secondRoot.path}/download.db');
        appdata.settings[22] = secondRoot.path;
        await manager.init();
        response.complete(const Res(detail));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect((await manager.getComicOrNull(initial.id))!.eps, initial.eps);
      expect(logic.comics.single, same(initial));
      expect(find.text('章节信息已更新'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
