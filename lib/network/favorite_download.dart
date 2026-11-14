import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/network/network_logging.dart';

class FavoriteDownloading extends DownloadingItem {
  FavoriteDownloading(
      this.comic, super.whenFinish, super.onError, super.updateInfo, super.id,
      {super.type = DownloadType.favorite,
      @visibleForTesting Future<DownloadingItem> Function()? loadDownloadLogic})
      : _loadDownloadLogicForTesting = loadDownloadLogic;

  FavoriteItem comic;

  late DownloadingItem downloadLogic;
  int _startGeneration = 0;
  final Future<DownloadingItem> Function()? _loadDownloadLogicForTesting;
  Future<DownloadingItem>? _pendingDownloadLogic;

  @override
  void start() {
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_startGeneration;
    final manager = DownloadManager();
    try {
      final previousDirectory = directory;
      await super.onStart();
      if (!_isActiveStart(generation, manager)) {
        return;
      }
      if (directory != previousDirectory) {
        await updateInfo?.call();
        if (!_isActiveStart(generation, manager)) return;
      }
      final logic = await _loadDownloadLogicOnce();
      if (!_isActiveStart(generation, manager)) {
        return;
      }
      logic.directory = directory;
      downloadLogic = logic;
      final removed = manager.downloading.removeFirst();
      if (!identical(removed, this)) {
        manager.downloading.addFirst(removed);
        return;
      }
      manager.downloading.addFirst(logic);
      await updateInfo?.call();
      if (generation != _startGeneration ||
          !identical(manager.downloading.firstOrNull, logic) ||
          !manager.isDownloading) {
        return;
      }
      logic.start();
    } catch (e, s) {
      if (!_isActiveStart(generation, manager)) return;
      Log.error("Download", "${safeNetworkError(e)}\n$s");
      try {
        await onError?.call();
      } catch (callbackError, callbackStack) {
        Log.error(
            "Download", "${safeNetworkError(callbackError)}\n$callbackStack");
      }
    }
  }

  bool _isActiveStart(int generation, DownloadManager manager) =>
      generation == _startGeneration &&
      identical(manager.downloading.firstOrNull, this) &&
      manager.isDownloading;

  Future<DownloadingItem> _loadDownloadLogicOnce() {
    final pending = _pendingDownloadLogic;
    if (pending != null) return pending;

    late final Future<DownloadingItem> request;
    request = (_loadDownloadLogicForTesting?.call() ?? _loadDownloadLogic())
        .whenComplete(() {
      if (identical(_pendingDownloadLogic, request)) {
        _pendingDownloadLogic = null;
      }
    });
    _pendingDownloadLogic = request;
    return request;
  }

  Future<DownloadingItem> _loadDownloadLogic() async {
    switch (comic.type.key) {
      case 0:
        final comicItem = await PicacgNetwork().getComicInfo(comic.target);
        return PicDownloadingItem(
            comicItem.data,
            List.generate(comicItem.data.eps.length, (index) => index),
            onFinish,
            onError,
            updateInfo,
            id);
      case 1:
        final gallery = await EhNetwork().getGalleryInfo(comic.target);
        return EhDownloadingItem(
            gallery.data, onFinish, onError, updateInfo, id, 0);
      case 2:
        final jmComic = await JmNetwork().getComicInfo(comic.target);
        final downloadedEp =
            List.generate(jmComic.data.epNames.length, (index) => index);
        if (downloadedEp.isEmpty) downloadedEp.add(0);
        return JmDownloadingItem(
            jmComic.data, downloadedEp, onFinish, onError, updateInfo, id);
      case 3:
        final hitomiComic = await HiNetwork().getComicInfo(comic.target);
        return HitomiDownloadingItem(hitomiComic.data, comic.coverPath,
            comic.target, onFinish, onError, updateInfo, id);
      case 4:
        final htComic = await HtmangaNetwork().getComicInfo(comic.target);
        return DownloadingHtComic(
            htComic.data, onFinish, onError, updateInfo, id);
      case 6:
        final nhComic = await NhentaiNetwork().getComicInfo(comic.target);
        return NhentaiDownloadingItem(
            nhComic.data, onFinish, onError, updateInfo, id);
      default:
        final comicSource = comic.type.comicSource;
        final comicInfoData = await comicSource.loadComicInfo!(comic.target);
        final downloadedEp = List.generate(
            comicInfoData.data.chapters?.length ?? 0, (index) => index);
        return CustomDownloadingItem(comicInfoData.data, downloadedEp, onFinish,
            onError, updateInfo, id);
    }
  }

  @override
  Future<void> pause() async {
    _startGeneration++;
    await super.pause();
  }

  @override
  Future<void> stop() async {
    _startGeneration++;
    await super.stop();
  }

  @override
  String get cover => comic.coverPath;

  @override
  Future<Map<int, List<String>>> getLinks() => downloadLogic.getLinks();

  @override
  String get title => comic.name;

  @override
  Map<String, dynamic> toMap() {
    return {"comic": comic.toJson(), ...toBaseMap()};
  }

  FavoriteDownloading.fromMap(
      Map<String, dynamic> json,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : comic = FavoriteItem.fromJson(json["comic"]),
        _loadDownloadLogicForTesting = null,
        super.fromMap(json, whenFinish, whenError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() =>
      downloadLogic.toDownloadedItem();

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return downloadLogic.downloadImage(link);
  }
}
