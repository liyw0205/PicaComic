import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_image.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/log.dart';
import '../base.dart';
import '../foundation/app.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({Key? key}) : super(key: key);

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
    _scrollController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _confirmRemoval([History? history]) {
    final manager = HistoryManager();
    return showDialog<void>(
      context: context,
      builder: (_) => _HistoryRemovalDialog(
        clearAll: history == null,
        onRemove: () async {
          if (history == null) {
            await manager.clearHistory();
          } else {
            await manager.remove(history.target);
          }
          if (mounted) setState(_reload);
        },
      ),
    );
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
                  onPressed: () => unawaited(_confirmRemoval()),
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
          onLongTap: () => unawaited(_confirmRemoval(history)),
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

class _HistoryRemovalDialog extends StatefulWidget {
  const _HistoryRemovalDialog({required this.clearAll, required this.onRemove});

  final bool clearAll;
  final Future<void> Function() onRemove;

  @override
  State<_HistoryRemovalDialog> createState() => _HistoryRemovalDialogState();
}

class _HistoryRemovalDialogState extends State<_HistoryRemovalDialog> {
  bool _removing = false;
  bool _failed = false;

  Future<void> _remove() async {
    if (_removing) return;
    setState(() {
      _removing = true;
      _failed = false;
    });
    try {
      await widget.onRemove();
      if (!mounted) return;
      final route = ModalRoute.of(context)!;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else if (route.isActive) {
        navigator.removeRoute(route);
      }
    } catch (error, stack) {
      Log.error('History',
          'Failed to delete history: ${safeNetworkError(error)}\n$stack');
      if (!mounted) return;
      setState(() {
        _removing = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_removing,
      child: AlertDialog(
        title: Text(widget.clearAll ? "清除记录".tl : "删除".tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.clearAll ? "要清除历史记录吗?".tl : "要删除这条历史记录吗".tl),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text("操作失败".tl,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _removing ? null : () => Navigator.of(context).pop(),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: _removing ? null : () => unawaited(_remove()),
            child: _removing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.clearAll ? "清除".tl : "删除".tl),
          ),
        ],
      ),
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
