import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/jm/week_recommendation_page.dart';

JmComicBrief _comic(String id) => JmComicBrief(id, 'author', 'name', '', []);

void main() {
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
    response.complete(Res([_comic('late')]));
    await Future.wait([first, duplicate]);

    expect(logic.isDisposed, isTrue);
    expect(logic.comics[0], isEmpty);
  });
}
