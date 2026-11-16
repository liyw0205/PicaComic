import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_image.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/foundation/history.dart';
import '../base.dart';
import '../foundation/app.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({Key? key, this.tileBuilder}) : super(key: key);

  final Widget Function(BuildContext context, History history)? tileBuilder;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  static const _pageSize = 60;
  final comics = <History>[];
  final _scrollController = ScrollController();
  final _searchFocus = FocusNode();
  bool _hasMore = true;
  int _totalCount = 0;
  bool searchMode = false;
  String keyword = "";
  bool isModified = false;
  bool _loadingPage = false;
  Timer? _searchDebounce;

  void _cancelSearchDebounce() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
  }

  @override
  void initState() {
    super.initState();
    _reload();
    _scrollController.addListener(_onScroll);
  }

  void _reload() {
    _cancelSearchDebounce();
    comics.clear();
    _hasMore = true;
    _loadingPage = false;
    if (!searchMode) _totalCount = HistoryManager().count();
    _loadPage();
  }

  void _loadPage() {
    final page = HistoryManager().getPage(
      limit: _pageSize,
      after: comics.isEmpty ? null : comics.last,
      keyword: searchMode ? keyword : '',
    );
    comics.addAll(page);
    _hasMore = page.length == _pageSize;
  }

  void _onScroll() {
    if (!mounted || _searchDebounce != null || !_hasMore || _loadingPage) {
      return;
    }
    if (_scrollController.position.extentAfter >= 800) return;
    _loadingPage = true;
    setState(_loadPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadingPage = false;
    });
  }

  @override
  void dispose() {
    _cancelSearchDebounce();
    if (isModified) {
      unawaited(appdata.history.saveData());
    }
    _scrollController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Widget buildTitle() {
    if (searchMode) {
      return TextField(
        focusNode: _searchFocus,
        decoration:
            InputDecoration(border: InputBorder.none, hintText: "搜索".tl),
        onChanged: (s) {
          keyword = s.toLowerCase();
          _cancelSearchDebounce();
          _searchDebounce = Timer(const Duration(milliseconds: 180), () {
            _searchDebounce = null;
            if (mounted) setState(_reload);
          });
        },
      );
    } else {
      return Text("${"历史记录".tl}($_totalCount)");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppbar(
            title: buildTitle(),
            actions: [
              Tooltip(
                message: "清除".tl,
                child: IconButton(
                  icon: const Icon(Icons.delete_forever),
                  onPressed: () => showDialog(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                            title: Text("清除记录".tl),
                            content: Text("要清除历史记录吗?".tl),
                            actions: [
                              TextButton(
                                  onPressed: () => App.globalBack(),
                                  child: Text("取消".tl)),
                              TextButton(
                                  onPressed: () {
                                    appdata.history.clearHistory();
                                    _cancelSearchDebounce();
                                    setState(_reload);
                                    isModified = true;
                                    App.globalBack();
                                  },
                                  child: Text("清除".tl)),
                            ],
                          )),
                ),
              ),
              Tooltip(
                message: "搜索".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      _cancelSearchDebounce();
                      searchMode = !searchMode;
                      if (!searchMode) {
                        keyword = "";
                      }
                      _reload();
                    });
                    if (searchMode) _searchFocus.requestFocus();
                  },
                ),
              )
            ],
          ),
          buildComics(comics),
          SliverPadding(
            padding:
                EdgeInsets.only(top: MediaQuery.of(context).padding.bottom),
          )
        ],
      ),
    );
  }

  Widget buildComics(List<History> comics_) {
    return SliverGrid(
      delegate:
          SliverChildBuilderDelegate(childCount: comics_.length, (context, i) {
        final history = comics_[i];
        final tileBuilder = widget.tileBuilder;
        if (tileBuilder != null) return tileBuilder(context, history);
        final comic = ComicItemBrief(
          history.title,
          history.subtitle,
          0,
          history.cover != "" ? history.cover : getJmCoverUrl(history.target),
          history.target,
          [],
        );
        return NormalComicTile(
          key: Key(history.target),
          sourceKey: history.type.comicSource?.key,
          onLongTap: () {
            showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text("删除".tl),
                    content: Text("要删除这条历史记录吗".tl),
                    actions: [
                      TextButton(
                          onPressed: () => App.globalBack(),
                          child: Text("取消".tl)),
                      TextButton(
                          onPressed: () {
                            appdata.history.remove(history.target);
                            setState(() {
                              isModified = true;
                              _reload();
                            });
                            App.globalBack();
                          },
                          child: Text("删除".tl)),
                    ],
                  );
                });
          },
          description_: timeToString(history.time),
          coverPath: comic.path,
          name: comic.title,
          subTitle_: comic.author,
          badgeName: history.type.name,
          headers: {
            if (history.type == HistoryType.ehentai)
              "cookie": EhNetwork().cookiesStr,
            if (history.type == HistoryType.ehentai ||
                history.type == HistoryType.hitomi)
              "User-Agent": webUA,
            if (history.type == HistoryType.hitomi)
              "Referer": "https://hitomi.la/"
          },
          onTap: () {
            toComicPageWithHistory(context, history);
          },
        );
      }),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }
}

void toComicPageWithHistory(BuildContext context, History history) {
  var source = history.type.comicSource;
  if (source == null) {
    showToast(message: "Comic Source Not Found");
    return;
  }
  context.to(
    () => ComicPage(
      sourceKey: source.key,
      id: history.target,
      cover: history.cover,
    ),
  );
}
