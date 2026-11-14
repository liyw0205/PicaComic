import 'dart:async';
import 'dart:isolate';
import 'package:dio/dio.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/file_downloader.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'dart:io';
import '../../tools/io_tools.dart';
import '../download.dart';
import 'eh_main_network.dart';
import 'get_gallery_id.dart';
import '../network_logging.dart';
import 'archive_utils.dart';

class DownloadedGallery extends DownloadedItem {
  Gallery gallery;
  double? size;
  DownloadedGallery(this.gallery, this.size);

  @override
  Map<String, dynamic> toJson() => {"gallery": gallery.toJson(), "size": size};
  DownloadedGallery.fromJson(Map<String, dynamic> map)
      : gallery = Gallery.fromJson(map["gallery"]),
        size = map["size"];

  @override
  DownloadType get type => DownloadType.ehentai;

  @override
  List<int> get downloadedEps => [0];

  @override
  List<String> get eps => ["EP 1"];

  @override
  String get name {
    if (appdata.settings[78] == "1") {
      return gallery.subTitle ?? gallery.title;
    } else {
      return gallery.title;
    }
  }

  @override
  String get id => getGalleryId(gallery.link);

  @override
  String get subTitle => gallery.uploader;

  @override
  double? get comicSize => size;

  @override
  set comicSize(double? value) {
    size = value;
  }

  List<String> _getTags() {
    var res = <String>[];
    for (final values in gallery.tags.values) {
      res.addAll(values);
    }
    return res;
  }

  @override
  List<String> get tags => _getTags();
}

///e-hentai的下载进程模型
class EhDownloadingItem extends DownloadingItem {
  EhDownloadingItem(this.gallery, super.whenFinish, super.onError,
      super.updateInfo, super.id, this.downloadType,
      {super.type = DownloadType.ehentai});

  ///画廊模型
  final Gallery gallery;

  final int downloadType;

  @override
  Map<String, String> get headers => {
        "Cookie": EhNetwork().cookiesStr,
        "User-Agent": webUA,
        "Referer": EhNetwork().ehBaseUrl,
      };

  @override
  String get cover =>
      gallery.coverPath.replaceFirst('s.exhentai.org', 'ehgt.org');

  @override
  String get title => gallery.title;

  @override
  Future<Map<int, List<String>>> getLinks() async {
    return {
      0: List.generate(
          (int.parse(gallery.maxPage)), (index) => (index + 1).toString())
    };
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return ImageManager().getEhImageNew(gallery, int.parse(link));
  }

  @override
  Map<String, dynamic> toMap() => {
        "gallery": gallery.toJson(),
        "downloadType": downloadType,
        "_downloadLink": _downloadLink,
        "_currentBytes": _currentBytes,
        "_totalBytes": _totalBytes,
        ...super.toBaseMap()
      };

  @override
  Future<void> onStart() async {
    await super.onStart();
    // clear showKey and imageKey
    // imageKey is saved through the network cache mechanism
    gallery.auth?.remove("showKey");
    await CacheManager().deleteKeyword("exhentai.org");
    await CacheManager().deleteKeyword("e-hentai.org");
  }

  int? _currentBytes;

  int? _totalBytes;

  @override
  int get totalPages {
    if (downloadType == 0) {
      return super.totalPages;
    } else {
      return _totalBytes ?? 1;
    }
  }

  @override
  int get downloadedPages {
    if (downloadType == 0) {
      return super.downloadedPages;
    } else {
      return _currentBytes ?? 0;
    }
  }

  EhArchiveDownloader? _downloader;

  bool _stop = false;
  int _archiveRun = 0;
  CancelToken? _archiveStartToken;

  String? _downloadLink;

  int _currentSpeed = 0;

  @override
  int get currentSpeed =>
      downloadType == 0 ? super.currentSpeed : _currentSpeed;

