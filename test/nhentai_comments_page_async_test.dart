import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/nhentai_network/models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/nhentai/comments.dart';

NhentaiComment _comment(String id) =>
    NhentaiComment('user-$id', '', 'comment-$id', 0);

void main() {
  test('initial loading coalesces duplicate requests', () async {
    final response = Completer<Res<List<NhentaiComment>>>();
    var calls = 0;
    final logic = NhentaiCommentsPageLogic(
      'comic',
      loader: (id) {
        calls++;
        expect(id, 'comic');
        return response.future;
      },
    );

    final first = logic.get();
    final duplicate = logic.get();
    expect(calls, 1);

    response.complete(Res([_comment('first')]));
    await Future.wait([first, duplicate]);

    expect(logic.comments!.map((comment) => comment.userName), ['user-first']);
    expect(logic.loading, isFalse);
    logic.dispose();
  });

  test('retry invalidates a stale response', () async {
    final stale = Completer<Res<List<NhentaiComment>>>();
    final fresh = Completer<Res<List<NhentaiComment>>>();
    var calls = 0;
    final logic = NhentaiCommentsPageLogic(
      'comic',
      loader: (_) {
        calls++;
        return calls == 1 ? stale.future : fresh.future;
      },
    );

    final first = logic.get();
    logic.retry();
    final retried = logic.get();
    fresh.complete(Res([_comment('fresh')]));
    await retried;
    stale.complete(Res([_comment('stale')]));
    await first;

    expect(logic.comments!.map((comment) => comment.userName), ['user-fresh']);
    expect(logic.message, isNull);
    expect(logic.loading, isFalse);
    expect(calls, 2);
    logic.dispose();
  });

  test('disposed logic ignores an in-flight response', () async {
    final response = Completer<Res<List<NhentaiComment>>>();
    final logic = NhentaiCommentsPageLogic(
      'comic',
      loader: (_) => response.future,
    );

    final load = logic.get();
    logic.dispose();
    response.complete(Res([_comment('late')]));
    await load;

    expect(logic.isDisposed, isTrue);
    expect(logic.comments, isNull);
  });

  test('loader exceptions become retryable page errors', () async {
    final logic = NhentaiCommentsPageLogic(
      'comic',
      loader: (_) => Future<Res<List<NhentaiComment>>>.error(
        StateError('fixture failure'),
      ),
    );

    await logic.get();

    expect(logic.loading, isFalse);
    expect(logic.comments, isNull);
    expect(logic.message, contains('fixture failure'));
    logic.dispose();
  });
}
