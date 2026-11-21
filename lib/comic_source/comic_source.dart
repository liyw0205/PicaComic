library comic_source;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/update.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/source_network_policy.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/atomic_file.dart';
import '../base.dart';
import '../foundation/js_engine.dart';
import '../network/base_comic.dart';
import '../network/res.dart';
import 'built_in/ehentai.dart';
import 'built_in/hitomi.dart';
import 'built_in/ht_manga.dart';
import 'built_in/jm.dart';
import 'built_in/nhentai.dart';
import 'built_in/picacg.dart';

part 'category.dart';

part 'favorites.dart';

part 'parser.dart';

/// build comic list, [Res.subData] should be maxPage or null if there is no limit.
typedef ComicListBuilder = Future<Res<List<BaseComic>>> Function(int page);

typedef LoginFunction = Future<Res<bool>> Function(String, String);

typedef LoadComicFunc = Future<Res<ComicInfoData>> Function(String id);

typedef LoadComicPagesFunc = Future<Res<List<String>>> Function(
    String id, String? ep);

typedef CommentsLoader = Future<Res<List<Comment>>> Function(
    String id, String? subId, int page, String? replyTo);

typedef SendCommentFunc = Future<Res<bool>> Function(
    String id, String? subId, String content, String? replyTo);

typedef GetImageLoadingConfigFunc = FutureOr<Map<String, dynamic>> Function(
    String imageKey, String comicId, String epId);
typedef GetThumbnailLoadingConfigFunc = Map<String, dynamic> Function(
    String imageKey)?;

class ComicSource {
  static final builtIn = [picacg, ehentai, jm, hitomi, htManga, nhentai];

  static List<ComicSource> sources = [];

  /// Keeps a source-specific failure visible without preventing other sources
  /// from starting. The value is intentionally a short, non-sensitive summary.
  static final Map<String, String> initFailures = <String, String>{};

  static ComicSource? find(String key) =>
      sources.firstWhereOrNull((element) => element.key == key);

  static ComicSource? fromIntKey(int key) =>
      sources.firstWhereOrNull((element) => element.key.hashCode == key);

  static Future<void> init() async {
    sources.clear();
    initFailures.clear();
    for (var source in builtInSources) {
      if (appdata.appSettings.isComicSourceEnabled(source)) {
        try {
          var s = builtIn.firstWhere((e) => e.key == source);
          // Keep the source discoverable while its migration hook runs; some
          // built-in hooks resolve their own source through ComicSource.find.
          sources.add(s);
          SourceNetworkPolicy.instance.configure(s.key);
          await s.loadData();
          await s.initData?.call(s);
        } catch (e) {
          final key = source;
          sources.removeWhere((candidate) => candidate.key == key);
          initFailures[key] = e.runtimeType.toString();
          log('Source $key initialization failed: ${e.runtimeType}',
              'ComicSource', LogLevel.error);
        }
      }
    }
    final path = "${App.dataPath}/comic_source";
    if (!(await Directory(path).exists())) {
      await Directory(path).create(recursive: true);
      return;
    }
    await for (var entity in Directory(path).list()) {
      if (entity is File && entity.path.endsWith(".js")) {
        try {
          if ((await entity.stat()).size > ComicSourceParser.maxSourceBytes) {
            throw ComicSourceParseException("Source file exceeds 1 MiB limit");
          }
          var source = await ComicSourceParser()
              .parse(await entity.readAsString(), entity.absolute.path);
          sources.add(source);
          SourceNetworkPolicy.instance.configure(source.key);
        } catch (e, s) {
          final key =
              entity.uri.pathSegments.last.replaceFirst(RegExp(r'\.js$'), '');
          initFailures[key] = e.runtimeType.toString();
          log("${safeNetworkError(e)}\n$s", "ComicSource", LogLevel.error);
        }
      }
    }
  }

  static Future reload() async {
    sources.clear();
    JsEngine().runCode("ComicSource.sources = {};");
    await init();
  }

  /// Name of this source.
  final String name;

  /// Identifier of this source.
  final String key;

  int get intKey {
    return key.hashCode;
  }

  /// Account config.
  final AccountConfig? account;

  /// Category data used to build a static category tags page.
  final CategoryData? categoryData;

  /// Category comics data used to build a comics page with a category tag.
  final CategoryComicsData? categoryComicsData;

  /// Favorite data used to build favorite page.
  final FavoriteData? favoriteData;

  /// Explore pages.
  final List<ExplorePageData> explorePages;

  /// Search page.
  final SearchPageData? searchPageData;

  /// Settings.
  final List<SettingItem> settings;

  /// Load comic info.
  final LoadComicFunc? loadComicInfo;

