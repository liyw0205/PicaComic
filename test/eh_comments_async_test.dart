import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/ehentai/eh_comments_page.dart';

Res<List<Comment>> _response(String id) =>
    Res([Comment(id, 'user', 'content', 'time', 0, null)]);

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

    response.complete(_response('first'));
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
    fresh.complete(_response('fresh'));
    await retry;
    stale.complete(_response('stale'));
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
    response.complete(_response('late'));
    await request;

    expect(logic.isDisposed, isTrue);
    expect(logic.comments, isEmpty);
  });
}
