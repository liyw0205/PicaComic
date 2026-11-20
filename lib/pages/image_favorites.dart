import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/foundation/ui_mode.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';

import 'reader/comic_reading_page.dart';

class ImageFavoritesPage extends StatefulWidget {
  const ImageFavoritesPage({super.key, this.tileBuilder});

  /// Optional lightweight tile factory for callers that need to render the
  /// pagination surface without starting image decoding.
  final Widget Function(BuildContext context, ImageFavorite image)? tileBuilder;

  @override
  State<ImageFavoritesPage> createState() => _ImageFavoritesPageState();
}

class _ImageFavoritesPageState extends StateWithController<ImageFavoritesPage> {
  static const _pageSize = 60;

  final _images = <ImageFavorite>[];
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _searchDebounce;

  int? _nextCursor;
  int? _headRowId;
  int _totalCount = 0;
  String _keyword = '';
  bool _hasMore = true;
  bool _loading = false;
  bool _searchMode = false;

  @override
  Object? get tag => "image_favorites_page";

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _reload() {
    if (!HistoryManager().isOpen) return;
    _images.clear();
    _nextCursor = null;
    _headRowId = null;
    _hasMore = true;
    _totalCount = ImageFavoriteManager.count(keyword: _keyword);
    _loadPage();
  }

