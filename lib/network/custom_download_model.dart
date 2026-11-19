import 'dart:io';

import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download_model.dart';

import '../tools/io_tools.dart';
import 'download.dart';

class CustomDownloadedItem extends DownloadedItem {
  @override
  double? comicSize;

  @override
  final List<int> downloadedEps;

  final Map<String, String>? chapters;

  @override
  List<String> get eps =>
      chapters?.isNotEmpty == true ? chapters!.values.toList() : ["EP 1"];

  final String comicId;

  @override
  final String id;

  @override
  final String name;

  @override
  final String subTitle;

  @override
  final List<String> tags;

  @override
  DownloadType get type => DownloadType.other;

  final String sourceKey;

  final String sourceName;

  final String cover;

  CustomDownloadedItem(
      this.comicSize,
      this.downloadedEps,
      Map<String, String>? chapters,
      this.id,
      this.name,
      this.subTitle,
      this.tags,
      this.sourceKey,
      this.sourceName,
      this.cover,
      this.comicId)
      : chapters = chapters?.isEmpty == true ? null : chapters;

  @override
  Map<String, dynamic> toJson() => {
        "comicSize": comicSize,
        "downloadedEps": downloadedEps,
        "chapters": chapters,
        "id": id,
        "name": name,
        "subTitle": subTitle,
        "tags": tags,
        "sourceKey": sourceKey,
        "sourceName": sourceName,
        "cover": cover,
        "comicId": comicId
      };

  CustomDownloadedItem.fromJson(Map<String, dynamic> json)
      : comicSize = json["comicSize"],
        downloadedEps = List<int>.from(json["downloadedEps"]),
        chapters = (json["chapters"] as Map?)?.isNotEmpty == true
            ? (json["chapters"] as Map)
                .map((key, value) => MapEntry(key.toString(), value.toString()))
            : null,
        id = json["id"],
        name = json["name"],
        subTitle = json["subTitle"],
        tags = List<String>.from(json["tags"]),
        sourceKey = json["sourceKey"],
        sourceName = json["sourceName"],
        cover = json["cover"],
        comicId = json["comicId"];
}

/// Applies refreshed source chapters only when downloaded directories keep
/// pointing at the same chapter IDs.
CustomDownloadedItem refreshCustomDownloadedChapters(
    CustomDownloadedItem item, Map<String, String> latestChapters) {
  final storedChapters = item.chapters;
  if (storedChapters == null || storedChapters.isEmpty) {
    throw StateError('单话下载记录不能切换为分章节目录');
  }
  if (latestChapters.isEmpty) {
    throw StateError('漫画源没有返回章节信息');
  }

  final storedEntries = storedChapters.entries.toList();
  final latestEntries = latestChapters.entries.toList();
  if (storedChapters.keys.any((id) => id.trim().isEmpty) ||
      latestChapters.keys.any((id) => id.trim().isEmpty)) {
    throw StateError('章节信息不完整，已保留旧下载章节');
  }
  final seenIndexes = <int>{};
  for (final index in item.downloadedEps) {
    if (index < 0 ||
        index >= storedEntries.length ||
        index >= latestEntries.length ||
        !seenIndexes.add(index) ||
        storedEntries[index].key != latestEntries[index].key) {
      throw StateError('章节顺序已变化，已保留旧下载章节');
    }
  }

  var unchanged = storedChapters.length == latestChapters.length;
  if (unchanged) {
    for (var index = 0; index < storedEntries.length; index++) {
      final stored = storedEntries[index];
      final latest = latestEntries[index];
      if (stored.key != latest.key || stored.value != latest.value) {
        unchanged = false;
        break;
      }
    }
  }
  if (unchanged) return item;

  return CustomDownloadedItem(
    item.comicSize,
    List<int>.of(item.downloadedEps),
    Map<String, String>.from(latestChapters),
    item.id,
    item.name,
    item.subTitle,
    item.tags,
    item.sourceKey,
    item.sourceName,
    item.cover,
    item.comicId,
  )
    ..time = item.time
    ..directory = item.directory;
}

class CustomDownloadingItem extends DownloadingItem {
  CustomDownloadingItem(this.comic, this._downloadEps, super.whenFinish,
      super.whenError, super.updateInfo, super.id,
      {super.type = DownloadType.other})
      : source = ComicSource.find(comic.sourceKey)!;

  final ComicInfoData comic;

  final List<int> _downloadEps;

  late final ComicSource source;

  @override
  String get cover => comic.cover;

  @override
  bool get haveEps => comic.chapters?.isNotEmpty == true;

  Stream<DownloadProgress> _getImage(String url) async* {
    if (source.getImageLoadingConfig != null) {
      int ep = links!.keys.elementAt(downloadingEp);
      var config = await source.getImageLoadingConfig!(url, comic.comicId,
          comic.chapters?.keys.elementAtOrNull(ep - 1) ?? comic.comicId);
      yield* ImageManager()
          .getImage(config["url"] ?? url, Map.from(config['headers'] ?? {}));
      return;
    }
    yield* ImageManager().getImage(url);
  }

  @override
  Map<String, String> get headers => {
        "User-Agent": webUA,
      };

  Future<void> getOneEp(int i, Map<int, List<String>> links) async {
    if (links[i + 1] != null) return;

    int retry = 0;

    while (retry < 3) {
      try {
        links[i + 1] = (await source.loadComicPages!(
                comic.comicId, comic.chapters!.keys.elementAt(i)))
            .data;
        return;
      } catch (e) {
        await Future.delayed(const Duration(seconds: 3));
        retry++;
      }
    }

    throw Exception("Failed to get chapters");
  }

  @override
  Future<Map<int, List<String>>> getLinks() async {
    var links = <int, List<String>>{};
    if (comic.chapters?.isNotEmpty == true) {
      var futures = <Future>[];
      for (var i in _downloadEps) {
        futures.add(getOneEp(i, links));
        await Future.delayed(const Duration(milliseconds: 200));
        if (futures.length % 5 == 0) {
          await Future.wait(futures);
          futures.clear();
        }
      }
      await Future.wait(futures);
    } else {
      var res = await source.loadComicPages!(comic.comicId, null);
      links[0] = res.data;
    }
    return links;
  }

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toMap() => {
        "comic": comic.toJson(),
        "_downloadEps": _downloadEps,
        ...super.toBaseMap()
      };

  CustomDownloadingItem.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : comic = ComicInfoData.fromJson(map["comic"]),
        _downloadEps = List<int>.from(map["_downloadEps"]),
        super.fromMap(map, whenFinish, whenError, updateInfo) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  @override
  Future<DownloadedItem> toDownloadedItem() async {
    var previous = <int>[];
    if (DownloadManager().isExists(id)) {
      var comic = await DownloadManager().getComicOrNull(id);
      previous = comic!.downloadedEps;
    }
    var downloaded = (_downloadEps + previous).toSet().toList();
    downloaded.sort();
    var tags = <String>[];
    comic.tags.forEach((key, value) => tags.addAll(value));
    return CustomDownloadedItem(
      await getFolderSize(Directory(path)),
      downloaded,
      comic.chapters,
      id,
      comic.title,
      comic.subTitle ?? "",
      tags,
      comic.sourceKey,
      source.name,
      comic.cover,
      comic.comicId,
    );
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return _getImage(link);
  }
}
