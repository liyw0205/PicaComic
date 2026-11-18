import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/subscription_pager.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/ehentai/subscription.dart';
import 'package:pica_comic/tools/translations.dart';

EhGalleryBrief _subscriptionComic(String id) =>
    EhGalleryBrief(id, 'Manga', 'time', 'user', '', 3, id, []);

Res<Galleries> _subscriptionPage(String id, {String? next}) => Res(Galleries()
  ..galleries = [_subscriptionComic(id)]
  ..next = next);

class _UnusedCookieJar implements SingleInstanceCookieJar {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WatchedNetwork extends EhNetwork {
  _WatchedNetwork(this.html) : super.create();

  final String html;
  final requests = <String>[];

  @override
  Future<String> getCookies(bool setNW, [String? url]) async => '';

  @override
  Future<Res<String>> request(String url,
      {Map<String, String>? headers,
      CacheExpiredTime expiredTime = CacheExpiredTime.short,
      bool setNW = true,
      CancelToken? cancelToken}) async {
    requests.add(url);
    return Res(Uri.parse(url).hasQuery
        ? '<html><table class="itg gltm"><tbody></tbody></table></html>'
        : html);
  }
}

class _ReaderNetwork extends EhNetwork {
  _ReaderNetwork(this.pages) : super.create();

  final Map<int, String> pages;
  final requests = <String>[];

  @override
  Future<String> getCookies(bool setNW, [String? url]) async => '';

  @override
  Future<Res<String>> request(String url,
      {Map<String, String>? headers,
      CacheExpiredTime expiredTime = CacheExpiredTime.short,
      bool setNW = true,
      CancelToken? cancelToken}) async {
    requests.add(url);
    final query = Uri.parse(url).queryParameters;
    final page = int.tryParse(query['p'] ?? '') ?? 0;
    final html = pages[page];
    if (html == null) return const Res.error('Missing reader fixture');
    return Res(html);
  }
}

String _readerPageLinks(Iterable<String> links) => '''
  <html><div id="gdt">${links.map((link) => '<a href="$link"><div></div></a>').join()}</div></html>
''';

String _readerPage(Iterable<int> imagePages) => _readerPageLinks(
    imagePages.map((page) => 'https://e-hentai.org/s/key/123-$page'));

const _listingImage =
    '<img src="data:image/gif;base64,AAAA" data-src="https://img.invalid/cover.jpg">';
const _listingLink = 'https://e-hentai.org/g/123/token/';
const _watchedFixtures = {
  'thumbnail': '''<div class="gl1t"><a href="$_listingLink">Title</a>
    $_listingImage<div class="gl5t"><div><div class="cs">Manga</div>
    <div>2026-11-17 01:00</div><div>12 pages</div>
    <div class="ir" style="background-position:0px -1px"></div></div></div></div>''',
  'minimal': '''<table class="itg gltm"><tbody><tr>
    <td class="gl1m"><div class="cs">Manga</div></td>
    <td class="gl2m"><div>2026-11-17 01:00</div><div><div>$_listingImage</div></div></td>
    <td class="gl3m"><a href="$_listingLink"><div class="glink">Title</div></a></td>
    <td class="gl4m"><div class="ir" style="background-position:0px -1px"></div></td>
    <td class="gl5m"><div><a>User</a></div></td>
    </tr></tbody></table>''',
  'compact': '''<table class="itg gltc"><tbody><tr><td><div>Manga</div></td>
    <td><div></div><div><div>$_listingImage</div></div>
    <div><div>2026-11-17 01:00</div><div class="ir" style="background-position:0px -1px"></div></div></td>
    <td><a href="$_listingLink"><div>Title</div><div><div title="female:glasses"></div></div></a></td>
    <td><div><a>User</a></div><div>12 pages</div></td></tr></tbody></table>''',
  'extended': '''<table class="itg glte"><tbody><tr>
    <td class="gl1e"><div><a href="$_listingLink">$_listingImage</a></div></td>
    <td class="gl2e"><div><a><div><div class="glink">Title</div></div></a>
    <div class="gl3e"><div class="cn">Manga</div><div>2026-11-17 01:00</div>
    <div>12 pages</div><div><a>User</a></div>
    <div class="ir" style="background-position:0px -1px"></div></div></div></td></tr></tbody></table>''',
};

const _galleryFixture = '''<html><h1 id="gn">Title</h1>
  <h1 id="gj">Original title</h1><div class="cs">Manga</div>
  <div id="gleft"><div id="gd1"><div
    style="background:url(https://img.invalid/cover.jpg)"></div></div></div>
  <div id="gdn"><a>User</a></div><div id="gdd"><table><tbody>
    <tr><td class="gdt2">2026-11-17 01:00</td></tr>
    <tr><td class="gdt2">12 pages</td></tr></tbody></table></div>
  <div id="rating_image" style="background-position:0px -1px"></div>
  <div id="rating_label">Average: 5</div>
  <a id="favoritelink"> Add to Favorites</a>
  <script>var gid=123; var token="fixture";</script></html>''';

void main() {
  AppTranslation.translations = const {};

  test('comic detail retries transient failures and keeps the final result',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-detail-retry-');
    final previousHistory = HistoryManager.cache;
    final history = HistoryManager.create();
    HistoryManager.cache = history;
    await history.init(
        databasePath: '${root.path}/history.db', importLegacy: false);
    addTearDown(() async {
      history.close();
      HistoryManager.cache = previousHistory;
      await root.delete(recursive: true);
    });
    final logic = ComicPageLogic<int>();
    var attempts = 0;
    var favoriteCalls = 0;

    await logic.get(
      () async {
        attempts++;
        if (attempts < 3) return const Res.error('temporary failure');
        return const Res(42);
      },
      (value) async {
        favoriteCalls++;
        return value.isEven;
      },
      () => 'fixture',
      retryAttempts: 3,
      retryDelay: Duration.zero,
    );

    expect(attempts, 3);
    expect(logic.data, 42);
    expect(logic.message, isNull);
    expect(favoriteCalls, 1);
    logic.dispose();
  });

