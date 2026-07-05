import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cloudflare.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import '../app_dio.dart';
import 'models.dart';
import 'package:html/parser.dart';

export 'models.dart';

class NhentaiNetwork {
  factory NhentaiNetwork() => _cache ?? (_cache = NhentaiNetwork._create());

  NhentaiNetwork._create();

  static const String accessTokenCookie = "access_token";
  static const String refreshTokenCookie = "refresh_token";
  static const String apiKeyCookie = "api_key";
  static const String authHeaderCookie = "authorization";
  static const String _authRefreshHeader = "Pica-Nh-Auth-Refresh";
  static const String _authRetriedExtra = "picaNhAuthRetried";

  static NhentaiNetwork? _cache;

  SingleInstanceCookieJar? cookieJar;

  bool logged = false;

  String baseUrl = "https://nhentai.net";

  late Dio dio;

  Future<void> init() async {
    cookieJar = SingleInstanceCookieJar.instance;
    logged = _hasStoredLogin();
    dio = logDio(BaseOptions(
      headers: {
        "Accept":
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6",
        "Referer": "$baseUrl/",
      },
      validateStatus: (i) => i == 200 || i == 302,
    ));
    dio.interceptors.add(CookieManagerSql(cookieJar!));
    dio.interceptors.add(_NhentaiAuthInterceptor(this));
    dio.interceptors.add(CloudflareInterceptor());
  }

  void logout() async {
    logged = false;
    cookieJar!.deleteUri(Uri.parse(baseUrl));
  }

  bool _hasStoredLogin() {
    final cookies = cookieJar?.loadForRequest(Uri.parse(baseUrl)) ?? const [];
    return cookies.any((cookie) =>
        {
          "sessionid",
          accessTokenCookie,
          refreshTokenCookie,
          apiKeyCookie,
          authHeaderCookie,
        }.contains(cookie.name.toLowerCase()) &&
        cookie.value.isNotEmpty);
  }

  String? _cookieValue(String name) {
    final cookies = cookieJar?.loadForRequest(Uri.parse(baseUrl)) ?? const [];
    for (final cookie in cookies) {
      if (cookie.name.toLowerCase() == name.toLowerCase() &&
          cookie.value.isNotEmpty) {
        return cookie.value;
      }
    }
    return null;
  }

