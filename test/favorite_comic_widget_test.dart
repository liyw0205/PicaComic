import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/hitomi/hitomi_comic_page.dart';
import 'package:pica_comic/pages/htmanga/ht_comic_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _FavoritesStore extends LocalFavoritesManager {
  _FavoritesStore() : super.create();

  Future<List<String>>? pendingFind;
  Future<void>? pendingAdd;
  Future<void>? pendingSave;
  int addCalls = 0;

  @override
  Future<List<String>> find(String target, FavoriteType type) =>
      pendingFind ?? super.find(target, type);

  @override
  Future<void> addComic(String folder, FavoriteItem comic,
      [int? order, bool downloadCover = true]) {
    addCalls++;
    return pendingAdd ?? super.addComic(folder, comic, order, downloadCover);
  }

  @override
  Future<void> saveData() => pendingSave ?? super.saveData();
}

class _HitomiFavoritePage extends HitomiComicPage {
  const _HitomiFavoritePage(this.onFavoritePanel)
      : super.fromLink('https://hitomi.la/galleries/42.html');

  final ValueChanged<FavoriteComicWidget> onFavoritePanel;

  @override
  void favoriteComic(FavoriteComicWidget widget) => onFavoritePanel(widget);
}

class _HtFavoritePage extends HtComicPage {
  const _HtFavoritePage(this.onFavoritePanel) : super('42');

  final ValueChanged<FavoriteComicWidget> onFavoritePanel;

  @override
  void favoriteComic(FavoriteComicWidget widget) => onFavoritePanel(widget);
}

class _EmptyDetailHistory extends HistoryManager {
  _EmptyDetailHistory() : super.create();

  @override
  Future<History?> find(String target) async => null;
}

class _FavoriteDetailPage extends BaseComicPage<ComicInfoData> {
  const _FavoriteDetailPage(this.load, {this.showActions = false});

  final Future<Res<ComicInfoData>> Function() load;
  final bool showActions;

  @override
  String get tag => 'favorite-detail-fixture';

  @override
  String get id => 'fixture';

  @override
  String get downloadedId => 'fixture';

  @override
  FavoriteItem toLocalFavoriteItem() => FavoriteItem(
        target: id,
        name: data!.title,
        coverPath: '',
        author: '',
        type: FavoriteType.picacg,
        tags: [],
      );

  @override
  Future<Res<ComicInfoData>> loadData() => load();

  @override
  Future<bool> loadFavorite(ComicInfoData data) async =>
      data.isFavorite == true;

  @override
  bool? get favoriteOnPlatformInitial => data?.isFavorite;

  @override
  Widget buildLoading(BuildContext context) => const Text('Loading');

  @override
  Widget buildTitle(ComicPageLogic<ComicInfoData> logic) =>
      SliverToBoxAdapter(child: Text('Platform: ${logic.favoriteOnPlatform}'));

  @override
  Widget buildComicInfo(
          ComicPageLogic<ComicInfoData> logic, BuildContext context,
          [bool loaded = true]) =>
      SliverToBoxAdapter(
          child: showActions
              ? buildActions(logic, context, true)
              : const SizedBox.shrink());

  @override
  Widget buildTags(ComicPageLogic logic, BuildContext context) =>
      const SliverToBoxAdapter(child: SizedBox.shrink());

  @override
  List<Widget> buildEpisodeInfo(BuildContext context) => [];

  @override
  List<Widget> buildIntroduction(BuildContext context) => [];

  @override
  List<Widget> buildThumbnails(BuildContext context) => [];

  @override
  List<Widget> buildRecommendation(BuildContext context) => [];