  /// Load comic pages.
  final LoadComicPagesFunc? loadComicPages;

  final GetImageLoadingConfigFunc? getImageLoadingConfig;

  final Map<String, dynamic> Function(String imageKey)?
      getThumbnailLoadingConfig;

  final String? matchBriefIdReg;

  var data = <String, dynamic>{};

  bool get isLogin => data["account"] != null;

  final String filePath;

  final String url;

  final String version;

  final CommentsLoader? commentsLoader;

  final SendCommentFunc? sendCommentFunc;

  final RegExp? idMatcher;

  final Widget Function(BuildContext context, String id, String? cover)?
      comicPageBuilder;

  Future<void> loadData() async {
    final file = File("${App.dataPath}/comic_source/$key.data");
    if (!await file.exists()) return;

    final contents = await file.readAsString();
    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException {
      await _recoverInvalidData(file, 'invalid JSON');
      return;
    }
    if (decoded is! Map) {
      await _recoverInvalidData(file, 'JSON root is not an object');
      return;
    }
    data = Map<String, dynamic>.from(decoded);
  }

  Future<void> _recoverInvalidData(File file, String reason) async {
    var suffix = DateTime.now().microsecondsSinceEpoch;
    var backup = File('${file.path}.corrupt.$suffix');
    while (await backup.exists()) {
      backup = File('${file.path}.corrupt.${++suffix}');
    }
    await file.rename(backup.path);
    data = <String, dynamic>{};
    log(
      'Saved source data for $key had $reason; preserved as '
          '${backup.uri.pathSegments.last} and loaded defaults.',
      'ComicSource',
      LogLevel.warning,
    );
  }

  Future<void> _saveTail = Future<void>.value();

  /// Serializes source snapshots and keeps a failed write from wedging later
  /// saves. Each call captures its own state before entering the queue.
  Future<void> saveData() async {
    final snapshot = jsonEncode(data);
    final operation = _saveTail.then<void>((_) async {
      final file = File("${App.dataPath}/comic_source/$key.data");
      await writeTextFileAtomically(file, snapshot);
    });
    _saveTail = operation.then<void>((_) {}, onError: (_, __) {});
    await operation;
  }

  Future<bool> reLogin() async {
    if (data["account"] == null) {
      return false;
    }
    final List accountData = data["account"];
    var res = await account!.login!(accountData[0], accountData[1]);
    if (res.error) {
      Log.error("Failed to re-login", safeNetworkError(res.errorMessage));
    }
    return !res.error;
  }

  Future<Res<T>> runWithLoginRetry<T>(Future<Res<T>> Function() operation,
      {bool requireLogin = true}) async {
    bool isCurrent() => identical(ComicSource.find(key), this);

    if (!isCurrent()) return const Res.error("Comic Source Not Found");
    if (requireLogin && !isLogin) return const Res.error("Not login");

    var res = await operation();
    if (!isCurrent()) return const Res.error("Comic Source Not Found");
    if (!res.error || !res.errorMessageWithoutNull.contains("Login expired")) {
      return res;
    }

    final reLoginRes = await reLogin();
    if (!isCurrent()) return const Res.error("Comic Source Not Found");
    if (!reLoginRes) {
      return const Res.error("Login expired and re-login failed");
    }

    res = await operation();
    if (!isCurrent()) return const Res.error("Comic Source Not Found");
    return res;
  }

  // only for built-in comic sources
  final FutureOr<void> Function(ComicSource source)? initData;

  bool get isBuiltIn => filePath == 'built-in';

  final Widget Function(BuildContext, BaseComic, List<ComicTileMenuOption>?)?
      comicTileBuilderOverride;

  ComicSource(
      this.name,
      this.key,
      this.account,
      this.categoryData,
      this.categoryComicsData,
      this.favoriteData,
      this.explorePages,
      this.searchPageData,
      this.settings,
      this.loadComicInfo,
      this.loadComicPages,
      this.getImageLoadingConfig,
      this.getThumbnailLoadingConfig,
      this.matchBriefIdReg,
      this.filePath,
      this.url,
      this.version,
      this.commentsLoader,
      this.sendCommentFunc)
      : initData = null,
        comicTileBuilderOverride = null,
        idMatcher = null,
        comicPageBuilder = null;

  ComicSource.named({
    required this.name,
    required this.key,
    this.account,
    this.categoryData,
    this.categoryComicsData,
    this.favoriteData,
    this.explorePages = const [],
    this.searchPageData,
    this.settings = const [],
    this.loadComicInfo,
    this.loadComicPages,
    this.getImageLoadingConfig,
    this.getThumbnailLoadingConfig,
    this.matchBriefIdReg,
    required this.filePath,
    this.url = '',
    this.version = '',
    this.commentsLoader,
    this.sendCommentFunc,
    this.initData,
    this.comicTileBuilderOverride,
    this.idMatcher,
    this.comicPageBuilder,
  });