  void _loadPage() {
    if (_loading || !_hasMore || !HistoryManager().isOpen) return;
    _loading = true;
    final page = ImageFavoriteManager.getPage(
      limit: _pageSize,
      afterRowId: _nextCursor,
      keyword: _keyword,
    );
    _images.addAll(page.items);
    _headRowId ??= page.firstRowId;
    _nextCursor = page.nextCursor;
    _hasMore = page.hasMore;
    _loading = false;
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 800) {
      _loadPage();
    }
  }

  @override
  void refresh() {
    if (!mounted) return;
    _reconcileExternalChanges();
    super.refresh();
  }

  void _reconcileExternalChanges() {
    if (!HistoryManager().isOpen) return;
    // Walk every bounded batch newer than the loaded head. Reading only one
    // page here can permanently skip rows when a sync/import adds more than
    // [_pageSize] favorites before the next refresh. The inclusive watermark
    // also handles SQLite reusing a deleted highest rowid.
    final headRowId = _headRowId;
    final latestRowId = ImageFavoriteManager.latestRowId();
    if (headRowId != null && (latestRowId == null || latestRowId < headRowId)) {
      // A table whose newest row is below the watermark has reused rowids
      // after deleting the previous head. Rebuild the window in one pass so
      // stale image providers and scroll callbacks cannot observe a partial
      // state while the database is being replaced.
      _reload();
      return;
    }
    if (_headRowId == null) {
      // An empty page has no watermark yet. Populate it directly so an
      // external add can transition out of the empty state without requiring
      // the page to be recreated.
      final page = ImageFavoriteManager.getPage(
        limit: _pageSize,
        keyword: _keyword,
      );
      _images.addAll(page.items);
      _headRowId = page.firstRowId;
      _nextCursor = page.nextCursor;
      _hasMore = page.hasMore;
    } else {
      final known = _images.map((image) => image.key).toSet();
      int? cursor;
      while (true) {
        final page = ImageFavoriteManager.getPage(
          limit: _pageSize,
          afterRowId: cursor,
          newerThanOrEqualRowId: _headRowId,
          keyword: _keyword,
        );
        for (final image in page.items.reversed) {
          if (known.add(image.key)) {
            _images.insert(0, image);
          }
        }
        if (!page.hasMore) break;
        cursor = page.nextCursor;
        if (cursor == null) break;
      }
    }
    final existing = ImageFavoriteManager.existingKeys(_images);
    _images.removeWhere((image) => !existing.contains(image.key));
    _totalCount = ImageFavoriteManager.count(keyword: _keyword);
  }

  void _setKeyword(String value) {
    _keyword = value.trim();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) _reload();
    });
  }

  void _toggleSearch() {
    final enabled = !_searchMode;
    _searchDebounce?.cancel();
    setState(() {
      _searchMode = enabled;
      if (!enabled) {
        _searchController.clear();
        _keyword = '';
      }
    });
    _reload();
    if (enabled) {
      scheduleMicrotask(_searchFocus.requestFocus);
    }
  }

  Widget _buildTitle() {
    if (_searchMode) {
      return TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: "搜索".tl,
        ),
        onChanged: _setKeyword,
      );
    }
    return Text("${"图片收藏".tl}($_totalCount)");
  }

  List<Widget> _buildActions() => [
        Tooltip(
          message: "搜索".tl,
          child: IconButton(
            icon: Icon(_searchMode ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    if (UiMode.m1(context)) {
      return Scaffold(
        appBar: AppBar(
          title: _buildTitle(),
          actions: _buildActions(),
        ),
        body: buildPage(),
      );
    }
    return Material(
      child: Column(
        children: [
          Appbar(
            title: _buildTitle(),
            actions: _buildActions(),
          ),
          Expanded(
            child: buildPage(),
          )
        ],
      ),
    );
  }

  Widget buildPage() {
    if (_images.isEmpty && !_loading) {
      return Center(
        child: Text(_keyword.isEmpty ? "暂无图片收藏".tl : "没有匹配结果".tl),
      );
    }
    return GridView.builder(
      controller: _scrollController,
      cacheExtent: 800,
      gridDelegate: SliverGridDelegateWithComics(true, appdata.settings[74]),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        final image = _images[index];
        final tileBuilder = widget.tileBuilder;
        if (tileBuilder != null) return tileBuilder(context, image);
        return FavoriteImageTile(
          image,
          onDeleted: () {
            setState(() {
              _images.removeWhere((item) => item.key == image.key);
              _totalCount = ImageFavoriteManager.count(keyword: _keyword);
            });
          },
        );
      },
    );
  }
}

class FavoriteImageTile extends StatelessWidget {
  const FavoriteImageTile(this.image, {this.onDeleted, super.key});

  final ImageFavorite image;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: image.title.replaceAll("\n", ""),
      child: RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            elevation: 1,
            child: Stack(
              children: [
                Positioned.fill(
                    child: Container(
                        decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            borderRadius: BorderRadius.circular(8)),
                        clipBehavior: Clip.antiAlias,
                        child: ThumbnailImage(
                          image: _ImageProvider(image),
                        ))),
                Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withOpacity(0.3),
                                Colors.black.withOpacity(0.5),
                              ]),
                          borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(8),
                              bottomRight: Radius.circular(8))),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                        child: Text(
                          image.title.replaceAll("\n", ""),
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 14.0,
                            color: Colors.white,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )),
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onTap,
                      onLongPress: () => onLongTap(context),
                      onSecondaryTapDown: (details) =>
                          onSecondaryTap(context, details),
                      borderRadius: BorderRadius.circular(8),
                      child: const SizedBox.expand(),
                    ),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  void onTap() {
    var type = image.id.split("-")[0];
    _readWithKey(type, image.id.replaceFirst("$type-", ""), image.ep,
        image.page, image.title, image.otherInfo);
  }

  void _readWithKey(String key, String target, int ep, int page, String title,
      Map<String, dynamic> otherInfo) {
    switch (key) {
      case "picacg":
        App.globalTo(() => ComicReadingPage.picacg(
            target, ep, List.from(otherInfo["eps"]), title,
            initialPage: page));
      case "ehentai":
        App.globalTo(
          () => ComicReadingPage.ehentai(
            Gallery.fromJson(otherInfo["gallery"]),
            initialPage: page,
          ),
        );
      case "jm":
        App.globalTo(
          () => ComicReadingPage(
            JmReadingData(
              title,
              target,
              List.from(otherInfo["eps"]),
              List.from(
                otherInfo["jmEpNames"],
              ),
            ),
            page,
            ep,
          ),
        );
      case "hitomi":
        App.globalTo(
          () => ComicReadingPage(
            HitomiReadingData(
              title,
              target,
              (otherInfo["hitomi"] as List)
                  .map((e) => HitomiFile.fromMap(e))
                  .toList(),
              target,
            ),
            page,
            0,
          ),
        );
      case "htManga":
      case "htmanga":
        final eps = otherInfo["eps"];
        // Older favorites only stored chapter IDs, without display names.
        final chapters = eps is Map
            ? Map<String, String>.from(eps)
            : eps is List
                ? {for (final id in eps) id.toString(): id.toString()}
                : null;
        App.globalTo(
          () => ComicReadingPage.htmanga(target, title,
              initialPage: page, initialEp: ep, chapters: chapters),
        );
      case "nhentai":
        App.globalTo(
          () => ComicReadingPage.nhentai(target, title, initialPage: page),
        );
      default:
        var source = ComicSource.find(key);
        if (source == null) throw "Unknown source $key";
        App.globalTo(
          () => ComicReadingPage(
            CustomReadingData(
              target,
              title,
              source,
              otherInfo["eps"] == null
                  ? null
                  : Map<String, String>.from(otherInfo["eps"]),
            ),
            page,
            ep,
          ),
        );
    }
  }

  void onLongTap(BuildContext context) {
    unawaited(_confirmRemoval(context));
  }

  Future<void> _confirmRemoval(BuildContext context) async {
    final pageRoute = ModalRoute.of(context);
    final onRemoved = onDeleted;
    final controller = StateController.findOrNull(tag: "image_favorites_page");
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => _ImageRemovalDialog(image: image),
    );
    if (deleted != true || !context.mounted || pageRoute?.isActive == false) {
      return;
    }
    onRemoved?.call();
    showToast(message: "删除成功".tl);
    if (onRemoved == null &&
        identical(controller,
            StateController.findOrNull(tag: "image_favorites_page"))) {
      controller?.refresh();
    }
  }

  void onSecondaryTap(BuildContext context, TapDownDetails details) {
    showDesktopMenu(context, details.globalPosition, [
      DesktopMenuEntry(text: "查看".tl, onClick: onTap),
      DesktopMenuEntry(
          text: "删除".tl, onClick: () => unawaited(_confirmRemoval(context))),
    ]);
  }
}

