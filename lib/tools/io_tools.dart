import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart' show ZipFileEncoder;
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/tools/data_backup.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:zip_flutter/zip_flutter.dart';

import '../foundation/app.dart';

Future<double> getFolderSize(Directory path) async {
  double total = 0;
  for (var f in path.listSync(recursive: true)) {
    if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file) {
      total += File(f.path).lengthSync() / 1024 / 1024;
    }
  }
  return total;
}

Future<bool> exportComic(String id, String name,
    [List<String>? epNames]) async {
  try {
    name = sanitizeFileName(name);
    var data = ExportComicData(
      id,
      downloadManager.path!,
      name,
      epNames,
      downloadManager.getDirectory(id),
    );
    var res = await compute(runningExportComic, data);
    if (!res) {
      return false;
    }

    if (App.isMobile) {
      var params =
          SaveFileDialogParams(sourceFilePath: '${data.path}$pathSep$name.zip');
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final FileSaveLocation? result =
          await getSaveLocation(suggestedName: '$name.zip');

      if (result != null) {
        const String mimeType = 'application/zip';
        final XFile textFile =
            XFile('${data.path}$pathSep$name.zip', mimeType: mimeType);
        await textFile.saveTo(result.path);
      }
    }

    var file = File('${data.path}$pathSep$name.zip');
    file.delete();
    return true;
  } catch (e) {
    return false;
  }
}

Future<bool> exportComics(List<DownloadedItem> comics) async {
  try {
    var exportDatas = <ExportComicData>[];
    for (var comic in comics) {
      var id = comic.id;
      var name = sanitizeFileName(comic.name);
      var path = downloadManager.path;
      var epNames = comic.eps;
      exportDatas.add(ExportComicData(
        id,
        path!,
        name,
        epNames,
        downloadManager.getDirectory(id),
      ));
    }
    await Isolate.run(() => runningExportComics(exportDatas));
    if (App.isMobile) {
      var params = SaveFileDialogParams(
          sourceFilePath: '${downloadManager.path}/comics.zip');
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final FileSaveLocation? result =
          await getSaveLocation(suggestedName: 'comics.zip');

      if (result != null) {
        const String mimeType = 'application/zip';
        final XFile textFile =
            XFile('${downloadManager.path}/comics.zip', mimeType: mimeType);
        await textFile.saveTo(result.path);
      }
    }
    var file = File('${downloadManager.path}/comics.zip');
    if (file.existsSync()) {
      file.delete();
    }
    return true;
  } catch (e) {
    return false;
  }
}

Future<bool> exportPdf(String pdfPath) async {
  try {
    final source = File(pdfPath);
    if (!await source.exists()) {
      return false;
    }
    var saved = false;
    if (App.isMobile) {
      var params = SaveFileDialogParams(sourceFilePath: pdfPath);
      saved = await FlutterFileDialog.saveFile(params: params) != null;
    } else {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: File(pdfPath).name,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'pdf', extensions: ['pdf'])
        ],
      );

      if (result != null) {
        const String mimeType = 'application/pdf';
        final XFile textFile = XFile(pdfPath, mimeType: mimeType);
        await textFile.saveTo(result.path);
        saved = true;
      }
    }
    if (saved && await source.exists()) {
      await source.delete();
    }
    return saved;
  } catch (e) {
    return false;
  }
}

class ExportComicData {
  String id;
  String path;
  String name;
  String directory;
  List<String>? epNames;

  ExportComicData(this.id, this.path, this.name, this.epNames, this.directory);
}

Future<bool> runningExportComic(ExportComicData data) async {
  final fileName = '${data.path}/${data.name}.zip';
  try {
    final path = Directory("${data.path}/${data.directory}");
    var zipFile = ZipFile.open(fileName);
    String? currentDirName;

    void walk(String path) {
      for (var entry in Directory(path).listSync()) {
        if (entry is Directory) {
          var index = int.parse(entry.name) - 1;
          currentDirName = sanitizeFileName(
              data.epNames?.elementAtOrNull(index) ?? "Chapter ${index + 1}");
          walk(entry.path);
        } else {
          var filePathInZip = sanitizeFileName(data.name);
          if (currentDirName != null) {
            filePathInZip += "/$currentDirName";
          }
          filePathInZip += "/${entry.name}";
          zipFile.addFile(filePathInZip, entry.path);
        }
      }
    }

    walk(path.path);
    zipFile.close();
    return true;
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
    return false;
  }
}

