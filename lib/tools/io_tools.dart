import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
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
    if (App.isMobile) {
      var params = SaveFileDialogParams(sourceFilePath: pdfPath);
      await FlutterFileDialog.saveFile(params: params);
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
      }
    }
    if (File(pdfPath).existsSync()) {
      File(pdfPath).delete();
    }
    return true;
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
    List<FileSystemEntity> contents = source.listSync();
    for (FileSystemEntity content in contents) {
      String newPath = destination.path +
          Platform.pathSeparator +
          content.path.split(Platform.pathSeparator).last;

      if (content is File) {
        content.copySync(newPath);
      } else if (content is Directory) {
        Directory newDirectory = Directory(newPath);
        newDirectory.createSync();
        copyDirectory(content.absolute, newDirectory.absolute);
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
        newDirectory.createSync(recursive: true);
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
    if (!directory.existsSync()) {
      appdata.settings[22] = "";
      appdata.updateSettings();
    }
  }
}

Future<String?> _exportData(String path, String appdataString,
    String? downloadPath, String outPath) async {
  var encode = ZipFile.open(outPath);
  try {
    var filePath = "$path${pathSep}appdata";
    var file = File(filePath);
    if (file.existsSync()) {
      file.deleteSync();
    }
    file.createSync();
    file.writeAsStringSync(appdataString);
    encode.addFile(file.uri.pathSegments.last, file.path);
    var localFavorite = File("$path${pathSep}local_favorite.db");
    var history = File("$path${pathSep}history.db");
    if (!localFavorite.existsSync()) {
      localFavorite.createSync();
    }
    if (!history.existsSync()) {
      history.createSync();
    }
    encode.addFile(
        localFavorite.name, localFavorite.path.replaceAll("\\", "/"));
    encode.addFile(history.name, history.path);
    encode.addFile('cookies.db', "$path/cookies.db");
    await for (var entry in Directory("$path/comic_source").list()) {
      if (entry is File) {
        encode.addFile('comic_source/${entry.name}', entry.path);
      }
    }
    if (downloadPath != null) {
      downloadPath = downloadPath.replaceAll('\\', '/');
      var sourceFolder =
          downloadPath.substring(0, downloadPath.lastIndexOf('/'));
      void walk(String path) {
        for (var entry in Directory(path).listSync()) {
          if (entry is Directory) {
            walk(entry.path);
          } else {
            var filePathInZip = entry.path.replaceFirst(sourceFolder, "");
            if (filePathInZip.startsWith('/') ||
                filePathInZip.startsWith('\\')) {
              filePathInZip = filePathInZip.substring(1);
            }
            encode.addFile(filePathInZip, entry.path);
          }
        }
      }

      walk(downloadPath);
    }
    return null;
  } catch (e) {
    return e.toString();
  } finally {
    encode.close();
  }
}

Future<String> exportDataToFile(bool includeDownload, String outPath) async {
  var path = App.dataPath;
  try {
    var appdataString = const JsonEncoder().convert(appdata.toJson());
    var downloadPath = includeDownload ? DownloadManager().path : null;
    var res = await compute<List<String?>, String?>(
        (message) =>
            _exportData(message[0]!, message[1]!, message[2], message[3]!),
        [path, appdataString, downloadPath, outPath]);

    if (res != null) {
      throw Exception(res);
    }
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
    rethrow;
  }
  return outPath;
}

Future<bool> runExportData(bool includeDownload) async {
  try {
    var outPath = '${App.cachePath}/userdata.picadata';
    if (App.isDesktop) {
      final FileSaveLocation? result =
          await getSaveLocation(suggestedName: 'userData.picadata');
      if (result == null) {
        return true;
      }
      outPath = result.path;
    }
    if (await File(outPath).exists()) {
      await File(outPath).delete();
    }
    await exportDataToFile(includeDownload, outPath);

    var dialog = showLoadingDialog(
      App.globalContext!,
      barrierDismissible: false,
      allowCancel: false,
    );

    if (App.isMobile) {
      var params = SaveFileDialogParams(sourceFilePath: outPath);
      await FlutterFileDialog.saveFile(params: params);
      File(outPath).delete();
    }

    dialog.close();
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "${safeNetworkError(e)}\n$s");
    return false;
  }
  return true;
}

