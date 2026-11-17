import 'dart:async';

import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';

class HtComicPage extends BaseComicPage<HtComicInfo> {
  const HtComicPage(this.id, {super.key, this.comicCover});

  @override
  final String id;

  final String? comicCover;

  @override
  void openFavoritePanel() {
    favoriteComic(FavoriteComicWidget(
      havePlatformFavorite: htManga.isLogin,
      needLoadFolderData: true,
      foldersLoader: () => HtmangaNetwork().getFolders(),
      localFavoriteItem: toLocalFavoriteItem(),
      setFavorite: (b) {},
      selectFolderCallback: (folder, page) async {
        if (page == 0) {
          return HtmangaNetwork().addFavorite(data!.id, folder);
        } else {
          LocalFavoritesManager()
              .addComic(folder, FavoriteItem.fromHtcomic(data!.toBrief()));
          return const Res(true);
        }
      },
    ));
  }

  @override
  String? get cover => data?.cover ?? comicCover;

  @override
  void download() {
    final id = "Ht${data!.id}";
    if (DownloadManager().isExists(id)) {
      showToast(message: "已下载".tl);
      return;
    }
    for (var i in DownloadManager().downloading) {
      if (i.id == id) {
        showToast(message: "下载中".tl);
        return;
      }
    }
    DownloadManager().addHtDownload(data!);
    showToast(message: "已加入下载队列".tl);
  }

  @override
  void onThumbnailTapped(int index) {
    final comic = data;
    if (comic == null) return;
    unawaited(_openReader(comic, initialPage: index + 1));
  }

  Future<void> _openReader(HtComicInfo comic,
      {required int initialPage}) async {
    try {
      await History.findOrCreate(comic);
      if (!_isPageActive(comic)) return;
      await App.globalTo(
        () => ComicReadingPage.htmanga(
          comic.target,
          comic.title,
          initialPage: initialPage,
          chapters: comic.chapters,
        ),
      );
    } catch (error, stack) {
      LogManager.addLog(
        LogLevel.error,
        "UI",
        "Failed to open Ht Manga reader: ${safeNetworkError(error)}\n$stack",
      );
    }
  }

  @override
  EpsData? get eps {
    final chapters = data?.chapters;
    if (chapters == null || chapters.isEmpty) return null;
    return EpsData(chapters.values.toList(), (index) async {
      await History.findOrCreate(data!);
      App.globalTo(
        () => ComicReadingPage.htmanga(
          data!.id,
          data!.title,
          initialEp: index + 1,
          chapters: chapters,
        ),
      );
    });
  }

  @override
  String? get introduction => data!.description;

  @override
  Future<Res<HtComicInfo>> loadData() => HtmangaNetwork().getComicInfo(id);

  @override
  int? get pages => data?.chapters == null ? data?.pages : null;

  @override
  void read(History? history) {
    final comic = data;
    if (comic == null) return;
    unawaited(_read(comic, history));
  }

  Future<void> _read(HtComicInfo comic, History? history) async {
    try {
      final currentHistory = await History.createIfNull(history, comic);
      if (!_isPageActive(comic)) return;
      await App.globalTo(
        () => ComicReadingPage.htmanga(
          comic.target,
          comic.title,
          initialPage: currentHistory.page,
          initialEp: currentHistory.ep,
          chapters: comic.chapters,
        ),
      );
    } catch (error, stack) {
      LogManager.addLog(
        LogLevel.error,
        "UI",
        "Failed to open Ht Manga reader: ${safeNetworkError(error)}\n$stack",
      );
    }
  }

  bool _isPageActive(HtComicInfo comic) {
    final logic =
        StateController.findOrNull<ComicPageLogic<HtComicInfo>>(tag: tag);
    return App.globalContext?.mounted == true &&
        logic != null &&
        !logic.isDisposed &&
        identical(logic.data, comic);
  }

  @override
  SliverGrid? recommendationBuilder(HtComicInfo data) => null;

  @override
  String get tag => "Ht ComicPage $id";

  @override
  Map<String, List<String>>? get tags =>
      {"分类".tl: data!.category.toList(), "标签".tl: data!.tags.keys.toList()};

  @override
  void tapOnTag(String tag, String key) => context.to(() => SearchResultPage(
        keyword: tag,
        sourceKey: sourceKey,
      ));