class _ImageRemovalDialog extends StatefulWidget {
  const _ImageRemovalDialog({required this.image});

  final ImageFavorite image;

  @override
  State<_ImageRemovalDialog> createState() => _ImageRemovalDialogState();
}

class _ImageRemovalDialogState extends State<_ImageRemovalDialog> {
  bool _removing = false;
  bool _failed = false;

  Future<void> _remove() async {
    if (_removing) return;
    setState(() {
      _removing = true;
      _failed = false;
    });
    try {
      await ImageFavoriteManager.delete(widget.image);
    } catch (error, stack) {
      Log.error('ImageFavorites',
          'Failed to delete favorite image: ${safeNetworkError(error)}\n$stack');
      if (!mounted) return;
      setState(() {
        _removing = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    final route = ModalRoute.of(context)!;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(true);
    } else if (route.isActive) {
      navigator.removeRoute(route, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_removing,
      child: AlertDialog(
        title: Text("确认删除".tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("要删除这个图片吗".tl),
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
                : Text("确认".tl),
          ),
        ],
      ),
    );
  }
}

class _ImageProvider extends BaseImageProvider<_ImageProvider> {
  _ImageProvider(this.image);

  final ImageFavorite image;

  @override
  String get key => image.key;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    final localFile = Uri.file(image.imagePath).isAbsolute
        ? File(image.imagePath)
        : File("${App.dataPath}/images/${image.imagePath}");
    if (localFile.existsSync()) {
      return await localFile.readAsBytes();
    } else {
      var type = image.id.split("-")[0];
      Stream<DownloadProgress> stream;
      switch (type) {
        case "ehentai":
          stream = ImageManager().getEhImageNew(
              Gallery.fromJson(image.otherInfo["gallery"]), image.page);
        case "jm":
          stream = ImageManager().getJmImage(image.otherInfo["url"], null,
              epsId: image.otherInfo["epsId"],
              scrambleId: "220980",
              bookId: image.otherInfo["bookId"]);
        case "hitomi":
          stream = ImageManager().getHitomiImage(
              HitomiFile.fromMap(image.otherInfo["hitomi"][image.page - 1]),
              image.otherInfo["galleryId"]);
        case "picacg":
        case "nhentai":
        case "htmanga":
        case "htManga":
          stream = ImageManager().getImage(image.otherInfo["url"]);
        default:
          final comicId = image.id.substring(type.length + 1);
          final eps = image.otherInfo["eps"];
          final chapterIds = eps is Map
              ? eps.keys
              : eps is List
                  ? eps
                  : const <String>[];
          final epId =
              chapterIds.elementAtOrNull(image.ep - 1)?.toString() ?? comicId;
          stream = ImageManager()
              .getCustomImage(image.otherInfo["url"], comicId, epId, type);
      }
      DownloadProgress? finishProgress;
      await for (var progress in stream) {
        if (progress.currentBytes == progress.expectedBytes) {
          finishProgress = progress;
        }
        chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.expectedBytes));
      }
      var file = finishProgress!.getFile();
      var data = await file.readAsBytes();
      final file2 = Uri.file(image.imagePath).isAbsolute
          ? File(image.imagePath)
          : File("${App.dataPath}/images/${image.imagePath}");
      if (!file2.existsSync()) {
        await file2.create(recursive: true);
      }
      await file2.writeAsBytes(data);
      return data;
    }
  }

  @override
  Future<_ImageProvider> obtainKey(ImageConfiguration configuration) async {
    return this;
  }
}
