import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/hitomi_network/search.dart';
import 'package:pica_comic/network/hitomi_network/search_sort.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/extensions.dart';
import '../../base.dart';
import '../../foundation/log.dart';
import '../http_client.dart';
import '../res.dart';
import '../search_language.dart';
import 'fetch_data.dart';
import 'hitomi_models.dart';
import 'image.dart';

/// 用于 hitomi.la 的网络请求类
class HiNetwork {
  factory HiNetwork() => cache == null ? (cache = HiNetwork._create()) : cache!;

  HiNetwork._create();

  static HiNetwork? cache;

  String get baseDomain => appdata.settings[87];

  static String _hitomiLink(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.startsWith('http')) return value;
    if (value.startsWith('//')) return 'https:$value';
    return Uri.parse('https://hitomi.la/').resolve(value).toString();
  }

  static String _cdnLink(String raw, String domain) {
    final value = raw.trim();
    if (value.isEmpty || value.startsWith('http')) return value;
    if (value.startsWith('//')) return 'https:$value';
    return Uri.parse('https://$domain/').resolve(value).toString();
  }

  static Iterable<Map<String, dynamic>> _maps(dynamic value) sync* {
    if (value is! Iterable) return;
    for (final item in value) {
      if (item is Map) yield Map<String, dynamic>.from(item);
    }
  }

  static String _coverFromSrcset(String srcset, String domain) {
    final candidate = srcset
        .split(',')
        .map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (candidate.isEmpty) return '';
    final url = _cdnLink(candidate.split(RegExp(r'\s+')).first, domain);
    final uri = Uri.tryParse(url);
    if (uri == null || uri.path.isEmpty) return '';
    var path = uri.path;
    path = path.replaceFirst('avifbigtn', 'webpbigtn');
    if (path.endsWith('.avif')) {
      path = '${path.substring(0, path.length - 5)}.webp';
    }
    return Uri(
      scheme: 'https',
      host: 'atn.$domain',
      path: path,
    ).toString();
  }

  /// Decode the JavaScript assignment returned by the Hitomi gallery API.
  ///
  /// The response is not always a bare JSON document, so only the outer JSON
  /// object is passed to the decoder.
  static Map<String, dynamic> decodeGalleryJson(String source) {
    final start = source.indexOf('{');
    final end = source.lastIndexOf('}');
    if (start < 0 || end < start) {
      throw const FormatException('Gallery JSON object is missing');
    }
    final decoded =
        const JsonDecoder().convert(source.substring(start, end + 1));
    if (decoded is! Map) {
      throw const FormatException('Gallery JSON must be an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static bool _flag(dynamic value) =>
      value == true || value == 1 || value == '1' || value == 'true';

  static int _intValue(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  Future<String> _coverFromGalleryJson(
      String id, Map<String, dynamic> json) async {
    final file = _maps(json['files']).firstOrNull;
    if (file == null) return '';
    final hash = file['hash']?.toString() ?? '';
    if (hash.isEmpty) return '';
    final image = HitomiFile(
      file['name']?.toString() ?? '',
      hash,
      _flag(file['haswebp']),
      _flag(file['hasavif']),
      _intValue(file['height']),
      _intValue(file['width']),
      id,
    );
    final extension = image.preferredExtension;
    try {
      return await GG()
          .urlFromUrlFromHash(id, image, '${extension}bigtn', extension);
    } catch (_) {
      return '';
    }
  }

  /// Build a brief from the current gallery JSON shape without relying on the
  /// legacy HTML gallery-block endpoint.
  static HitomiComicBrief briefFromGalleryJson(
    String id,
    Map<String, dynamic> json, {
    String cover = '',
  }) {
    final galleryUrl = json['galleryurl']?.toString();
    final link = galleryUrl == null || galleryUrl.isEmpty
        ? 'https://hitomi.la/galleries/$id.html'
        : galleryUrl.startsWith('http')
            ? galleryUrl
            : _hitomiLink(galleryUrl);
    final tags = <Tag>[];
    final rawTags = json['tags'];
    if (rawTags is List) {
      for (final rawTag in rawTags) {
        if (rawTag is! Map || rawTag['tag'] == null) continue;
        var name = rawTag['tag'].toString();
        if (_flag(rawTag['female'])) name += ' ♀';
        if (_flag(rawTag['male'])) name += ' ♂';
        final rawLink = rawTag['url']?.toString() ?? '';
        tags.add(Tag(
          name,
          _hitomiLink(rawLink),
        ));
      }
    }
    final artists = <String>[];
    final rawArtists = json['artists'];
    if (rawArtists is List) {
      for (final rawArtist in rawArtists) {
        if (rawArtist is Map && rawArtist['artist'] != null) {
          artists.add(rawArtist['artist'].toString());
        }
      }
    }
    return HitomiComicBrief(
      json['title']?.toString() ?? id,
      json['type']?.toString() ?? '',
      json['language']?.toString() ?? '',
      tags,
      json['date']?.toString() ?? '',
      artists.isEmpty ? 'N/A' : artists.first,
      link,
      cover,
    );
  }

  ///基本的get请求
  Future<Res<String>> get(String url,
      {CacheExpiredTime expiredTime = CacheExpiredTime.short}) async {
    try {
      var options = BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
          headers: {"User-Agent": webUA, "Referer": "https://hitomi.la/"});
      var dio = CachedNetwork();
      var res = await dio.get(url, options, expiredTime: expiredTime);
      return Res(res.data);
    } catch (e) {
      return Res(null,
          errorMessage: e.toString() == "null" ? "未知错误" : e.toString());
    }
  }

  ///从一个漫画列表中获取所有的漫画
  Future<Res<ComicList>> getComics(String url) async {
    var comicList = ComicList(url);
    var res = await loadNextPage(comicList);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage!);
    } else {
      return Res(comicList);
    }
  }

  Future<Res<bool>> loadNextPage(ComicList comicList) async {
    if (comicList.toLoad >= comicList.total) return const Res(false);
    var comicIds = await fetchComicData(comicList.url, comicList.toLoad,
        maxLength: comicList.total);
    if (comicIds.error) {
      return Res(false, errorMessage: comicIds.errorMessage!);
    }
    comicList.total = int.parse(comicIds.subData);
    comicList.toLoad += 100;
    comicList.comicIds.addAll(comicIds.data);
    return const Res(true);
  }

  ///获取一个漫画的简略信息
  Future<Res<HitomiComicBrief>> getComicInfoBrief(String id) async {
    Future<HitomiComicBrief?> parseHtml(Res<String> response) async {
      if (response.error) return null;
      try {
        var comicDiv = parse(response.data);
        var name = comicDiv.querySelector("h1.lillie > a")!.text;
        var link = comicDiv.querySelector("h1.lillie > a")!.attributes["href"]!;
        link = _hitomiLink(link);
        var artist = comicDiv.querySelector("div.artist-list a")?.text ?? "N/A";
        String cover;
        try {
          cover = comicDiv
                  .querySelector("div.dj-img1 > picture > source")
                  ?.attributes["data-srcset"] ??
              comicDiv
                  .querySelector("div.cg-img1 > picture > source")!
                  .attributes["data-srcset"]!;
          cover = _coverFromSrcset(cover, baseDomain);
        } catch (e) {
          cover = "";
        }
        var table =
            comicDiv.querySelectorAll("div.dj-content > table.dj-desc > tbody");
        String type = "", lang = "";
        var tags = <Tag>[];
        for (var tr in table[0].children) {
          if (tr.firstChild!.text == "Type") {
            type = tr.children[1].text;
          } else if (tr.firstChild!.text == "Language") {
            lang = tr.children[1].text;
          } else if (tr.firstChild!.text == "Series") {
            for (var liA
                in tr.querySelectorAll("td.series-list > ul > li > a")) {
              if (liA.text != "N/A") {
                tags.add(
                    Tag(liA.text, _hitomiLink(liA.attributes["href"] ?? '')));
              }
            }
          } else if (tr.firstChild!.text == "Tags") {
            for (var liA
                in tr.querySelectorAll("td.relatedtags > ul > li > a")) {
              tags.add(
                  Tag(liA.text, _hitomiLink(liA.attributes["href"] ?? '')));
            }
          }
        }
        var time = comicDiv.querySelector("div.dj-content > p")!.text;
        return HitomiComicBrief(
            name, type, lang, tags, time, artist, link, cover);
      } catch (_) {
        return null;
      }
    }

    final gallery = await _getGalleryJson(id);
    if (!gallery.error) {
      try {
        final cover = await _coverFromGalleryJson(id, gallery.data);
        return Res(briefFromGalleryJson(id, gallery.data, cover: cover));
      } catch (e, s) {
        LogManager.addLog(
            LogLevel.error, "Data Analysis", "${safeNetworkError(e)}\n$s");
      }
    }

    // Older mirrors may expose only the legacy HTML block endpoint.
    final block = await parseHtml(
        await get("https://ltn.$baseDomain/galleryblock/$id.html"));
    if (block != null) return Res(block);
    return Res(null, errorMessage: gallery.errorMessage ?? "解析失败");
  }

  Future<Res<Map<String, dynamic>>> _getGalleryJson(String id) async {
    final res = await get("https://ltn.$baseDomain/galleries/$id.js");
    if (res.error) return Res(null, errorMessage: res.errorMessage);
    try {
      return Res(decodeGalleryJson(res.data));
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Data Analysis", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  ///搜索Hitomi
  Future<Res<List<int>>> search(String keyword,
      {HitomiSearchSort sort = HitomiSearchSort.dateAdded}) async {
    await setNetworkProxy();
    try {
      var searchEngine = HitomiSearch(
          withDefaultSearchLanguage(
              keyword, int.tryParse(appdata.settings[69]) ?? 0),
          sort: sort);
      var res = await searchEngine.search();
      return Res(res.data);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Network", "${safeNetworkError(e)}\n$s");
      return Res(null, errorMessage: "$e");
    }
  }

  ///获取漫画信息
  Future<Res<HitomiComic>> getComicInfo(String target) async {
    String id;
    if (target.isNum) {
      id = target;
    } else {
      final match = RegExp(r"\d+(?=\.html(?:$|[?#]))").firstMatch(target) ??
          RegExp(r"\d+").firstMatch(target);
      if (match == null) {
        return const Res.error("无效的漫画链接");
      }
      id = match[0]!;
    }
    var brief = await getComicInfoBrief(id);
    if (brief.error) {
      return Res(null, errorMessage: brief.errorMessage!);
    }
    final gallery = await _getGalleryJson(id);
    if (gallery.error) {
      return Res(null, errorMessage: gallery.errorMessage);
    }
    // 返回一个 JS 脚本，图片 URL 也在这里面。
    final json = gallery.data;
    var parodys = <Tag>[];
    var characters = <Tag>[];
    var tags = <Tag>[];
    var files = <HitomiFile>[];

    for (final parody in _maps(json["parodys"])) {
      final name = parody["parody"]?.toString();
      if (name == null || name.isEmpty) continue;
      parodys.add(Tag(
          name, _cdnLink(parody["url"]?.toString() ?? '', 'ltn.$baseDomain')));
    }

    for (final character in _maps(json["characters"])) {
      final name = character["character"]?.toString();
      if (name == null || name.isEmpty) continue;
      characters.add(Tag(name,
          _cdnLink(character["url"]?.toString() ?? '', 'ltn.$baseDomain')));
    }

    for (final tag in _maps(json["tags"])) {
      final tagName = tag["tag"]?.toString();
      if (tagName == null || tagName.isEmpty) continue;
      var text = tagName;
      if (_flag(tag["female"])) text += " ♀";
      if (_flag(tag["male"])) text += " ♂";
      tags.add(
          Tag(text, _cdnLink(tag["url"]?.toString() ?? '', 'ltn.$baseDomain')));
    }

    for (final file in _maps(json["files"])) {
      files.add(HitomiFile(
        file["name"]?.toString() ?? '',
        file["hash"]?.toString() ?? '',
        _flag(file["haswebp"]),
        _flag(file["hasavif"]),
        _intValue(file["height"]),
        _intValue(file["width"]),
        id,
      ));
    }

    return Res(HitomiComic(
      id,
      json["title"]?.toString() ?? id,
      (json["related"] is List)
          ? (json["related"] as List)
              .whereType<num>()
              .map((e) => e.toInt())
              .toList()
          : <int>[],
      json["type"]?.toString() ?? "",
      (json["artists"] is List)
          ? (json["artists"] as List)
              .whereType<Map>()
              .map((e) => e["artist"]?.toString())
              .whereType<String>()
              .toList()
          : <String>[],
      json["language"]?.toString() ?? "",
      parodys,
      characters,
      tags,
      json["date"]?.toString() ?? "",
      files,
      (json["groups"] is List)
          ? (json["groups"] as List)
              .whereType<Map>()
              .map((e) => e["group"]?.toString())
              .whereType<String>()
              .toList()
          : <String>[],
      brief.data.cover,
    ));
  }
}