  ComicSource.unknown(this.key)
      : name = "Unknown",
        account = null,
        categoryData = null,
        categoryComicsData = null,
        favoriteData = null,
        explorePages = [],
        searchPageData = null,
        settings = [],
        loadComicInfo = null,
        loadComicPages = null,
        getImageLoadingConfig = null,
        getThumbnailLoadingConfig = null,
        matchBriefIdReg = null,
        filePath = "",
        url = "",
        version = "",
        commentsLoader = null,
        sendCommentFunc = null,
        initData = null,
        comicTileBuilderOverride = null,
        idMatcher = null,
        comicPageBuilder = null;
}

class AccountConfig {
  final LoginFunction? login;

  final FutureOr<void> Function(BuildContext)? onLogin;

  final String? loginWebsite;

  final String? registerWebsite;

  final void Function() logout;

  final bool allowReLogin;

  final List<AccountInfoItem> infoItems;

  const AccountConfig(
      this.login, this.loginWebsite, this.registerWebsite, this.logout,
      {this.onLogin})
      : allowReLogin = true,
        infoItems = const [];

  const AccountConfig.named({
    this.login,
    this.loginWebsite,
    this.registerWebsite,
    required this.logout,
    this.onLogin,
    this.allowReLogin = true,
    this.infoItems = const [],
  });
}

class AccountInfoItem {
  final String title;
  final String Function()? data;
  final void Function()? onTap;
  final WidgetBuilder? builder;

  AccountInfoItem({required this.title, this.data, this.onTap, this.builder});
}

class LoadImageRequest {
  String url;

  Map<String, String> headers;

  LoadImageRequest(this.url, this.headers);
}

class ExplorePageData {
  final String title;

  final ExplorePageType type;

  final ComicListBuilder? loadPage;

  final Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;

  /// return a `List` contains `List<BaseComic>` or `ExplorePagePart`
  final Future<Res<List<Object>>> Function(int index)? loadMixed;

  final WidgetBuilder? overridePageBuilder;

  ExplorePageData(this.title, this.type, this.loadPage, this.loadMultiPart)
      : loadMixed = null,
        overridePageBuilder = null;

  ExplorePageData.named({
    required this.title,
    required this.type,
    this.loadPage,
    this.loadMultiPart,
    this.loadMixed,
    this.overridePageBuilder,
  });
}

class ExplorePagePart {
  final String title;

  final List<BaseComic> comics;

  /// If this is not null, the [ExplorePagePart] will show a button to jump to new page.
  ///
  /// Value of this field should match the following format:
  ///   - search:keyword
  ///   - category:categoryName
  ///
  /// End with `@`+`param` if the category has a parameter.
  final String? viewMore;

  const ExplorePagePart(this.title, this.comics, this.viewMore);
}

enum ExplorePageType {
  multiPageComicList,
  singlePageWithMultiPart,
  mixed,
  override,
}

typedef SearchFunction = Future<Res<List<BaseComic>>> Function(
    String keyword, int page, List<String> searchOption);

class SearchPageData {
  /// If this is not null, the default value of search options will be first element.
  final List<SearchOptions>? searchOptions;

  final Widget Function(BuildContext, List<String> initialValues,
      void Function(List<String>))? customOptionsBuilder;

  final Widget Function(String keyword, List<String> options)?
      overrideSearchResultBuilder;

  /// Builds a scrollable results body using the shared search header sliver.
  final Widget Function(String keyword, List<String> options, Widget header)?
      customResultsBuilder;

  final SearchFunction? loadPage;

  final bool enableLanguageFilter;

  final bool enableTagsSuggestions;

  const SearchPageData(this.searchOptions, this.loadPage)
      : enableLanguageFilter = false,
        customOptionsBuilder = null,
        overrideSearchResultBuilder = null,
        customResultsBuilder = null,
        enableTagsSuggestions = false;

  const SearchPageData.named({
    this.searchOptions,
    this.loadPage,
    this.enableLanguageFilter = false,
    this.customOptionsBuilder,
    this.overrideSearchResultBuilder,
    this.customResultsBuilder,
    this.enableTagsSuggestions = false,
  });
}

class SearchOptions {
  final LinkedHashMap<String, String> options;

  final String label;

  const SearchOptions(this.options, this.label);

  String get defaultValue => options.keys.first;

  const SearchOptions.named({required this.options, required this.label});
}