  String? _decodeCookieValue(String name) {
    final value = _cookieValue(name);
    if (value == null) {
      return null;
    }
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String get _apiUserAgent {
    final ua = appdata.implicitData.length > 3 ? appdata.implicitData[3] : "";
    return ua.trim().isEmpty ? webUA : ua.trim();
  }

  String? _authorizationHeader() {
    final apiKey = _decodeCookieValue(apiKeyCookie);
    if (apiKey != null) {
      return "Key $apiKey";
    }

    final savedHeader = _decodeCookieValue(authHeaderCookie);
    if (savedHeader != null) {
      final lower = savedHeader.toLowerCase();
      if (lower.startsWith("key ") ||
          lower.startsWith("user ") ||
          lower.startsWith("bearer ")) {
        return savedHeader;
      }
      return "Key $savedHeader";
    }

    final accessToken = _decodeCookieValue(accessTokenCookie);
    if (accessToken != null) {
      return "User $accessToken";
    }
    return null;
  }

  Future<bool> refreshAuthTokens() async {
    final refreshToken = _decodeCookieValue(refreshTokenCookie);
    if (refreshToken == null) {
      return false;
    }
    try {
      final response = await dio.post(
        "$baseUrl/api/v2/auth/refresh",
        data: {
          refreshTokenCookie: refreshToken,
          "refreshToken": refreshToken,
          "refresh": refreshToken,
        },
        options: Options(
          headers: {_authRefreshHeader: "1"},
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
          validateStatus: (i) => i != null && i >= 200 && i < 300,
        ),
      );
      final data = _jsonData(response.data);
      if (data is Map) {
        _saveTokenCookies(data);
      }
      logged = _authorizationHeader() != null;
      return logged;
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Nhentai Auth", "refresh failed: $e\n$s");
      return false;
    }
  }

  void _saveTokenCookies(Map data) {
    void saveToken(String name, List<String> aliases) {
      String value = "";
      for (final key in [name, ...aliases]) {
        final v = data[key];
        if (v != null && v.toString().isNotEmpty) {
          value = v.toString();
          break;
        }
      }
      final tokens = data["tokens"];
      if (value.isEmpty && tokens is Map) {
        for (final key in [name, ...aliases]) {
          final v = tokens[key];
          if (v != null && v.toString().isNotEmpty) {
            value = v.toString();
            break;
          }
        }
      }
      if (value.isEmpty) {
        return;
      }
      final cookie = Cookie(name, value)
        ..domain = ".nhentai.net"
        ..path = "/";
      cookieJar?.saveFromResponse(Uri.parse(baseUrl), [cookie]);
    }

    saveToken(accessTokenCookie, const ["accessToken", "access", "token"]);
    saveToken(refreshTokenCookie, const ["refreshToken", "refresh"]);
  }

  Future<Res<bool>> validateLogin() async {
    if (cookieJar == null) {
      await init();
    }
    if (_authorizationHeader() == null && !await refreshAuthTokens()) {
      logged = false;
      return const Res(null, errorMessage: "missing auth token");
    }
    final res = await _apiGet("$baseUrl/api/v2/user");
    logged = res.success;
    return res.success ? const Res(true) : Res.fromErrorRes(res);
  }

  Future<Res<String>> get(String url) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res =
          await dio.get<String>(url, options: Options(followRedirects: false));
      if (res.statusCode == 302) {
        var path = res.headers["Location"]?.first ??
            res.headers["location"]?.first ??
            "";
        return get(Uri.parse(url).replace(path: path).toString());
      }
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<String>> post(String url, dynamic data,
      [Map<String, String>? headers]) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res = await dio.post<String>(url,
          data: data, options: Options(headers: headers));
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<dynamic>> _apiGet(String url) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      final res = await dio.get(
        url,
        options: Options(
          responseType: ResponseType.json,
          headers: {"Accept": "application/json"},
          validateStatus: (i) => i != null && i >= 200 && i < 300,
        ),
      );
      return Res(_jsonData(res.data));
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<dynamic>> _apiRequest(
    String method,
    String url, {
    dynamic data,
  }) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      final res = await dio.request(
        url,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.json,
          headers: {"Accept": "application/json"},
          validateStatus: (i) => i != null && i >= 200 && i < 300,
        ),
      );
      return Res(_jsonData(res.data));
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  dynamic _jsonData(dynamic data) {
    if (data is String) {
      try {
        return const JsonDecoder().convert(data);
      } catch (_) {
        return data;
      }
    }
    return data;
  }

