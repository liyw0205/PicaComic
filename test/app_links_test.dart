import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/pages/ehentai/eh_gallery_page.dart';
import 'package:pica_comic/pages/hitomi/hitomi_comic_page.dart';
import 'package:pica_comic/pages/jm/jm_comic_page.dart';
import 'package:pica_comic/pages/nhentai/comic_page.dart';
import 'package:pica_comic/pages/tools.dart';
import 'package:pica_comic/tools/app_links.dart';
import 'package:pica_comic/tools/translations.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;
  final popped = <Route<dynamic>>[];
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
    pushed.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }
}

void main() {
  AppTranslation.translations = const {};
  late GlobalKey<NavigatorState>? previousNavigator;

  setUp(() {
    previousNavigator = App.mainNavigatorKey;
    App.mainNavigatorKey = App.navigatorKey;
  });

  tearDown(() {
    hideAllMessages();
    App.mainNavigatorKey = previousNavigator;
  });

  const validLinks = {
    'https://e-hentai.org/g/123/abc456/': 'https://e-hentai.org/g/123/abc456/',
    'http://exhentai.org/g/123/abc456?p=2#page':
        'https://exhentai.org/g/123/abc456',
    'https://nhentai.net/g/123/': 'https://nhentai.net/g/123/',
    'https://nhentai.xxx/g/123?utm_source=share': 'https://nhentai.net/g/123/',
    'https://hitomi.la/galleries/123.html':
        'https://hitomi.la/galleries/123.html',
    'https://hitomi.la/doujinshi/title-2026-123.html?ref=456#1':
        'https://hitomi.la/galleries/123.html',
    'https://hitomi.la/manga/title-123.html':
        'https://hitomi.la/galleries/123.html',
    'https://hitomi.la/cg/title-123.html':
        'https://hitomi.la/galleries/123.html',
  };

  test('detection accepts the same gallery URLs that navigation supports', () {
    for (final link in validLinks.keys) {
      expect(canHandle(link), isTrue, reason: link);
    }
  });

  const invalidLinks = [
    '',
    'not a link',
    'https://hitomi.la',
    'https://hitomi.la/',
    'https://hitomi.la/tag/test-123.html',
    'https://hitomi.la/galleries/not-a-number.html',
    'https://hitomi.la/%FF/123.html',
    'https://nhentai.net/',
    'https://nhentai.net/g/',
    'https://nhentai.net/g/not-a-number/',
    'https://nhentai.net/search/?q=/g/123',
    'https://e-hentai.org/',
    'https://e-hentai.org/g/123/',
    'https://e-hentai.org/g/not-a-number/token/',
    'https://e-hentai.org/other/g/123/token/',
    'ftp://nhentai.net/g/123/',
    'https://example.com/g/123/',
    'https://nhentai.net.example.com/g/123/',
  ];

  test('detection rejects home, search, malformed, and unrelated URLs', () {
    for (final link in invalidLinks) {
      expect(canHandle(link), isFalse, reason: link);
    }
  });

  testWidgets('valid links push the expected comic page and canonical target',
      (tester) async {
    for (final entry in validLinks.entries) {
      final observer = _RouteObserver();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: App.navigatorKey,
        navigatorObservers: [observer],
        home: const Scaffold(body: Text('Home')),
      ));

      expect(handleAppLinks(Uri.parse(entry.key)), isTrue, reason: entry.key);
      final route = observer.latest! as AppPageRoute;
      final page = route.builder(App.globalContext!);
      final host = Uri.parse(entry.key).host;
      if (host == 'hitomi.la') {
        expect(page, isA<HitomiComicPage>());
        expect((page as HitomiComicPage).link, entry.value);
      } else if (host.startsWith('nhentai.')) {
        expect(page, isA<NhentaiComicPage>());
        expect((page as NhentaiComicPage).url, entry.value);
      } else {
        expect(page, isA<EhGalleryPage>());
        expect((page as EhGalleryPage).link, entry.value);
      }
      // Inspect the destination before its remote detail loader is rendered.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('invalid links do not throw or push a page', (tester) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [observer],
      home: const Scaffold(body: Text('Home')),
    ));
    final initialRoute = observer.latest;
    for (final link in invalidLinks) {
      expect(
          handleAppLinks(Uri.parse(link), showMessageWhenError: false), isFalse,
          reason: link);
      expect(observer.latest, same(initialRoute), reason: link);
    }
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('silent link probes do not show an error toast', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      home: const OverlayWidget(Scaffold(body: Text('Home'))),
    ));
    final uri = Uri.parse('https://hitomi.la/tag/example.html');
    expect(handleAppLinks(uri, showMessageWhenError: false), isFalse);
    await tester.pump();
    expect(find.text('Unknown Link'), findsNothing);

    expect(handleAppLinks(uri), isFalse);
    await tester.pump();
    expect(find.text('Unknown Link'), findsOneWidget);
    hideAllMessages();
    await tester.pump(const Duration(seconds: 3));
  });

  test('navigation without an active navigator rejects the link safely', () {
    App.mainNavigatorKey = null;
    expect(
        handleAppLinks(Uri.parse(validLinks.keys.first),
            showMessageWhenError: false),
        isFalse);
  });

  Future<(_RouteObserver, _RouteObserver)> openToolInput(
      WidgetTester tester, String title) async {
    final root = _RouteObserver();
    final main = _RouteObserver();
    App.mainNavigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [root],
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: OverlayWidget(Navigator(
        key: App.mainNavigatorKey,
        observers: [main],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: TextButton(onPressed: openTool, child: Text('Open tools')),
          ),
        ),
      )),
    ));
    await tester.tap(find.text('Open tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    return (root, main);
  }

  for (final keyboard in [false, true]) {
    testWidgets('link tool keeps invalid input open (keyboard: $keyboard)',
        (tester) async {
      final (root, main) = await openToolInput(tester, '打开链接');
      final initialRoute = main.latest;
      for (final text in ['', 'https://hitomi.la/', 'https://example.com/']) {
        await tester.enterText(find.byType(TextField), text);
        if (keyboard) {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        } else {
          await tester.tap(find.text('打开'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget, reason: text);
        expect(find.text('不支持的链接'), findsOneWidget, reason: text);
        expect(root.popped, isEmpty, reason: text);
        expect(main.latest, same(initialRoute), reason: text);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('JM ID tool keeps empty input open (keyboard: $keyboard)',
        (tester) async {
      final (root, main) = await openToolInput(tester, '禁漫漫画ID');
      final initialRoute = main.latest;
      if (keyboard) {
        await tester.testTextInput.receiveAction(TextInputAction.done);
      } else {
        await tester.tap(find.text('提交'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('输入的ID不是数字'), findsOneWidget);
      expect(root.popped, isEmpty);
      expect(main.latest, same(initialRoute));
      expect(tester.takeException(), isNull);
    });

    for (final isJm in [false, true]) {
      testWidgets(
          'tool submits to the main navigator (JM: $isJm, keyboard: $keyboard)',
          (tester) async {
        final (root, main) =
            await openToolInput(tester, isJm ? '禁漫漫画ID' : '打开链接');
        await tester.enterText(find.byType(TextField),
            isJm ? '123' : 'hitomi.la/galleries/123.html');
        if (keyboard) {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        } else {
          await tester.tap(find.text(isJm ? '提交' : '打开'));
        }
        final route = main.latest! as AppPageRoute;
        final page = route.builder(App.mainNavigatorKey!.currentContext!);
        if (isJm) {
          expect(page, isA<JmComicPage>());
          expect((page as JmComicPage).id, '123');
        } else {
          expect(page, isA<HitomiComicPage>());
          expect((page as HitomiComicPage).link,
              'https://hitomi.la/galleries/123.html');
        }
        expect(root.popped.whereType<DialogRoute>(), hasLength(1));
        expect(root.popped.whereType<ModalBottomSheetRoute>(), hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final isJm in [false, true]) {
    testWidgets('tool input ignores a removed host sheet (JM: $isJm)',
        (tester) async {
      final (root, main) =
          await openToolInput(tester, isJm ? '禁漫漫画ID' : '打开链接');
      final value = isJm ? '123' : 'https://hitomi.la/galleries/123.html';
      await tester.enterText(find.byType(TextField), value);
      final submit =
          tester.widget<TextField>(find.byType(TextField)).onSubmitted!;
      App.navigatorKey.currentState!
          .removeRoute(root.pushed.whereType<ModalBottomSheetRoute>().single);
      submit(value);
      await tester.idle();

      expect(main.pushed, hasLength(1));
      expect(root.popped.whereType<MaterialPageRoute>(), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets('tool submission preserves a newer root route (JM: $isJm)',
        (tester) async {
      final (root, main) =
          await openToolInput(tester, isJm ? '禁漫漫画ID' : '打开链接');
      final value = isJm ? '123' : 'https://hitomi.la/galleries/123.html';
      await tester.enterText(find.byType(TextField), value);
      tester.widget<TextField>(find.byType(TextField)).onSubmitted!(value);
      final newerRoute = DialogRoute<void>(
        context: App.globalContext!,
        builder: (_) => const AlertDialog(content: Text('New dialog')),
      );
      App.navigatorKey.currentState!.push<void>(newerRoute);
      await tester.idle();

      expect(newerRoute.isActive, isTrue);
      expect(root.popped, isNot(contains(newerRoute)));
      expect(main.latest, isA<AppPageRoute>());
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing tool input keeps the tools open (JM: $isJm)',
        (tester) async {
      final (root, main) =
          await openToolInput(tester, isJm ? '禁漫漫画ID' : '打开链接');
      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('禁漫漫画ID'), findsOneWidget);
      expect(root.popped.whereType<DialogRoute>(), hasLength(1));
      expect(root.popped.whereType<ModalBottomSheetRoute>(), isEmpty);
      expect(main.pushed, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('duplicate tool submissions navigate only once (JM: $isJm)',
        (tester) async {
      final (root, main) =
          await openToolInput(tester, isJm ? '禁漫漫画ID' : '打开链接');
      final value = isJm ? '123' : 'https://hitomi.la/galleries/123.html';
      await tester.enterText(find.byType(TextField), value);
      final submit =
          tester.widget<TextField>(find.byType(TextField)).onSubmitted!;
      submit(value);
      submit(value);
      await tester.idle();

      expect(root.popped, hasLength(2));
      expect(main.pushed, hasLength(2));
      expect(main.latest, isA<AppPageRoute>());
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
