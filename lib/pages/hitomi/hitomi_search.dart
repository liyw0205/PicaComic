import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/foundation/ui_mode.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/hitomi_network/search_sort.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shimmer_animation/shimmer_animation.dart';

import '../../network/res.dart';

class HitomiSearchResults extends StatefulWidget {
  const HitomiSearchResults({
    super.key,
    required this.keyword,
    required this.sort,
    required this.header,
    this.loadResults,
  });

  final String keyword;
  final HitomiSearchSort sort;
  final Widget header;
  final Future<Res<List<int>>> Function(String, HitomiSearchSort)? loadResults;

  @override
  State<HitomiSearchResults> createState() => _HitomiSearchResultsState();
}

class _HitomiSearchResultsState
    extends LoadingState<HitomiSearchResults, List<int>> {
  @override
  Widget buildFrame(BuildContext context, Widget child) {
    return SafeArea(
      top: UiMode.m1(context),
      bottom: false,
      child: SmoothCustomScrollView(slivers: [widget.header, child]),
    );
  }

  @override
  Widget buildLoading() => SliverFillRemaining(
      hasScrollBody: false, child: super.buildLoading());

  @override
  Widget buildError() => SliverFillRemaining(
      hasScrollBody: false, child: super.buildError());

  @override
  Widget buildContent(BuildContext context, List<int> data) {
    if (data.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: Text('没有找到漫画'.tl)),
      );
    }
    return SliverGrid(
      delegate: SliverChildBuilderDelegate(
        (context, index) => HitomiComicTileDynamicLoading(data[index],
            key: ValueKey(data[index])),
        childCount: data.length,
      ),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }

  @override
  Future<Res<List<int>>> loadData() =>
      widget.loadResults?.call(widget.keyword, widget.sort) ??
      HiNetwork().search(widget.keyword, sort: widget.sort);
}

class HitomiComicTileDynamicLoading extends StatefulWidget {
  const HitomiComicTileDynamicLoading(this.id,
      {Key? key, this.addonMenuOptions})
      : super(key: key);
  final int id;

  final List<ComicTileMenuOption>? addonMenuOptions;

  @override
  State<HitomiComicTileDynamicLoading> createState() =>
      _HitomiComicTileDynamicLoadingState();
}

class _HitomiComicTileDynamicLoadingState
    extends State<HitomiComicTileDynamicLoading> {
  HitomiComicBrief? comic;
  String? _error;
  bool _loading = false;
  int _requestGeneration = 0;

  static List<HitomiComicBrief> cache = [];

  @override
  void initState() {
    super.initState();
    _loadComic();
  }

  @override
  void didUpdateWidget(covariant HitomiComicTileDynamicLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id == widget.id) return;
    _requestGeneration++;
    comic = null;
    _loadComic();
  }

  @override
  void dispose() {
    _requestGeneration++;
    super.dispose();
  }

  HitomiComicBrief? _cachedComic() {
    for (var cachedComic in cache) {
      var id = RegExp(r"\d+(?=\.html)").firstMatch(cachedComic.link)![0]!;
      if (id == widget.id.toString()) {
        return cachedComic;
      }
    }
    return null;
  }

  void _loadComic() {
    final cached = _cachedComic();
    if (cached != null) {
      comic = cached;
      _error = null;
      _loading = false;
      return;
    }
    if (_loading) return;
    _loading = true;
    _error = null;
    final generation = ++_requestGeneration;
    final id = widget.id.toString();
    unawaited(() async {
      try {
        final result = await HiNetwork().getComicInfoBrief(id);
        if (!mounted ||
            generation != _requestGeneration ||
            id != widget.id.toString()) {
          return;
        }
        if (result.error) {
          if (mounted && generation == _requestGeneration) {
            setState(() {
              _error = result.errorMessage ?? "Network Error";
            });
          }
          return;
        }
        final existing = _cachedComic();
        if (existing == null) {
          cache.add(result.data);
        }
        setState(() {
          comic = existing ?? result.data;
        });
      } catch (error, stack) {
        if (mounted && generation == _requestGeneration) {
          setState(() {
            _error = safeNetworkError(error);
          });
          LogManager.addLog(
            LogLevel.error,
            "Network",
            "Failed to load Hitomi comic brief: "
                "${safeNetworkError(error)}\n$stack",
          );
        }
      } finally {
        if (generation == _requestGeneration) {
          _loading = false;
        }
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    if (comic == null) {
      if (_error != null) {
        return Center(
          child: IconButton(
            tooltip: "重试".tl,
            icon: const Icon(Icons.refresh),
            onPressed: _loadComic,
          ),
        );
      }
      return buildLoadingWidget();
    } else {
      return buildComicTile(context, comic!, 'hitomi');
    }
  }

  Widget buildPlaceHolder() {
    return const ComicTilePlaceholder();
  }

  Widget buildLoadingWidget() {
    return Shimmer(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: buildPlaceHolder(),
    );
  }
}
