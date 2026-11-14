import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/network/favorite_download.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/directory_maintenance.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

import 'nhentai_network/models.dart';
import 'picacg_network/models.dart';

typedef DownloadingCallback = void Function();

class DownloadManager with _DownloadDb implements Listenable {
  static DownloadManager? cache;

  factory DownloadManager() => cache ?? (cache = DownloadManager._create());

  DownloadManager._create();

  ///下载目录
  String? path;

  ///下载队列
  var downloading = Queue<DownloadingItem>();

  final Set<DownloadingItem> _stopping = HashSet<DownloadingItem>.identity();

  bool _startRequestedDuringStop = false;

  bool _pauseRequestedDuringStop = false;

  int _downloadControlGeneration = 0;

  ///是否正在下载
  bool isDownloading = false;

  ///是否出现了错误
  bool _error = false;

  ///是否出现了错误
  bool get error => _error;

  ///是否初始化
  bool _runInit = false;

  static const int _downloadQueueVersion = 1;
  static const String _downloadQueueFileName = 'newDownload.json';

  // Queue snapshots are serialized so a completion callback cannot overwrite
  // a newer snapshot with a slower write.
  Future<void> _queueWriteTail = Future<void>.value();

  @override
  Database? _db;

  final List<VoidCallback> _listeners = [];

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in _listeners) {
      listener();
    }
  }

  ///获取下载目录
  Future<void> _getPath() async {
    if (appdata.settings[22] == "") {
      final appPath = await getApplicationSupportDirectory();
      path = "${appPath.path}/download";
    } else {
      path = appdata.settings[22];
    }
    if (App.isIOS) {
      if (path!.startsWith('/var/mobile/Containers/Data/Application/')) {
        if (!Directory(path!).existsSync()) {
          final appPath = await getApplicationSupportDirectory();
          path = "${appPath.path}/download";
        }
      }
    }
    var dir = Directory(path!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (App.isAndroid) {
      var file = File("$path/.nomedia");
      if (!file.existsSync()) {
        await file.create();
      }
    }
  }

  ///更换下载目录
  Future<String> updatePath(String newPath, {bool transform = true}) async {
    // Stop network writes before copying the directory. Persist the paused
    // progress so the destination can be resumed after a restart without
    // relying on an in-memory queue.
    if (isDownloading) await pause();
    await _saveInfo();
    await _queueWriteTail;
    if (transform) {
      var source = Directory(path!);
      final appPath = await getApplicationSupportDirectory();
      var destination = Directory(
        newPath == "" ? "${appPath.path}${pathSep}download" : newPath,
      );
      try {
        if (source.absolute.path != destination.absolute.path) {
          await migrateDirectory(source, destination);
        }
      } catch (e) {
        return e.toString();
      }
    }

    _runInit = false;
    _db!.dispose();
    downloading.clear();
    await init();
    return "ok";
  }

  ///读取数据, 获取未完成的下载和已下载的漫画ID
  Future<void> _getInfo() async {
    await _queueWriteTail;
    final file = File("$path$pathSep$_downloadQueueFileName");
    await _recoverQueueFiles(file);
    if (!await file.exists()) {
      await _saveInfo();
      return;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      final envelope = _decodeQueueEnvelope(decoded);
      final restored = <DownloadingItem>[];
      for (final rawItem in envelope['downloading'] as List<Object?>) {
        if (rawItem is! Map) {
          throw const FormatException('Invalid download task record');
        }
        restored.add(downloadingItemFromMap(
          Map<String, dynamic>.from(rawItem),
          _onFinish,
          _onError,
          _saveInfo,
        ));
      }
      downloading.addAll(restored);

      // A legacy snapshot has no marker. Rewrite it only after every task has
      // been decoded successfully, keeping migration all-or-nothing.
      if (!envelope.containsKey('version')) {
        try {
          await _preserveLegacyQueueFile(file);
          await _saveInfo();
        } catch (e, s) {
          // A migration backup or replacement failure must not turn a valid
          // legacy queue into an empty queue.
          LogManager.addLog(LogLevel.warning, "IO",
              "Failed to migrate download information\n${safeNetworkError(e)}\n$s");
        }
      }
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "IO",
          "Failed to read downloaded information\n${safeNetworkError(e)}\n$s");
      await _moveQueueFileAside(file, 'corrupt');
      downloading.clear();
      await _saveInfo();
    }
  }

  Map<String, dynamic> _decodeQueueEnvelope(Object? value) {
    if (value is! Map) {
      throw const FormatException('Invalid download queue snapshot');
    }
    final envelope = Map<String, dynamic>.from(value);
    final version = envelope['version'];
    if (version != null && version != _downloadQueueVersion) {
      throw FormatException('Unsupported download queue version: $version');
    }
    final state = envelope['state'];
    if (state != null && state != 'committed') {
      throw const FormatException('Uncommitted download queue snapshot');
    }
    if (envelope['downloading'] is! List) {
      throw const FormatException('Missing download queue records');
    }
    return envelope;
  }

  Future<bool> _isValidQueueFile(File file) async {
    if (!await file.exists()) return false;
    try {
      _decodeQueueEnvelope(jsonDecode(await file.readAsString()));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _recoverQueueFiles(File target) async {
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    final targetValid = await _isValidQueueFile(target);

    if (targetValid) {
      // A valid target is the last committed snapshot. Temporary and backup
      // files are remnants of an earlier atomic replacement.
      if (await temporary.exists()) await temporary.delete();
      if (await backup.exists()) await backup.delete();
      return;
    }

    // A complete temporary snapshot is newer than the previous backup. This
    // is the expected state after the target was moved aside but before the
    // temporary file was renamed into place.
    if (await _isValidQueueFile(temporary)) {
      if (await target.exists()) await _moveQueueFileAside(target, 'corrupt');
      await temporary.rename(target.path);
      if (await backup.exists()) {
        try {
          await backup.delete();
        } catch (e, s) {
          LogManager.addLog(LogLevel.warning, 'IO',
              'Failed to remove stale download snapshot backup\n${safeNetworkError(e)}\n$s');
        }
      }
      return;
    }

    if (await _isValidQueueFile(backup)) {
      if (await target.exists()) await _moveQueueFileAside(target, 'corrupt');
      await backup.rename(target.path);
      return;
    }

    // Keep an incomplete temporary file as evidence for diagnostics and a
    // future manual recovery instead of silently deleting it.
    if (await temporary.exists()) {
      await _moveQueueFileAside(temporary, 'corrupt');
    }
  }

  Future<void> _moveQueueFileAside(File file, String reason) async {
    if (!await file.exists()) return;
    final destination = File(
      '${file.path}.$reason.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await file.rename(destination.path);
    } catch (_) {
      // Rename can fail on some platforms when another reader has the file
      // open. A copy still preserves the original before replacement.
      await file.copy(destination.path);
    }
  }

  Future<void> _preserveLegacyQueueFile(File file) async {
    var destination = File('${file.path}.legacy-v1');
    if (await destination.exists()) {
      destination = File(
          '${file.path}.legacy-v1.${DateTime.now().microsecondsSinceEpoch}');
    }
    await file.copy(destination.path);
  }

  Future<void> _initDb() async {
    var oldData = <String, DownloadedItem>{};
    final databaseFile = File("$path/download.db");
    if (!await databaseFile.exists()) {
      await for (var entity in Directory(path!).list()) {
        if (entity is! Directory) continue;
        final infoFile = File("${entity.path}/info.json");
        if (!await infoFile.exists()) continue;

        final id = entity.name;
        final json = await infoFile.readAsString();
        final time = await infoFile.lastModified();
        final comic = _getComicFromJson(id, json, time);
        if (comic == null) continue;

        try {
          await infoFile.delete();
        } catch (e, s) {
          LogManager.addLog(LogLevel.warning, "IO",
              "Failed to remove legacy download metadata: ${safeNetworkError(e)}\n$s");
        }

        var directory = comic.name;
        var renamedEntity = entity;
        var i = -1;
        while (true) {
          try {
            final target =
                '${entity.parent.path}${Platform.pathSeparator}${sanitizeFileName(directory)}';
            renamedEntity = await renamedEntity.rename(target);
            break;
          } catch (e) {
            i++;
            if (i > 20) {
              // It seems that the error is unrelated to the directory name.
              Log.error("IO",
                  "Failed to rename downloaded directory: ${safeNetworkError(e)}");
              break;
            }
            directory = comic.name + i.toString();
          }
        }
        oldData[renamedEntity.name] = comic;
      }
    }
    _db = sqlite3.open("$path/download.db");
    _createTable();
    for (var entry in oldData.entries) {
      _addToDb(entry.value, entry.key);
    }
  }

  Future<void> dispose() async {
    _runInit = false;
    isDownloading = false;
    for (final item in downloading.toList()) {
      try {
        await item.stop();
      } catch (e, s) {
        LogManager.addLog(LogLevel.error, "Download",
            "Failed to stop download during dispose: ${safeNetworkError(e)}\n$s");
      }
    }
    downloading.clear();
    await _queueWriteTail;
    _db?.dispose();
    _db = null;
  }

  ///初始化下载管理器
  Future<void> init() async {
    if (_runInit) return;
    _runInit = true;
    await _getPath();
    await _getInfo();
    await _initDb();
  }

  ///储存当前的下载队列信息, 每完成一张图片的下载调用一次
  Future<void> _saveInfo() async {
    notifyListeners();
    final data = <String, dynamic>{
      'version': _downloadQueueVersion,
      'state': 'committed',
      'generation': DateTime.now().microsecondsSinceEpoch,
      'downloading': <Map<String, dynamic>>[],
    };
    for (var item in downloading) {
      (data['downloading'] as List<Map<String, dynamic>>).add(item.toMap());
    }
    final targetPath = "$path$pathSep$_downloadQueueFileName";
    final encoded = const JsonEncoder().convert(data);
    final write = _queueWriteTail.then<void>((_) async {
      await _writeQueueSnapshot(File(targetPath), encoded);
    });
    _queueWriteTail = write.catchError((Object error, StackTrace stack) {
      LogManager.addLog(LogLevel.error, 'IO',
          'Failed to save download information\n${safeNetworkError(error)}\n$stack');
    });
    return write;
  }

  /// Queue additions happen from synchronous UI callbacks. Keep their
  /// persistence failure observable in logs without creating an unhandled
  /// future while retaining the awaitable `_saveInfo` API for lifecycle code.
  void _saveInfoDetached() {
    unawaited(_saveInfo().catchError((Object error, StackTrace stack) {
      LogManager.addLog(LogLevel.error, 'IO',
          'Failed to persist download queue\n${safeNetworkError(error)}\n$stack');
    }));
  }

  Future<void> _writeQueueSnapshot(File target, String encoded) async {
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(encoded, flush: true);

    // Keep the previous committed file until the replacement has completed;
    // startup recovery can restore it if the process stops between renames.
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    // Cleanup is best-effort: a valid target is enough to recover on startup.
    if (await backup.exists()) {
      try {
        await backup.delete();
      } catch (e, s) {
        LogManager.addLog(LogLevel.warning, 'IO',
            'Failed to remove download snapshot backup\n${safeNetworkError(e)}\n$s');
      }
    }
  }

  /// move comic to first
  Future<void> moveToFirst(DownloadingItem item) async {
    if (!downloading.any((queued) => identical(queued, item)) ||
        identical(downloading.firstOrNull, item) ||
        _stopping.isNotEmpty) {
      return;
    }
    final wasDownloading = isDownloading;
    if (wasDownloading) await pause();
    if (_stopping.isNotEmpty ||
        !downloading.any((queued) => identical(queued, item))) {
      return;
    }
    _removeDownloadingIdentity(item);
    downloading.addFirst(item);
    if (wasDownloading) start();
    await _saveInfo();
  }

  bool _removeDownloadingIdentity(DownloadingItem item) {
    final items = downloading.toList();
    final index = items.indexWhere((queued) => identical(queued, item));
    if (index < 0) return false;
    items.removeAt(index);
    downloading
      ..clear()
      ..addAll(items);
    return true;
  }

  String generateId(String source, String id) {
    var comicSource = ComicSource.find(source)!;
    if (comicSource.matchBriefIdReg != null) {
      id = RegExp(comicSource.matchBriefIdReg!).firstMatch(id)!.group(1)!;
    }
    id = "$source-$id";
    return id;
  }

  ///当一个下载任务完成时, 调用此函数
  Future<void> _onFinish() async {
    final task = downloading.firstOrNull;
    if (task == null) return;
    if (!_removeDownloadingIdentity(task)) return;
    final nextTask = downloading.firstOrNull;
    final controlGeneration = _downloadControlGeneration;
    try {
      // Commit the durable comic record before removing the queue snapshot.
      // If either conversion or queue persistence fails, restore the task so
      // restart/retry can safely replay an idempotent database upsert.
      _addToDb(await task.toDownloadedItem(), task.directory!);
      await _saveInfo();
    } catch (_) {
      if (!downloading.any((queued) => identical(queued, task))) {
        downloading.addFirst(task);
        notifyListeners();
      }
      rethrow;
    }
    StateController.findOrNull<DownloadPageLogic>()?.refresh();
    if (downloading.isEmpty) {
      isDownloading = false;
      await notifications.endProgress();
    } else if (isDownloading &&
        controlGeneration == _downloadControlGeneration &&
        (nextTask == null || identical(downloading.firstOrNull, nextTask))) {
      downloading.first.start();
    }
  }

  ///暂停下载
  Future<void> pause() async {
    _downloadControlGeneration++;
    isDownloading = false;
    final item = downloading.firstOrNull;
    if (item != null && _stopping.contains(item)) {
      _pauseRequestedDuringStop = true;
      _startRequestedDuringStop = false;
      return;
    }
    if (item != null) await item.pause();
  }

  ///出现错误时调用此函数
  Future<void> _onError() async {
    _error = true;
    notifyListeners();
    try {
      await pause();
    } finally {
      try {
        await notifications.sendNotification("下载出错".tl, "点击查看详情".tl);
      } catch (e, s) {
        LogManager.addLog(LogLevel.warning, "Download",
            "Failed to send download error notification\n${safeNetworkError(e)}\n$s");
      }
    }
  }

  ///开始或继续下载
  void start() {
    if (isDownloading) return;
    final item = downloading.firstOrNull;
    if (item == null) return;
    if (_stopping.contains(item)) {
      _pauseRequestedDuringStop = false;
      _startRequestedDuringStop = true;
      return;
    }
    _downloadControlGeneration++;
    _error = false;
    isDownloading = true;
    item.start();
  }

  ///取消指定的下载
  Future<void> cancel(String id) async {
    final item = downloading.cast<DownloadingItem?>().firstWhere(
          (item) => item?.id == id,
          orElse: () => null,
        );
    if (item == null) return;
    if (_stopping.contains(item)) return;
    final wasFirst = identical(downloading.firstOrNull, item);
    final wasDownloading = isDownloading;

    if (wasFirst) _downloadControlGeneration++;

    if (wasFirst) {
      _error = false;
      isDownloading = false;
      _stopping.add(item);
      try {
        await item.stop();
      } catch (e, s) {
        LogManager.addLog(LogLevel.error, "Download",
            "Failed to remove download: ${safeNetworkError(e)}\n$s");
      } finally {
        _removeDownloadingIdentity(item);
        _stopping.remove(item);
      }
    } else {
      _removeDownloadingIdentity(item);
    }

    final shouldResume = wasFirst &&
        !_pauseRequestedDuringStop &&
        (wasDownloading || _startRequestedDuringStop);
    if (wasFirst) {
      _startRequestedDuringStop = false;
      _pauseRequestedDuringStop = false;
    }

    notifyListeners();

    if (downloading.isEmpty) {
      isDownloading = false;
      await notifications.endProgress();
    } else if (shouldResume) {
      start();
    }
    await _saveInfo();
  }

  Future<DownloadedItem?> getComicOrNull(String id) async {
    return _getComicWithDb(id);
  }

  ///删除已下载的漫画
  Future<void> delete(List<String> ids) async {
    for (var id in ids) {
      var comic = Directory("$path/${getDirectory(id)}");
      try {
        await comic.delete(recursive: true);
      } catch (e) {
        if (e is PathNotFoundException) {
          //忽略
        } else {
          // Keep the durable database row when the filesystem operation
          // fails; it is the only record that can make the deletion
          // retryable after a restart.
          rethrow;
        }
      }
      _deleteFromDb(id);
      _DownloadDb.clearDirectoryCache(id);
    }
  }

  /// return error message when error, or null if success.
  Future<String?> deleteEpisode(DownloadedItem comic, int ep) async {
    try {
      if (comic.downloadedEps.length == 1) {
        return "Delete Error: only one downloaded episode";
      }
      final episodeDirectory =
          Directory("$path/${getDirectory(comic.id)}/${ep + 1}");
      if (await episodeDirectory.exists()) {
        await episodeDirectory.delete(recursive: true);
      }
      var size = await Directory("$path/${getDirectory(comic.id)}").getMBSize();
      comic.downloadedEps.remove(ep);
      comic.comicSize = size;
      _addToDb(comic, comic.directory ?? getDirectory(comic.id));
      return null;
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
      return e.toString();
    }
  }

  /// 获取漫画章节的长度, 适用于有章节的漫画
  Future<int> getEpLength(String id, int ep) async {
    var directory = Directory("$path/${getDirectory(id)}/$ep");
    var files = directory.list();
    return files.length;
  }

  /// 获取漫画的长度, 适用于无章节的漫画
  Future<int> getComicLength(String id) async {
    var directory = Directory("$path/${getDirectory(id)}");
    var files = directory.list();
    return await files.length - 1;
  }

  ///获取图片, 对于无章节的漫画, ep参数为0
  File getImage(String id, int ep, int index) {
    String downloadPath;
    if (ep == 0) {
      downloadPath = "$path/${getDirectory(id)}/";
    } else {
      downloadPath = "$path/${getDirectory(id)}/$ep/";
    }
    for (var file in Directory(downloadPath).listSync()) {
      if (file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "") ==
          index.toString()) {
        return file as File;
      }
    }
    throw Exception("File not found");
  }

  Future<File> getImageAsync(String id, int ep, int index) async {
    String downloadPath;
    if (ep == 0) {
      downloadPath = "$path/${getDirectory(id)}/";
    } else {
      downloadPath = "$path/${getDirectory(id)}/$ep/";
    }
    var fileName = _downloadedFileName["$id$ep$index"];
    if (fileName != null) {
      return File(downloadPath + fileName);
    }
    await for (var file in Directory(downloadPath).list()) {
      var i = file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "");
      if (i.isNum) {
        if (_downloadedFileName.length > 2000) {
          _downloadedFileName.remove(_downloadedFileName.keys.first);
        }
        _downloadedFileName["$id$ep$i"] = file.name;
      }
    }
    if (_downloadedFileName["$id$ep$index"] == null) {
      throw Exception("File not found");
    }
    return File(downloadPath + _downloadedFileName["$id$ep$index"]!);
  }

  static final _downloadedFileName = <String, String>{};

  ///获取封面, 所有漫画源通用
  File getCover(String id) {
    return File("$path/${getDirectory(id)}/cover.jpg");
  }
}

