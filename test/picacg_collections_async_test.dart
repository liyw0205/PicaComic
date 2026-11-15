import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/picacg/collections_page.dart';

ComicItemBrief _comic(String id) =>
    ComicItemBrief('title', 'author', 0, 'cover', id, const []);

Res<List<List<ComicItemBrief>>> _response(String id) => Res([
      [_comic(id)],
      const <ComicItemBrief>[]
    ]);

void main() {
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

    response.complete(_response('first'));
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
    fresh.complete(_response('fresh'));
    await retry;
    stale.complete(_response('stale'));
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
    response.complete(_response('late'));
    await request;

    expect(logic.isDisposed, isTrue);
    expect(logic.c1, isEmpty);
  });
}
