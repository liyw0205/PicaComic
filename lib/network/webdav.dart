import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:webdav_client/webdav_client.dart';

import '../base.dart';

Future<bool> _retryZone(Future<bool> Function() fn) async {
  int time = 1;
  while (time < 1 << 3) {
    var res = await fn();
    if (res) {
      return true;
    }
    await Future.delayed(Duration(seconds: time));
    time *= 2;
  }
  return false;
}

class Webdav {
  // Every WebDAV operation is appended to the same queue. Keeping the queue
  // as a Future avoids polling races and, unlike a mutex held across an
  // await, cannot deadlock when an operation schedules a local settings write.
  static Future<void> _operationQueue = Future<void>.value();
  static Future<bool>? _uploadTask;
  static bool _uploadAgain = false;
  static String? _queuedConfig;

  /// Sync current data to webdav server. Return true if success.
  static Future<bool> uploadData([String? config]) {
    final current = _uploadTask;
    if (current != null) {
      _uploadAgain = true;
      _queuedConfig = config;
      return current;
    }
    final task = _runUploadLoop(config);
    _uploadTask = task;
    task.then<void>((_) {
      if (identical(_uploadTask, task)) {
        _uploadTask = null;
        _startLateUploadIfNeeded();
      }
    }, onError: (_, __) {
      if (identical(_uploadTask, task)) {
        _uploadTask = null;
        _startLateUploadIfNeeded();
      }
    });
    return task;
  }

  static void _startLateUploadIfNeeded() {
    if (!_uploadAgain) {
      return;
    }
    final config = _queuedConfig;
    _uploadAgain = false;
    _queuedConfig = null;
    // A caller can arrive in the microtask gap between the final coalescing
    // check and completion of the task. Do not lose that requested upload.
    uploadData(config);
  }

  static Future<bool> _runUploadLoop(String? config) async {
    var result = false;
    do {
      _uploadAgain = false;
      final requestedConfig = config;
      config = null;
      result =
          await _enqueueOperation(() => _uploadOnceExclusive(requestedConfig));
      if (_uploadAgain) {
        config = _queuedConfig;
        _queuedConfig = null;
      }
    } while (_uploadAgain);
    return result;
  }

  static Future<bool> _uploadOnceExclusive(String? config) async {
    String? previousVersion;
    try {
      config ??= appdata.settings[45];
      var configs = config.split(';');
      if (configs.length != 4 || configs.elementAtOrNull(0) == "") {
        return true;
      }
      if (!configs[3].endsWith('/') && !configs[3].endsWith('\\')) {
        configs[3] += '/';
      }
      LogManager.addLog(LogLevel.info, "network", "Uploading Data");
      var client = newClient(
        configs[0],
        user: configs[1],
        password: configs[2],
        debug: false,
      );
      client.setHeaders({'content-type': 'text/plain'});
      client.setConnectTimeout(8000);
      client.setSendTimeout(60000);
      client.setReceiveTimeout(60000);
      previousVersion = appdata.settings[46];
      final previousNumber = int.tryParse(previousVersion) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final targetVersion = max(now, previousNumber + 1);
      final oldFiles = <String>[];
      var files = await client.readDir(configs[3]);
      final currentDays =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ 86400;
      for (var file in files) {
        final version = _versionFromFileName(file.name);
        if (version != null &&
            version != targetVersion &&
            version ~/ 86400 == currentDays &&
            file.path != null) {
          oldFiles.add(file.path!);
        }
      }

      // The archive contains the same version as its remote filename. Keep
      // the in-memory value temporary until the remote write succeeds.
      appdata.settings[46] = targetVersion.toString();
      await client.writeFromFile(
          await exportDataToFile(false, "${App.cachePath}/userdata.picadata"),
          "${configs[3]}$targetVersion.picadata");
      await appdata.updateSettings(false);

      // Delete old same-day versions only after the new version is present
      // and the local version has been committed. A cleanup failure should
      // not turn a successful upload into a failed sync.
      for (var path in oldFiles) {
        try {
          await client.remove(path);
        } catch (e, s) {
          LogManager.addLog(LogLevel.warning, "Sync",
              "Failed to remove old WebDAV backup.\n${safeNetworkError(e)}\n$s");
        }
      }
      return true;
    } catch (e, s) {
      if (previousVersion != null) {
        appdata.settings[46] = previousVersion;
      }
      LogManager.addLog(LogLevel.error, "Sync",
          "Failed to upload data to webdav server.\n${safeNetworkError(e)}\n$s");
      return false;
    }
  }