Future<bool> runningExportComics(List<ExportComicData> datas) async {
  try {
    var result = "${datas.first.path}/comics.zip";
    if (File(result).existsSync()) {
      File(result).deleteSync();
    }
    var zipFile = ZipFile.open(result);
    for (var data in datas) {
      final directory = Directory('${data.path}/${data.directory}');

      String? currentDirName;

      void walk(String path) {
        for (var entry in Directory(path).listSync()) {
          if (entry is Directory) {
            var index = int.parse(entry.name) - 1;
            currentDirName = sanitizeFileName(
                data.epNames?.elementAtOrNull(index) ?? "Chapter ${index + 1}");
            walk(entry.path);
          } else {
            var filePathInZip = sanitizeFileName(data.name);
            if (currentDirName != null) {
              filePathInZip += "/$currentDirName";
            }
            filePathInZip += "/${entry.name}";
            zipFile.addFile(filePathInZip, entry.path);
          }
        }
      }

      walk(directory.path);
    }
    zipFile.close();
    return true;
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
    return false;
  }
}

Future<void> eraseCache() async {
  return CacheManager().clear();
}

Future<void> copyDirectory(Directory source, Directory destination) async {
  try {
    await destination.create(recursive: true);
    await for (final content in source.list()) {
      String newPath = destination.path +
          Platform.pathSeparator +
          content.path.split(Platform.pathSeparator).last;

      if (content is File) {
        await content.copy(newPath);
      } else if (content is Directory) {
        Directory newDirectory = Directory(newPath);
        await copyDirectory(content.absolute, newDirectory.absolute);
      }
    }
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
    rethrow;
  }
}

/// move all files and directories from source to destination
Future<void> moveDirectory(Directory source, Directory destination) async {
  try {
    source = source.absolute;
    destination = destination.absolute;
    List<FileSystemEntity> contents = source.listSync();
    for (FileSystemEntity content in contents) {
      if (content is File) {
        await content
            .rename(destination.path + Platform.pathSeparator + content.name);
      } else if (content is Directory) {
        Directory newDirectory =
            Directory(destination.path + Platform.pathSeparator + content.name);
        await newDirectory.create(recursive: true);
        await moveDirectory(content, newDirectory);
      }
    }
    await source.deleteIgnoreError(recursive: true);
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
    rethrow;
  }
}

///检查下载目录是否可用, 不可用则重置
Future<void> checkDownloadPath() async {
  var path = appdata.settings[22];
  if (path != "") {
    var directory = Directory(path);
    if (!await directory.exists()) {
      appdata.settings[22] = "";
      await appdata.updateSettings();
    }
  }
}

Future<String> exportDataToFile(bool includeDownload, String outPath,
        {Map<String, Object?>? revision, bool includeSensitive = false}) =>
    DataMaintenance.run(() async {
      await appdata.waitForSettingsWrites();
      final stage = await Directory(App.cachePath).createTemp('data-export-');
      final output =
          File('$outPath.partial-${DateTime.now().microsecondsSinceEpoch}');
      try {
        await File('${stage.path}/appdata').writeAsString(
            jsonEncode(appdata.toJson(includeSensitive: includeSensitive)),
            flush: true);
        await LocalFavoritesManager()
            .snapshotTo('${stage.path}/local_favorite.db');
        await HistoryManager().snapshotTo('${stage.path}/history.db');
        // Cookies and source configuration can contain reusable credentials.
        // They are included only for the authenticated sync archive; ordinary
        // user exports remain portable without exposing login state.
        if (includeSensitive) {
          snapshotDatabase(
              '${App.dataPath}/cookies.db', '${stage.path}/cookies.db');
          final sources = Directory('${App.dataPath}/comic_source');
          if (sources.existsSync())
            await copyBackupEntity(sources.path, '${stage.path}/comic_source');
        }
        if (includeDownload && DownloadManager().path != null) {
          final downloads = Directory(DownloadManager().path!);
          if (downloads.existsSync())
            await copyBackupEntity(downloads.path, '${stage.path}/download');
        }
        await writeBackupManifest(stage, revision: revision);
        await compute<List<String>, void>((paths) {
          ZipFileEncoder().zipDirectory(Directory(paths[0]),
              filename: paths[1], followLinks: false);
        }, [stage.path, output.path]);
        if (Platform.isWindows && File(outPath).existsSync())
          File(outPath).deleteSync();
        output.renameSync(outPath);
        return outPath;
      } finally {
        if (stage.existsSync()) stage.deleteSync(recursive: true);
        if (output.existsSync()) output.deleteSync();
      }
    }, suppressSync: true);