  test('refresh cancels a pending detail retry', () async {
    final retryStarted = Completer<void>();
    final retryRelease = Completer<Res<int>>();
    final logic = ComicPageLogic<int>();
    var attempts = 0;

    final request = logic.get(
      () async {
        attempts++;
        if (attempts == 1) return const Res.error('temporary failure');
        if (!retryStarted.isCompleted) retryStarted.complete();
        return retryRelease.future;
      },
      (_) async => false,
      () => 'fixture',
      retryAttempts: 3,
      retryDelay: Duration.zero,
    );
    await retryStarted.future;
    logic.refresh_();
    retryRelease.complete(const Res(99));
    await request;

    expect(attempts, 2);
    expect(logic.data, isNull);
    expect(logic.loading, isTrue);
    expect(logic.message, isNull);
    logic.dispose();
  });

  test('a failed continuous page waits for an explicit retry', () async {
    final logic = ComicsPageLogic<int>()
      ..comics = [1]
      ..current = 1
      ..maxPage = 3;
    var calls = 0;

    Future<Res<List<int>>> load(int page) async {
      calls++;
      expect(page, 2);
      return const Res.error('temporary failure');
    }

    await logic.loadNextPage(load);
    expect(logic.paginationError, 'temporary failure');
    expect(logic.current, 1);

    await logic.loadNextPage(load);
    expect(calls, 1);

    await logic.retryNextPage(load);
    expect(calls, 2);
    expect(logic.current, 1);
  });

  test('a thrown page request can retry the same page', () async {
    final logic = ComicsPageLogic<int>()
      ..comics = [1]
      ..current = 1
      ..maxPage = 3;
    var calls = 0;

    Future<Res<List<int>>> load(int page) async {
      expect(page, 2);
      calls++;
      if (calls == 1) throw StateError('temporary exception');
      return const Res([2], subData: 3);
    }

    await logic.loadNextPage(load);
    expect(logic.paginationError, contains('temporary exception'));
    expect(logic.loadingData, isFalse);
    expect(logic.current, 1);

    await logic.retryNextPage(load);
    expect(logic.comics, [1, 2]);
    expect(logic.current, 2);
    expect(logic.paginationError, isNull);
  });