  static Future<bool> downloadData([String? config]) async {
    final force = config != null;
    return _enqueueOperation(() async {
      try {
        config ??= appdata.settings[45];
        var configs = config!.split(';');
        if (configs.length != 4 || configs.elementAtOrNull(0) == "") {
          return true;
        }
        if (!configs[3].endsWith('/') && !configs[3].endsWith('\\')) {
          configs[3] += '/';
        }
        LogManager.addLog(LogLevel.info, "network", "Downloading Data");
        var client = newClient(
          configs[0],
          user: configs[1],
          password: configs[2],
          debug: false,
        );
        client.setConnectTimeout(8000);
        client.setSendTimeout(60000);
        client.setReceiveTimeout(60000);

        var files = await client.readDir(configs[3]);
        int? maxVersion;
        for (var file in files) {
          final version = _versionFromFileName(file.name);
          if (version != null) {
            maxVersion = max(maxVersion ?? 0, version);
          }
        }

        if (!force && maxVersion?.toString() == appdata.settings[46]) {
          LogManager.addLog(LogLevel.info, "Sync",
              "No updated version of data.\nStop downloading data.");
          return true;
        }

        final fileName =
            maxVersion != null ? "$maxVersion.picadata" : "picadata";
        final cachePath = (await getApplicationCacheDirectory()).path;
        await client.read2File("${configs[3]}$fileName", "$cachePath/picadata");
        final imported = await importData("$cachePath/picadata");
        // importData updates appdata through its serialized settings writer.
        // Drain that writer before releasing the WebDAV operation so a
        // following upload cannot race and overwrite the imported snapshot.
        await appdata.waitForSettingsWrites();
        return imported;
      } catch (e, s) {
        LogManager.addLog(LogLevel.error, "Sync",
            "Failed to download data from webdav server.\n${safeNetworkError(e)}\n$s");
        return false;
      }
    });
  }

  static Future<T> _enqueueOperation<T>(Future<T> Function() operation) {
    final queued = _operationQueue.then<T>((_) => operation());
    // Keep the chain alive after a failed operation. The caller still gets the
    // original error/result from [queued], while later sync attempts proceed.
    _operationQueue = queued.then<void>(
      (_) {},
      onError: (_, __) {},
    );
    return queued;
  }

  /// Drain operations already submitted before destructive local-data actions
  /// such as clearAppdata. New operations may still be submitted afterwards.
  static Future<void> waitForIdle() => _operationQueue;

  static int? _versionFromFileName(String? name) {
    if (name == null || !name.endsWith('.picadata')) {
      return null;
    }
    final stem = name.substring(0, name.length - '.picadata'.length);
    final version = int.tryParse(stem);
    return version != null && version >= 0 ? version : null;
  }

  static Future<void> syncData() async {
    var configs = appdata.settings[45].split(';');
    if (configs.length != 4 || configs.elementAtOrNull(0) == "") {
      return;
    }
    var controller = showLoadingDialog(
      App.globalContext!,
      barrierDismissible: false,
      allowCancel: true,
      message: "同步数据中".tl,
      cancelButtonText: "隐藏".tl,
    );
    var res = await _retryZone(Webdav.downloadData);
    await Future.delayed(const Duration(milliseconds: 50));
    if (!res) {
      controller.close();
      showToast(
        message: "下载数据失败, 已保留同步设置".tl,
        trailing: Button.icon(
          onPressed: () {
            syncData();
          },
          icon: const Icon(Icons.refresh),
        ),
      );
    } else {
      controller.close();
    }
  }
}
