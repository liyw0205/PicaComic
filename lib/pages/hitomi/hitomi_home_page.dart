import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/translations.dart';
import '../../foundation/app.dart';
import '../../network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/components/components.dart';

class HitomiHomePageLogic extends StateController {
  HitomiHomePageLogic({
    Future<Res<ComicList>> Function(String)? loadComics,
    Future<Res<bool>> Function(ComicList)? loadNextPage,
    Future<Res<HitomiComicBrief>> Function(String)? loadComicInfoBrief,
  })  : _loadComics = loadComics ?? ((url) => HiNetwork().getComics(url)),
        _loadNextPage =
            loadNextPage ?? ((comics) => HiNetwork().loadNextPage(comics)),
        _loadComicInfoBrief =
            loadComicInfoBrief ?? ((id) => HiNetwork().getComicInfoBrief(id));

  final Future<Res<ComicList>> Function(String) _loadComics;
  final Future<Res<bool>> Function(ComicList) _loadNextPage;
  final Future<Res<HitomiComicBrief>> Function(String) _loadComicInfoBrief;

  bool loading = true;
  String? message;
  int currentPage = 1;
  ComicList? comics;
  List<HitomiComicBrief> hitomiComics = [];
  bool _requestInFlight = false;
  bool _nextPageInFlight = false;
  int _generation = 0;

  bool _isCurrent(int generation) => !isDisposed && generation == _generation;

  Future<void> get(String url) async {
    if (isDisposed || _requestInFlight) return;
    final generation = ++_generation;
    _requestInFlight = true;
    try {
      final res = await _loadComics(url);
      if (!_isCurrent(generation)) return;
      if (res.error) {
        message = res.errorMessage;
      } else {
        final parseRes = await parseIds(res.data, generation: generation);
        if (!_isCurrent(generation)) return;
        if (parseRes) {
          comics = res.data;
        }
      }
      loading = false;
      update();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      message = safeNetworkError(error);
      loading = false;
      update();
    } finally {
      if (generation == _generation) {
        _requestInFlight = false;
      }
    }
  }

  Future<void> loadNextPage(String url) async {
    final current = comics;
    if (isDisposed ||
        _requestInFlight ||
        _nextPageInFlight ||
        current == null ||
        current.toLoad >= current.total) {
      return;
    }
    final generation = _generation;
    _nextPageInFlight = true;
    try {
      final res = await _loadNextPage(current);
      if (!_isCurrent(generation) || !identical(comics, current)) return;
      if (res.error) {
        showToast(message: res.errorMessage ?? "Error");
      } else {
        final parseRes = await parseIds(current, generation: generation);
        if (!_isCurrent(generation) || !identical(comics, current)) return;
        if (parseRes) {
          update();
        } else {
          showToast(message: message ?? "Error");
        }
      }
    } catch (error) {
      if (_isCurrent(generation) && identical(comics, current)) {
        showToast(message: safeNetworkError(error));
      }
    } finally {
      if (generation == _generation) {
        _nextPageInFlight = false;
      }
    }
  }

  Future<bool> parseIds(ComicList comics, {int? generation}) async {
    var futures = <Future<Res<HitomiComicBrief>>>[];
    var parsed = <HitomiComicBrief>[];

    Future<bool> wait() async {
      var result = await Future.wait(futures);
      futures.clear();
      for (var r in result) {
        if (r.error) {
          message = r.errorMessage;
          return false;
        }
        parsed.add(r.data);
      }
      return true;
    }

    Future<void> discardPending() async {
      final pending = futures;
      futures = <Future<Res<HitomiComicBrief>>>[];
      try {
        await Future.wait(pending);
      } catch (_) {
        // A stale request must still observe every started future so a late
        // network failure cannot become an unhandled error.
      }
    }

    for (var id in comics.comicIds) {
      if (generation != null && !_isCurrent(generation)) {
        await discardPending();
        return false;
      }
      if (futures.length >= 5) {
        var res = await wait();
        if (!res) return false;
      }
      futures.add(_loadComicInfoBrief(id.toString()));
    }
    var res = await wait();
    if (!res || (generation != null && !_isCurrent(generation))) return false;
    hitomiComics.addAll(parsed);
    comics.comicIds.clear();
    return true;
  }

  void refresh_() {
    _generation++;
    _requestInFlight = false;
    _nextPageInFlight = false;
    loading = true;
    comics = null;
    hitomiComics.clear();
    message = null;
    currentPage = 1;
    update();
  }
}

class HitomiHomePageComics extends StatelessWidget {
  const HitomiHomePageComics(this.url, {Key? key}) : super(key: key);
  final String url;

  static void Function() refresh = () {};

  @override
  Widget build(BuildContext context) {
    return StateBuilder<HitomiHomePageLogic>(
        tag: url,
        init: HitomiHomePageLogic(),
        builder: (logic) {
          refresh = logic.refresh_;
          if (logic.loading) {
            unawaited(logic.get(url));
            return const Center(
              child: CircularProgressIndicator(),
            );
          } else if (logic.message != null) {
            return NetworkError(
              message: logic.message!,
              retry: () => logic.refresh_(),
              withAppbar: false,
            );
          } else {
            return CustomScrollView(
              slivers: [
                SliverGridComics(
                  comics: logic.hitomiComics,
                  sourceKey: "hitomi",
                  onLastItemBuild: () {
                    unawaited(logic.loadNextPage(url));
                  },
                ),
                if (logic.comics!.toLoad < logic.comics!.total)
                  const SliverToBoxAdapter(
                    child: ListLoadingIndicator(),
                  )
              ],
            );
          }
        });
  }
}

class HitomiHomePage extends StatefulWidget {
  const HitomiHomePage({super.key});

  @override
  State<HitomiHomePage> createState() => _HitomiHomePageState();
}

class _HitomiHomePageState extends State<HitomiHomePage> {
  var type = "index";
  var lang = "-all";

  @override
  Widget build(BuildContext context) {
    var url = "https://ltn.${HiNetwork().baseDomain}/$type$lang.nozomi";
    return Column(
      children: [
        Material(
          textStyle: Theme.of(context).textTheme.headlineMedium,
          child: SizedBox(
            height: 50,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(
                  width: 16,
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text("hitomi"),
                ),
                const Spacer(),
                Material(
                  child: Select(
                    values: [
                      "最新".tl,
                      "热门 | 今天".tl,
                      "热门 | 一周".tl,
                      "热门 | 本月".tl,
                      "热门 | 一年".tl
                    ],
                    initialValue: 0,
                    onChange: (i) => setState(() {
                      type = [
                        "index",
                        "popular/today",
                        "popular/week",
                        "popular/month",
                        "popular/year"
                      ][i];
                    }),
                  ),
                ),
                const SizedBox(
                  width: 16,
                ),
                Material(
                  child: Select(
                    width: 100,
                    values: const ["All", "中文", "日本語", "English"],
                    initialValue: 0,
                    onChange: (i) => setState(() {
                      lang = ["-all", "-chinese", "-japanese", "-english"][i];
                    }),
                  ),
                ),
                const SizedBox(
                  width: 16,
                ),
              ],
            ),
          ),
        ),
        const Divider(),
        Expanded(
          child: HitomiHomePageComics(
            url,
            key: Key(url),
          ),
        )
      ],
    );
  }
}