  NhentaiComicBrief parseComic(Element comicDom) {
    var img = comicDom.querySelector("a > img")!.attributes["src"]!;
    var name = comicDom.querySelector("div.caption")!.text;
    var id = comicDom.querySelector("a")!.attributes["href"]!.nums;
    var lang = "Unknown";
    var tags = comicDom.attributes["data-tags"] ?? "";
    if (tags.contains("12227")) {
      lang = "English";
    } else if (tags.contains("6346")) {
      lang = "日本語";
    } else if (tags.contains("29963")) {
      lang = "中文";
    }
    var tagsRes = <String>[];
    for (var tag in tags.split(" ")) {
      if (nhentaiTags[tag] != null) {
        tagsRes.add(nhentaiTags[tag]!);
      }
    }
    return NhentaiComicBrief(name, img, id, lang, tagsRes);
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  List? _asList(dynamic value) => value is List ? value : null;

  int _readInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  String _readString(dynamic value) => value?.toString() ?? "";

  String _readTitle(Map<String, dynamic> gallery) {
    final englishTitle = _readString(gallery["english_title"]);
    if (englishTitle.isNotEmpty) {
      return englishTitle;
    }
    final japaneseTitle = _readString(gallery["japanese_title"]);
    if (japaneseTitle.isNotEmpty) {
      return japaneseTitle;
    }
    final title = _asMap(gallery["title"]);
    if (title == null) {
      return "";
    }
    for (final key in const ["english", "pretty", "japanese"]) {
      final value = _readString(title[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return "";
  }

  String _readSubTitle(Map<String, dynamic> gallery) {
    final title = _asMap(gallery["title"]);
    if (title == null) {
      return "";
    }
    final pretty = _readString(title["pretty"]);
    final english = _readString(title["english"]);
    if (pretty.isNotEmpty && pretty != english) {
      return pretty;
    }
    return _readString(title["japanese"]);
  }

  String _readImagePath(dynamic image) {
    if (image is String) {
      return image;
    }
    final imageMap = _asMap(image);
    if (imageMap == null) {
      return "";
    }
    for (final key in const ["path", "url", "thumbnail"]) {
      final value = _readString(imageMap[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return "";
  }

  String _readThumbnailPath(Map<String, dynamic> gallery) {
    final thumbnail = _readImagePath(gallery["thumbnail"]);
    if (thumbnail.isNotEmpty) {
      return thumbnail;
    }
    final cover = _readImagePath(gallery["cover"]);
    if (cover.isNotEmpty) {
      return cover;
    }
    final pages = _asList(gallery["pages"]);
    if (pages != null && pages.isNotEmpty) {
      return _readImagePath(pages.first);
    }
    return "";
  }

  String _remoteImageUrl(String subdomain, String path) {
    if (path.isEmpty) {
      return "";
    }
    if (path.startsWith("http://") || path.startsWith("https://")) {
      return path;
    }
    final normalizedPath = path.startsWith("/") ? path.substring(1) : path;
    return "https://$subdomain.${Uri.parse(baseUrl).host}/$normalizedPath";
  }

  int _parseMediaId(String path) {
    final start = path.indexOf("galleries/");
    if (start < 0) {
      return 0;
    }
    final idStart = start + "galleries/".length;
    final idEnd = path.indexOf("/", idStart);
    if (idEnd < 0) {
      return 0;
    }
    return int.tryParse(path.substring(idStart, idEnd)) ?? 0;
  }

  String _extensionFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith(".gif")) {
      return "gif";
    }
    if (lower.endsWith(".png")) {
      return "png";
    }
    if (lower.endsWith(".webp")) {
      return "webp";
    }
    if (lower.endsWith(".avif")) {
      return "avif";
    }
    return "jpg";
  }

  String _extensionFromImage(dynamic image, String path) {
    if (path.isNotEmpty) {
      return _extensionFromPath(path);
    }
    final imageMap = _asMap(image);
    final type = _readString(imageMap?["t"]);
    if (type.isEmpty) {
      return "jpg";
    }
    return switch (type[0]) {
      "g" => "gif",
      "p" => "png",
      "w" => "webp",
      "a" => "avif",
      _ => "jpg",
    };
  }

  String _fallbackImageUrl(
    String subdomain,
    int mediaId,
    String name,
    String ext,
  ) {
    if (mediaId <= 0) {
      return "";
    }
    return "https://$subdomain.${Uri.parse(baseUrl).host}/galleries/$mediaId/$name.$ext";
  }

  Map<String, List<String>> _readTagGroups(Map<String, dynamic> gallery) {
    final res = <String, List<String>>{};
    final tags = _asList(gallery["tags"]);
    if (tags == null) {
      return res;
    }
    for (final item in tags) {
      final tag = _asMap(item);
      if (tag == null) {
        continue;
      }
      final name = _readString(tag["name"]);
      if (name.isEmpty) {
        continue;
      }
      final type = _readString(tag["type"]);
      final key = switch (type) {
        "artist" => "Artists",
        "category" => "Categories",
        "character" => "Characters",
        "group" => "Groups",
        "language" => "Languages",
        "parody" => "Parodies",
        _ => "Tags",
      };
      res.putIfAbsent(key, () => []).add(name);
    }
    return res;
  }

  String _readLang(Map<String, List<String>> tags) {
    final languages = tags["Languages"] ?? const <String>[];
    final value = languages.join(" ").toLowerCase();
    if (value.contains("chinese")) {
      return "中文";
    }
    if (value.contains("japanese")) {
      return "日本語";
    }
    if (value.contains("english")) {
      return "English";
    }
    return "Unknown";
  }

  NhentaiComicBrief? _parseApiComic(dynamic raw) {
    var gallery = _asMap(raw);
    if (gallery == null) {
      return null;
    }
    gallery = _asMap(gallery["gallery"]) ?? gallery;
    final id = _readInt(gallery["id"]);
    if (id <= 0) {
      return null;
    }
    final title = _readTitle(gallery);
    var thumbnailPath = _readThumbnailPath(gallery);
    var mediaId = _readInt(gallery["media_id"]);
    if (mediaId <= 0) {
      mediaId = _parseMediaId(thumbnailPath);
    }
    final cover = _remoteImageUrl("t", thumbnailPath).isNotEmpty
        ? _remoteImageUrl("t", thumbnailPath)
        : _fallbackImageUrl("t", mediaId, "thumb",
            _extensionFromImage(gallery["thumbnail"], thumbnailPath));
    final tagGroups = _readTagGroups(gallery);
    final tags = tagGroups.values.expand((e) => e).toList();
    return NhentaiComicBrief(
        title, cover, id.toString(), _readLang(tagGroups), tags);
  }

  List<NhentaiComicBrief> _parseApiComicList(dynamic payload) {
    final items = _findApiList(payload);
    if (items == null) {
      return const [];
    }
    return removeNullValue(
      items.map((item) => _parseApiComic(item)).toList(),
    );
  }

  List? _findApiList(dynamic payload) {
    if (payload is List) {
      return payload;
    }
    final map = _asMap(payload);
    if (map == null) {
      return null;
    }
    for (final key in const [
      "result",
      "galleries",
      "favorites",
      "items",
      "data"
    ]) {
      final value = _asList(map[key]);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  int _apiPageCount(dynamic payload, List items) {
    final map = _asMap(payload);
    if (map == null) {
      return 1;
    }
    final pageCount = _readInt(map["num_pages"]);
    if (pageCount > 0) {
      return pageCount;
    }
    final total = _readInt(map["total"]);
    final perPage = _readInt(map["per_page"]);
    if (total > 0 && perPage > 0) {
      return (total / perPage).ceil();
    }
    return items.isEmpty ? 0 : 1;
  }

  String _sortApiValue(NhentaiSort sort) => switch (sort) {
        NhentaiSort.recent => "",
        NhentaiSort.popularToday => "popular-today",
        NhentaiSort.popularWeek => "popular-week",
        NhentaiSort.popularMonth => "popular-month",
        NhentaiSort.popularAll => "popular",
      };

  NhentaiComic? _parseApiComicInfo(dynamic payload, String originalId) {
    final root = _asMap(payload);
    if (root == null) {
      return null;
    }
    final gallery = _asMap(root["gallery"]) ?? root;
    final id = _readInt(gallery["id"]);
    if (id <= 0 && originalId.isNotEmpty) {
      return null;
    }

    final title = _readTitle(gallery);
    final subTitle = _readSubTitle(gallery);
    final coverPath = _readImagePath(gallery["cover"]);
    final thumbnailPath = _readThumbnailPath(gallery);
    var mediaId = _readInt(gallery["media_id"]);
    if (mediaId <= 0) {
      mediaId = _parseMediaId(coverPath.isNotEmpty ? coverPath : thumbnailPath);
    }
    final cover = _remoteImageUrl("t", coverPath).isNotEmpty
        ? _remoteImageUrl("t", coverPath)
        : _fallbackImageUrl("t", mediaId, "cover",
            _extensionFromImage(gallery["cover"], coverPath));
    final tags = _readTagGroups(gallery);
    final favorite = logged &&
        (gallery["favorite"] == true ||
            gallery["is_favorite"] == true ||
            gallery["is_favorited"] == true);
    final thumbnails = _parseApiThumbnails(gallery, mediaId);
    final recommendations =
        _parseApiComicList(gallery["related"] ?? root["related"]);
    return NhentaiComic(
      id <= 0 ? originalId : id.toString(),
      title,
      subTitle,
      cover,
      tags,
      favorite,
      thumbnails,
      recommendations,
      "",
    );
  }

  List<String> _parseApiThumbnails(Map<String, dynamic> gallery, int mediaId) {
    final pages = _asList(gallery["pages"]);
    if (pages == null) {
      return const [];
    }
    final res = <String>[];
    for (var i = 0; i < pages.length; i++) {
      final page = _asMap(pages[i]);
      if (page == null) {
        continue;
      }
      final thumbnailPath = _readImagePath(page["thumbnail"]);
      if (thumbnailPath.isNotEmpty) {
        res.add(_remoteImageUrl("t", thumbnailPath));
        continue;
      }
      final pagePath = _readImagePath(page);
      final ext = _extensionFromImage(page, pagePath);
      res.add(_fallbackImageUrl("t", mediaId, "${i + 1}t", ext));
    }
    return res.where((e) => e.isNotEmpty).toList();
  }

  List<String> _parseApiImages(dynamic payload) {
    var gallery = _asMap(payload);
    if (gallery == null) {
      return const [];
    }
    gallery = _asMap(gallery["gallery"]) ?? gallery;
    final pages = _asList(gallery["pages"]);
    if (pages == null) {
      return const [];
    }
    var mediaId = _readInt(gallery["media_id"]);
    final res = <String>[];
    for (var i = 0; i < pages.length; i++) {
      final page = _asMap(pages[i]);
      if (page == null) {
        continue;
      }
      final pagePath = _readImagePath(page);
      if (pagePath.isNotEmpty) {
        res.add(_remoteImageUrl("i", pagePath));
        continue;
      }
      if (mediaId <= 0) {
        mediaId = _parseMediaId(pagePath);
      }
      final ext = _extensionFromImage(page, pagePath);
      final fallback = _fallbackImageUrl("i", mediaId, "${i + 1}", ext);
      if (fallback.isNotEmpty) {
        res.add(fallback);
      }
    }
    return res;
  }

  String _categoryPathToQuery(String path) {
    final parts = path.split("/").where((part) => part.isNotEmpty).toList();
    if (parts.length < 2) {
      return "";
    }
    final type = parts.first;
    final name = parts.sublist(1).join("/");
    if (type.isEmpty || name.isEmpty) {
      return "";
    }
    return "$type:$name";
  }

  List<T> removeNullValue<T extends Object>(List<T?> list) {
    while (list.remove(null)) {}
    return List.from(list);
  }

  Future<Res<NhentaiHomePageData>> getHomePage([int? page]) async {
    final apiUrl = Uri.parse("$baseUrl/api/v2/galleries").replace(
      queryParameters: {
        if (page != null && page != 1) "page": page.toString(),
      },
    ).toString();
    final apiRes = await _apiGet(apiUrl);
    if (apiRes.success && _findApiList(apiRes.data) != null) {
      return Res(
          NhentaiHomePageData(const [], _parseApiComicList(apiRes.data)));
    }

    var url = baseUrl;
    if (page != null && page != 1) {
      url = "$url?page=$page";
    }
    var res = await get(url);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      List<Element> popularDoms;
      if (url == baseUrl) {
        popularDoms = document.querySelectorAll(
            "div.container.index-container.index-popular > div.gallery");
      } else {
        popularDoms = const [];
      }
      var latest = document
          .querySelectorAll("div.container.index-container > div.gallery");

      return Res(NhentaiHomePageData(
        removeNullValue(List.generate(
            popularDoms.length, (index) => parseComic(popularDoms[index]))),
        removeNullValue(List.generate(latest.length - popularDoms.length,
            (index) => parseComic(latest[index + popularDoms.length]))),
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<bool>> loadMoreHomePageData(NhentaiHomePageData data) async {
    final nextPage = data.page + 1;
    final apiUrl = Uri.parse("$baseUrl/api/v2/galleries").replace(
      queryParameters: {"page": nextPage.toString()},
    ).toString();
    final apiRes = await _apiGet(apiUrl);
    if (apiRes.success && _findApiList(apiRes.data) != null) {
      data.latest.addAll(_parseApiComicList(apiRes.data));
      data.page = nextPage;
      return const Res(true);
    }

    var res = await get("$baseUrl?page=${data.page + 1}");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);

      var latest = document.querySelectorAll("div.gallery");

      data.latest.addAll(removeNullValue(
          List.generate(latest.length, (index) => parseComic(latest[index]))));

      data.page++;

      return const Res(true);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<NhentaiComicBrief>>> search(String keyword, int page,
      [NhentaiSort sort = NhentaiSort.recent]) async {
    if (appdata.searchHistory.contains(keyword)) {
      appdata.searchHistory.remove(keyword);
    }
    appdata.searchHistory.add(keyword);
    appdata.writeHistory();
    final queryParameters = {
      "query": keyword,
      "page": page.toString(),
    };
    final sortValue = _sortApiValue(sort);
    if (sortValue.isNotEmpty) {
      queryParameters["sort"] = sortValue;
    }
    final apiUrl = Uri.parse("$baseUrl/api/v2/search")
        .replace(
          queryParameters: queryParameters,
        )
        .toString();
    final apiRes = await _apiGet(apiUrl);
    final apiItems = _findApiList(apiRes.dataOrNull);
    if (apiRes.success && apiItems != null) {
      return Res(
        _parseApiComicList(apiRes.data),
        subData: _apiPageCount(apiRes.data, apiItems),
      );
    }

    var res = await get(
        "$baseUrl/search?q=${Uri.encodeComponent(keyword)}&page=$page${sort.value}");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);

      var comicDoms = document.querySelectorAll("div.gallery");

      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;

      Future.microtask(() {
        try {
          StateController.find<PreSearchController>().update();
        } catch (e) {
          //
        }
      });

      if (comicDoms.isEmpty) {
        return const Res([], subData: 0);
      }

      return Res(
          removeNullValue(List.generate(
              comicDoms.length, (index) => parseComic(comicDoms[index]))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<NhentaiComic>> getComicInfo(String id) async {
    final apiUrl = id == ""
        ? "$baseUrl/api/v2/galleries/random"
        : "$baseUrl/api/v2/galleries/$id?include=comments%2Crelated";
    final apiRes = await _apiGet(apiUrl);
    if (apiRes.success) {
      final comic = _parseApiComicInfo(apiRes.data, id);
      if (comic != null) {
        return Res(comic);
      }
    }

    Res<String> res;
    if (id == "") {
      res = await get("$baseUrl/random");
      if (res.error) {
        return Res.fromErrorRes(res);
      }
    } else {
      res = await get("$baseUrl/g/$id/");
    }
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      String combineSpans(Element? title) {
        var res = "";
        for (var span in title?.children ?? []) {
          res += span.text;
        }
        return res;
      }

      var document = parse(res.data);

      id = id == "" ? document.querySelector("h3#gallery_id")!.text.nums : id;

      var cover =
          document.querySelector("div#cover > a > img")!.attributes["src"]!;

      var title = combineSpans(document.querySelector("h1.title")!);

      var subTitle = combineSpans(document.querySelector("h2.title"));

      Map<String, List<String>> tags = {};
      for (var field in document.querySelectorAll("div.tag-container")) {
        var fieldName =
            field.firstChild!.text!.removeAllBlank.replaceLast(":", "");
        if (fieldName == "Uploaded") {
          var timeStr = document.querySelector("time")?.attributes["datetime"];
          if (timeStr != null) {
            tags["时间".tl] = [timeToString(DateTime.parse(timeStr))];
            continue;
          }
        }
        tags[fieldName] = [];
        for (var span in field.querySelectorAll("span.name")) {
          tags[fieldName]!.add(span.text);
        }
      }

      bool favorite =
          document.querySelector("button#favorite > span.text")?.text !=
                  "Favorite" &&
              logged;

      var thumbnails = <String>[];
      for (var t in document.querySelectorAll("a.gallerythumb > img")) {
        thumbnails.add(t.attributes["src"]!);
      }

      var recommendations = <NhentaiComicBrief>[];
      for (var comic in document.querySelectorAll("div.gallery")) {
        var c = parseComic(comic);
        recommendations.add(c);
      }
      String token = "";
      try {
        var script = document
            .querySelectorAll("script")
            .firstWhere((element) => element.text.contains("csrf_token"))
            .text;
        token = script.split("csrf_token: \"")[1].split("\",")[0];
      } catch (e) {
        // ignore
      }

      return Res(NhentaiComic(id, title, subTitle, cover, tags, favorite,
          thumbnails, recommendations, token));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<NhentaiComment>>> getComments(String id) async {
    var res = await get("$baseUrl/api/gallery/$id/comments");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var json = const JsonDecoder().convert(res.data);
      var comments = <NhentaiComment>[];
      for (var c in json) {
        comments.add(NhentaiComment(
            c["poster"]["username"],
            "https://i3.nhentai.net/${c["poster"]["avatar_url"]}",
            c["body"],
            c["post_date"]));
      }
      return Res(comments);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<String>>> getImages(String id) async {
    final apiRes = await _apiGet("$baseUrl/api/v2/galleries/$id");
    if (apiRes.success) {
      final images = _parseApiImages(apiRes.data);
      if (images.isNotEmpty) {
        return Res(images);
      }
    }

    var res = await get("$baseUrl/g/$id/1/");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      var scripts = document.querySelectorAll("script");

      var script = scripts
          .firstWhere((element) => element.text.contains("media_id"))
          .text;

      var galleryData = json.decode(json.decode(script)["body"]);

      var url = document
          .querySelector("#image-container > a > img")!
          .attributes["src"]!;

      String baseUrl = url.split('/galleries')[0];

      var images = <String>[];
      for (var image in galleryData["pages"]) {
        images.add("$baseUrl/${image["path"]}");
      }

      return Res(images);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  // 一页 25 个
  Future<Res<List<NhentaiComicBrief>>> getFavorites(int page) async {
    if (!logged && !_hasStoredLogin()) {
      return const Res(null, errorMessage: "login required");
    }
    if (_authorizationHeader() == null && !await refreshAuthTokens()) {
      return const Res(null, errorMessage: "login required");
    }
    final apiUrl = Uri.parse("$baseUrl/api/v2/favorites").replace(
      queryParameters: {"page": page.toString()},
    ).toString();
    final apiRes = await _apiGet(apiUrl);
    final apiItems = _findApiList(apiRes.dataOrNull);
    if (apiRes.success && apiItems != null) {
      logged = true;
      return Res(
        _parseApiComicList(apiRes.data),
        subData: _apiPageCount(apiRes.data, apiItems),
      );
    }
    if (apiRes.error) {
      return Res.fromErrorRes(apiRes);
    }

    var res = await get("$baseUrl/favorites/?page=$page");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      var comics = document.querySelectorAll("div.gallery");
      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;
      return Res(
          removeNullValue(List.generate(
              comics.length, (index) => parseComic(comics[index]))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<bool>> favoriteComic(String id, String token) async {
    if (_authorizationHeader() == null && !await refreshAuthTokens()) {
      return const Res(null, errorMessage: "login required");
    }
    var res =
        await _apiRequest("POST", "$baseUrl/api/v2/galleries/$id/favorite");
    if (res.error) {
      return Res.fromErrorRes(res);
    } else {
      return const Res(true);
    }
  }

  Future<Res<bool>> unfavoriteComic(String id, String token) async {
    if (_authorizationHeader() == null && !await refreshAuthTokens()) {
      return const Res(null, errorMessage: "login required");
    }
    var res =
        await _apiRequest("DELETE", "$baseUrl/api/v2/galleries/$id/favorite");
    if (res.error) {
      return Res.fromErrorRes(res);
    } else {
      return const Res(true);
    }
  }

  Future<Res<List<NhentaiComicBrief>>> getCategoryComics(
      String path, int page, NhentaiSort sort) async {
    final query = _categoryPathToQuery(path);
    if (query.isNotEmpty) {
      final queryParameters = {
        "query": query,
        "page": page.toString(),
      };
      final sortValue = _sortApiValue(sort);
      if (sortValue.isNotEmpty) {
        queryParameters["sort"] = sortValue;
      }
      final apiUrl = Uri.parse("$baseUrl/api/v2/search")
          .replace(
            queryParameters: queryParameters,
          )
          .toString();
      final apiRes = await _apiGet(apiUrl);
      final apiItems = _findApiList(apiRes.dataOrNull);
      if (apiRes.success && apiItems != null) {
        return Res(
          _parseApiComicList(apiRes.data),
          subData: _apiPageCount(apiRes.data, apiItems),
        );
      }
    }

    var param = switch (sort) {
      NhentaiSort.recent => '/',
      NhentaiSort.popularToday => '/popular-today',
      NhentaiSort.popularWeek => '/popular-week',
      NhentaiSort.popularMonth => '/popular-month',
      NhentaiSort.popularAll => '/popular'
    };
    var res = await get("$baseUrl$path$param?page=$page");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);

      var comicDoms = document.querySelectorAll("div.gallery");

      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;

      Future.microtask(() {
        try {
          StateController.find<PreSearchController>().update();
        } catch (e) {
          //
        }
      });

      if (comicDoms.isEmpty) {
        return const Res([], subData: 0);
      }

      return Res(
          removeNullValue(List.generate(
              comicDoms.length, (index) => parseComic(comicDoms[index]))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }
}

enum NhentaiSort {
  recent(""),
  popularToday("&sort=popular-today"),
  popularWeek("&sort=popular-week"),
  popularMonth("&sort=popular-month"),
  popularAll("&sort=popular");

  final String value;

  const NhentaiSort(this.value);

  static NhentaiSort fromValue(String value) {
    switch (value) {
      case "":
        return NhentaiSort.recent;
      case "&sort=popular-today":
        return NhentaiSort.popularToday;
      case "&sort=popular-week":
        return NhentaiSort.popularWeek;
      case "&sort=popular-month":
        return NhentaiSort.popularMonth;
      case "&sort=popular":
        return NhentaiSort.popularAll;
      default:
        return NhentaiSort.recent;
    }
  }
}

class _NhentaiAuthInterceptor extends Interceptor {
  final NhentaiNetwork network;

  _NhentaiAuthInterceptor(this.network);

  bool _isApiV2(Uri uri) => uri.path.startsWith("/api/v2/");

  bool _isRefresh(RequestOptions options) =>
      options.headers[NhentaiNetwork._authRefreshHeader] != null ||
      options.uri.path.startsWith("/api/v2/auth/refresh");

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_isApiV2(options.uri)) {
      options.headers["Accept"] = "application/json";
      options.headers["User-Agent"] = network._apiUserAgent;
      if (!_isRefresh(options) && options.headers["Authorization"] == null) {
        final authorization = network._authorizationHeader();
        if (authorization != null) {
          options.headers["Authorization"] = authorization;
        }
      }
    }
    options.headers.remove(NhentaiNetwork._authRefreshHeader);
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (!_shouldRefresh(err)) {
      handler.next(err);
      return;
    }
    final refreshed = await network.refreshAuthTokens();
    if (!refreshed) {
      handler.next(err);
      return;
    }
    try {
      final options = err.requestOptions;
      options.extra[NhentaiNetwork._authRetriedExtra] = true;
      options.headers.remove("Authorization");
      final response = await network.dio.fetch(options);
      handler.resolve(response);
    } catch (_) {
      handler.next(err);
    }
  }

  bool _shouldRefresh(DioException err) {
    final response = err.response;
    if (response == null) {
      return false;
    }
    final options = response.requestOptions;
    if (!_isApiV2(options.uri) ||
        _isRefresh(options) ||
        options.extra[NhentaiNetwork._authRetriedExtra] == true) {
      return false;
    }
    final code = response.statusCode;
    if (code == HttpStatus.unauthorized) {
      return true;
    }
    if (code != HttpStatus.forbidden) {
      return false;
    }
    final path = options.uri.path;
    return path.startsWith("/api/v2/user") ||
        path.startsWith("/api/v2/favorites") ||
        path.startsWith("/api/v2/blacklist") ||
        path.startsWith("/api/v2/auth/");
  }
}
