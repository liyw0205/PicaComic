import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _CommentRequest {
  _CommentRequest(this.page, this.replyTo);

  final int page;
  final String? replyTo;
  final response = Completer<Res<List<Comment>>>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late List<ComicSource> previousSources;
  late List<_CommentRequest> requests;
  late List<String> sent;
  late Future<Res<bool>> Function() send;

  setUp(() {
    previousSources = ComicSource.sources;
    requests = [];
    sent = [];
    send = () async => const Res(true);
  });

  tearDown(() {
    hideAllMessages();
    ComicSource.sources = previousSources;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    ComicSource.sources = [
      ComicSource.named(
        name: 'Comments fixture',
        key: 'comments-fixture',
        filePath: 'fixture.js',
        commentsLoader: (id, subId, page, replyTo) {
          expect(id, 'comic');
          expect(subId, 'chapter');
          final request = _CommentRequest(page, replyTo);
          requests.add(request);
          return request.response.future;
        },
        sendCommentFunc: (id, subId, content, replyTo) {
          expect(id, 'comic');
          expect(subId, 'chapter');
          expect(replyTo, isNull);
          sent.add(content);
          return send();
        },
      ),
    ];
    late BaseComicPage<ComicInfoData> page;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => OverlayWidget(child!),
      home: Scaffold(body: Builder(builder: (context) {
        page = const ComicPage(sourceKey: 'comments-fixture', id: 'comic')
            .build(context) as BaseComicPage<ComicInfoData>;
        return TextButton(
          onPressed: () => page.openComments!(),
          child: const Text('Open comments'),
        );
      })),
    ));
    final logic = StateController.put(
      ComicPageLogic<ComicInfoData>()
        ..data = const ComicInfoData('Comic', '', '', '', {}, null, null, null,
            1, null, 'comments-fixture', 'comic',
            subId: 'chapter'),
      tag: page.tag,
    );
    addTearDown(() async {
      hideAllMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      logic.controller.dispose();
      StateController.remove<ComicPageLogic<ComicInfoData>>(page.tag);
    });
    await tester.tap(find.text('Open comments'));
    await pump(tester);
    expect(requests.single.page, 1);
  }

  Future<void> resolve(WidgetTester tester, _CommentRequest request,
      String content, int maxPage) async {
    request.response.complete(Res(
      [Comment('User', null, content, null, null, content)],
      subData: maxPage,
    ));
    await pump(tester);
  }

  Future<void> submit(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byIcon(Icons.send));
    await pump(tester);
  }

  Future<_CommentRequest> reloadDuringPagination(WidgetTester tester) async {
    await open(tester);
    await resolve(tester, requests.single, 'Old first page', 3);
    expect(requests.last.page, 2);
    final oldPage = requests.last;
    await submit(tester, 'Posted comment');
    expect(sent, ['Posted comment']);
    expect(requests.last.page, 1);
    return oldPage;
  }

  for (final immutable in [false, true]) {
    testWidgets('pagination owns the first page list (immutable: $immutable)',
        (tester) async {
      await open(tester);
      final firstPage = immutable
          ? const [Comment('User', null, 'First page', null, null, 'first')]
          : [const Comment('User', null, 'First page', null, null, 'first')];
      requests.single.response.complete(Res(firstPage, subData: 2));
      await pump(tester);
      expect(requests.last.page, 2);
      await resolve(tester, requests.last, 'Second page', 2);

      expect(find.text('First page'), findsOneWidget);
      expect(find.text('Second page'), findsOneWidget);
      expect(find.byType(ListLoadingIndicator), findsNothing);
      expect(firstPage, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final throwsError in [false, true]) {
    testWidgets('pagination failure offers an explicit retry ($throwsError)',
        (tester) async {
      await open(tester);
      await resolve(tester, requests.single, 'First page', 3);
      final failedPage = requests.last;
      expect(failedPage.page, 2);
      if (throwsError) {
        failedPage.response.completeError(StateError('Page failed'));
      } else {
        failedPage.response.complete(const Res.error('Page failed'));
      }
      await pump(tester);

      expect(find.text('First page'), findsOneWidget);
      expect(find.byType(ListLoadingIndicator), findsNothing);
      final retry = find.widgetWithIcon(TextButton, Icons.refresh);
      expect(retry, findsOneWidget);
      expect(find.text(throwsError ? 'StateError' : 'Page failed'),
          findsOneWidget);
      tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
      await pump(tester);
      expect(requests, hasLength(2));

      final onPressed = tester.widget<TextButton>(retry).onPressed!;
      onPressed();
      onPressed();
      await pump(tester);
      expect(requests, hasLength(3));
      expect(requests.last.page, 2);
      expect(retry, findsNothing);
      expect(find.byType(ListLoadingIndicator), findsOneWidget);

      await resolve(tester, requests.last, 'Retried second page', 3);
      expect(requests, hasLength(4));
      expect(requests.last.page, 3);
      await resolve(tester, requests.last, 'Third page', 3);
      expect(find.text('First page'), findsOneWidget);
      expect(find.text('Retried second page'), findsOneWidget);
      expect(find.text('Third page'), findsOneWidget);
      expect(find.byType(ListLoadingIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a failed pagination retry can be retried again', (tester) async {
    await open(tester);
    await resolve(tester, requests.single, 'First page', 2);
    requests.last.response.complete(const Res.error('Page failed'));
    await pump(tester);
    await tester.tap(find.widgetWithIcon(TextButton, Icons.refresh));
    await pump(tester);
    expect(requests.last.page, 2);
    requests.last.response.complete(const Res.error('Retry failed'));
    await pump(tester);

    expect(find.text('Retry failed'), findsOneWidget);
    expect(find.byType(ListLoadingIndicator), findsNothing);
    await tester.tap(find.widgetWithIcon(TextButton, Icons.refresh));
    await pump(tester);
    expect(requests.last.page, 2);
    await resolve(tester, requests.last, 'Second page', 2);
    expect(requests, hasLength(4));
    expect(find.text('Second page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending after a pagination error starts a fresh list',
      (tester) async {
    await open(tester);
    await resolve(tester, requests.single, 'First page', 3);
    requests.last.response.complete(const Res.error('Page failed'));
    await pump(tester);
    expect(find.widgetWithIcon(TextButton, Icons.refresh), findsOneWidget);
    await submit(tester, 'Posted comment');
    expect(requests.last.page, 1);
    await resolve(tester, requests.last, 'Fresh first page', 2);
    expect(requests.last.page, 2);
    await resolve(tester, requests.last, 'Fresh second page', 2);

    expect(requests, hasLength(4));
    expect(find.text('First page'), findsNothing);
    expect(find.text('Fresh first page'), findsOneWidget);
    expect(find.text('Fresh second page'), findsOneWidget);
    expect(find.widgetWithIcon(TextButton, Icons.refresh), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending a comment discards a late page from the previous list',
      (tester) async {
    final oldPage = await reloadDuringPagination(tester);
    await resolve(tester, requests.last, 'Fresh first page', 1);
    await resolve(tester, oldPage, 'Stale second page', 3);

    expect(find.text('Fresh first page'), findsOneWidget);
    expect(find.text('Stale second page'), findsNothing);
    expect(requests, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  for (final throwsError in [false, true]) {
    testWidgets('a stale pagination error stays silent (throws: $throwsError)',
        (tester) async {
      final oldPage = await reloadDuringPagination(tester);
      await resolve(tester, requests.last, 'Fresh first page', 1);
      if (throwsError) {
        oldPage.response.completeError(StateError('Stale pagination failed'));
      } else {
        oldPage.response.complete(const Res.error('Stale pagination failed'));
      }
      await pump(tester);

      expect(find.text('Fresh first page'), findsOneWidget);
      expect(find.text(throwsError ? 'StateError' : 'Stale pagination failed'),
          findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2));
    });
  }

  testWidgets('the refreshed list can paginate while an old page is pending',
      (tester) async {
    final oldPage = await reloadDuringPagination(tester);
    await resolve(tester, requests.last, 'Fresh first page', 2);
    expect(requests, hasLength(4));
    final newPage = requests.last;
    expect(newPage.page, 2);
    await resolve(tester, oldPage, 'Stale second page', 3);
    await resolve(tester, newPage, 'Fresh second page', 2);

    expect(find.text('Fresh first page'), findsOneWidget);
    expect(find.text('Fresh second page'), findsOneWidget);
    expect(find.text('Stale second page'), findsNothing);
    expect(requests, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated submit before the next frame sends only once',
      (tester) async {
    final sentResponse = Completer<Res<bool>>();
    send = () => sentResponse.future;
    await open(tester);
    await resolve(tester, requests.single, 'First page', 1);
    await tester.enterText(find.byType(TextField), 'Posted comment');
    final onPressed = tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
        .onPressed!;
    onPressed();
    onPressed();
    expect(sent, ['Posted comment']);

    sentResponse.complete(const Res(true));
    await pump(tester);
    await resolve(tester, requests.last, 'Fresh first page', 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('whitespace does not submit an empty comment', (tester) async {
    await open(tester);
    await resolve(tester, requests.single, 'First page', 1);
    await submit(tester, ' \n ');

    expect(sent, isEmpty);
    expect(requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending preserves a new draft typed while awaiting the response',
      (tester) async {
    final sentResponse = Completer<Res<bool>>();
    send = () => sentResponse.future;
    await open(tester);
    await resolve(tester, requests.single, 'First page', 1);
    await submit(tester, 'Posted comment');
    await tester.enterText(find.byType(TextField), 'Next draft');
    sentResponse.complete(const Res(true));
    await pump(tester);
    await resolve(tester, requests.last, 'Fresh first page', 1);

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Next draft');
    expect(sent, ['Posted comment']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the comments panel disposes its draft controller',
      (tester) async {
    await open(tester);
    await resolve(tester, requests.single, 'First page', 1);
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    App.navigatorKey.currentState!.pop();
    await pump(tester);

    expect(() => controller.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  for (final throwsError in [false, true]) {
    testWidgets(
        'send failure preserves the list and allows retry ($throwsError)',
        (tester) async {
      send = () async {
        if (sent.length > 1) return const Res(true);
        if (throwsError) throw StateError('Send failed');
        return const Res.error('Send failed');
      };
      await open(tester);
      await resolve(tester, requests.single, 'First page', 1);
      await submit(tester, 'Posted comment');

      expect(find.text('First page'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Posted comment');
      expect(requests, hasLength(1));
      expect(find.byIcon(Icons.send), findsOneWidget);

      await tester.tap(find.byIcon(Icons.send));
      await pump(tester);
      await resolve(tester, requests.last, 'Fresh first page', 1);
      expect(sent, ['Posted comment', 'Posted comment']);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(find.text('Fresh first page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2));
    });
  }

  testWidgets('initial load failure can be retried', (tester) async {
    await open(tester);
    requests.single.response.complete(const Res.error('Initial load failed'));
    await pump(tester);
    expect(find.text('Initial load failed'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await pump(tester);
    expect(requests, hasLength(2));
    expect(requests.last.page, 1);
    await resolve(tester, requests.last, 'Retried first page', 1);

    expect(find.text('Retried first page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial loading ignores a response after the panel closes',
      (tester) async {
    await open(tester);
    App.navigatorKey.currentState!.pop();
    await pump(tester);
    await resolve(tester, requests.single, 'Late first page', 3);

    expect(find.text('Late first page'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late send does not reload a closed panel', (tester) async {
    final sentResponse = Completer<Res<bool>>();
    send = () => sentResponse.future;
    await open(tester);
    await resolve(tester, requests.single, 'First page', 1);
    await submit(tester, 'Posted comment');
    App.navigatorKey.currentState!.pop();
    await pump(tester);
    sentResponse.complete(const Res(true));
    await pump(tester);

    expect(find.byType(TextField), findsNothing);
    expect(requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
