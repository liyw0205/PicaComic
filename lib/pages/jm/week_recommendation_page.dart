import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';

typedef JmWeekRecommendationLoader = Future<Res<Map<String, String>>>
    Function();
typedef JmWeekRecommendationComicsLoader = Future<Res<List<JmComicBrief>>>
    Function(String id, WeekRecommendationType type);

class JWRPLogic extends StateController {
  JWRPLogic({JmWeekRecommendationLoader? loader})
      : _loader = loader ?? (() => jmNetwork.getWeekRecommendation());

  final JmWeekRecommendationLoader _loader;

  bool loading = true;
  Map<String, String>? rec;
  String? message;
  String currentName = "";
  String currentId = "";
  bool _requestInFlight = false;
  int _generation = 0;

  void change() {
    if (isDisposed) return;
    _generation++;
    _requestInFlight = false;
    loading = true;
    rec = null;
    message = null;
    currentName = "";
    currentId = "";
    update();
  }

  Future<void> get() async {
    if (isDisposed || _requestInFlight) return;
    final requestGeneration = _generation;
    _requestInFlight = true;
    rec = null;
    message = null;
    try {
      final res = await _loader();
      if (isDisposed || requestGeneration != _generation) return;
      if (res.error) {
        message = res.errorMessage;
      } else if (res.data.isEmpty) {
        message = "暂无可用分类".tl;
      } else {
        rec = res.data;
        currentName = rec!.values.first;
        currentId = rec!.keys.first;
      }
      loading = false;
      update();
    } catch (error) {
      if (isDisposed || requestGeneration != _generation) return;
      message = error.toString();
      loading = false;
      update();
    } finally {
      if (requestGeneration == _generation) {
        _requestInFlight = false;
      }
    }
  }
}

class JmWeekRecommendationPage extends StatelessWidget {
  JmWeekRecommendationPage({Key? key}) : super(key: key);
  final logic = StateController.put(JWRPLogic());

  @override
  Widget build(BuildContext context) {
    var key = GlobalKey();
    const titleLength = 190;
    return Scaffold(
      appBar: Appbar(
        title: Text("每周必看".tl),
        actions: [
          StateBuilder<JWRPLogic>(
            builder: (logic) => Container(
              key: key,
              margin: const EdgeInsets.all(5),
              padding: const EdgeInsets.all(5),
              width: MediaQuery.of(context).size.width > 250 + titleLength
                  ? 250
                  : MediaQuery.of(context).size.width - titleLength,
              height: 40,
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.all(Radius.circular(16))),
              child: Row(
                children: [
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child: Text(
                      logic.currentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_drop_down_sharp),
                    iconSize: 16,
                    onPressed: () {
                      if (logic.rec == null) return;
                      var renderObject =
                          key.currentContext!.findRenderObject() as RenderBox;
                      var offset = renderObject.localToGlobal(Offset.zero);
                      offset = Offset(offset.dx + 246, offset.dy + 53);
                      showMenu(
                          constraints: BoxConstraints(
                              maxHeight: 300,
                              minWidth: (MediaQuery.of(context).size.width > 250
                                      ? 250
                                      : MediaQuery.of(context).size.width) -
                                  16),
                          context: context,
                          position: RelativeRect.fromLTRB(
                              offset.dx,
                              offset.dy,
                              MediaQuery.of(context).size.width - offset.dx,
                              MediaQuery.of(context).size.height - offset.dy),
                          items: [
                            for (var item in logic.rec!.entries)
                              PopupMenuItem(
                                child: Text(item.value),
                                onTap: () {
                                  logic.currentId = item.key;
                                  logic.currentName = item.value;
                                  logic.update();
                                },
                              )
                          ]);
                    },
                  ),
                ],
              ),
            ),
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StateBuilder<JWRPLogic>(
              builder: (logic) {
                if (logic.loading) {
                  unawaited(logic.get());
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                } else if (logic.message != null) {
                  return NetworkError(
                    message: logic.message!,
                    retry: () {
                      logic.change();
                      unawaited(logic.get());
                    },
                  );
                } else {
                  return WeekRecommendationList(
                    logic.currentId,
                    key: Key(logic.currentId),
                  );
                }
              },
            ),
          )
        ],
      ),
    );
  }
}

class WRLLogic extends StateController {
  WRLLogic({JmWeekRecommendationComicsLoader? loader})
      : _loader = loader ??
            ((id, type) => jmNetwork.getWeekRecommendationComics(id, type));

  final JmWeekRecommendationComicsLoader _loader;

  var comics = <List<JmComicBrief>>[[], [], []];
  var messages = <String?>[null, null, null];
  var loading = <bool>[true, true, true];
  final _requestInFlight = <bool>[false, false, false];
  final _generation = <int>[0, 0, 0];

  Future<void> get(int index, String id) async {
    if (isDisposed || index < 0 || index >= loading.length) return;
    if (_requestInFlight[index]) return;
    final requestGeneration = _generation[index];
    _requestInFlight[index] = true;
    try {
      final res = await _loader(id, WeekRecommendationType.values[index]);
      if (isDisposed || requestGeneration != _generation[index]) return;
      if (res.error) {
        messages[index] = res.errorMessage;
      } else {
        comics[index] = res.data;
      }
      loading[index] = false;
      update();
    } catch (error) {
      if (isDisposed || requestGeneration != _generation[index]) return;
      messages[index] = error.toString();
      loading[index] = false;
      update();
    } finally {
      if (requestGeneration == _generation[index]) {
        _requestInFlight[index] = false;
      }
    }
  }

  void retry(int index, String id) {
    if (isDisposed || index < 0 || index >= loading.length) return;
    _generation[index]++;
    _requestInFlight[index] = false;
    loading[index] = true;
    messages[index] = null;
    comics[index] = [];
    update();
    unawaited(get(index, id));
  }
}

class WeekRecommendationList extends StatelessWidget {
  const WeekRecommendationList(this.id, {Key? key}) : super(key: key);
  final String id;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
        length: 3,
        child: Column(
          children: [
            TabBar(tabs: [
              Tab(
                text: "韩漫".tl,
              ),
              Tab(
                text: "日漫".tl,
              ),
              Tab(
                text: "其它".tl,
              )
            ]),
            Expanded(
                child: StateBuilder<WRLLogic>(
                    init: WRLLogic(),
                    tag: id,
                    builder: (logic) {
                      return TabBarView(children: [
                        for (int i = 0; i <= 2; i++)
                          buildPage(i, logic, context)
                      ]);
                    }))
          ],
        ));
  }

  Widget buildPage(int index, WRLLogic logic, BuildContext context) {
    if (logic.loading[index]) {
      unawaited(logic.get(index, id));
      return const Center(
        child: CircularProgressIndicator(),
      );
    } else if (logic.comics[index].isEmpty) {
      return NetworkError(
        message: logic.messages[index] ?? "未知错误".tl,
        retry: () => logic.retry(index, id),
      );
    } else {
      return CustomScrollView(
        slivers: [
          SliverGridComics(comics: logic.comics[index], sourceKey: "jm"),
        ],
      );
    }
  }
}