Future<bool> runExportData(bool includeDownload) async {
  Directory? work;
  try {
    work = await Directory(App.cachePath).createTemp('data-share-');
    var outPath = '${work.path}/userdata.picadata';
    if (App.isDesktop) {
      final result = await getSaveLocation(suggestedName: 'userData.picadata');
      if (result == null) return true;
      outPath = result.path;
    }
    await exportDataToFile(includeDownload, outPath);
    if (App.isMobile) {
      await FlutterFileDialog.saveFile(
          params: SaveFileDialogParams(sourceFilePath: outPath));
    }
    return true;
  } catch (e, s) {
    Log.error('IO', '${safeNetworkError(e)}\n$s');
    return false;
  } finally {
    if (work != null && await work.exists()) {
      try {
        await work.delete(recursive: true);
      } catch (e, s) {
        Log.warning('IO',
            'Failed to remove export staging directory.\n${safeNetworkError(e)}\n$s');
      }
    }
  }
}

enum DataImportResult { imported, skipped, cancelled, failed }

Future<bool> importData([String? filePath]) async {
  final result =
      await importDataResult(filePath, checkVersion: filePath != null);
  return result == DataImportResult.imported ||
      result == DataImportResult.skipped;
}

Future<DataImportResult> importDataResult(String? filePath,
    {bool checkVersion = false, bool preserveSettings = false}) async {
  if (filePath == null) {
    if (App.isMobile) {
      filePath = await FlutterFileDialog.pickFile(
          params: const OpenFileDialogParams());
    } else {
      filePath = (await openFile(acceptedTypeGroups: [
        const XTypeGroup(label: 'data'),
      ]))
          ?.path;
    }
    if (filePath == null) return DataImportResult.cancelled;
  }
  final selected = filePath;
  return DataMaintenance.run(() async {
    final work = await Directory(App.cachePath).createTemp('data-import-');
    final extracted = Directory('${work.path}/input');
    DataRestoreTransaction? transaction;
    var stopped = false;
    var committed = false;
    final trustedRestoreRoots = <String>[
      if (DownloadManager().path != null) DownloadManager().path!,
    ];

    Future<void> reopen() async {
      final favorites = LocalFavoritesManager().init(importLegacy: false);
      final histories = HistoryManager().init(importLegacy: false);
      SingleInstanceCookieJar.instance?.init();
      await favorites;
      await histories;
      await ComicSource.reload();
      await DownloadManager().init();
      stopped = false;
    }

    void closeDatabases() {
      LocalFavoritesManager().close();
      HistoryManager().close();
      SingleInstanceCookieJar.instance?.dispose();
    }

    try {
      await recoverPendingDataRestore(App.dataPath,
          trustedAllowedRoots: trustedRestoreRoots);
      await compute<List<String>, void>((paths) async {
        await extractDataBackup(paths[0], Directory(paths[1]));
      }, [selected, extracted.path]);
      final payload = Map<String, dynamic>.from(
          jsonDecode(await File('${extracted.path}/appdata').readAsString())
              as Map);
      final settings = payload['settings'] as List;
      final version =
          int.tryParse(settings.elementAtOrNull(46)?.toString() ?? '0');
      if (version == null)
        throw const FormatException('Invalid backup revision');
      if (checkVersion &&
          version <= (int.tryParse(appdata.settings[46]) ?? 0)) {
        return DataImportResult.skipped;
      }
      final candidate = Appdata()
        ..settings = List.of(appdata.settings)
        ..firstUse = List.of(appdata.firstUse)
        ..blockingKeyword = List.of(appdata.blockingKeyword)
        ..favoriteTags = Set.of(appdata.favoriteTags);
      await candidate.readDataFromJson(payload,
          importHistory: false, persist: false);
      if (preserveSettings) {
        candidate.settings = List.of(appdata.settings);
        candidate.firstUse = List.of(appdata.firstUse);
      }
      candidate.settings[45] = appdata.settings[45];
      final mergedFavoritePath = '${work.path}/local_favorite.db';
      final mergedHistoryPath = '${work.path}/history.db';
      await LocalFavoritesManager().snapshotTo(mergedFavoritePath);
      await HistoryManager().snapshotTo(mergedHistoryPath);
      final favorites = LocalFavoritesManager.create();
      final histories = HistoryManager.create();
      try {
        await favorites.init(
            databasePath: mergedFavoritePath, importLegacy: false);
        await histories.init(
            databasePath: mergedHistoryPath, importLegacy: false);
        if (File('${extracted.path}/local_favorite.db').existsSync()) {
          await favorites.mergeFrom('${extracted.path}/local_favorite.db');
        }
        if (File('${extracted.path}/localFavorite').existsSync()) {
          await favorites.mergeLegacyJson('${extracted.path}/localFavorite');
        }
        if (File('${extracted.path}/history.db').existsSync()) {
          await histories.mergeFrom('${extracted.path}/history.db');
        }
        if (payload['history'] != null) {
          await histories.readDataFromJson(payload['history'] as List);
        }
      } finally {
        favorites.close();
        histories.close();
      }
      checkBackupDatabase(mergedFavoritePath, 'folder_order');
      checkBackupDatabase(mergedHistoryPath, 'history');
      await File('${work.path}/settings')
          .writeAsString(jsonEncode(candidate.settings), flush: true);
      await File('${work.path}/settings.bak')
          .writeAsString(jsonEncode(appdata.settings), flush: true);
      final replacements = <String, String>{
        '${App.dataPath}/local_favorite.db': mergedFavoritePath,
        '${App.dataPath}/history.db': mergedHistoryPath,
        '${App.dataPath}/settings': '${work.path}/settings',
        '${App.dataPath}/settings.bak': '${work.path}/settings.bak',
      };
      for (final name in ['comic_source', 'cookies.db']) {
        final path = '${extracted.path}/$name';
        if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
          replacements['${App.dataPath}/$name'] = path;
        }
      }
      final dirs = extracted
          .listSync()
          .whereType<Directory>()
          .where((e) =>
              e.uri.pathSegments.where((p) => p.isNotEmpty).last !=
              'comic_source')
          .toList();
      if (dirs.length > 1)
        throw const FormatException('Ambiguous download directory');
      if (dirs.isNotEmpty && DownloadManager().path != null) {
        final mergedDownloads = '${work.path}/downloads';
        if (Directory(DownloadManager().path!).existsSync()) {
          await copyBackupEntity(DownloadManager().path!, mergedDownloads);
        } else {
          Directory(mergedDownloads).createSync();
        }
        await copyBackupEntity(dirs.single.path, mergedDownloads);
        replacements[DownloadManager().path!] = mergedDownloads;
      }
      await appdata.waitForSettingsWrites();
      await DownloadManager().dispose();
      stopped = true;
      transaction = await DataRestoreTransaction.prepare(
          App.dataPath, replacements,
          allowedRoots: trustedRestoreRoots);
      closeDatabases();
      transaction.apply();
      // Reopen synchronously before the first await after replacing files.
      final favoriteInit = LocalFavoritesManager().init(importLegacy: false);
      final historyInit = HistoryManager().init(importLegacy: false);
      SingleInstanceCookieJar.instance?.init();
      await favoriteInit;
      await historyInit;
      appdata.settings = candidate.settings;
      appdata.firstUse = candidate.firstUse;
      appdata.blockingKeyword = candidate.blockingKeyword;
      appdata.favoriteTags = candidate.favoriteTags;
      await appdata.writeData(false);
      await ComicSource.reload();
      await DownloadManager().init();
      stopped = false;
      transaction.commit();
      committed = true;
      try {
        await transaction.recover();
      } catch (e, s) {
        Log.warning('IO',
            'Restore committed; cleanup deferred.\n${safeNetworkError(e)}\n$s');
      }
      LocalFavoritesManager().updateUI();
      return DataImportResult.imported;
    } catch (e, s) {
      Log.error('importData', '${safeNetworkError(e)}\n$s');
      if (!committed && transaction != null) {
        try {
          await DownloadManager().dispose();
          stopped = true;
          closeDatabases();
          await transaction.recover();
          await appdata.readData(throwOnError: true);
          await reopen();
        } catch (recoveryError, recoveryStack) {
          Log.error(
              'importData',
              'Recovery retained for next startup.\n'
                  '${safeNetworkError(recoveryError)}\n$recoveryStack');
        }
      } else if (!committed &&
          File('${App.dataPath}/data-restore/journal.json').existsSync()) {
        try {
          await DownloadManager().dispose();
          stopped = true;
          closeDatabases();
          await recoverPendingDataRestore(App.dataPath,
              trustedAllowedRoots: trustedRestoreRoots);
          await appdata.readData(throwOnError: true);
          await reopen();
        } catch (error, stack) {
          Log.error(
              'importData',
              'Recovery retained for next startup.\n'
                  '${safeNetworkError(error)}\n$stack');
        }
      } else if (stopped) {
        try {
          await reopen();
        } catch (error, stack) {
          Log.error('importData', '${safeNetworkError(error)}\n$stack');
        }
      }
      return DataImportResult.failed;
    } finally {
      if (work.existsSync()) work.deleteSync(recursive: true);
    }
  }, suppressSync: true, operationName: 'data-import');
}

