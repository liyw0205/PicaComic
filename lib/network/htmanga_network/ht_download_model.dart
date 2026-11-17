import 'dart:async';
import 'dart:io';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/download_model.dart';
import '../../foundation/image_manager.dart';
import '../../tools/io_tools.dart';

class DownloadedHtComic extends DownloadedItem {
  DownloadedHtComic(this.comic, this.size, [List<int>? downloadedEps])
      : _downloadedEps = downloadedEps ??
            (comic.chapters?.isNotEmpty != true
                ? [0]
                : List<int>.generate(comic.chapters!.length, (index) => index));

  HtComicInfo comic;

  double? size;

  final List<int> _downloadedEps;

  @override
  double? get comicSize => size;

  @override
  List<int> get downloadedEps => _downloadedEps;

  @override
  List<String> get eps => comic.chapters?.isNotEmpty == true
      ? comic.chapters!.values.toList()
      : ["EP 1"];

  @override
  String get id => "Ht${comic.id}";

  @override
  String get name => comic.name;

  @override
  String get subTitle => comic.uploader;

  @override
  DownloadType get type => DownloadType.htmanga;

  @override
  Map<String, dynamic> toJson() => {
        "comic": comic.toJson(),
        "size": size,
        "downloadedEps": _downloadedEps,
      };

  DownloadedHtComic.fromJson(Map<String, dynamic> json)
      : comic = HtComicInfo.fromJson(json["comic"]),
        size = json["size"],
        _downloadedEps = (json["downloadedEps"] as List?)?.cast<int>() ??
            ((json["comic"]["chapters"] as Map?)?.isNotEmpty != true
                ? [0]
                : List<int>.generate((json["comic"]["chapters"] as Map).length,
                    (index) => index));

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => comic.tags.keys.toList();
}

class DownloadingHtComic extends DownloadingItem {
  DownloadingHtComic(
      this.comic, super.whenFinish, super.whenError, super.updateInfo, super.id,
      {super.type = DownloadType.htmanga});

  final HtComicInfo comic;

  String _getCover() {
    var uri = comic.coverPath;
    if (uri.contains("https:") && !uri.contains("https://")) {
      uri = uri.replaceFirst("https:", "https://");
    }
    return uri;
  }

  @override
  String get cover => _getCover();

  @override
  String get title => comic.name;

  @override
  Future<Map<int, List<String>>> getLinks() async {
    final chapters = comic.chapters;
    if (chapters == null || chapters.isEmpty) {
      var res = await HtmangaNetwork().getImages(comic.id);
      return {0: res.data};
    }
    final links = <int, List<String>>{};
    for (final entry in chapters.keys.toList().asMap().entries) {
      final res = await HtmangaNetwork().getImages(entry.value);
      if (res.error || res.data.isEmpty) {
        throw StateError(
            'Failed to load WNACG chapter ${entry.key + 1}: ${res.errorMessage ?? "empty image list"}');
      }
      links[entry.key + 1] = res.data;
    }
    return links;
  }

  @override
  bool get haveEps => comic.chapters?.isNotEmpty == true;

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return ImageManager().getImage(link);
  }

  @override
  Map<String, dynamic> toMap() =>
      {"comic": comic.toJson(), ...super.toBaseMap()};

  DownloadingHtComic.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : comic = HtComicInfo.fromJson(map["comic"]),
        super.fromMap(map, whenFinish, whenError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async {
    return DownloadedHtComic(
      comic,
      await getFolderSize(Directory(path)),
      comic.chapters?.isNotEmpty != true
          ? [0]
          : List<int>.generate(comic.chapters!.length, (index) => index),
    );
  }
}
