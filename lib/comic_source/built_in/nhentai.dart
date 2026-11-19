import 'dart:async';
import 'dart:collection';

import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/nhentai_network/login.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/nhentai/comic_page.dart';
import 'package:pica_comic/pages/nhentai/tag_stack_bar.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import '../../base.dart';
import '../../foundation/history.dart';
import '../../pages/reader/comic_reading_page.dart';

final nhentai = ComicSource.named(
  name: 'nhentai',
  key: 'nhentai',
  filePath: 'built-in',
  favoriteData: FavoriteData(
    key: "nhentai",
    title: "nhentai",
    multiFolder: false,
    loadComic: (i, [folder]) => NhentaiNetwork().getFavorites(i),
    loadFolders: null,
  ),
  categoryData: CategoryData(
    title: "nhentai",
    key: "nhentai",
    categories: [
      const FixedCategoryPart("language", ["中文", "日本語", "english"], "category",
          ["/language/chinese", "/language/japanese", "/language/english"]),
      RandomCategoryPartWithRuntimeData(
        "tag",
        () => nhentaiTags.values,
        50,
        "category",
        buildParam: (tag) => nhentaiStackParam([NhentaiTagTerm('tag', tag)]),
      ),
    ],
    enableRankingPage: false,
    buttons: [
      CategoryButtonData(
        label: "推荐",
        onTap: () => App.mainNavigatorKey?.currentContext?.to(
          () => const ComicPage(sourceKey: "nhentai", id: ""),
        ),
      ),
    ],
  ),
  categoryComicsData: CategoryComicsData.named(
    load: (category, param, options, page) async {
      final terms = nhentaiTermsFromParam(param);
      if (terms == null) return const Res.error('Invalid category');
      var lang = int.tryParse(appdata.settings[69]) ?? 0;
      if (param!.startsWith('/combo/') ||
          (lang >= 1 && lang <= 3) ||
          NhentaiTagSettings.defaultExcludes.isNotEmpty) {
        return NhentaiNetwork().search(
          NhentaiTagQuery(terms: terms).toQuery(),
          page,
          NhentaiSort.fromValue(options[0]),
        );
      }
      return NhentaiNetwork()
          .getCategoryComics(param, page, NhentaiSort.fromValue(options[0]));
    },
    options: [
      CategoryComicsOptions.named(
        options: LinkedHashMap.of({
          "": "最近",
          "&sort=popular-today": "热门 | 今天",
          "&sort=popular-week": "热门 | 一周",
          "&sort=popular-month": "热门 | 本月",
          "&sort=popular": "热门 | 所有时间",
        }),
        notShowWhen: ["random", "latest"],
      ),
    ],
  ),
  account: AccountConfig.named(
    onLogin: (context) async {
      var future = Completer<void>();
      unawaited(nhLogin(() {
        future.complete();
      }));
      await future.future;
      if (NhentaiNetwork().logged) {
        var source = ComicSource.find('nhentai')!;
        source.data["account"] = 'ok';
        await source.saveData();
      }
    },
    logout: () {
      NhentaiNetwork().logged = false;
      NhentaiNetwork().logout();
      var source = ComicSource.find('nhentai')!;
      source.data["account"] = null;
      unawaited(source.saveData());
    },
    allowReLogin: false,
  ),
  comicTileBuilderOverride: (context, comic, options) {
    return _NhentaiComicTile(
      comic as NhentaiComicBrief,
      addonMenuOptions: options,
      tagTerms: List.unmodifiable(NhentaiTagScope.termsOf(context)),
    );
  },
  explorePages: [
    ExplorePageData.named(
      title: "nhentai",
      type: ExplorePageType.mixed,
      loadMixed: (index) async {
        var res = await NhentaiNetwork().getHomePage(index);
        if (res.error) {
          return Res.fromErrorRes(res);
        }
        if (index == 1) {
          final parts = <Object>[];
          if (res.data.popular.isNotEmpty) {
            parts.add(ExplorePagePart("Popular", res.data.popular, null));
          }
          parts.add(res.data.latest);
          return Res(
            parts,
            subData:
                res.data.totalPages ?? (res.data.latest.isEmpty ? index : null),
          );
        } else {
          return Res(
            res.data.latest.isEmpty ? const [] : [res.data.latest],
            subData: res.data.totalPages ??
                (res.data.latest.isEmpty ? (index > 1 ? index - 1 : 1) : null),
          );
        }
      },
    ),
  ],
  idMatcher: RegExp(r"^(\d+|nh\d+|nhentai\d+)$"),
  searchPageData: SearchPageData.named(
    loadPage: (keyword, page, options) {
      return NhentaiNetwork()
          .search(keyword, page, NhentaiSort.fromValue(options[0]));
    },
    enableLanguageFilter: true,
    enableTagsSuggestions: true,
    searchOptions: [
      SearchOptions(
        LinkedHashMap.of({
          "": "最近",
          "&sort=popular-today": "热门 | 今天",
          "&sort=popular-week": "热门 | 一周",
          "&sort=popular-month": "热门 | 本月",
          "&sort=popular": "热门 | 所有时间",
        }),
        '排序',
      )
    ],
  ),
  comicPageBuilder: (context, id, cover) {
    return NhentaiComicPage(
      id.replaceFirst(RegExp(r'^(?:nhentai|nh)', caseSensitive: false), ''),
      comicCover: cover,
    );
  },
);