Future<void> saveLog(String log) async {
  // Keep this boundary defensive: callers outside LogsPage may still pass a
  // raw LogManager string, so exported files must always receive a second
  // redaction pass.
  log = redactLogText(log);
  var path = (await getTemporaryDirectory()).path;
  var file = File("$path${pathSep}logs.txt");
  await file.writeAsString(log, flush: true);
  if (App.isMobile) {
    var params =
        SaveFileDialogParams(sourceFilePath: "$path${pathSep}logs.txt");
    await FlutterFileDialog.saveFile(params: params);
  } else {
    final String? directoryPath = await getDirectoryPath();
    if (directoryPath != null) {
      await file.copy("$directoryPath${pathSep}logs.txt");
    }
  }
}

Future<void> exportStringDataAsFile(String data, String fileName) async {
  if (App.isMobile) {
    var cachePath = (await getApplicationCacheDirectory()).path;
    var file = File("$cachePath$pathSep$fileName");
    await file.parent.create(recursive: true);
    await file.writeAsString(data, flush: true);
    var params = SaveFileDialogParams(sourceFilePath: file.path);
    await FlutterFileDialog.saveFile(params: params);
  } else {
    final FileSaveLocation? result =
        await getSaveLocation(suggestedName: fileName);
    if (result == null) {
      return;
    }

    final Uint8List fileData =
        Uint8List.fromList(const Utf8Encoder().convert(data));
    const String mimeType = 'text/plain';
    final XFile textFile =
        XFile.fromData(fileData, mimeType: mimeType, name: fileName);
    await textFile.saveTo(result.path);
  }
}

Future<String?> getDataFromUserSelectedFile(List<String> extensions) async {
  String? filePath;
  if (App.isMobile) {
    var params = const OpenFileDialogParams();
    filePath = await FlutterFileDialog.pickFile(params: params);
  } else {
    XTypeGroup typeGroup = XTypeGroup(
      label: 'data',
      extensions: extensions,
    );
    final XFile? file =
        await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    filePath = file?.path;
  }
  if (filePath == null) {
    return null;
  }
  return File(filePath).readAsString();
}

extension FileExtension on File {
  String get name => uri.pathSegments.last;
}

String bytesLengthToReadableSize(int size) {
  if (size < 1024) {
    return "$size B";
  } else if (size < 1024 * 1024) {
    return "${(size / 1024).toStringAsFixed(2)} KB";
  } else if (size < 1024 * 1024 * 1024) {
    return "${(size / 1024 / 1024).toStringAsFixed(2)} MB";
  } else {
    return "${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}
