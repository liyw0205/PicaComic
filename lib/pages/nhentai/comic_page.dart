import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/category_comics_page.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/translations.dart';

import '../../base.dart';
import '../../foundation/app.dart';
import '../../foundation/history.dart';
import '../../foundation/local_favorites.dart';
import '../../network/download.dart';
import 'comments.dart';

class NhentaiComicPage extends BaseComicPage<NhentaiComic> {
  const NhentaiComicPage(String id,
      {super.key, this.comicCover, this.tagTerms = const []})
      : _id = id;

  final String _id;

  final String? comicCover;

  final List<NhentaiTagTerm> tagTerms;

  @override
  String get url => "https://nhentai.net/g/$_id/";

  @override
  String get id => (data?.id) ?? _id;

  @override
  ActionFunc? get searchSimilar => () {
        String? subTitle = data!.subTitle;
        if (subTitle == "") {
          subTitle = null;
        }
        var title = subTitle ?? data!.title;
        title = title
            .replaceAll(RegExp(r"\[.*?\]"), "")
            .replaceAll(RegExp(r"\(.*?\)"), "");
        context.to(
          () => SearchResultPage(
            keyword: "\"$title\"".trim(),
            sourceKey: sourceKey,
          ),
        );
      };

  @override
  void openFavoritePanel() {
    favoriteComic(FavoriteComicWidget(
      havePlatformFavorite: NhentaiNetwork().logged,
      needLoadFolderData: false,
      favoriteOnPlatform: data!.favorite,
      initialFolder: NhentaiNetwork().logged ? "0" : null,
      localFavoriteItem: toLocalFavoriteItem(),
      setFavorite: (b) {
        if (favorite != b) {
          favorite = b;
          update();
        }
      },
      folders: const {"0": "Nhentai"},
      selectFolderCallback: (folder, page) async {
        if (page == 0) {
          var res = await NhentaiNetwork().favoriteComic(id, data!.token);
          if (res.success) {
            data!.favorite = true;
          }
          return res;
        } else {
          LocalFavoritesManager().addComic(
            folder,
            FavoriteItem.fromNhentai(
              NhentaiComicBrief(
                data!.title,
                data!.cover,
                id,
                "Unknown",
                data!.tags["Tags"] ?? const <String>[],
              ),
            ),
          );
          return const Res(true);
        }
      },
      cancelPlatformFavorite: () async {
        var res = await NhentaiNetwork().unfavoriteComic(id, data!.token);
        if (res.success) {
          data!.favorite = false;
        }
        return res;
      },
    ));
  }

  @override
  ActionFunc? get openComments => () {
        showComments(App.globalContext!, id);
      };

  @override
  String? get cover => comicCover ?? data?.cover;

  @override
  void download() {
    final id = "nhentai${data!.id}";
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
    DownloadManager().addNhentaiDownload(data!);
    showToast(message: "已加入下载队列".tl);
  }

  @override
  EpsData? get eps => null;

  @override
  String? get introduction => null;

  @override
  bool get enableTranslationToCN => App.locale.languageCode == "zh";

  @override
  Future<Res<NhentaiComic>> loadData() => NhentaiNetwork().getComicInfo(_id);

  @override
  int? get pages => int.tryParse(data?.tags["Pages"]?.elementAtOrNull(0) ?? "");

  @override
  String? get subTitle => data?.subTitle;

  @override
  void read(History? history) {
    unawaited(_read(history));
  }

  Future<void> _read(History? history) async {
    final logic = _pageLogic;
    final comic = logic?.data;
    if (!_isCurrent(logic, comic)) return;
    history = await History.createIfNull(history, comic!);
    if (!_isCurrent(logic, comic) || App.globalContext?.mounted != true) return;
    App.globalTo(() => ComicReadingPage.nhentai(
          comic.id,
          comic.title,
          initialPage: history!.page,
        ));
  }

  @override
  void onThumbnailTapped(int index) {
    unawaited(_openThumbnail(index));
  }

  Future<void> _openThumbnail(int index) async {
    final logic = _pageLogic;
    final comic = logic?.data;
    if (!_isCurrent(logic, comic)) return;
    await History.findOrCreate(comic!);
    if (!_isCurrent(logic, comic) || App.globalContext?.mounted != true) return;
    App.globalTo(
      () => ComicReadingPage.nhentai(
        comic.id,
        comic.title,
        initialPage: index + 1,
      ),
    );
  }

  ComicPageLogic<NhentaiComic>? get _pageLogic =>
      StateController.findOrNull<ComicPageLogic<NhentaiComic>>(tag: tag);

  bool _isCurrent(ComicPageLogic<NhentaiComic>? logic, NhentaiComic? comic) =>
      logic != null &&
      !logic.isDisposed &&
      comic != null &&
      identical(logic.data, comic) &&
      identical(
          StateController.findOrNull<ComicPageLogic<NhentaiComic>>(tag: tag),
          logic);

  @override
  Future<bool> loadFavorite(NhentaiComic data) async {
    return data.favorite ||
        (await LocalFavoritesManager().findWithModel(toLocalFavoriteItem()))
            .isNotEmpty;
  }

  @override
  Widget? recommendationBuilder(NhentaiComic data) =>
      SliverGridComics(comics: data.recommendations, sourceKey: sourceKey);

  @override
  String get tag => "Nhentai $_id";

  Map<String, List<String>> generateTags() {
    var tags = Map<String, List<String>>.from(data!.tags);
    tags.remove("Pages");
    tags.removeWhere((key, value) => value.isEmpty);
    return tags;
  }

  @override
  Map<String, List<String>>? get tags => generateTags();

  @override
  void tapOnTag(String tag, String key) {
    final namespace = nhentaiNamespaceOfField(key);
    if (namespace == null) {
      context.to(
        () => SearchResultPage(
          keyword: tag,
          sourceKey: sourceKey,
        ),
      );
    } else {
      final term = NhentaiTagTerm(namespace, tag);
      final result = nhentaiStackAdd(
          NhentaiTagSettings.stackEnabled ? tagTerms : const [], term);
      switch (result.outcome) {
        case NhentaiStackOutcome.duplicate:
          showToast(message: '这个标签已经在当前组合里了'.tl);
          return;
        case NhentaiStackOutcome.limit:
          showToast(
              message: '最多同时 @n 个标签'.tlParams({'n': '$nhentaiTagStackLimit'}));
          return;
        case NhentaiStackOutcome.added:
          break;
      }
      context.to(
        () => CategoryComicsPage(
          category: tag,
          categoryKey: ComicSource.find(sourceKey)!.categoryData!.key,
          param: nhentaiStackParam(result.terms),
        ),
      );
    }
  }

  @override
  ThumbnailsData? get thumbnailsCreator =>
      ThumbnailsData(data!.thumbnails, (page) async => const Res([]), 1);

  @override
  String? get title => data?.title;

  @override
  Card? get uploaderInfo => null;

  @override
  String get source => "Nhentai";

  @override
  FavoriteItem toLocalFavoriteItem() =>
      FavoriteItem.fromNhentai(NhentaiComicBrief(data!.title, data!.cover, id,
          "Unknown", data!.tags["Tags"] ?? const <String>[]));

  @override
  String get downloadedId => "nhentai${data!.id}";

  @override
  String get sourceKey => 'nhentai';
}
