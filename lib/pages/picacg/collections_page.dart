import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';

typedef PicacgCollectionsLoader = Future<Res<List<List<ComicItemBrief>>>>
    Function();

class CollectionPageLogic extends StateController {
  CollectionPageLogic({PicacgCollectionsLoader? loader})
      : _loader = loader ?? (() => network.getCollection());

  final PicacgCollectionsLoader _loader;

  bool isLoading = true;
  var c1 = <ComicItemBrief>[];
  var c2 = <ComicItemBrief>[];
  bool status = true;
  String? message;
  bool _requestInFlight = false;
  int _generation = 0;

  void retry() {
    if (isDisposed) return;
    _generation++;
    _requestInFlight = false;
    isLoading = true;
    status = true;
    message = null;
    c1 = [];
    c2 = [];
    update();
  }

  Future<void> get() async {
    if (isDisposed || _requestInFlight) return;
    final requestGeneration = _generation;
    _requestInFlight = true;
    try {
      final collections = await _loader();
      if (isDisposed || requestGeneration != _generation) return;
      if (!collections.success) {
        status = false;
        message = collections.errorMessageWithoutNull;
      } else if (collections.data.length < 2) {
        status = false;
        message = "推荐数据格式错误".tl;
      } else {
        c1 = collections.data[0];
        c2 = collections.data[1];
        status = true;
        message = null;
      }
      isLoading = false;
      update();
    } catch (error) {
      if (isDisposed || requestGeneration != _generation) return;
      status = false;
      message = safeNetworkError(error);
      isLoading = false;
      update();
    } finally {
      if (requestGeneration == _generation) {
        _requestInFlight = false;
      }
    }
  }
}

class CollectionsPage extends StatelessWidget {
  const CollectionsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("推荐".tl),
      ),
      body: StateBuilder<CollectionPageLogic>(
        init: CollectionPageLogic(),
        builder: (logic) {
          if (logic.isLoading) {
            unawaited(logic.get());
            return const Center(
              child: CircularProgressIndicator(),
            );
          } else if (logic.status) {
            return CustomScrollView(
              slivers: [
                SliverGridComics(
                  comics: logic.c1 + logic.c2,
                  sourceKey: 'picacg',
                ),
                SliverPadding(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(App.globalContext!).padding.bottom,
                  ),
                )
              ],
            );
          } else {
            return NetworkError(
              message: logic.message ?? "网络错误".tl,
              retry: () {
                logic.retry();
              },
            );
          }
        },
      ),
    );
  }
}