  @override
  start() async {
    if (downloadType == 0) {
      return super.start();
    } else {
      final run = ++_archiveRun;
      _stop = false;
      _archiveStartToken?.cancel('Archive run superseded');
      final startToken = CancelToken();
      _archiveStartToken = startToken;
      try {
        await onStart();
        if (!_isArchiveRunActive(run)) return;
        await downloadCover(
          shouldContinue: () => _isArchiveRunActive(run),
          cancelToken: startToken,
        );
        if (!_isArchiveRunActive(run)) return;
        if (gallery.auth?["archiveDownload"] == null) {
          throw "No archive download link";
        }
        if (_downloadLink == null) {
          var res = await EhNetwork().getArchiveDownloadLink(
              gallery.auth!["archiveDownload"]!, downloadType,
              cancelToken: startToken);
          if (!_isArchiveRunActive(run)) return;
          if (res.error) {
            throw res.errorMessage!;
          }
          _downloadLink = res.data;
        }
        _downloader = EhArchiveDownloader(
          _downloadLink!,
          path,
          (current, total, speed) {
            if (!_isArchiveRunActive(run)) return;
            _currentBytes = current;
            _totalBytes = total;
            _currentSpeed = speed;
            updateInfo?.call();
          },
          () {
            if (_isArchiveRunActive(run)) {
              unawaited(Future<void>.sync(() => onError?.call()).catchError(
                  (error, stack) => log("${safeNetworkError(error)}\n$stack",
                      "Download", LogLevel.error)));
            }
          },
          () {
            if (_isArchiveRunActive(run)) {
              finish();
            }
          },
        );
        await _downloader!.start();
      } catch (e, s) {
        if (!_isArchiveRunActive(run)) return;
        log("${safeNetworkError(e)}\n$s", "Download", LogLevel.error);
        await onError?.call();
        return;
      }
    }
  }

  void finish() {
    unawaited(Future<void>.sync(() => onFinish?.call()).catchError((error,
            stack) =>
        log("${safeNetworkError(error)}\n$stack", "Download", LogLevel.error)));
  }

  bool _isArchiveRunActive(int run) =>
      run == _archiveRun &&
      !_stop &&
      DownloadManager().isDownloading &&
      identical(DownloadManager().downloading.firstOrNull, this);

  @override
  Future<void> pause() async {
    if (downloadType == 0) {
      await super.pause();
    } else {
      _archiveRun++;
      _stop = true;
      _archiveStartToken?.cancel('Archive task paused');
      _archiveStartToken = null;
      await _downloader?.pause();
    }
  }

  @override
  Future<void> stop() async {
    if (downloadType == 0) {
      await super.stop();
    } else {
      _archiveRun++;
      _stop = true;
      _archiveStartToken?.cancel('Archive task stopped');
      _archiveStartToken = null;
      await stopAndDeleteEhArchiveDirectory(
        path: path,
        stopWorker: _downloader?.stop,
      );
      _downloader = null;
    }
  }