  test('refresh resets pagination and ignores the previous generation',
      () async {
    final stalePage = Completer<Res<List<int>>>();
    final logic = ComicsPageLogic<int>()
      ..comics = [10]
      ..dividedComics = {
        10: [10]
      }
      ..current = 10
      ..maxPage = 20;

    final staleLoad = logic.loadNextPage((page) {
      expect(page, 11);
      return stalePage.future;
    });

    logic.refresh();
    expect(logic.current, 1);
    expect(logic.maxPage, isNull);
    expect(logic.dividedComics, isNull);

    await logic.get((page) async {
      expect(page, 1);
      return const Res([1], subData: 4);
    });
    stalePage.complete(const Res([99], subData: 20));
    await staleLoad;

    expect(logic.comics, [1]);
    expect(logic.dividedComics, {
      1: [1]
    });
    expect(logic.current, 1);
    expect(logic.maxPage, 4);
    expect(logic.loadingData, isFalse);
  });

  test('dispose invalidates an in-flight page response', () async {
    final response = Completer<Res<List<int>>>();
    final logic = ComicsPageLogic<int>()
      ..comics = [1]
      ..current = 1
      ..maxPage = 3;

    final request = logic.loadNextPage((page) {
      expect(page, 2);
      return response.future;
    });

    logic.dispose();
    response.complete(const Res([2], subData: 3));
    await request;

    expect(logic.comics, [1]);
    expect(logic.current, 1);
    expect(logic.loadingData, isFalse);
  });