class _NhentaiComicTile extends ComicTile {
  final NhentaiComicBrief comic;

  const _NhentaiComicTile(this.comic,
      {this.addonMenuOptions, this.tagTerms = const []});

  final List<NhentaiTagTerm> tagTerms;

  @override
  String get description => comic.lang;

  @override
  Widget? buildSubDescription(BuildContext context) {
    final pages = comic.pages;
    if (pages == null || pages <= 0) {
      return null;
    }
    return Text(
      "${pages}P",
      style: const TextStyle(fontSize: 12.0),
    );
  }

  @override
  Widget get image => AnimatedImage(
        image: CachedImageProvider(
          comic.cover,
          headers: {
            "User-Agent": webUA,
          },
        ),
        fit: BoxFit.cover,
        height: double.infinity,
        width: double.infinity,
        filterQuality: FilterQuality.medium,
      );

  @override
  void onTap_() {
    App.mainNavigatorKey!.currentContext!.to(
      () => NhentaiComicPage(
        comic.id,
        comicCover: comic.cover,
        tagTerms: tagTerms,
      ),
    );
  }

  @override
  String get subTitle => "ID: ${comic.id}";

  @override
  String get title => comic.title;

  List<String> _generateTags(List<String> tags) {
    if (App.locale.languageCode != "zh") {
      return tags;
    }
    var res = <String>[];
    for (var tag in tags) {
      res.add(tag.translateTagsToCN);
    }
    return res;
  }

  @override
  List<String>? get tags => _generateTags(comic.tags);

  @override
  ActionFunc? get read => () async {
        bool cancel = false;
        var dialog = showLoadingDialog(
          App.globalContext!,
          onCancel: () => cancel = true,
        );
        var res = await NhentaiNetwork().getComicInfo(comic.id);
        if (cancel) {
          return;
        }
        dialog.close();
        if (res.error) {
          showToast(message: res.errorMessage ?? "Error");
        } else {
          var history = await History.findOrCreate(res.data);
          App.globalTo(
            () => ComicReadingPage.nhentai(
              res.data.id,
              res.data.title,
              initialPage: history.page,
            ),
          );
        }
      };

  @override
  FavoriteItem? get favoriteItem => FavoriteItem.fromNhentai(comic);

  @override
  String get comicID => comic.id;

  @override
  final List<ComicTileMenuOption>? addonMenuOptions;
}