  @override
  ThumbnailsData? get thumbnailsCreator {
    if (data!.chapters != null) return null;
    return ThumbnailsData(
        data!.thumbnails,
        (page) => HtmangaNetwork().getThumbnails(data!.id, page),
        (data!.pages / 12).ceil());
  }

  @override
  String? get title => data?.name.removeAllBlank;

  @override
  Card? get uploaderInfo => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.inversePrimary,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              Expanded(
                flex: 0,
                child: Avatar(
                  size: 50,
                  avatarUrl: data!.avatar,
                  couldBeShown: false,
                  name: data!.uploader,
                ),
              ),
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(15, 10, 0, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data!.uploader,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      Text("投稿作品${data!.uploadNum}部")
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Future<bool> loadFavorite(HtComicInfo data) => Future.value(false);

  @override
  String get source => "绅士漫画".tl;

  @override
  FavoriteItem toLocalFavoriteItem() =>
      FavoriteItem.fromHtcomic(data!.toBrief());

  @override
  String get downloadedId => "Ht${data!.id}";

  @override
  String get sourceKey => 'htmanga';
}

class HtComicPageLogic extends StateController {
  bool loading = true;
  HtComicInfo? comic;
  String? message;
  final ScrollController controller = ScrollController();
  bool showAppbarTitle = false;
  List<String> images = [];
  bool _requestInFlight = false;
  bool _imagesRequestInFlight = false;
  int _requestGeneration = 0;
  int _imagesGeneration = 0;

  Future<void> get(String id) async {
    if (isDisposed || _requestInFlight) return;
    _requestInFlight = true;
    final generation = ++_requestGeneration;
    _imagesGeneration++;
    _imagesRequestInFlight = false;
    try {
      final res = await HtmangaNetwork().getComicInfo(id);
      if (isDisposed || generation != _requestGeneration) return;
      message = res.errorMessage;
      comic = res.dataOrNull;
      images
        ..clear()
        ..addAll(
          res.subData is Iterable
              ? (res.subData as Iterable).whereType<String>()
              : const <String>[],
        );
      loading = false;
      update();
    } catch (error, stack) {
      if (isDisposed || generation != _requestGeneration) return;
      message = safeNetworkError(error);
      loading = false;
      update();
      LogManager.addLog(
        LogLevel.error,
        "Network",
        "Failed to load Ht Manga comic: ${safeNetworkError(error)}\n$stack",
      );
    } finally {
      if (generation == _requestGeneration) {
        _requestInFlight = false;
      }
    }
  }

  void refresh_() {
    if (isDisposed) return;
    _requestGeneration++;
    _imagesGeneration++;
    _requestInFlight = false;
    _imagesRequestInFlight = false;
    comic = null;
    message = null;
    loading = true;
    images.clear();
    update();
  }

  Future<void> getImages() async {
    final currentComic = comic;
    if (isDisposed || currentComic == null || _imagesRequestInFlight) return;
    _imagesRequestInFlight = true;
    final generation = ++_imagesGeneration;
    final nextPage = images.length ~/ 12 + 1;
    try {
      final res =
          await HtmangaNetwork().getThumbnails(currentComic.id, nextPage);
      if (isDisposed ||
          generation != _imagesGeneration ||
          !identical(currentComic, comic)) {
        return;
      }
      if (!res.error) {
        images.addAll(res.data);
        update();
      } else {
        LogManager.addLog(
          LogLevel.error,
          "Network",
          "Failed to load Ht Manga thumbnails: "
              "${safeNetworkError(res.errorMessage)}",
        );
      }
    } catch (error, stack) {
      if (isDisposed ||
          generation != _imagesGeneration ||
          !identical(currentComic, comic)) {
        return;
      }
      LogManager.addLog(
        LogLevel.error,
        "Network",
        "Failed to load Ht Manga thumbnails: "
            "${safeNetworkError(error)}\n$stack",
      );
    } finally {
      if (generation == _imagesGeneration) {
        _imagesRequestInFlight = false;
      }
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _requestGeneration++;
    _imagesGeneration++;
    _requestInFlight = false;
    _imagesRequestInFlight = false;
    controller.dispose();
    super.dispose();
  }
}