  test('EH subscriptions refresh the cursor and copy display buffers',
      () async {
    var firstRequests = 0;
    final calls = <String>[];
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (url) async {
        calls.add(url);
        if (!Uri.parse(url).hasQuery) {
          return _subscriptionPage('first-${++firstRequests}',
              next: '/watched?next=2');
        }
        return _subscriptionPage('second');
      },
    );
    final logic = ComicsPageLogic<EhGalleryBrief>();
    await logic.get(pager.load);
    await logic.loadNextPage(pager.load);
    expect(logic.comics!.map((comic) => comic.id), ['first-1', 'second']);
    // Appending page two to the display must not alter page one's cached list.
    logic.current = 1;
    await logic.get(pager.load);
    expect(logic.dividedComics![1]!.map((comic) => comic.id), ['first-2']);
    logic.refresh();
    await logic.get(pager.load);
    expect(logic.comics!.single.id, 'first-3');
    expect(calls, [
      'https://e-hentai.org/watched',
      'https://e-hentai.org/watched?next=2',
      'https://e-hentai.org/watched',
      'https://e-hentai.org/watched',
    ]);
    logic.dispose();
  });

  test('EH subscription failures and exceptions retry the same cursor',
      () async {
    final calls = <String>[];
    var attempts = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (url) async {
        calls.add(url);
        if (!Uri.parse(url).hasQuery) {
          return _subscriptionPage('first', next: '?next=2');
        }
        attempts++;
        if (attempts == 1) return const Res.error('temporary failure');
        if (attempts == 2) throw StateError('temporary exception');
        return _subscriptionPage('second');
      },
    );
    final logic = ComicsPageLogic<EhGalleryBrief>();
    await logic.get(pager.load);
    await logic.loadNextPage(pager.load);
    expect(logic.current, 1);
    expect(logic.paginationError, 'temporary failure');
    await logic.retryNextPage(pager.load);
    expect(logic.current, 1);
    expect(logic.paginationError, contains('temporary exception'));
    await logic.retryNextPage(pager.load);
    expect(logic.current, 2);
    expect(logic.maxPage, 2);
    expect(logic.paginationError, isNull);
    expect(logic.comics!.map((comic) => comic.id), ['first', 'second']);
    expect(
        calls.skip(1), List.filled(3, 'https://e-hentai.org/watched?next=2'));
    await logic.loadNextPage(pager.load);
    expect(calls.length, 4);
    logic.dispose();
  });

  test('EH paged mode learns its final page and clamps an overshoot', () async {
    final calls = <String>[];
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (url) async {
        calls.add(url);
        return Uri.parse(url).hasQuery
            ? _subscriptionPage('second')
            : _subscriptionPage('first', next: '?next=2');
      },
    );
    final logic = ComicsPageLogic<EhGalleryBrief>();
    await logic.get(pager.load);
    expect(logic.maxPage, isNull);
    logic.current = 5;
    await logic.get(pager.load);
    expect(logic.maxPage, 2);
    expect(logic.current, 2);
    await logic.get(pager.load);
    expect(logic.dividedComics![2]!.single.id, 'second');
    expect(calls.length, 2);
    logic.dispose();
  });

  test('EH empty final page ends immediately without repeated requests',
      () async {
    var calls = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (_) async {
        calls++;
        return Res(Galleries());
      },
    );
    final result = await pager.load(1);
    expect(result.data, isEmpty);
    expect(result.subData, 1);
    expect((await pager.load(20)).data, isEmpty);
    expect(calls, 1);
  });

  test('EH initial failure and malformed next link do not advance the cursor',
      () async {
    var calls = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (_) async {
        calls++;
        if (calls == 1) return const Res.error('Not authenticated');
        if (calls == 2) return _subscriptionPage('invalid', next: 'http://[');
        return _subscriptionPage('valid');
      },
    );
    expect((await pager.load(1)).errorMessage, 'Not authenticated');
    await expectLater(pager.load(2), throwsFormatException);
    final retry = await pager.load(2);
    expect(retry.data, isEmpty);
    expect(retry.subData, 1);
    expect(calls, 3);
  });

  test('EH duplicate queued requests share the resolved page', () async {
    final second = Completer<Res<Galleries>>();
    var calls = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (_) {
        calls++;
        return calls == 1
            ? Future.value(_subscriptionPage('first', next: '?next=2'))
            : second.future;
      },
    );
    await pager.load(1);
    final first = pager.load(2);
    final duplicate = pager.load(2);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    second.complete(_subscriptionPage('second'));
    final results = await Future.wait([first, duplicate]);
    expect(
        results.map((result) => result.data.single.id), ['second', 'second']);
    results.first.data.clear();
    expect(results.last.data.single.id, 'second');
    expect((await pager.load(2)).data.single.id, 'second');
    expect(calls, 2);
  });

  test('EH refresh ignores a stale page and resets its pending request queue',
      () async {
    final late = Completer<Res<Galleries>>();
    var firstRequests = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (url) async {
        if (Uri.parse(url).hasQuery) return late.future;
        return _subscriptionPage('first-${++firstRequests}',
            next: '?next=$firstRequests');
      },
    );
    final logic = ComicsPageLogic<EhGalleryBrief>();
    await logic.get(pager.load);
    final stale = logic.loadNextPage(pager.load);
    await Future<void>.delayed(Duration.zero);
    logic.refresh();
    await logic.get(pager.load);
    late.complete(_subscriptionPage('stale'));
    await stale;
    expect(logic.comics!.single.id, 'first-2');
    expect(logic.current, 1);
    expect(logic.maxPage, isNull);
    expect(logic.paginationError, isNull);
    logic.dispose();
  });

  test('EH site change discards the old cursor and its late response',
      () async {
    var site = 'https://e-hentai.org';
    final late = Completer<Res<Galleries>>();
    final calls = <String>[];
    final pager = EhSubscriptionPager(
      baseUrl: () => site,
      loader: (url) async {
        calls.add(url);
        if (Uri.parse(url).hasQuery) return late.future;
        return _subscriptionPage(Uri.parse(url).host, next: '?next=2');
      },
    );
    await pager.load(1);
    final old = pager.load(2);
    await Future<void>.delayed(Duration.zero);
    site = 'https://exhentai.org';
    expect((await pager.load(3)).error, isTrue);
    expect(calls, hasLength(2));
    final fresh = await pager.load(1);
    expect(fresh.data.single.id, 'exhentai.org');
    late.complete(_subscriptionPage('old-site'));
    expect((await old).error, isTrue);
    expect(calls, [
      'https://e-hentai.org/watched',
      'https://e-hentai.org/watched?next=2',
      'https://exhentai.org/watched',
    ]);
  });

  test('EH cursor cycles stop without issuing the repeated request', () async {
    var calls = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (_) async {
        calls++;
        return _subscriptionPage('first', next: '/watched');
      },
    );
    await pager.load(1);
    expect((await pager.load(100)).error, isTrue);
    expect((await pager.load(2)).error, isTrue);
    expect(calls, 1);
    expect((await pager.load(0)).error, isTrue);
    expect(calls, 1);
  });

  test('EH watched fixtures parse four display modes and lazy covers',
      () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      for (final lazy in [true, false]) {
        for (final fixture in _watchedFixtures.entries) {
          final markup = lazy
              ? fixture.value
              : fixture.value.replaceAll(_listingImage,
                  '<img src="https://img.invalid/cover.jpg" data-src="unused">');
          final network = _WatchedNetwork('''<html>$markup
          <a id="dnext" href="/watched?next=123">Next</a></html>''');
          final pager = EhSubscriptionPager(
            loader: network.getGalleries,
            baseUrl: () => 'https://e-hentai.org',
          );
          final result = await pager.load(1);
          expect(result.success, isTrue, reason: fixture.key);
          expect(result.data, hasLength(1), reason: fixture.key);
          expect(result.data.single.title, 'Title', reason: fixture.key);
          expect(result.data.single.link, _listingLink, reason: fixture.key);
          expect(result.data.single.coverPath, 'https://img.invalid/cover.jpg',
              reason: fixture.key);
          final last = await pager.load(2);
          expect(last.data, isEmpty);
          expect(last.subData, 2);
          expect(network.requests, [
            'https://e-hentai.org/watched',
            'https://e-hentai.org/watched?next=123',
          ]);
        }
      }
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  test('EH rating CSS keeps all ten scores across formatting changes',
      () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      final network = _WatchedNetwork('');
      for (final x in [0, -16, -32, -48, -64]) {
        for (final y in [-1, -21]) {
          final expected = 5 + x / 16 - (y == -21 ? 0.5 : 0);
          for (final style in [
            'background-position:${x}px ${y}px',
            'background-position: ${x}px ${y}px;',
            'display:inline-block; background-position:\t${x}px\n${y}px; color:red',
            'BACKGROUND-POSITION: ${x}PX ${y}PX !important;',
            'background-position:/* rating */ ${x}px ${y}px',
          ]) {
            expect(network.getStarsFromPosition(style), expected,
                reason: style);
          }
        }
      }
      expect(network.getStarsFromPosition('background-position:0 -1px'), 5);
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  test('EH rating CSS handles missing data and valid declaration precedence',
      () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      final network = _WatchedNetwork('');
      for (final style in [
        '',
        ' ',
        'display:block',
        'background-position:',
        'background-position:garbage',
        'background-position:0px',
        'background-position:0px -1px -21px',
        'background-position:0% -1px',
        'background-position:0em -1px',
        'background-position:-80px -1px',
        'background-position:0px -2px',
      ]) {
        expect(network.getStarsFromPosition(style), 0.5, reason: style);
      }
      const five = 'background-position:0px -1px';
      const three = 'background-position:-32px -1px';
      expect(network.getStarsFromPosition('$five; $three'), 3);
      expect(network.getStarsFromPosition('$five !important; $three'), 5);
      expect(network.getStarsFromPosition('$five; $three !important'), 3);
      expect(
          network.getStarsFromPosition('$five !important; $three !important'),
          3);
      expect(network.getStarsFromPosition('$five; background-position:garbage'),
          5);
      expect(network.getStarsFromPosition('content:"$three"; $five'), 5);
      expect(network.getStarsFromPosition('/* $three; */ $five'), 5);
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  test('EH lists retain galleries when rating elements or styles are missing',
      () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      for (final fixture in _watchedFixtures.entries) {
        for (final style in [
          null,
          '',
          'missing-element',
          'broken',
          'display:block; background-position: -16px -21px;'
        ]) {
          final document = parse(fixture.value);
          final rating = document.querySelector('.ir')!;
          if (style == 'missing-element') {
            rating.remove();
          } else if (style == null) {
            rating.attributes.remove('style');
          } else {
            rating.attributes['style'] = style;
          }
          final network = _WatchedNetwork(document.outerHtml);
          final result =
              await network.getGalleries('https://e-hentai.org/watched');
          expect(result.success, isTrue, reason: '${fixture.key}: $style');
          expect(result.data.galleries, hasLength(1),
              reason: '${fixture.key}: $style');
          final gallery = result.data.galleries.single;
          expect(gallery.title, 'Title');
          expect(gallery.link, _listingLink);
          expect(gallery.coverPath, 'https://img.invalid/cover.jpg');
          expect(
              gallery.stars, style?.startsWith('display:') == true ? 3.5 : 0.5);
        }
      }
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  test('EH details remain readable without optional rating markup', () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      for (final style in [
        null,
        '',
        'missing-element',
        'display:block; background-position: -32px -21px;'
      ]) {
        final document = parse(_galleryFixture);
        final rating = document.getElementById('rating_image')!;
        if (style == 'missing-element') {
          rating.remove();
          document.getElementById('rating_label')!.remove();
        } else if (style == null) {
          rating.attributes.remove('style');
        } else {
          rating.attributes['style'] = style;
        }
        final network = _WatchedNetwork(document.outerHtml);
        final result = await network.getGalleryInfo(_listingLink);
        expect(result.success, isTrue, reason: result.errorMessage);
        expect(result.data.title, 'Title');
        expect(result.data.subTitle, 'Original title');
        expect(result.data.maxPage, '12');
        expect(result.data.coverPath, 'https://img.invalid/cover.jpg');
        expect(result.data.auth!['gid'], '123');
        expect(result.data.stars,
            style?.startsWith('display:') == true ? 2.5 : 0.5);
        expect(result.data.rating,
            style == 'missing-element' ? isNull : 'Average: 5');
      }
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  test('EH reader resolves images by gallery page number, not DOM order',
      () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      final network = _ReaderNetwork({
        0: _readerPage(List.generate(20, (index) => 20 - index)),
        1: _readerPage(List.generate(20, (index) => 40 - index)),
      });
      for (final page in [1, 3, 20, 21, 25, 40]) {
        final result = await network.getReaderLink(
            'https://e-hentai.org/g/123/token/', page);
        expect(result.success, isTrue, reason: 'page=$page');
        expect(result.data, 'https://e-hentai.org/s/key/123-$page');
      }
      expect(network.requests.toSet(), {
        'https://e-hentai.org/g/123/token/',
        'https://e-hentai.org/g/123/token/?p=1',
      });
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  test('EH reader preserves DOM order when page numbers are ambiguous',
      () async {
    final previousCookieJar = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = _UnusedCookieJar();
    try {
      final unknownFormat = _ReaderNetwork({
        0: _readerPageLinks([
          'https://e-hentai.org/s/key/123-3',
          'https://e-hentai.org/s/key/page-two',
          'https://e-hentai.org/s/key/123-1',
        ]),
      });
      final unknownResult = await unknownFormat.getReaderLink(
          'https://e-hentai.org/g/123/token/', 1);
      expect(unknownResult.data, 'https://e-hentai.org/s/key/123-3');

      final duplicatePages = _ReaderNetwork({
        0: _readerPageLinks([
          'https://e-hentai.org/s/key/123-3',
          'https://e-hentai.org/s/key/123-3',
          'https://e-hentai.org/s/key/123-1',
        ]),
      });
      final duplicateResult = await duplicatePages.getReaderLink(
          'https://e-hentai.org/g/123/token/', 1);
      expect(duplicateResult.data, 'https://e-hentai.org/s/key/123-3');
    } finally {
      SingleInstanceCookieJar.instance = previousCookieJar;
    }
  });

  testWidgets('EH toolbar refresh ignores responses after its page is removed',
      (tester) async {
    final settings = List<String>.from(appdata.settings);
    appdata.settings[25] = '0';
    addTearDown(() {
      appdata.settings = settings;
    });
    final pending = Completer<Res<Galleries>>();
    var calls = 0;
    final pager = EhSubscriptionPager(
      baseUrl: () => 'https://e-hentai.org',
      loader: (_) {
        calls++;
        return calls == 1 ? Future.value(Res(Galleries())) : pending.future;
      },
    );
    await tester.pumpWidget(MaterialApp(home: SubscriptionPage(pager: pager)));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    final fresh = EhSubscriptionPager(
        baseUrl: () => 'https://e-hentai.org',
        loader: (_) async => Res(Galleries()));
    await tester.pumpWidget(MaterialApp(home: SubscriptionPage(pager: fresh)));
    await tester.pumpAndSettle();
    pending.complete(const Res.error('Late failure'));
    await tester.pumpAndSettle();
    expect(find.text('Late failure'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
