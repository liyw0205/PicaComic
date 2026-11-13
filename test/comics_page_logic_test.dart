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

    logic.loadNextPage(load);
    await Future<void>.delayed(Duration.zero);
    expect(logic.paginationError, 'temporary failure');
    expect(logic.current, 1);

    logic.loadNextPage(load);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    logic.retryNextPage(load);
    await Future<void>.delayed(Duration.zero);
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

    logic.loadNextPage(load);
    await Future<void>.delayed(Duration.zero);
    expect(logic.paginationError, contains('temporary exception'));
    expect(logic.loadingData, isFalse);
    expect(logic.current, 1);

    logic.retryNextPage(load);
    await Future<void>.delayed(Duration.zero);
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

    logic.loadNextPage((page) {
      expect(page, 11);
      return stalePage.future;
    });
    await Future<void>.delayed(Duration.zero);

    logic.refresh();
    expect(logic.current, 1);
    expect(logic.maxPage, isNull);
    expect(logic.dividedComics, isNull);

    logic.get((page) async {
      expect(page, 1);
      return const Res([1], subData: 4);
    });
    await Future<void>.delayed(Duration.zero);
    stalePage.complete(const Res([99], subData: 20));
    await Future<void>.delayed(Duration.zero);

    expect(logic.comics, [1]);
    expect(logic.dividedComics, {
      1: [1]
    });
    expect(logic.current, 1);
    expect(logic.maxPage, 4);
    expect(logic.loadingData, isFalse);
  });
}
