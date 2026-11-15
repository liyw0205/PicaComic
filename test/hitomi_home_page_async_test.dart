import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/hitomi/hitomi_home_page.dart';

HitomiComicBrief _brief(int id) => HitomiComicBrief(
      'Comic $id',
      'Type',
      'Language',
      [],
      'Time',
      'Artist',
      'https://hitomi.la/galleries/$id.html',
      'https://example.test/$id.webp',
    );

ComicList _list(Iterable<int> ids, {int total = 100}) {
  final comics = ComicList('fixture')..total = total;
  comics.comicIds.addAll(ids);
  return comics;
}

void main() {
  test('initial request is coalesced while loading', () async {
    final response = Completer<Res<ComicList>>();
    var calls = 0;
    final logic = HitomiHomePageLogic(
      loadComics: (_) {
        calls++;
        return response.future;
      },
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    final first = logic.get('fixture');
    final duplicate = logic.get('fixture');
    expect(calls, 1);

    response.complete(Res(_list([1], total: 1)));
    await Future.wait([first, duplicate]);

    expect(logic.loading, isFalse);
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/1.html',
    ]);
  });

  test('refresh ignores an older request and keeps only the fresh result',
      () async {
    final requests = <Completer<Res<ComicList>>>[];
    final logic = HitomiHomePageLogic(
      loadComics: (_) {
        final request = Completer<Res<ComicList>>();
        requests.add(request);
        return request.future;
      },
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    final stale = logic.get('fixture');
    logic.refresh_();
    final fresh = logic.get('fixture');
    expect(requests, hasLength(2));

    requests[0].complete(Res(_list([1], total: 1)));
    await stale;
    expect(logic.loading, isTrue);
    expect(logic.hitomiComics, isEmpty);

    requests[1].complete(Res(_list([2], total: 1)));
    await fresh;
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/2.html',
    ]);
  });

  test('pagination coalesces duplicate tail requests', () async {
    final list = _list([1], total: 2);
    list.toLoad = 1;
    final nextPage = Completer<Res<bool>>();
    var nextCalls = 0;
    final logic = HitomiHomePageLogic(
      loadComics: (_) async => Res(list),
      loadNextPage: (current) {
        nextCalls++;
        current.comicIds.add(2);
        current.toLoad = 2;
        return nextPage.future;
      },
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    await logic.get('fixture');
    final first = logic.loadNextPage('fixture');
    final duplicate = logic.loadNextPage('fixture');
    expect(nextCalls, 1);

    nextPage.complete(const Res(true));
    await Future.wait([first, duplicate]);
    expect(logic.hitomiComics.map((comic) => comic.id), [
      'https://hitomi.la/galleries/1.html',
      'https://hitomi.la/galleries/2.html',
    ]);

    await logic.loadNextPage('fixture');
    expect(nextCalls, 1);
  });

  test('disposed request cannot publish its result', () async {
    final response = Completer<Res<ComicList>>();
    final logic = HitomiHomePageLogic(
      loadComics: (_) => response.future,
      loadComicInfoBrief: (id) async => Res(_brief(int.parse(id))),
    );

    final request = logic.get('fixture');
    logic.dispose();
    response.complete(Res(_list([1], total: 1)));
    await request;

    expect(logic.loading, isTrue);
    expect(logic.hitomiComics, isEmpty);
  });
}