FileSystemEntity? _importEntityAt(String entityPath) {
  final type = FileSystemEntity.typeSync(entityPath, followLinks: false);
  if (type == FileSystemEntityType.file) {
    return File(entityPath);
  }
  if (type == FileSystemEntityType.directory) {
    return Directory(entityPath);
  }
  return null;
}

void _deleteImportEntity(String entityPath) {
  final entity = _importEntityAt(entityPath);
  if (entity is File) {
    entity.deleteSync();
  } else if (entity is Directory) {
    entity.deleteSync(recursive: true);
  }
}

void _writeImportRollbackManifest(String manifestPath,
    List<List<String>> rollbackEntries, List<String> createdTargets) {
  File(manifestPath).writeAsStringSync(const JsonEncoder().convert({
    "entries": rollbackEntries,
    "created": createdTargets,
  }));
}

void _restoreImportRollback(String manifestPath) {
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    return;
  }
  final decoded = const JsonDecoder().convert(manifest.readAsStringSync());
  if (decoded is! Map) {
    throw const FormatException("Invalid import rollback manifest");
  }

  final created = (decoded["created"] as List<dynamic>? ?? const [])
      .whereType<String>()
      .toList();
  final entries = (decoded["entries"] as List<dynamic>? ?? const [])
      .whereType<List<dynamic>>()
      .where((entry) => entry.length == 2)
      .map((entry) => [entry[0].toString(), entry[1].toString()])
      .toList();

  // Remove targets that did not exist before the import first. Existing
  // targets are restored below from their renamed backups.
  for (final target in created.reversed) {
    _deleteImportEntity(target);
  }
  for (final entry in entries.reversed) {
    final backup = _importEntityAt(entry[1]);
    if (backup == null) {
      continue;
    }
    _deleteImportEntity(entry[0]);
    Directory(entry[0]).parent.createSync(recursive: true);
    backup.renameSync(entry[0]);
  }
}

void _discardImportRollback(String manifestPath) {
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    return;
  }
  final decoded = const JsonDecoder().convert(manifest.readAsStringSync());
  if (decoded is Map) {
    final entries = (decoded["entries"] as List<dynamic>? ?? const [])
        .whereType<List<dynamic>>()
        .where((entry) => entry.length == 2);
    for (final entry in entries) {
      try {
        _deleteImportEntity(entry[1].toString());
      } catch (_) {
        // A stale backup is safer than discarding an otherwise valid import.
      }
    }
  }
  try {
    manifest.deleteSync();
  } catch (_) {
    // Cleanup failure must not turn a completed import into a rollback.
  }
}