  @override
  ThumbnailsData? get thumbnailsCreator => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory root;
  late Directory dataDirectory;
  late _FavoritesStore store;
  late String previousSync;
  late String previousQuickFolder;
  LocalFavoritesManager? previousStore;
  final comic = FavoriteItem(
    target: 'fixture',
    name: 'Fixture',
    coverPath: '',
    author: '',
    type: const FavoriteType(0),
    tags: [],
  );

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp('pica-panel-data-');
    App.dataPath = dataDirectory.path;
  });

  setUp(() async {
    previousSync = appdata.settings[45];
    previousQuickFolder = appdata.settings[51];
    appdata.settings[45] = '';
    root = await Directory.systemTemp.createTemp('pica-favorite-panel-');
    previousStore = LocalFavoritesManager.cache;
    store = _FavoritesStore();
    LocalFavoritesManager.cache = store;
    await store.init(
        databasePath: '${root.path}/favorites.db', importLegacy: false);
    store.createFolder('Local A');
    store.createFolder('Local B');
  });

  tearDown(() async {
    hideAllMessages();
    store.close();
    LocalFavoritesManager.cache = previousStore;
    appdata.settings[45] = previousSync;
    appdata.settings[51] = previousQuickFolder;
    await root.delete(recursive: true);
  });

  tearDownAll(() => dataDirectory.delete(recursive: true));

  Future<void> openPanel(WidgetTester tester, FavoriteComicWidget panel) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => Dialog(
              child: SizedBox(width: 520, height: 500, child: panel),
            ),
          ),
          child: const Text('Open'),
        );
      })),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> closePanel(WidgetTester tester) async {
    App.navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FavoriteComicWidget), findsNothing);
  }

  Button action(WidgetTester tester) =>
      tester.widget<Button>(find.byType(Button).last);

  for (final initial in [true, false, null]) {
    testWidgets('detail loads and refreshes platform favorite=$initial',
        (tester) async {
      final previousHistory = HistoryManager.cache;
      HistoryManager.cache = _EmptyDetailHistory();
      addTearDown(() => HistoryManager.cache = previousHistory);
      var platformFavorite = initial;
      final page = _FavoriteDetailPage(() async => Res(ComicInfoData('Fixture',
          null, '', null, {}, null, null, null, 0, null, 'fixture', 'fixture',
          isFavorite: platformFavorite)));
      await tester.pumpWidget(MaterialApp(home: page));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Platform: $initial'), findsOneWidget);

      final logic =
          StateController.find<ComicPageLogic<ComicInfoData>>(tag: page.tag);
      for (final updated in [false, true, null]) {
        platformFavorite = updated;
        logic.refresh_();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.text('Platform: $updated'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      logic.controller.dispose();
    });
  }

  Future<ComicPageLogic<ComicInfoData>> openQuickFavorite(
      WidgetTester tester) async {
    final previousHistory = HistoryManager.cache;
    HistoryManager.cache = _EmptyDetailHistory();
    addTearDown(() => HistoryManager.cache = previousHistory);
    appdata.settings[51] = 'Local A';
    final page = _FavoriteDetailPage(
        () async => const Res(ComicInfoData('Fixture', null, '', null, {}, null,
            null, null, 0, null, 'fixture', 'fixture',
            isFavorite: false)),
        showActions: true);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: OverlayWidget(page),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final logic =
        StateController.find<ComicPageLogic<ComicInfoData>>(tag: page.tag);
    addTearDown(() => logic.controller.dispose());
    return logic;
  }

  testWidgets('quick favorite waits for saving and ignores repeated presses',
      (tester) async {
    final saved = Completer<void>();
    store.pendingAdd = saved.future;
    final logic = await openQuickFavorite(tester);
    await tester.longPress(find.text('收藏'));
    await tester.pump();
    final prematureSuccess = find.text('已收藏').evaluate().isNotEmpty;
    await tester.longPress(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();
    final callsBeforeSaving = store.addCalls;
    saved.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(prematureSuccess, isFalse);
    expect(callsBeforeSaving, 1);
    expect(logic.favorite, isTrue);
    expect(find.byIcon(Icons.collections_bookmark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick favorite handles a save error and permits retry',
      (tester) async {
    final saved = Completer<void>();
    store.pendingAdd = saved.future;
    final logic = await openQuickFavorite(tester);
    await tester.longPress(find.text('收藏'));
    saved.completeError(StateError('fixture save failure'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(logic.favorite, isFalse);
    expect(tester.takeException(), isNull);

    store.pendingAdd = Future<void>.value();
    await tester.longPress(find.text('收藏'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(logic.favorite, isTrue);
    expect(store.addCalls, 2);
  });

  for (final refresh in [false, true]) {
    testWidgets(
        'quick favorite ignores completion after ${refresh ? 'refresh' : 'close'}',
        (tester) async {
      final saved = Completer<void>();
      store.pendingAdd = saved.future;
      final logic = await openQuickFavorite(tester);
      await tester.longPress(find.text('收藏'));
      if (refresh) {
        logic.refresh_();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      saved.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(logic.favorite, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  const htComic =
      HtComicInfo('42', '', 'Fixture', '', 2, {}, '', '', '', 0, []);

  for (final localFavorite in [false, true]) {
    testWidgets('WNACG detail restores local favorite=$localFavorite',
        (tester) async {
      await tester.runAsync(() async {
        await store.addComic(
            'Local A',
            FavoriteItem(
              target: '42',
              name: 'Other source',
              coverPath: '',
              author: '',
              type: FavoriteType.jm,
              tags: [],
            ),
            null,
            false);
        if (localFavorite) {
          await store.addComic('Local B',
              FavoriteItem.fromHtcomic(htComic.toBrief()), null, false);
        }
      });

      expect(
          await const HtComicPage('42').loadFavorite(htComic), localFavorite);
    });
  }

  testWidgets('WNACG local add and removal update the detail favorite state',
      (tester) async {
    late FavoriteComicWidget panel;
    final page = _HtFavoritePage((widget) => panel = widget);
    final logic = StateController.put(
        ComicPageLogic<HtComicInfo>()..data = htComic,
        tag: page.tag);
    addTearDown(() {
      logic.controller.dispose();
      StateController.remove<ComicPageLogic<HtComicInfo>>(page.tag);
    });
    page.openFavoritePanel();
    await openPanel(tester, panel);
    await tester.tap(find.text('Local A'));
    await tester.pump();
    await tester.runAsync(
        () => (action(tester).onPressed as Future<void> Function())());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(await store.find('42', FavoriteType.htManga), ['Local A']);
    expect(page.favorite, isTrue);

    page.openFavoritePanel();
    await openPanel(tester, panel);
    await tester.tap(find.text('Local A'));
    await tester.pump();
    expect(find.text('取消收藏'), findsNWidgets(2));
    await tester.runAsync(
        () => (action(tester).onPressed as Future<void> Function())());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(await store.find('42', FavoriteType.htManga), isEmpty);
    expect(page.favorite, isFalse);
  });

  for (final localFavorite in [false, true]) {
    for (final platformFavorite in [null, false, true]) {
      testWidgets(
          'custom detail state combines local=$localFavorite and platform=$platformFavorite',
          (tester) async {
        const sourceKey = 'custom-fixture';
        final data = ComicInfoData('Fixture', null, '', null, {}, null, null,
            null, 0, null, sourceKey, 'fixture',
            isFavorite: platformFavorite);
        FavoriteItem item(String key) => FavoriteItem(
              target: 'fixture',
              name: 'Fixture',
              coverPath: '',
              author: '',
              type: FavoriteType(key.hashCode),
              tags: [],
            );
        await tester.runAsync(() async {
          await store.addComic('Local A', item('other-source'), null, false);
          if (localFavorite) {
            await store.addComic('Local B', item(sourceKey), null, false);
          }
        });
        late BaseComicPage<ComicInfoData> page;
        await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
          page = const ComicPage(sourceKey: sourceKey, id: 'fixture')
              .build(context) as BaseComicPage<ComicInfoData>;
          return const SizedBox.shrink();
        })));

        expect(await page.loadFavorite(data),
            localFavorite || platformFavorite == true);
      });
    }
  }

  testWidgets('Hitomi local callback waits for persistence', (tester) async {
    final persisted = Completer<void>();
    store.pendingAdd = persisted.future;
    late FavoriteComicWidget panel;
    final page = _HitomiFavoritePage((widget) => panel = widget);
    final logic = StateController.put(
        ComicPageLogic<HitomiComic>()
          ..data = HitomiComic(
              '42', 'Fixture', [], '', [], '', [], [], [], '', [], [], 'cover'),
        tag: page.tag);
    addTearDown(() {
      logic.controller.dispose();
      StateController.remove<ComicPageLogic<HitomiComic>>(page.tag);
    });
    page.openFavoritePanel();
    final result =
        Future<Res<bool>>.sync(() => panel.selectFolderCallback!('Local A', 1));
    var completed = false;
    unawaited(result.then((_) => completed = true));
    await tester.pump();
    expect(completed, isFalse);
    persisted.complete();
    expect((await result).success, isTrue);
  });

  testWidgets('network folders are requested once across rebuilds and tabs',
      (tester) async {
    final folders = Completer<Res<Map<String, String>>>();
    var requests = 0;
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: true,
          needLoadFolderData: true,
          localFavoriteItem: comic,
          foldersLoader: () {
            requests++;
            return folders.future;
          },
          setFavorite: (_) {},
        ));
    await tester.tap(find.text('本地'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(requests, 1);
    folders.complete(const Res({'network': 'Network folder'}));
    await tester.pump();
    await closePanel(tester);
  });

  testWidgets('late folder lookup does not rebuild a closed panel',
      (tester) async {
    final folders = Completer<Res<Map<String, String>>>();
    final local = Completer<List<String>>();
    store.pendingFind = local.future;
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: true,
          needLoadFolderData: true,
          localFavoriteItem: comic,
          foldersLoader: () => folders.future,
          setFavorite: (_) {},
        ));
    await closePanel(tester);
    local.complete([]);
    folders.complete(const Res({'network': 'Network folder'}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final throwsError in [false, true]) {
    testWidgets('folder loading failure allows retry (throws: $throwsError)',
        (tester) async {
      var requests = 0;
      await openPanel(
          tester,
          FavoriteComicWidget(
            havePlatformFavorite: true,
            needLoadFolderData: true,
            localFavoriteItem: comic,
            foldersLoader: () async {
              if (++requests == 1) {
                if (throwsError) throw StateError('Folder request failed');
                return const Res.error('Folder request failed');
              }
              return const Res({'network': 'Network folder'});
            },
            setFavorite: (_) {},
          ));

      expect(requests, 1);
      expect(find.byType(NetworkError), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(requests, 2);
      expect(find.text('Network folder'), findsOneWidget);
      await closePanel(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('local-only panel ignores the initial network folder',
      (tester) async {
    final calls = <String>[];
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: false,
          needLoadFolderData: false,
          initialFolder: '0',
          localFavoriteItem: comic,
          selectFolderCallback: (id, type) {
            calls.add(id);
            return const Res(true);
          },
          setFavorite: (_) {},
        ));
    expect(action(tester).disabled, isTrue);
    await tester.tap(find.text('Local A'));
    await tester.pump();
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(calls, ['Local A']);
  });

  testWidgets('adding uses a snapshot of the selected folders', (tester) async {
    final first = Completer<Res<bool>>();
    final calls = <(String, int)>[];
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: false,
          needLoadFolderData: false,
          localFavoriteItem: comic,
          selectFolderCallback: (id, type) {
            calls.add((id, type));
            if (id == 'Local A') return first.future;
            return const Res(true);
          },
          setFavorite: (_) {},
        ));
    await tester.tap(find.text('Local A'));
    await tester.tap(find.text('Local B'));
    await tester.pump();
    final pending = (action(tester).onPressed as Future<void> Function())();
    await tester.pump();
    await tester.tap(find.text('Local B'));
    first.complete(const Res(true));
    await pending;
    await tester.pump(const Duration(seconds: 3));
    expect(calls, [('Local A', 1), ('Local B', 1)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding waits for completion and ignores repeated presses',
      (tester) async {
    final saved = Completer<Res<bool>>();
    final favoriteChanges = <bool>[];
    var calls = 0;
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: false,
          needLoadFolderData: false,
          localFavoriteItem: comic,
          selectFolderCallback: (_, __) {
            calls++;
            return saved.future;
          },
          setFavorite: favoriteChanges.add,
        ));
    await tester.tap(find.text('Local A'));
    await tester.pump();
    final submit = action(tester).onPressed as Future<void> Function();
    final pending = submit();
    await tester.pump();
    final repeated = submit();
    await tester.pump();
    final callsBeforeSaving = calls;
    final loadingBeforeSaving = action(tester).isLoading;
    final changesBeforeSaving = List<bool>.of(favoriteChanges);
    final prematureSuccess = find.text('添加收藏成功').evaluate().isNotEmpty;
    saved.complete(const Res(true));
    await Future.wait([pending, repeated]);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(callsBeforeSaving, 1);
    expect(loadingBeforeSaving, isTrue);
    expect(changesBeforeSaving, isEmpty);
    expect(prematureSuccess, isFalse);
    expect(favoriteChanges, [true]);
    expect(find.byType(FavoriteComicWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed folder stops the batch and permits retry',
      (tester) async {
    final calls = <String>[];
    final favoriteChanges = <bool>[];
    var fail = true;
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: false,
          needLoadFolderData: false,
          localFavoriteItem: comic,
          selectFolderCallback: (id, type) {
            calls.add(id);
            return id == 'Local A' && fail
                ? const Res.error('Save failed')
                : const Res(true);
          },
          setFavorite: favoriteChanges.add,
        ));
    await tester.tap(find.text('Local A'));
    await tester.tap(find.text('Local B'));
    await tester.pump();
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(calls, ['Local A']);
    expect(favoriteChanges, isEmpty);
    expect(find.byType(FavoriteComicWidget), findsOneWidget);
    expect(action(tester).isLoading, isFalse);
    fail = false;
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(calls, ['Local A', 'Local A', 'Local B']);
    expect(favoriteChanges, [true, true]);
    await tester.pumpAndSettle();
    expect(find.byType(FavoriteComicWidget), findsNothing);
  });

  testWidgets('retry keeps a successful earlier local folder', (tester) async {
    final calls = <String>[];
    final favoriteChanges = <bool>[];
    var fail = true;
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: false,
          needLoadFolderData: false,
          localFavoriteItem: comic,
          selectFolderCallback: (id, type) {
            calls.add(id);
            return id == 'Local B' && fail
                ? const Res.error('Save failed')
                : const Res(true);
          },
          setFavorite: favoriteChanges.add,
        ));
    await tester.tap(find.text('Local A'));
    await tester.tap(find.text('Local B'));
    await tester.pump();
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(favoriteChanges, [true]);
    expect(find.byType(FavoriteComicWidget), findsOneWidget);

    fail = false;
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(calls, ['Local A', 'Local B', 'Local B']);
    expect(favoriteChanges, [true, true]);
  });

  testWidgets('network folder IDs do not collide with local folder names',
      (tester) async {
    await tester.runAsync(() => store.addComic('Local A', comic, null, false));
    final calls = <(String, int)>[];
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: true,
          needLoadFolderData: false,
          folders: const {'Local A': 'Network folder'},
          initialFolder: 'Local A',
          localFavoriteItem: comic,
          selectFolderCallback: (id, type) {
            calls.add((id, type));
            return const Res(true);
          },
          setFavorite: (_) {},
        ));
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(calls, [('Local A', 0)]);
  });

  testWidgets('swiping tabs clears the old selection and changes its type',
      (tester) async {
    final calls = <(String, int)>[];
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: true,
          needLoadFolderData: false,
          folders: const {'network': 'Network folder'},
          initialFolder: 'network',
          localFavoriteItem: comic,
          selectFolderCallback: (id, type) {
            calls.add((id, type));
            return const Res(true);
          },
          setFavorite: (_) {},
        ));
    await tester.drag(find.byType(TabBarView), const Offset(-480, 0));
    await tester.pumpAndSettle();
    expect(action(tester).disabled, isTrue);
    await tester.tap(find.text('Local A'));
    await tester.pump();
    await (action(tester).onPressed as Future<void> Function())();
    await tester.pump(const Duration(seconds: 3));
    expect(calls, [('Local A', 1)]);
  });

  testWidgets('removing all selected local favorites clears the comic state',
      (tester) async {
    await tester.runAsync(() async {
      await store.addComic('Local A', comic, null, false);
      await store.addComic('Local B', comic, null, false);
    });
    final favoriteChanges = <bool>[];
    await openPanel(
        tester,
        FavoriteComicWidget(
          havePlatformFavorite: false,
          needLoadFolderData: false,
          localFavoriteItem: comic,
          setFavorite: favoriteChanges.add,
        ));
    await tester.tap(find.text('Local A'));
    await tester.tap(find.text('Local B'));
    await tester.pump();
    expect(find.text('取消收藏'), findsNWidgets(3));
    await tester.runAsync(
        () => (action(tester).onPressed as Future<void> Function())());
    await tester.pump(const Duration(seconds: 3));
    expect(store.count('Local A'), 0);
    expect(store.count('Local B'), 0);
    expect(favoriteChanges, [false]);
    await tester.pumpAndSettle();
    expect(find.byType(FavoriteComicWidget), findsNothing);
  });

  for (final fromRow in [false, true]) {
    testWidgets('local cancellation awaits saving (row: $fromRow)',
        (tester) async {
      await tester
          .runAsync(() => store.addComic('Local A', comic, null, false));
      final saved = Completer<void>();
      store.pendingSave = saved.future;
      final favoriteChanges = <bool>[];
      await openPanel(
          tester,
          FavoriteComicWidget(
            havePlatformFavorite: false,
            needLoadFolderData: false,
            localFavoriteItem: comic,
            setFavorite: favoriteChanges.add,
          ));
      Future<void>? pending;
      if (fromRow) {
        await tester.tap(find.text('取消收藏'));
      } else {
        await tester.tap(find.text('Local A'));
        await tester.pump();
        pending = (action(tester).onPressed as Future<void> Function())();
      }
      await tester.pump();
      final loadingBeforeSaving = action(tester).isLoading;
      final changesBeforeSaving = List<bool>.of(favoriteChanges);
      final prematureSuccess = find.text('取消收藏成功').evaluate().isNotEmpty;
      saved.complete();
      if (pending != null) await pending;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(loadingBeforeSaving, isTrue);
      expect(changesBeforeSaving, isEmpty);
      expect(prematureSuccess, isFalse);
      expect(store.count('Local A'), 0);
      expect(favoriteChanges, [false]);
      expect(find.byType(FavoriteComicWidget),
          fromRow ? findsOneWidget : findsNothing);
      if (fromRow) await closePanel(tester);
      expect(tester.takeException(), isNull);
    });
  }

  for (final withFolder in [false, true]) {
    testWidgets('network cancellation can retry a throw (folder: $withFolder)',
        (tester) async {
      var attempts = 0;
      final favoriteChanges = <bool>[];
      Future<Res<bool>> cancel() async {
        if (++attempts == 1) throw StateError('Cancel failed');
        return const Res(true);
      }

      await openPanel(
          tester,
          FavoriteComicWidget(
            havePlatformFavorite: true,
            needLoadFolderData: withFolder,
            favoriteOnPlatform: withFolder ? null : true,
            initialFolder: 'network',
            foldersLoader: () async =>
                const Res({'network': 'Network folder'}, subData: ['network']),
            localFavoriteItem: comic,
            cancelPlatformFavorite: cancel,
            cancelPlatformFavoriteWithFolder: (id) {
              expect(id, 'network');
              return cancel();
            },
            setFavorite: favoriteChanges.add,
          ));
      await (action(tester).onPressed as Future<void> Function())();
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(FavoriteComicWidget), findsOneWidget);
      expect(action(tester).isLoading, isFalse);
      expect(favoriteChanges, isEmpty);
      await (action(tester).onPressed as Future<void> Function())();
      await tester.pump(const Duration(seconds: 3));
      expect(attempts, 2);
      expect(favoriteChanges, [false]);
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteComicWidget), findsNothing);
    });

    testWidgets('late network cancellation is ignored (folder: $withFolder)',
        (tester) async {
      final result = Completer<Res<bool>>();
      final favoriteChanges = <bool>[];
      await openPanel(
          tester,
          FavoriteComicWidget(
            havePlatformFavorite: true,
            needLoadFolderData: withFolder,
            favoriteOnPlatform: withFolder ? null : true,
            initialFolder: 'network',
            foldersLoader: () async =>
                const Res({'network': 'Network folder'}, subData: ['network']),
            localFavoriteItem: comic,
            cancelPlatformFavorite: () => result.future,
            cancelPlatformFavoriteWithFolder: (_) => result.future,
            setFavorite: favoriteChanges.add,
          ));
      final pending = (action(tester).onPressed as Future<void> Function())();
      await closePanel(tester);
      result.complete(const Res(true));
      await pending;
      await tester.pump();
      expect(find.text('取消收藏成功'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(favoriteChanges, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in ['success', 'error', 'throw']) {
    testWidgets('late add $outcome does not update the closed panel',
        (tester) async {
      final result = Completer<Res<bool>>();
      final favoriteChanges = <bool>[];
      await openPanel(
          tester,
          FavoriteComicWidget(
            havePlatformFavorite: false,
            needLoadFolderData: false,
            localFavoriteItem: comic,
            selectFolderCallback: (_, __) => result.future,
            setFavorite: favoriteChanges.add,
          ));
      await tester.tap(find.text('Local A'));
      await tester.pump();
      final pending = (action(tester).onPressed as Future<void> Function())();
      await closePanel(tester);
      if (outcome == 'throw') {
        result.completeError(StateError('Save failed'));
      } else {
        result.complete(outcome == 'success'
            ? const Res(true)
            : const Res.error('Save failed'));
      }
      await pending;
      await tester.pump();
      expect(find.text('添加收藏成功'), findsNothing);
      expect(find.textContaining('Save failed'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(favoriteChanges, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
