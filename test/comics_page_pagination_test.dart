import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/state_controller.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/translations.dart';

class _PaginationPage extends ComicsPage<BaseComic> {
  const _PaginationPage(this.load);

  final Future<Res<List<BaseComic>>> Function(int) load;

  @override
  String get sourceKey => 'pagination-fixture';

  @override
  String? get title => null;

  @override
  String get tag => 'pagination-fixture';

  @override
  Widget? get header => const SliverToBoxAdapter(child: Text('Header'));

  @override
  Future<Res<List<BaseComic>>> getComics(int page) => load(page);

  @override
  Widget buildItem(BuildContext context, BaseComic item) => Text(item.title);
}

const _blocked = CustomComic(
    'Blocked', '', '', 'blocked', ['hidden'], '', 'pagination-fixture');
const _before =
    CustomComic('Before', '', '', 'before', [], '', 'pagination-fixture');
const _after =
    CustomComic('After', '', '', 'after', [], '', 'pagination-fixture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late List<String> previousSettings;
  late List<String> previousKeywords;
  late List<int> requests;
  late Future<Res<List<BaseComic>>> Function(int) respond;

  setUp(() {
    previousSettings = List.of(appdata.settings);
    previousKeywords = appdata.blockingKeyword;
    appdata.settings[25] = '0';
    appdata.settings[64] = '0';
    appdata.appSettings.fullyHideBlockedWorks = true;
    appdata.blockingKeyword = ['hidden'];
    requests = [];
    respond = (_) async => const Res([], subData: 1);
  });

  tearDown(() {
    hideAllMessages();
    appdata.settings = previousSettings;
    appdata.blockingKeyword = previousKeywords;
  });

  Future<void> open(WidgetTester tester, {bool settle = true}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: _PaginationPage((page) {
        requests.add(page);
        return respond(page);
      }),
    ));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  void rebuild() => StateController.find<ComicsPageLogic<BaseComic>>(
          tag: 'pagination-fixture')
      .update();

  Future<void> turnPage(WidgetTester tester, {bool previous = false}) async {
    if (appdata.settings[64] == '0') {
      await tester.tap(find.text(previous ? '上一页' : '下一页').first);
    } else {
      await tester.tap(find.byIcon(
          previous ? Icons.keyboard_arrow_left : Icons.keyboard_arrow_right));
    }
    await tester.pumpAndSettle();
  }

  for (final floating in [false, true]) {
    for (final filtered in [false, true]) {
      testWidgets(
          '${floating ? 'floating' : 'inline'} selectors survive a ${filtered ? 'filtered' : 'source-empty'} page',
          (tester) async {
        appdata.settings[25] = '1';
        appdata.settings[64] = floating ? '1' : '0';
        respond = (page) async => Res(
            switch (page) {
              1 => [_before],
              2 => filtered ? [_blocked] : <BaseComic>[],
              _ => [_after],
            },
            subData: 3);
        await open(tester);
        expect(find.text('Before'), findsOneWidget);
        await turnPage(tester);
        expect(find.text('无匹配结果'), findsOneWidget);
        expect(find.text('Header'), findsOneWidget);
        expect(requests, [1, 2]);
        await turnPage(tester);
        expect(find.text('After'), findsOneWidget);
        await turnPage(tester, previous: true);
        expect(find.text('无匹配结果'), findsOneWidget);
        await turnPage(tester, previous: true);
        expect(find.text('Before'), findsOneWidget);
        expect(requests, [1, 2, 3]);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final knownTotal in [false, true]) {
    testWidgets(
        'continuous view passes hidden pages (known total: $knownTotal)',
        (tester) async {
      respond = (page) async => Res([page < 3 ? _blocked : _after],
          subData: knownTotal || page == 3 ? 3 : null);
      await open(tester);

      expect(requests, [1, 2, 3]);
      expect(find.text('After'), findsOneWidget);
      expect(find.text('Blocked'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a fully hidden final page ends without further requests',
      (tester) async {
    respond = (_) async => const Res([_blocked], subData: 2);
    await open(tester);

    expect(requests, [1, 2]);
    expect(find.text('无匹配结果'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    rebuild();
    await tester.pumpAndSettle();
    expect(requests, [1, 2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty first response retains the reported following page',
      (tester) async {
    respond =
        (page) async => Res(page == 1 ? <BaseComic>[] : [_after], subData: 2);
    await open(tester);

    expect(requests, [1, 2]);
    expect(find.text('After'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty first response without a total remains terminal',
      (tester) async {
    respond = (_) async => const Res([]);
    await open(tester);

    expect(requests, [1]);
    expect(find.text('无匹配结果'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continuous pagination leaves the source first page unchanged',
      (tester) async {
    const firstPage = <BaseComic>[_before];
    respond = (page) async => Res(page == 1 ? firstPage : [_after], subData: 2);
    await open(tester);

    expect(requests, [1, 2]);
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('After'), findsOneWidget);
    expect(firstPage, [_before]);
    expect(tester.takeException(), isNull);
  });

  for (final throwsError in [false, true]) {
    testWidgets('hidden-page loading failure waits for retry ($throwsError)',
        (tester) async {
      respond = (page) async {
        if (page == 1) return const Res([_blocked], subData: 2);
        if (requests.where((page) => page == 2).length == 1) {
          if (throwsError) throw StateError('Next page failed');
          return const Res.error('Next page failed');
        }
        return const Res([_after], subData: 2);
      };
      await open(tester);
      expect(requests, [1, 2]);
      expect(
          find.text(
              throwsError ? 'Bad state: Next page failed' : 'Next page failed'),
          findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      rebuild();
      await tester.pumpAndSettle();
      expect(requests, [1, 2]);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(requests, [1, 2, 2]);
      expect(find.text('After'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unknown totals keep the existing empty-page stopping limit',
      (tester) async {
    respond = (page) async => Res(page <= 2 ? [_blocked] : <BaseComic>[]);
    await open(tester);

    expect(requests, [1, 2, 3, 4, 5, 6]);
    expect(find.text('无匹配结果'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a hidden-page request discards its late response',
      (tester) async {
    final next = Completer<Res<List<BaseComic>>>();
    respond = (page) => page == 1
        ? Future.value(const Res([_blocked], subData: 2))
        : next.future;
    await open(tester, settle: false);
    expect(requests, [1, 2]);
    await tester.pumpWidget(const SizedBox.shrink());
    next.complete(const Res([_after], subData: 2));
    await tester.pump();

    expect(requests, [1, 2]);
    expect(find.text('After'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
