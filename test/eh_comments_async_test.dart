import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart' hide Comment;
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/picacg_network/models.dart' hide Comment;
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/ehentai/eh_comments_page.dart';
import 'package:pica_comic/pages/jm/week_recommendation_page.dart';
import 'package:pica_comic/pages/picacg/collections_page.dart';

Res<List<Comment>> _commentResponse(String id) =>
    Res([Comment(id, 'user', 'content', 'time', 0, null)]);

ComicItemBrief _collectionComic(String id) =>
    ComicItemBrief('title', 'author', 0, 'cover', id, const []);

Res<List<List<ComicItemBrief>>> _collectionResponse(String id) => Res([
      [_collectionComic(id)],
      const <ComicItemBrief>[]
    ]);

JmComicBrief _jmComic(String id) => JmComicBrief(id, 'author', 'name', '', []);

void main() {
  test('EH comment loading coalesces duplicate requests', () async {
    final response = Completer<Res<List<Comment>>>();
    var calls = 0;
    final logic = CommentsPageLogic(loader: (_) {
      calls++;
      return response.future;
    });

    final first = logic.get('url');
    final duplicate = logic.get('url');
    expect(calls, 1);

    response.complete(_commentResponse('first'));
    await Future.wait([first, duplicate]);

    expect(logic.isLoading, isFalse);
    expect(logic.comments.single.id, 'first');
    logic.dispose();
  });

  test('stale EH comment response cannot overwrite a retry', () async {
    final stale = Completer<Res<List<Comment>>>();
    final fresh = Completer<Res<List<Comment>>>();
    var calls = 0;
    final logic = CommentsPageLogic(loader: (_) {
      calls++;
      return calls == 1 ? stale.future : fresh.future;
    });

    final first = logic.get('url');
    logic.retry();
    final retry = logic.get('url');
    fresh.complete(_commentResponse('fresh'));
    await retry;
    stale.complete(_commentResponse('stale'));
    await first;

    expect(calls, 2);
    expect(logic.comments.single.id, 'fresh');
    logic.dispose();
  });

  test('disposed EH comment response is ignored', () async {
    final response = Completer<Res<List<Comment>>>();
    final logic = CommentsPageLogic(loader: (_) => response.future);

    final request = logic.get('url');
    logic.dispose();
    response.complete(_commentResponse('late'));
    await request;

    expect(logic.isDisposed, isTrue);
    expect(logic.comments, isEmpty);
  });

  test('collection loading coalesces duplicate requests', () async {
    final response = Completer<Res<List<List<ComicItemBrief>>>>();
    var calls = 0;
    final logic = CollectionPageLogic(loader: () {
      calls++;
      return response.future;
    });

    final first = logic.get();
    final duplicate = logic.get();
    expect(calls, 1);

    response.complete(_collectionResponse('first'));
    await Future.wait([first, duplicate]);

    expect(logic.isLoading, isFalse);
    expect(logic.status, isTrue);
    expect(logic.c1.single.id, 'first');
    logic.dispose();
  });

  test('stale collection response cannot overwrite a retry', () async {
    final stale = Completer<Res<List<List<ComicItemBrief>>>>();
    final fresh = Completer<Res<List<List<ComicItemBrief>>>>();
    var calls = 0;
    final logic = CollectionPageLogic(loader: () {
      calls++;
      return calls == 1 ? stale.future : fresh.future;
    });

    final first = logic.get();
    logic.retry();
    final retry = logic.get();
    fresh.complete(_collectionResponse('fresh'));
    await retry;
    stale.complete(_collectionResponse('stale'));
    await first;

    expect(calls, 2);
    expect(logic.c1.single.id, 'fresh');
    logic.dispose();
  });

  test('disposed collection response is ignored', () async {
    final response = Completer<Res<List<List<ComicItemBrief>>>>();
    final logic = CollectionPageLogic(loader: () => response.future);

    final request = logic.get();
    logic.dispose();
    response.complete(_collectionResponse('late'));
    await request;

    expect(logic.isDisposed, isTrue);
    expect(logic.c1, isEmpty);
  });

  test('recommendation loading coalesces duplicate requests', () async {
    final response = Completer<Res<Map<String, String>>>();
    var calls = 0;
    final logic = JWRPLogic(loader: () {
      calls++;
      return response.future;
    });

    final first = logic.get();
    final duplicate = logic.get();
    expect(calls, 1);

    response.complete(const Res({'id': '本周'}));
    await Future.wait([first, duplicate]);

    expect(logic.currentId, 'id');
    expect(logic.currentName, '本周');
    expect(logic.loading, isFalse);
    logic.dispose();
  });

  test('stale recommendation response cannot overwrite a retry', () async {
    final stale = Completer<Res<Map<String, String>>>();
    final fresh = Completer<Res<Map<String, String>>>();
    var calls = 0;
    final logic = JWRPLogic(loader: () {
      calls++;
      return calls == 1 ? stale.future : fresh.future;
    });

    final first = logic.get();
    logic.change();
    final retry = logic.get();
    fresh.complete(const Res({'fresh': '新'}));
    await retry;
    stale.complete(const Res({'stale': '旧'}));
    await first;

    expect(logic.currentId, 'fresh');
    expect(logic.currentName, '新');
    expect(calls, 2);
    logic.dispose();
  });

  test(
      'category loading coalesces per index and disposed responses are ignored',
      () async {
    final response = Completer<Res<List<JmComicBrief>>>();
    var calls = 0;
    final logic = WRLLogic(loader: (id, type) {
      calls++;
      expect(id, 'week');
      expect(type, WeekRecommendationType.korean);
      return response.future;
    });

    final first = logic.get(0, 'week');
    final duplicate = logic.get(0, 'week');
    expect(calls, 1);
    logic.dispose();
    response.complete(Res([_jmComic('late')]));
    await Future.wait([first, duplicate]);

    expect(logic.isDisposed, isTrue);
    expect(logic.comics[0], isEmpty);
  });
}