/// import data, filePath is used for webdav
Future<bool> importData([String? filePath]) async {
  final enableCheck = filePath != null;
  var path = (await getApplicationSupportDirectory()).path;
  if (filePath == null) {
    if (App.isMobile) {
      var params = const OpenFileDialogParams();
      filePath = await FlutterFileDialog.pickFile(params: params);
    } else {
      const XTypeGroup typeGroup = XTypeGroup(
        label: 'data',
      );
      final XFile? file =
          await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
      filePath = file?.path;
    }
    if (filePath == null) {
      LogManager.addLog(LogLevel.error, "importData", "filePath is null");
      return false;
    }
  }
  final previousSettings = List<String>.from(appdata.settings);
  final previousFirstUse = List<String>.from(appdata.firstUse);
  final previousBlockingKeyword = List<String>.from(appdata.blockingKeyword);
  final previousFavoriteTags = Set<String>.from(appdata.favoriteTags);

  Future<void> restoreAppdataSnapshot() async {
    appdata.settings = List<String>.from(previousSettings);
    appdata.firstUse = List<String>.from(previousFirstUse);
    appdata.blockingKeyword = List<String>.from(previousBlockingKeyword);
    appdata.favoriteTags = Set<String>.from(previousFavoriteTags);
    await appdata.writeData(false);
  }

  SingleInstanceCookieJar.instance?.dispose();
  await DownloadManager().dispose();
  String data = '';
  final tempPath = "$path/dataTemp-${DateTime.now().microsecondsSinceEpoch}";
  final rollbackSuffix = '.restore-${DateTime.now().microsecondsSinceEpoch}';
  final rollbackManifestPath = '$tempPath/import-rollback.json';
  var computeFailed = false;
  var initializationFailed = false;
  try {
    data = await compute<List<String>, String>((data) async {
      var path = data[0];
      final tempPath = data[5];
      final rollbackSuffix = data[6];
      Directory(tempPath).createSync(recursive: true);
      ZipFile.openAndExtract(data[1], tempPath);
      var downloadPath = Directory(data[2]);
      List<FileSystemEntity> contents = Directory(tempPath).listSync();
      for (FileSystemEntity item in contents) {
        if (item is Directory) {
          if (item.name != "comic_source" && item.name != "download") {
            item.renameSync('$tempPath/download');
          }
        }
      }
      final json = File("$tempPath/appdata").readAsStringSync();
      final decoded = const JsonDecoder().convert(json);
      if (decoded is! Map || decoded["settings"] is! List) {
        throw const FormatException("Invalid appdata payload");
      }
      final settings = decoded["settings"] as List;
      final versionValue = settings.elementAtOrNull(46) ?? "1";
      final fileVersion = int.tryParse(versionValue.toString());
      if (fileVersion == null) {
        throw const FormatException("Invalid appdata version");
      }
      if (fileVersion <= int.parse(data[3]) && data[4] == "1") {
        return json;
      }
      final rollbackEntries = <List<String>>[];
      final createdTargets = <String>[];
      final rollbackManifestPath = '$tempPath/import-rollback.json';

      void markTarget(String targetPath) {
        if (_importEntityAt(targetPath) == null &&
            !createdTargets.contains(targetPath)) {
          createdTargets.add(targetPath);
        }
        _writeImportRollbackManifest(
            rollbackManifestPath, rollbackEntries, createdTargets);
      }

      void backupEntity(String entityPath) {
        final entity = _importEntityAt(entityPath);
        if (entity == null) {
          _writeImportRollbackManifest(
              rollbackManifestPath, rollbackEntries, createdTargets);
          return;
        }
        final backupPath = '$entityPath$rollbackSuffix';
        _deleteImportEntity(backupPath);
        Directory(backupPath).parent.createSync(recursive: true);
        // Persist the intended move before renaming. If the process stops
        // between rename and the next manifest write, recovery still knows
        // where the original entity was moved.
        rollbackEntries.add([entityPath, backupPath]);
        _writeImportRollbackManifest(
            rollbackManifestPath, rollbackEntries, createdTargets);
        entity.renameSync(backupPath);
        _writeImportRollbackManifest(
            rollbackManifestPath, rollbackEntries, createdTargets);
      }

      try {
        var localFavorite = File('$tempPath/localFavorite');
        if (localFavorite.existsSync()) {
          markTarget('$path/localFavorite');
          backupEntity('$path/localFavorite');
          localFavorite.copySync('$path/localFavorite');
        } else {
          var localFavorite2 = File('$tempPath/local_favorite.db');
          if (localFavorite2.existsSync()) {
            markTarget('$path/local_favorite_temp.db');
            backupEntity('$path/local_favorite_temp.db');
            localFavorite2.copySync('$path/local_favorite_temp.db');
          }
        }

        var history = File('$tempPath/history.db');
        if (history.existsSync()) {
          markTarget('$path/history_temp.db');
          backupEntity('$path/history_temp.db');
          history.copySync('$path/history_temp.db');
        }

        var comicSource = Directory('$tempPath/comic_source');
        if (comicSource.existsSync()) {
          markTarget('$path/comic_source');
          backupEntity('$path/comic_source');
          comicSource.renameSync('$path/comic_source');
        }

        var cookies = File('$tempPath/cookies.db');
        if (cookies.existsSync()) {
          markTarget('$path/cookies.db');
          backupEntity('$path/cookies.db');
          cookies.copySync('$path/cookies.db.importing');
          File('$path/cookies.db.importing').renameSync('$path/cookies.db');
        }

        var downloadData = Directory("$tempPath/download");
        if (downloadData.existsSync()) {
          markTarget(downloadPath.path);
          backupEntity(downloadPath.path);
          downloadPath.createSync(recursive: true);
          await moveDirectory(downloadData, downloadPath);
        }
      } catch (_) {
        try {
          _restoreImportRollback(rollbackManifestPath);
        } catch (_) {
          // Keep the original replacement error; any remaining restore paths
          // are left for manual recovery.
        }
        rethrow;
      }
      return json;
    }, [
      path,
      filePath,
      DownloadManager().path!,
      appdata.settings[46],
      (enableCheck ? "1" : "0"),
      tempPath,
      rollbackSuffix,
    ]);
  } catch (e, s) {
    computeFailed = true;
    Log.error("importData", "${safeNetworkError(e)}\n$s");
    return false;
  } finally {
    try {
      await ComicSource.reload();
      SingleInstanceCookieJar.instance?.init();
      await DownloadManager().init();
    } catch (e, s) {
      initializationFailed = true;
      Log.error(
          "importData",
          "Failed to reinitialize after import: "
              "${safeNetworkError(e)}\n$s");
      if (!computeFailed) {
        try {
          _restoreImportRollback(rollbackManifestPath);
        } catch (rollbackError, rollbackStack) {
          Log.error(
              "importData",
              "Failed to rollback after reinitialization: "
                  "${safeNetworkError(rollbackError)}\n$rollbackStack");
        }
      }
    }
    if (computeFailed || initializationFailed) {
      try {
        await Directory(tempPath).delete(recursive: true);
      } catch (_) {
        // Cleanup failure must not hide the import result.
      }
    }
  }
  if (initializationFailed) {
    return false;
  }
  try {
    var json = const JsonDecoder().convert(data);
    int fileVersion =
        int.parse((json["settings"] as List).elementAtOrNull(46) ?? "1");
    int appVersion = int.parse(appdata.settings[46]);
    if (fileVersion <= appVersion && enableCheck) {
      LogManager.addLog(
          LogLevel.info,
          "Appdata",
          "The data file version is $fileVersion, while the app data version is "
              "$appVersion\nStop importing data");
      _discardImportRollback(rollbackManifestPath);
      return false;
    }
    var dataReadRes = appdata.readDataFromJson(json);
    if (!dataReadRes) {
      LogManager.addLog(
          LogLevel.error, "Appdata", "appdata.readDataFromJson(json) failed");
      throw const FormatException("Failed to apply imported appdata");
    }
    await LocalFavoritesManager().readData();
    LocalFavoritesManager().updateUI();
    await HistoryManager().tryUpdateDb();
    // readDataFromJson schedules its serialized settings write internally;
    // wait for it before deleting the pre-import rollback snapshot.
    await appdata.waitForSettingsWrites();
    _discardImportRollback(rollbackManifestPath);
    return true;
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "${safeNetworkError(e)}\n$s");
    try {
      SingleInstanceCookieJar.instance?.dispose();
      await DownloadManager().dispose();
      _restoreImportRollback(rollbackManifestPath);
      await ComicSource.reload();
      SingleInstanceCookieJar.instance?.init();
      await DownloadManager().init();
    } catch (rollbackError, rollbackStack) {
      LogManager.addLog(
          LogLevel.error,
          "importData",
          "Failed to rollback imported data: "
              "${safeNetworkError(rollbackError)}\n$rollbackStack");
    }
    try {
      await appdata.waitForSettingsWrites();
      await restoreAppdataSnapshot();
      // Re-read the restored files so an unawaited readData() from a failed
      // import cannot leave the in-memory settings on the imported snapshot.
      await appdata.readData();
    } catch (restoreError, restoreStack) {
      LogManager.addLog(
          LogLevel.error,
          "importData",
          "Failed to restore appdata snapshot: "
              "${safeNetworkError(restoreError)}\n$restoreStack");
    }
    return false;
  } finally {
    try {
      await Directory(tempPath).delete(recursive: true);
    } catch (_) {
      // Cleanup failure must not hide the import result.
    }
  }
}

void saveLog(String log) async {
  var path = (await getTemporaryDirectory()).path;
  var file = File("$path${pathSep}logs.txt");
  file.writeAsStringSync(log);
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
    if (!file.existsSync()) {
      file.createSync();
    }
    file.writeAsStringSync(data);
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
  return File(filePath).readAsStringSync();
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
