import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/translations.dart';
import '../../base.dart';

class HtmangaNetwork {
  ///用于获取绅士漫画的网络请求类
  factory HtmangaNetwork() => _cache ?? (_cache = HtmangaNetwork._create());

  static HtmangaNetwork? _cache;

  HtmangaNetwork._create();

  static String get baseUrl => appdata.settings[31];

  /// WNACG has served both the paged and unpaged detail URL forms.
  static List<String> detailUrls(String id, {String? base}) {
    final root = (base ?? baseUrl).replaceFirst(RegExp(r'/$'), '');
    return [
      '$root/photos-index-page-1-aid-$id.html',
      '$root/photos-index-aid-$id.html',
    ];
  }

  /// Resolve image and link attributes from both protocol-relative and
  /// absolute URLs. The site mixes all three forms across its pages.
  static String resolveUrl(String raw, {String? base}) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final parsed = Uri.tryParse(value);
    if (parsed?.hasScheme == true) return value;
    if (value.startsWith('//')) return 'https:$value';
    final root = Uri.parse(base ?? baseUrl);
    return root.resolve(value).toString();
  }

  static List<String> _infoParts(String info) => info
      .split(RegExp(r'[,，]'))
      .map((part) => part.replaceAll('\n', '').trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  static int parsePages(String info) {
    final explicit =
        RegExp(r'(\d[\d,]*)\s*(?:頁|页|pages?|章|話|话)', caseSensitive: false)
            .firstMatch(info);
    final parts = _infoParts(info);
    final fallback = parts
        .where((part) => !RegExp(r'\d{4}[-/.]\d').hasMatch(part))
        .map((part) => RegExp(r'^\d[\d,]*$').firstMatch(part)?.group(0))
        .whereType<String>()
        .firstOrNull;
    final value = explicit?.group(1) ?? fallback;
    return int.tryParse(value?.replaceAll(',', '') ?? '') ?? 0;
  }

  static String parseTime(String info) {
    final parts = _infoParts(info);
    for (final part in parts) {
      if (!RegExp(r'\d[\d,]*\s*(?:頁|页|pages?|章|話|话)', caseSensitive: false)
          .hasMatch(part)) {
        return part;
      }
    }
    return parts.firstOrNull ?? '';
  }

  static String firstNonEmptyText(Iterable<String> values) => values
      .map((value) => value.trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');

  static bool isDetailPage(String html) =>
      parse(html).querySelector('div.userwrap > h2') != null;

  /// Reads the chapter links used by the current WNACG series detail page.
  ///
  /// Older single-gallery pages do not contain any of these nodes and return
  /// null, which keeps their existing one-episode behaviour intact.
  static Map<String, String>? parseChapterLinks(String html) {
    final document = parse(html);
    final chapters = <String, String>{};
    final nodes = document.querySelectorAll(
      '[data-chid], .sr_compact a[href], '
      'a[href*="photos-slide-aid-"], a[href*="photos-list-aid-"]',
    );
    for (final node in nodes) {
      final id = firstNonEmptyText([
        node.attributes['data-chid'] ?? '',
        ...RegExp(r'photos-(?:slide|list)-aid-(\d+)')
            .allMatches(node.attributes['href'] ?? '')
            .map((match) => match.group(1) ?? ''),
      ]);
      if (id.isEmpty) continue;
      final title = firstNonEmptyText([
        node.text,
        node.attributes['title'] ?? '',
      ]);
      if (title.isNotEmpty) chapters[id] = title;
    }
    return chapters.isEmpty ? null : chapters;
  }

  static List<String> parseImageList(String script) {
    final normalized = script.replaceAll(r'\/', '/');
    final imageUrls = RegExp(
      r'''url\s*:[^"']*\\?["']((?:https?:)?//[^"'\s\\]+)''',
    )
        .allMatches(normalized)
        .map((match) => resolveUrl(match[1]!))
        .where((url) => url.isNotEmpty)
        .toSet();
    if (imageUrls.isNotEmpty) return imageUrls.toList(growable: false);

    return RegExp(r'''(?:(?:https?:)?//)[^"'\s<>]+''')
        .allMatches(normalized)
        .map((match) => resolveUrl(match[0]!))
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  void logout() {
    SingleInstanceCookieJar.instance?.deleteUri(Uri.parse(baseUrl));
  }

  ///基本的Get请求
  Future<Res<String>> get(String url,
      {bool cache = true, Map<String, String>? headers}) async {
    var dio = CachedNetwork();
    try {
      var res = await dio.get(
          url,
          BaseOptions(
              headers: {"User-Agent": webUA, if (headers != null) ...headers}),
          cookieJar: SingleInstanceCookieJar.instance,
          expiredTime: cache ? CacheExpiredTime.short : CacheExpiredTime.no);
      if (res.url.contains("users-login")) {
        return Res(null, errorMessage: "未登录或登录到期".tl);
      }
      return Res(res.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const Res(null, errorMessage: "连接超时");
      } else {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///基本的Post请求
  Future<Res<String>> post(String url, String data) async {
    var dio = logDio(BaseOptions(headers: {
      "User-Agent": webUA,
      "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
    }));
    dio.interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
    try {
      var res = await dio.post(url, data: data);
      return Res(res.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const Res(null, errorMessage: "连接超时");
      } else {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///登录
  Future<Res<bool>> login(String account, String pwd,
      [bool saveData = true]) async {
    var res = await post("$baseUrl/users-check_login.html",
        "login_name=${Uri.encodeComponent(account)}&login_pass=${Uri.encodeComponent(pwd)}");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var json = const JsonDecoder().convert(res.data);
      if (json["html"].contains("登錄成功")) {
        return const Res(true);
      }
      return Res(null, errorMessage: json["html"]);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<bool>> loginFromAppdata() async {
    var res = await htManga.reLogin();
    return res ? const Res(true) : const Res.error("error");
  }

  Future<Res<HtHomePageData>> getHomePage() async {
    var res = await get(baseUrl, cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var titles = document.querySelectorAll("div.title_sort");
      var comicBlocks = document.querySelectorAll("div.bodywrap");
      Map<String, String> titleRes = {};
      for (var title in titles) {
        final titleNode = title.querySelector("div.title_h2");
        final linkNode = title.querySelector("div.r > a");
        if (titleNode == null || linkNode == null) continue;
        var text = titleNode.text;
        text = text.replaceAll("\n", "").removeAllBlank;
        var link = linkNode.attributes["href"] ?? '';
        link = resolveUrl(link);
        titleRes[text] = link;
      }
      var comicsRes = <List<HtComicBrief>>[];
      for (var block in comicBlocks) {
        var cs = block.querySelectorAll("div.gallary_wrap > ul.cc > li");
        var comics = <HtComicBrief>[];
        for (var c in cs) {
          try {
            var link = c.querySelector("div.pic_box > a")!.attributes["href"]!;
            var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
            var image =
                c.querySelector("div.pic_box > a > img")!.attributes["src"]!;
            image = resolveUrl(image);
            var name = c.querySelector("div.info > div.title > a")!.text;
            var infoCol = c.querySelector("div.info > div.info_col")!.text;
            comics.add(HtComicBrief(
                name, parseTime(infoCol), image, id, parsePages(infoCol)));
          } catch (_) {
            continue;
          }
        }
        comicsRes.add(comics);
      }
      if (comicsRes.length != titleRes.length) {
        throw Exception("漫画块数量和标题数量不相等");
      }
      return Res(HtHomePageData(comicsRes, titleRes));
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyze", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: "解析失败: $e");
    }
  }

  /// 获取给定漫画列表页面的漫画
  Future<Res<List<HtComicBrief>>> getComicList(String url, int page,
      {bool searchPage = false}) async {
    if (page != 1) {
      if (url.contains("search")) {
        url = "$url&p=$page";
      } else if (url.contains("ranking")) {
        url = url.replaceAll("ranking", "ranking-page-$page");
      } else {
        if (!url.contains("-")) {
          url = url.replaceAll(".html", "-.html");
        }
        url = url.replaceAll("index", "");
        var lr = url.split("albums-");
        lr[1] = "index-page-$page${lr[1]}";
        url = "${lr[0]}albums-${lr[1]}";
      }
    }
    var res = await get(url, cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var comics = <HtComicBrief>[];
      for (var comic in document
          .querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")) {
        try {
          var link =
              comic.querySelector("div.pic_box > a")!.attributes["href"]!;
          var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
          var image =
              comic.querySelector("div.pic_box > a > img")!.attributes["src"]!;
          image = resolveUrl(image);
          var name = comic
              .querySelector("div.info > div.title > a")!
              .attributes["title"]
              ?.replaceAll("<em>", "")
              .replaceAll("</em>", "");
          name = name ??
              comic
                  .querySelector("div.info > div.title > a")!
                  .text
                  .replaceAll("<em>", "")
                  .replaceAll("</em>", "");
          var infoCol = comic.querySelector("div.info > div.info_col")!.text;
          comics.add(HtComicBrief(
              name, parseTime(infoCol), image, id, parsePages(infoCol)));
        } catch (e) {
          continue;
        }
      }
      int pages;
      try {
        if (searchPage) {
          var result =
              int.parse(document.querySelectorAll("p.result > b")[0].text.nums);
          var comicsOnePage = document
              .querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")
              .length;
          pages = result ~/ comicsOnePage + 1;
        } else {
          var pagesLink = document.querySelectorAll("div.f_left.paginator > a");
          pages = int.parse(pagesLink.last.text);
        }
      } catch (e) {
        pages = 1;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyse", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<HtComicBrief>>> search(String keyword, int page) async {
    if (keyword != "") {
      appdata.searchHistory.remove(keyword);
      appdata.searchHistory.add(keyword);
      await appdata.writeHistory();
    }
    Future.delayed(const Duration(milliseconds: 300),
            () => StateController.find<PreSearchController>().update())
        .onError((error, stackTrace) => null);
    return getComicList(
        "$baseUrl/search/?q=${Uri.encodeComponent(keyword)}&f=_all&s=create_time_DESC&syn=yes",
        page,
        searchPage: true);
  }

  /// 获取漫画详情, subData为第一页的缩略图
  Future<Res<HtComicInfo>> getComicInfo(String id) async {
    Res<String>? res;
    String? lastError;
    for (final url in detailUrls(id)) {
      final candidate = await get(url, cache: false);
      if (!candidate.error) {
        if (!isDetailPage(candidate.data)) {
          lastError = 'WNACG detail page marker not found';
          continue;
        }
        res = candidate;
        break;
      }
      lastError = candidate.errorMessage;
    }
    if (res == null) {
      return Res(null, errorMessage: lastError);
    }
    try {
      var document = parse(res.data);
      var name = document.querySelector("div.userwrap > h2")!.text;
      var coverPath = document
          .querySelector(
              "div.userwrap > div.asTB > div.asTBcell.uwthumb > img")!
          .attributes["src"]!;
      coverPath = resolveUrl(coverPath);
      var labels = document.querySelectorAll("div.asTBcell.uwconn > label");
      final categoryLabel = labels.firstWhere(
        (label) => label.text.contains(RegExp(r'分類|分类')),
        orElse: () => labels.first,
      );
      final category = categoryLabel.text.contains('：')
          ? categoryLabel.text.split('：').sublist(1).join('：').trim()
          : categoryLabel.text.trim();
      final chapters = parseChapterLinks(res.data);
      final countLabel = labels.firstWhere(
        (label) => label.text
            .contains(RegExp(r'頁|页|章|話|话|pages?', caseSensitive: false)),
        orElse: () => labels.length > 1 ? labels[1] : categoryLabel,
      );
      final countText = countLabel.text.split('：').last;
      final pages = chapters?.length ?? parsePages(countText);
      var tagsDom = document.querySelectorAll("a.tagshow");
      var tags = <String, String>{};
      for (var tag in tagsDom) {
        var link = resolveUrl(tag.attributes["href"] ?? '');
        tags[tag.text] = link;
      }
      var description = firstNonEmptyText(document
          .querySelectorAll("div.asTBcell.uwconn > p")
          .map((paragraph) => paragraph.text));
      var uploader =
          document.querySelector("div.asTBcell.uwuinfo > a > p")!.text;
      var avatar = document
          .querySelector("div.asTBcell.uwuinfo > a > img")!
          .attributes["src"]!;
      avatar = resolveUrl(avatar);
      var uploadNum = int.parse(
          document.querySelector("div.asTBcell.uwuinfo > p > font")!.text);
      var photosDom = document.querySelectorAll("div.pic_box.tb > a > img");
      var photos = List<String>.generate(photosDom.length,
          (index) => resolveUrl(photosDom[index].attributes["src"] ?? ''));
      return Res(HtComicInfo(id, coverPath, name, category, pages, tags,
          description, uploader, avatar, uploadNum, photos,
          chapters: chapters));
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyse", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<String>>> getThumbnails(String id, int page) async {
    final root = baseUrl.replaceFirst(RegExp(r'/$'), '');
    var res = await get("$root/photos-index-page-$page-aid-$id.html");
    if (page == 1 && (res.error || !isDetailPage(res.data))) {
      final fallback = await get("$root/photos-index-aid-$id.html");
      if (fallback.error) {
        return Res(null, errorMessage: fallback.errorMessage);
      }
      res = fallback;
    }
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var photosDom = document.querySelectorAll("div.pic_box.tb > a > img");
      var photos = List<String>.generate(photosDom.length,
          (index) => resolveUrl(photosDom[index].attributes["src"] ?? ''));
      return Res(photos);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyse", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<String>>> getImages(String id) async {
    final root = baseUrl.replaceFirst(RegExp(r'/$'), '');
    var res = await get("$root/photos-gallery-aid-$id.html");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      final images = parseImageList(res.data);
      if (images.isEmpty) {
        return const Res.error("图片列表为空");
      }
      return Res(images);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyse", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  /// 获取收藏夹
  ///
  /// 返回Map, 值为收藏夹名，键为ID
  Future<Res<Map<String, String>>> getFolders() async {
    var res = await get("$baseUrl/users-addfav-id-210814.html", cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var data = <String, String>{};
      for (var option in document.querySelectorAll("option")) {
        if (option.attributes["value"] == "") continue;
        data[option.attributes["value"]!] = option.text;
      }
      return Res(data);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyse", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<bool> createFolder(String name) async => !(await post(
          "$baseUrl/users-favc_save-id.html",
          "favc_name=${Uri.encodeComponent(name)}"))
      .error;

  Future<bool> deleteFolder(String id) async => !(await get(
          "$baseUrl/users-favclass_del-id-$id.html"
          "?ajax=true&_t=${Random.secure().nextDouble()}",
          cache: false))
      .error;

  Future<Res<bool>> addFavorite(String comicId, String folderId) async {
    var res = await post(
        "$baseUrl/users-save_fav-id-$comicId.html", "favc_id=$folderId");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    return const Res(true);
  }

  Future<Res<bool>> delFavorite(String favoriteId) async {
    var res = await get(
      "$baseUrl/users-fav_del-id-$favoriteId.html?"
      "ajax=true&_t=${Random.secure().nextDouble()}",
      cache: false,
    );
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    return const Res(true);
  }

  ///获取收藏夹中的漫画
  Future<Res<List<HtComicBrief>>> getFavoriteFolderComics(
      String folderId, int page) async {
    var res = await get(
      "$baseUrl/users-users_fav-page-$page-c-$folderId.html",
      cache: false,
    );
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var comics = <HtComicBrief>[];
      for (var comic in document.querySelectorAll("div.asTB")) {
        var cover = comic
            .querySelector("div.asTBcell.thumb > div > img")!
            .attributes["src"]!;
        cover = resolveUrl(cover);
        var time = comic
            .querySelector("div.box_cel.u_listcon > p.l_catg > span")!
            .text
            .replaceAll("創建時間：", "");
        var name =
            comic.querySelector("div.box_cel.u_listcon > p.l_title > a")!.text;
        var link = comic
            .querySelector("div.box_cel.u_listcon > p.l_title > a")!
            .attributes["href"]!;
        var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
        var info =
            comic.querySelector("div.box_cel.u_listcon > p.l_detla")!.text;
        var pages = int.parse(RegExp(r"(?<=頁數：)[0-9]+").firstMatch(info)![0]!);
        var delUrl = comic
            .querySelector("div.box_cel.u_listcon > p.alopt > a")!
            .attributes["onclick"]!;
        var favoriteId = RegExp(r"(?<=del-id-)[0-9]+").firstMatch(delUrl)![0];
        comics.add(
            HtComicBrief(name, time, cover, id, pages, favoriteId: favoriteId));
      }
      int pages;
      try {
        var pagesLink = document.querySelectorAll("div.f_left.paginator > a");
        pages = int.parse(pagesLink.last.text);
      } catch (e) {
        pages = page;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analyse", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }
}