class SettingItem {
  final String name;
  final String iconName;
  final SettingType type;
  final List<String>? options;

  const SettingItem(this.name, this.iconName, this.type, this.options);
}

enum SettingType {
  switcher,
  selector,
  input,
}

class ComicInfoData with HistoryMixin {
  @override
  final String title;

  @override
  final String? subTitle;

  @override
  final String cover;

  final String? description;

  final Map<String, List<String>> tags;

  /// id-name
  final Map<String, String>? chapters;

  final List<String>? thumbnails;

  final Future<Res<List<String>>> Function(String id, int page)?
      thumbnailLoader;

  final int thumbnailMaxPage;

  final List<BaseComic>? suggestions;

  final String sourceKey;

  final String comicId;

  final bool? isFavorite;

  final String? subId;

  final int? pages;

  const ComicInfoData(
      this.title,
      this.subTitle,
      this.cover,
      this.description,
      this.tags,
      this.chapters,
      this.thumbnails,
      this.thumbnailLoader,
      this.thumbnailMaxPage,
      this.suggestions,
      this.sourceKey,
      this.comicId,
      {this.isFavorite,
      this.subId,
      this.pages});

  static int? parsePageCount(Map<String, dynamic> data) {
    for (final value in [data['pages'], data['maxPage']]) {
      final pageCount = switch (value) {
        num number when number.isFinite && number > 0 && number % 1 == 0 =>
          number.toInt(),
        String text => int.tryParse(text),
        _ => null,
      };
      if (pageCount != null && pageCount > 0) return pageCount;
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "subTitle": subTitle,
      "cover": cover,
      "description": description,
      "tags": tags,
      "chapters": chapters?.isNotEmpty == true ? chapters : null,
      "sourceKey": sourceKey,
      "comicId": comicId,
      "isFavorite": isFavorite,
      "subId": subId,
      "pages": pages,
    };
  }

  static Map<String, List<String>> _generateMap(Map<String, dynamic> map) {
    var res = <String, List<String>>{};
    map.forEach((key, value) {
      res[key] = List<String>.from(value);
    });
    return res;
  }

  ComicInfoData.fromJson(Map<String, dynamic> json)
      : title = json["title"],
        subTitle = json["subTitle"],
        cover = json["cover"],
        description = json["description"],
        tags = _generateMap(json["tags"]),
        chapters = (json["chapters"] as Map?)?.isNotEmpty == true
            ? (json["chapters"] as Map)
                .map((key, value) => MapEntry(key.toString(), value.toString()))
            : null,
        sourceKey = json["sourceKey"],
        comicId = json["comicId"],
        thumbnails = null,
        thumbnailLoader = null,
        thumbnailMaxPage = 0,
        suggestions = null,
        isFavorite = json["isFavorite"],
        subId = json["subId"],
        pages = parsePageCount(json);

  @override
  HistoryType get historyType => HistoryType(sourceKey.hashCode);

  @override
  String get target => comicId;
}

typedef CategoryComicsLoader = Future<Res<List<BaseComic>>> Function(
    String category, String? param, List<String> options, int page);

class CategoryComicsData {
  /// options
  final List<CategoryComicsOptions> options;

  /// [category] is the one clicked by the user on the category page.

  /// if [BaseCategoryPart.categoryParams] is not null, [param] will be not null.
  ///
  /// [Res.subData] should be maxPage or null if there is no limit.
  final CategoryComicsLoader load;

  final RankingData? rankingData;

  const CategoryComicsData(this.options, this.load, {this.rankingData});

  const CategoryComicsData.named({
    this.options = const [],
    required this.load,
    this.rankingData,
  });
}

class RankingData {
  final Map<String, String> options;

  final Future<Res<List<BaseComic>>> Function(String option, int page) load;

  const RankingData(this.options, this.load);

  const RankingData.named({
    required this.options,
    required this.load,
  });
}

class CategoryComicsOptions {
  /// Use a [LinkedHashMap] to describe an option list.
  /// key is for loading comics, value is the name displayed on screen.
  /// Default value will be the first of the Map.
  final LinkedHashMap<String, String> options;

  /// If [notShowWhen] contains category's name, the option will not be shown.
  final List<String> notShowWhen;

  final List<String>? showWhen;

  const CategoryComicsOptions(this.options, this.notShowWhen, this.showWhen);

  const CategoryComicsOptions.named({
    required this.options,
    this.notShowWhen = const [],
    this.showWhen,
  });
}

class Comment {
  final String userName;
  final String? avatar;
  final String content;
  final String? time;
  final int? replyCount;
  final String? id;

  const Comment(this.userName, this.avatar, this.content, this.time,
      this.replyCount, this.id);
}
