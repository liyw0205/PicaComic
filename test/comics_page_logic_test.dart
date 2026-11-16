import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';

void main() {
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
}