  EhDownloadingItem.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : gallery = Gallery.fromJson(map["gallery"]),
        downloadType = map["downloadType"],
        _currentBytes = map["_currentBytes"],
        _totalBytes = map["_totalBytes"],
        _downloadLink = map["_downloadLink"],
        super.fromMap(map, whenFinish, whenError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async {
    return DownloadedGallery(gallery, await getFolderSize(Directory(path)));
  }
}

Future<void> stopAndDeleteEhArchiveDirectory({
  required String path,
  required Future<void> Function()? stopWorker,
}) async {
  await stopWorker?.call();
  final directory = Directory(path);
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

class EhArchiveDownloader {
  final String url;
  final String savePath;
  final void Function(int current, int total, int speed) updateInfo;
  final void Function() onError;
  final void Function() onFinished;
  final Future<String?> Function() _proxyProvider;
  final Completer<void> _stopped = Completer<void>();

  late ReceivePort port;
  SendPort? sendPort;
  Isolate? isolate;
  Future<Isolate>? _spawnFuture;
  bool _stopRequested = false;
  bool _started = false;
  bool _portClosed = false;

  EhArchiveDownloader(
      this.url, this.savePath, this.updateInfo, this.onError, this.onFinished,
      {Future<String?> Function()? proxyProvider})
      : _proxyProvider = proxyProvider ?? getProxy;

  void _closePort() {
    if (_portClosed) return;
    _portClosed = true;
    port.close();
  }

  Future<void> stop() async {
    if (_stopped.isCompleted) return;
    _stopRequested = true;
    if (!_started) {
      _stopped.complete();
      return;
    }
    if (_spawnFuture == null) {
      _closePort();
      if (!_stopped.isCompleted) _stopped.complete();
      return;
    }
    sendPort?.send("stop");
    try {
      await _stopped.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (isolate == null && _spawnFuture != null) {
        try {
          isolate = await _spawnFuture!;
        } catch (_) {}
      }
      isolate?.kill(priority: Isolate.immediate);
      await _stopped.future;
    }
  }

  Future<void> pause() => stop();

  Future<void> start() async {
    if (_started) throw StateError('Archive downloader already started');
    if (_stopRequested || _stopped.isCompleted) return;
    _started = true;
    port = ReceivePort();
    var total = 0;
    port.listen((message) {
      if (message is SendPort) {
        sendPort = message;
        if (_stopRequested) message.send("stop");
      } else if (message is DownloadingStatus) {
        updateInfo(message.downloadedBytes, message.totalBytes + 1,
            message.bytesPerSecond);
        total = message.totalBytes;
      } else if (message == "finish") {
        isolate?.kill(priority: Isolate.immediate);
        isolate = null;
        _closePort();
        if (!_stopped.isCompleted) _stopped.complete();
        updateInfo(total + 1, total + 1, 0);
        onFinished();
      } else if (message == "stopped") {
        isolate = null;
        _closePort();
        if (!_stopped.isCompleted) _stopped.complete();
      } else if (message is _DownloadException) {
        isolate?.kill(priority: Isolate.immediate);
        isolate = null;
        _closePort();
        if (!_stopped.isCompleted) _stopped.complete();
        LogManager.addLog(LogLevel.error, "Download", message.message);
        onError();
      } else if (message is List) {
        isolate?.kill(priority: Isolate.immediate);
        isolate = null;
        _closePort();
        if (!_stopped.isCompleted) _stopped.complete();
        LogManager.addLog(LogLevel.error, "Download",
            "Archive worker failed (${message.isEmpty ? 'unknown' : message.first.runtimeType})");
        onError();
      } else if (message == null && !_stopped.isCompleted) {
        isolate = null;
        _closePort();
        _stopped.complete();
        if (!_stopRequested) onError();
      }
    });
    try {
      final proxy = await _proxyProvider();
      if (_stopRequested || _stopped.isCompleted) {
        _closePort();
        if (!_stopped.isCompleted) _stopped.complete();
        return;
      }
      _spawnFuture = Isolate.spawn<_DownloadData>(
          _run, _DownloadData(port.sendPort, url, savePath, proxy),
          onError: port.sendPort, onExit: port.sendPort);
      isolate = await _spawnFuture!;
      if (_stopRequested || _stopped.isCompleted) {
        if (_stopped.isCompleted) {
          isolate?.kill(priority: Isolate.immediate);
          isolate = null;
        } else {
          sendPort?.send("stop");
        }
        return;
      }
    } catch (_) {
      if (!_stopped.isCompleted) _stopped.complete();
      _closePort();
      rethrow;
    }
    if (_stopRequested) sendPort?.send("stop");
  }

  static Future<void> _run(_DownloadData data) async {
    final receivePort = ReceivePort();
    final sendPort = data.port;
    sendPort.send(receivePort.sendPort);

    FileDownloader? task;
    var stopRequested = false;
    var committed = false;
    Directory? extractionDir;
    Directory? stagingDir;

    receivePort.listen((message) {
      if (message == "stop") {
        stopRequested = true;
        unawaited(task?.stop());
      }
    });

    try {
      task = FileDownloader(data.url, "${data.savePath}/temp.zip", data.proxy);
      if (stopRequested) {
        await task.stop();
        sendPort.send("stopped");
        return;
      }

      await for (final status in task.start()) {
        sendPort.send(status);
      }
      if (stopRequested) throw const _DownloadStopped();

      final archivePath = "${data.savePath}/temp.zip";
      final extractionPath = "${data.savePath}/extract-temp";
      final outputDirectory = Directory(extractionPath);
      extractionDir = outputDirectory;
      final stagingDirectory = Directory("${data.savePath}/stage-temp");
      stagingDir = stagingDirectory;
      if (await outputDirectory.exists()) {
        await outputDirectory.delete(recursive: true);
      }
      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }

      verifyNoArchiveSymbolicLinks(archivePath);
      final archive = ZipFile.openRead(archivePath);
      late final int expectedPageCount;
      try {
        final entries = archive.getAllEntries();
        if (entries.isEmpty) throw const FormatException("Archive is empty");
        for (final entry in entries) {
          if (!isSafeArchivePath(entry.name)) {
            throw const FormatException("Archive contains an unsafe path");
          }
        }
        expectedPageCount = countArchivePageFiles(
            entries.where((entry) => !entry.isDir).map((entry) => entry.name));
      } finally {
        archive.close();
      }

      ZipFile.openAndExtract(archivePath, extractionPath);
      if (stopRequested) throw const _DownloadStopped();
      final files = await outputDirectory
          .list(recursive: true, followLinks: false)
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      files.sort((a, b) => compareNaturalArchivePaths(a.path, b.path));
      final candidates = files.where((file) {
        return isArchivePageFileName(file.uri.pathSegments.last);
      }).toList();
      if (candidates.isEmpty) {
        throw const FormatException("Archive has no image files");
      }
      verifyArchivePageCount(expectedPageCount, candidates.length);

      final stagedFiles = <File>[];
      for (var index = 0; index < candidates.length; index++) {
        if (stopRequested) throw const _DownloadStopped();
        final source = candidates[index];
        if (!await isValidArchiveImage(source)) {
          throw const FormatException("Archive contains an invalid image");
        }
        await stagingDirectory.create(recursive: true);
        final extension = source.uri.pathSegments.last.split('.').last;
        final staged = File("${stagingDirectory.path}/$index.$extension");
        await source.rename(staged.path);
        stagedFiles.add(staged);
      }

      await outputDirectory.delete(recursive: true);
      extractionDir = null;
      final backupDir = Directory("${stagingDirectory.path}/backup");
      final backups = <String, File>{};
      final installed = <File>[];
      try {
        for (final staged in stagedFiles) {
          if (stopRequested) throw const _DownloadStopped();
          final name = staged.uri.pathSegments.last;
          final target = File("${data.savePath}/$name");
          if (await target.exists()) {
            await backupDir.create(recursive: true);
            final backup = File("${backupDir.path}/$name");
            await target.rename(backup.path);
            backups[target.path] = backup;
          }
          await staged.rename(target.path);
          installed.add(target);
        }
        if (stopRequested) throw const _DownloadStopped();
        committed = true;
      } catch (_) {
        for (final target in installed.reversed) {
          if (await target.exists()) await target.delete();
        }
        for (final entry in backups.entries) {
          if (await entry.value.exists()) {
            await entry.value.rename(entry.key);
          }
        }
        rethrow;
      }

      try {
        await stagingDirectory.delete(recursive: true);
      } catch (_) {}
      try {
        await File(archivePath).delete();
      } catch (_) {}
      sendPort.send("finish");
    } catch (e, s) {
      for (final directory in [extractionDir, if (!committed) stagingDir]) {
        if (directory == null) continue;
        try {
          if (await directory.exists()) await directory.delete(recursive: true);
        } catch (_) {}
      }
      if (stopRequested || e is _DownloadStopped) {
        await task?.stop();
        sendPort.send("stopped");
        return;
      }
      sendPort.send(_DownloadException("${safeNetworkError(e)}\n$s"));
    } finally {
      receivePort.close();
    }
  }
}

class _DownloadData {
  final SendPort port;
  final String url;
  final String savePath;
  final String? proxy;

  const _DownloadData(this.port, this.url, this.savePath, this.proxy);
}

class _DownloadException {
  final String message;

  const _DownloadException(this.message);
}

class _DownloadStopped implements Exception {
  const _DownloadStopped();
}