DownloadingItem downloadingItemFromMap(
    Map<String, dynamic> map,
    DownloadProgressCallback whenFinish,
    DownloadProgressCallback whenError,
    Future<void> Function() updateInfo) {
  switch (map["type"]) {
    case 0:
      return PicDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 1:
      return EhDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 2:
      return JmDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 3:
      return HitomiDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 4:
      return DownloadingHtComic.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 5:
      return NhentaiDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 6:
      return CustomDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 7:
      return FavoriteDownloading.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    default:
      throw UnimplementedError();
  }
}

extension AddDownloadExt on DownloadManager {
  ///添加哔咔漫画下载
  void addPicDownload(ComicItem comic, List<int> downloadEps) {
    downloading.addLast(PicDownloadingItem(
        comic, downloadEps, _onFinish, _onError, _saveInfo, comic.id));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  ///添加E-Hentai下载
  void addEhDownload(Gallery gallery, [int type = 0]) {
    final id = getGalleryId(gallery.link);
    downloading.addLast(
        EhDownloadingItem(gallery, _onFinish, _onError, _saveInfo, id, type));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  ///添加禁漫下载
  void addJmDownload(JmComicInfo comic, List<int> downloadEps) {
    downloading.addLast(JmDownloadingItem(
        comic, downloadEps, _onFinish, _onError, _saveInfo, "jm${comic.id}"));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  ///添加Hitomi下载
  void addHitomiDownload(HitomiComic comic, String cover, String link) {
    final id = "hitomi${comic.id}";
    downloading.addLast(HitomiDownloadingItem(
        comic, cover, link, _onFinish, _onError, _saveInfo, id));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  ///添加绅士漫画下载
  void addHtDownload(HtComicInfo comic) {
    final id = "Ht${comic.id}";
    downloading
        .addLast(DownloadingHtComic(comic, _onFinish, _onError, _saveInfo, id));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  void addNhentaiDownload(NhentaiComic comic) {
    final id = "nhentai${comic.id}";
    downloading.addLast(
        NhentaiDownloadingItem(comic, _onFinish, _onError, _saveInfo, id));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  void addCustomDownload(ComicInfoData comic, List<int> downloadEps) {
    var id = generateId(comic.sourceKey, comic.comicId);
    downloading.addLast(CustomDownloadingItem(
        comic, downloadEps, _onFinish, _onError, _saveInfo, id));
    _saveInfoDetached();
    if (!isDownloading) start();
  }

  void addFavoriteDownload(FavoriteItem comic) {
    var id = switch (comic.type.key) {
      0 => comic.target,
      1 => getGalleryId(comic.target),
      2 => "jm${comic.target}",
      3 => "hitomi${RegExp(r"\d+(?=\.html)").firstMatch(comic.target)![0]!}",
      4 => "Ht${comic.target}",
      6 => "nhentai${comic.target}",
      _ => generateId(comic.type.comicSource.key, comic.target)
    };
    downloading.addLast(
        FavoriteDownloading(comic, _onFinish, _onError, _saveInfo, id));
    _saveInfoDetached();
    if (!isDownloading) start();
  }
}

DownloadedItem? _getComicFromJson(String id, String json, DateTime time,
    [String? directory]) {
  DownloadedItem comic;
  try {
    if (id.contains('-')) {
      comic = CustomDownloadedItem.fromJson(jsonDecode(json));
    } else if (id.startsWith("jm")) {
      comic = DownloadedJmComic.fromMap(jsonDecode(json));
    } else if (id.startsWith("hitomi")) {
      comic = DownloadedHitomiComic.fromMap(jsonDecode(json));
    } else if (id.startsWith("nhentai")) {
      comic = NhentaiDownloadedComic.fromJson(jsonDecode(json));
    } else if (id.startsWith("Ht")) {
      comic = DownloadedHtComic.fromJson(jsonDecode(json));
    } else if (id.isNum) {
      comic = DownloadedGallery.fromJson(jsonDecode(json));
    } else {
      comic = DownloadedComic.fromJson(jsonDecode(json));
    }
    comic.time = time;
    comic.directory = directory;
    return comic;
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO",
        "Failed to get downloaded comic info:\n${safeNetworkError(e)}\n$s");
    return null;
  }
}

abstract mixin class _DownloadDb {
  Database? get _db;

  void _createTable() {
    _db!.execute('''
      create table if not exists download (
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size int,
        json text
      )
    ''');
  }

  void _addToDb(DownloadedItem item, String directory, [DateTime? time]) {
    _db!.execute('''
      insert or replace into download
      values (?,?,?,?,?,?,?)
    ''', [
      item.id,
      item.name,
      item.subTitle,
      (time ?? DateTime.now()).millisecondsSinceEpoch,
      directory,
      item.comicSize,
      jsonEncode(item.toJson()),
    ]);
  }

  bool isExists(String id) {
    var result = _db!.select('''
      select id from download
      where id = ?
    ''', [id]);
    return result.isNotEmpty;
  }

  void _deleteFromDb(String id) {
    _db!.execute('''
      delete from download
      where id = ?
    ''', [id]);
  }

  DownloadedItem? _getComicWithDb(String id) {
    var result = _db!.select('''
      select * from download
      where id = ?
    ''', [id]);
    if (result.isEmpty) return null;
    var data = result.first;
    return _getComicFromJson(
      data['id'],
      data['json'],
      DateTime.fromMillisecondsSinceEpoch(data['time']),
      data['directory'],
    );
  }

  int get total {
    var result = _db!.select('''
      select count(*) from download
    ''');
    return result.first['count(*)'];
  }

  static const _orderColumns = <String, String>{
    'time': 'time',
    'title': 'title',
    'subtitle': 'subtitle',
    'size': 'size',
  };

  /// order: time, title, subtitle, size
  List<DownloadedItem> getAll(
      [String order = 'time', String direction = 'desc']) {
    final column = _orderColumns[order];
    if (column == null) {
      throw ArgumentError.value(order, 'order', 'Unsupported download sort');
    }
    final normalizedDirection = direction.toLowerCase();
    if (normalizedDirection != 'asc' && normalizedDirection != 'desc') {
      throw ArgumentError.value(direction, 'direction', 'Expected ASC or DESC');
    }
    final sqlDirection = normalizedDirection.toUpperCase();
    var result = _db!.select('''
      select * from download
      order by $column $sqlDirection, id ASC
    ''');
    return result
        .map(
          (e) => _getComicFromJson(e['id'], e['json'],
              DateTime.fromMillisecondsSinceEpoch(e['time']), e['directory'])!,
        )
        .toList();
  }

  static final _cache = <String, String>{};

  static void clearDirectoryCache(String id) => _cache.remove(id);

  String getDirectory(String id) {
    var directory = _cache[id];
    if (directory == null) {
      var result = _db!.select('''
      select directory from download
      where id = ?
    ''', [id]);
      directory = result.first['directory'];
      directory = _findAccurateDirectory(directory!);
      if (_cache.length > 50) {
        _cache.remove(_cache.keys.first);
      }
      _cache[id] = directory;
    }
    return directory;
  }

  String _findAccurateDirectory(String directory) {
    return sanitizeFileName(directory);
  }
}
