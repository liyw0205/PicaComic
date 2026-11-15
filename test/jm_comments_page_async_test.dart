import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/jm/jm_comments_page.dart';

Comment _comment(String id) =>
    Comment(id, '', 'user-$id', '', 'comment-$id', []);

void main() {
  test('initial loading coalesces requests and forwards the mode', () async {
    final response = Completer<Res<List<Comment>>>();
    var calls = 0;
    String? requestedMode;
    final logic = JmCommentsPageLogic(
      0,
      loader: (id, page, mode) {
        calls++;
        expect(id, 'comic');
        expect(page, 1);
        requestedMode = mode;
        return response.future;
      },
    );

    final first = logic.get('comic', 'all');
    final duplicate = logic.get('comic', 'all');
    expect(calls, 1);

    response.complete(Res([_comment('first')], subData: 1));
    await Future.wait([first, duplicate]);

    expect(requestedMode, 'all');
    expect(logic.comments!.map((comment) => comment.id), ['first']);
    expect(logic.loading, isFalse);
    expect(logic.totalComments, 1);
    logic.dispose();
  });

  test('refresh invalidates a stale initial response', () async {
    final stale = Completer<Res<List<Comment>>>();
    final fresh = Completer<Res<List<Comment>>>();
    var calls = 0;
    final logic = JmCommentsPageLogic(
      1,
      loader: (id, page, mode) {
        calls++;
        return calls == 1 ? stale.future : fresh.future;
      },
    );

    final staleLoad = logic.get('comic');
    logic.refresh_();
    final freshLoad = logic.get('comic');
    fresh.complete(Res([_comment('fresh')], subData: 1));
    await freshLoad;
    stale.complete(Res([_comment('stale')], subData: 1));
    await staleLoad;

    expect(logic.comments!.map((comment) => comment.id), ['fresh']);
    expect(logic.loading, isFalse);
    expect(calls, 2);
    logic.dispose();
  });

  test('retry starts a new generation without accepting its stale response',
      () async {
    final failed = Completer<Res<List<Comment>>>();
    final retried = Completer<Res<List<Comment>>>();
    var calls = 0;
    final logic = JmCommentsPageLogic(
      1,
      loader: (id, page, mode) {
        calls++;
        return calls == 1 ? failed.future : retried.future;
      },
    );

    final firstLoad = logic.get('comic');
    logic.retry();
    final retryLoad = logic.get('comic');
    retried.complete(Res([_comment('retried')], subData: 1));
    await retryLoad;
    failed.complete(const Res.error('stale failure'));
    await firstLoad;

    expect(logic.comments!.map((comment) => comment.id), ['retried']);
    expect(logic.message, isNull);
    expect(logic.loading, isFalse);
    expect(calls, 2);
    logic.dispose();
  });

  test(
      'pagination coalesces requests and stale pages cannot repopulate after refresh',
      () async {
    final pageTwo = Completer<Res<List<Comment>>>();
    final refreshed = Completer<Res<List<Comment>>>();
    var calls = 0;
    final logic = JmCommentsPageLogic(
      2,
      loader: (id, page, mode) {
        calls++;
        if (page == 1 && calls == 1) {
          return Future.value(Res([_comment('one')]));
        }
        if (calls == 2) return pageTwo.future;
        return refreshed.future;
      },
    );

    await logic.get('comic');
    final firstPage = logic.loadMore('comic');
    final duplicatePage = logic.loadMore('comic');
    expect(calls, 2);

    logic.refresh_();
    final refreshedPage = logic.get('comic');
    refreshed.complete(Res([_comment('new-one')], subData: 1));
    await refreshedPage;
    pageTwo.complete(Res([_comment('stale-two')], subData: 2));
    await Future.wait([firstPage, duplicatePage]);

    expect(logic.comments!.map((comment) => comment.id), ['new-one']);
    expect(logic.page, 1);
    expect(logic.totalComments, 1);
    expect(calls, 3);
    logic.dispose();
  });

  test('disposed logic ignores an in-flight response and disposes its editor',
      () async {
    final response = Completer<Res<List<Comment>>>();
    final logic = JmCommentsPageLogic(
      1,
      loader: (id, page, mode) => response.future,
    );

    final load = logic.get('comic');
    logic.dispose();
    response.complete(Res([_comment('late')]));
    await load;

    expect(logic.isDisposed, isTrue);
    expect(logic.comments, isNull);
  });
}
