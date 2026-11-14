import 'dart:math';
import 'dart:convert';
import 'dart:io' as io;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/secret_store.dart';
import 'package:pica_comic/network/sync_revision.dart';
import 'package:pica_comic/network/sync_transport.dart';
import 'package:pica_comic/tools/data_backup.dart';

import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';

import '../base.dart';

Future<bool> _retryZone(Future<bool> Function() fn) async {
  int time = 1;
  while (time < 1 << 3) {
    var res = await fn();
    if (res || Webdav.lastResult.status == SyncStatus.conflict) {
      return true;
    }
    await Future.delayed(Duration(seconds: time));
    time *= 2;
  }
  return false;
}

bool _sameRevision(SyncRevision left, SyncRevision right) {
  if (left.id != right.id ||
      left.device != right.device ||
      left.sha256 != right.sha256 ||
      left.parents.length != right.parents.length) {
    return false;
  }
  for (var i = 0; i < left.parents.length; i++) {
    if (left.parents[i] != right.parents[i]) return false;
  }
  return true;
}

class _SecretStoreReadError implements Exception {
  _SecretStoreReadError(this.error);

  final Object error;

  @override
  String toString() => 'WebDAV credential storage is unavailable: $error';
}

class Webdav {
  // The maintenance scope covers local snapshots and remote operations;
  // imports reuse it and suppress intermediate upload requests.
  static Future<bool>? _uploadTask;
  static bool _uploadAgain = false;
  static String? _queuedConfig;

  /// Sync current data to webdav server. Return true if success.
  static Future<bool> uploadData([String? config]) {
    if (DataMaintenance.syncSuppressed || DataMaintenance.busy) {
      return Future<bool>.value(true);
    }
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

  static SyncResult lastResult = const SyncResult(SyncStatus.unchanged);
  static SyncTransport Function(List<String>) transportFactory =
      WebdavSyncTransport.new;

  static List<String>? _parseConfig(String raw) {
    final values = raw.split(';');
    return values.length == 4 && values[0].isNotEmpty ? values : null;
  }

  /// Reads the public endpoint/path and obtains credentials from SecretStore.
  /// Explicit configs remain supported for old callers and one-shot actions.
  static Future<List<String>?> _config(String? config) async {
    final values = _parseConfig(config ?? appdata.settings[45]);
    if (values == null) return null;
    if (config != null || values[1].isNotEmpty || values[2].isNotEmpty) {
      return values;
    }
    String? username;
    String? password;
    try {
      username = await SecretStoreRegistry.instance.read(webdavUsernameSecret);
      password = await SecretStoreRegistry.instance.read(webdavPasswordSecret);
    } catch (error, stack) {
      // A platform plugin can be unavailable after an upgrade. Do not turn
      // that failure into an anonymous request; explicit anonymous configs
      // bypass this branch because they are passed as one-shot configs.
      Log.warning(
          'Sync',
          'Secret storage unavailable; WebDAV credentials were not loaded.\n'
              '${safeNetworkError(error)}\n$stack');
      throw _SecretStoreReadError(error);
    }
    return [values[0], username ?? '', password ?? '', values[3]];
  }

  static Future<List<String>?> configForSettings() async {
    try {
      return await _config(null);
    } catch (error, stack) {
      Log.warning(
          'Sync',
          'Secure credential storage is unavailable; WebDAV settings cannot be read.\n'
              '${safeNetworkError(error)}\n$stack');
      final values = _parseConfig(appdata.settings[45]);
      return values == null ? null : [values[0], '', '', values[3]];
    }
  }

  /// Moves credentials out of the legacy four-field setting. The old value is
  /// retained if the secret store cannot be written, so an upgrade is
  /// reversible and does not silently disable sync.
  static Future<bool> migrateLegacyConfig() async {
    final previousSetting = appdata.settings[45];
    final values = _parseConfig(previousSetting);
    if (values == null || (values[1].isEmpty && values[2].isEmpty)) {
      return false;
    }
    final store = SecretStoreRegistry.instance;
    String? previousUsername;
    String? previousPassword;
    var previousSecretsRead = false;
    try {
      previousUsername = await store.read(webdavUsernameSecret);
      previousPassword = await store.read(webdavPasswordSecret);
      previousSecretsRead = true;
      if (values[1].isEmpty) {
        await store.delete(webdavUsernameSecret);
      } else {
        await store.write(webdavUsernameSecret, values[1]);
      }
      if (values[2].isEmpty) {
        await store.delete(webdavPasswordSecret);
      } else {
        await store.write(webdavPasswordSecret, values[2]);
      }
      appdata.settings[45] = '${values[0]};;;${values[3]}';
      await appdata.updateSettings(false);
      return true;
    } catch (error, stack) {
      appdata.settings[45] = previousSetting;
      if (previousSecretsRead) {
        try {
          if (previousUsername == null) {
            await store.delete(webdavUsernameSecret);
          } else {
            await store.write(webdavUsernameSecret, previousUsername);
          }
          if (previousPassword == null) {
            await store.delete(webdavPasswordSecret);
          } else {
            await store.write(webdavPasswordSecret, previousPassword);
          }
        } catch (_) {
          // The legacy setting remains authoritative when a secure-store
          // rollback is unavailable; retry migration on a later startup.
        }
      }
      Log.warning(
          'Sync',
          'WebDAV credential migration retained legacy settings.\n'
              '${safeNetworkError(error)}\n$stack');
      return false;
    }
  }

  static Future<bool> saveConfig({
    required String url,
    required String username,
    required String password,
    required String path,
    bool sync = true,
  }) async {
    final store = SecretStoreRegistry.instance;
    final previousSetting = appdata.settings[45];
    String? previousUsername;
    String? previousPassword;
    var previousSecretsRead = false;
    try {
      previousUsername = await store.read(webdavUsernameSecret);
      previousPassword = await store.read(webdavPasswordSecret);
      previousSecretsRead = true;
      if (username.isEmpty) {
        await store.delete(webdavUsernameSecret);
      } else {
        await store.write(webdavUsernameSecret, username);
      }
      if (password.isEmpty) {
        await store.delete(webdavPasswordSecret);
      } else {
        await store.write(webdavPasswordSecret, password);
      }
      appdata.settings[45] = url.isEmpty ? '' : '$url;;;$path';
      await appdata.updateSettings(sync);
      return true;
    } catch (error, stack) {
      appdata.settings[45] = previousSetting;
      if (previousSecretsRead) {
        try {
          if (previousUsername == null) {
            await store.delete(webdavUsernameSecret);
          } else {
            await store.write(webdavUsernameSecret, previousUsername);
          }
          if (previousPassword == null) {
            await store.delete(webdavPasswordSecret);
          } else {
            await store.write(webdavPasswordSecret, previousPassword);
          }
        } catch (_) {
          // Keep the old public setting even if a best-effort secret rollback
          // is unavailable; the next startup can still use its legacy values.
        }
      }
      Log.error(
          'Sync',
          'WebDAV credential update failed; old settings retained.\n'
              '${safeNetworkError(error)}\n$stack');
      return false;
    }
  }

  static io.File _stateFile(List<String> config) {
    final key = sha256
        .convert(utf8.encode('${config[0]};${config[1]};${config[3]}'))
        .toString();
    return io.File('${App.dataPath}/sync-$key.json');
  }

  static Future<Map<String, dynamic>> _state(List<String> config) async {
    final file = _stateFile(config);
    if (!file.existsSync()) {
      return {'device': const Uuid().v4(), 'heads': <String>[]};
    }
    final data = jsonDecode(await file.readAsString());
    final heads = data is Map && data['heads'] is List
        ? data['heads'] as List
        : const <Object?>[];
    final uniqueHeads = <String>{};
    if (data is! Map ||
        data['device'] is! String ||
        !isRevisionId(data['device']) ||
        data['heads'] is! List ||
        heads.any(
            (e) => e is! String || !isRevisionId(e) || !uniqueHeads.add(e))) {
      throw const FormatException('Invalid local sync state');
    }
    return Map<String, dynamic>.from(data);
  }

  static Future<void> _saveState(
      List<String> config, Map<String, dynamic> state) async {
    final file = _stateFile(config);
    final temporary = io.File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state), flush: true);
    if (io.Platform.isWindows && file.existsSync()) file.deleteSync();
    temporary.renameSync(file.path);
  }

  static Future<List<SyncRevision>> _revisions(SyncTransport transport) async {
    final names = await transport.list();
    final revisions = <SyncRevision>[];
    for (final name in names) {
      final legacy = RegExp(r'^(\d+)\.picadata$').firstMatch(name);
      if (legacy != null) {
        final n = int.tryParse(legacy[1]!);
        if (n != null) {
          revisions.add(SyncRevision(
              id: 'legacy-$n',
              device: 'legacy',
              parents: const [],
              sha256: '',
              legacyVersion: n));
        }
        continue;
      }
      final match =
          RegExp(r'^revision-([a-zA-Z0-9_-]+)\.json$').firstMatch(name);
      if (match == null) continue;
      final revision = SyncRevision.fromJson(
          jsonDecode(await transport.readText(name)), match[1]!);
      if (!names.contains(revision.archiveName)) {
        throw const FormatException('Published sync revision has no archive');
      }
      revisions.add(revision);
    }
    return revisions;
  }

  static Future<bool> _uploadOnceExclusive(String? config) async {
    List<String>? configs;
    SyncTransport? transport;
    io.Directory? work;
    final previousVersion = appdata.settings[46];
    try {
      configs = await _config(config);
      if (configs == null) return true;
      transport = transportFactory(configs);
      final state = await _state(configs);
      // Persist the device identity before publishing anything remotely. A
      // failed first upload may leave an immutable archive behind; retaining
      // the same identity makes the retry an observable branch of this
      // device rather than an unrelated new device.
      final stateFile = _stateFile(configs);
      if (!stateFile.existsSync()) {
        await _saveState(configs, state);
      }
      final revisions = await _revisions(transport);
      final previousPointer = await transport.pointer();
      final parents = List<String>.from(state['heads'] as List);
      final id = const Uuid().v4();
      final metadata = <String, Object?>{
        'id': id,
        'device': state['device'],
        'parents': parents
      };
      work = await io.Directory(App.cachePath).createTemp('sync-upload-');
      // Numeric version remains solely for old archives; UUID and ancestry
      // determine ordering for the new protocol.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      appdata.settings[46] =
          max(now, (int.tryParse(previousVersion) ?? 0) + 1).toString();
      final archive = await exportDataToFile(
          false, '${work.path}/data.picadata',
          revision: metadata, includeSensitive: true);
      final digest = await fileDigest(io.File(archive));
      final revision = SyncRevision(
          id: id,
          device: state['device'] as String,
          parents: parents,
          sha256: digest);
      await transport.upload(archive, revision.archiveName);
      final verify = '${work.path}/verify.picadata';
      await transport.download(revision.archiveName, verify);
      if (await fileDigest(io.File(verify)) != digest) {
        throw const FormatException('Remote sync archive verification failed');
      }
      await transport.writeText(
          revision.descriptorName, encodeSyncRevision(revision));
      final published = SyncRevision.fromJson(
          jsonDecode(await transport.readText(revision.descriptorName)), id);
      if (published.sha256 != digest ||
          jsonEncode(published.parents) != jsonEncode(parents)) {
        throw const FormatException(
            'Remote sync descriptor verification failed');
      }
      final pointerUpdated = await transport.compareAndSetPointer(
          previousPointer,
          jsonEncode({
            'protocol': 2,
            'heads': [id]
          }));

      // Re-read the graph before committing local settings. A concurrent
      // descriptor or a same-ID mismatch must leave the previous local state
      // authoritative instead of only rolling back the in-memory version.
      final allRevisions = <String, SyncRevision>{
        for (final item in revisions) item.id: item
      };
      for (final item in await _revisions(transport)) {
        final previous = allRevisions[item.id];
        if (previous != null && !_sameRevision(previous, item)) {
          throw const FormatException('Conflicting sync revision descriptor');
        }
        allRevisions[item.id] = item;
      }
      final previousRevision = allRevisions[revision.id];
      if (previousRevision != null &&
          !_sameRevision(previousRevision, revision)) {
        throw const FormatException('Conflicting published sync revision');
      }
      allRevisions[revision.id] = revision;
      final heads = revisionHeads(allRevisions.values);
      lastResult = SyncResult(
          heads.length > 1 || !pointerUpdated
              ? SyncStatus.conflict
              : SyncStatus.success,
          heads: heads);

      await appdata.updateSettings(false);
      state['heads'] = [id];
      await _saveState(configs, state);
      // Retain every branch. Legacy clients lack ancestry; deleting their
      // archives based on local time could destroy an unmerged device state.
      if (lastResult.status == SyncStatus.conflict) {
        Log.warning(
            'Sync', 'Concurrent WebDAV branches retained: ${heads.length}');
      }
      return true;
    } catch (e, s) {
      appdata.settings[46] = previousVersion;
      lastResult = const SyncResult(SyncStatus.failed);
      Log.error('Sync', 'Failed to upload data.\n${safeNetworkError(e)}\n$s');
      return false;
    } finally {
      transport?.close();
      if (work != null && work.existsSync()) work.deleteSync(recursive: true);
    }
  }

  static Future<bool> downloadData([String? config]) =>
      _enqueueOperation(() async {
        List<String>? configs;
        SyncTransport? transport;
        try {
          configs = await _config(config);
          if (configs == null) return true;
          transport = transportFactory(configs);
          final state = await _state(configs);
          final heads = revisionHeads(await _revisions(transport));
          if (heads.length > 1) {
            lastResult = SyncResult(SyncStatus.conflict, heads: heads);
            return false;
          }
          if (heads.isEmpty) {
            // Pre-versioned backups used the literal name picadata.
            if ((await transport.list()).contains('picadata')) {
              await _importRevision(transport, null, preserveSettings: false);
              lastResult = const SyncResult(SyncStatus.success);
            } else {
              lastResult = const SyncResult(SyncStatus.unchanged);
            }
            return true;
          }
          final head = heads.single;
          if (config == null && (state['heads'] as List).contains(head.id)) {
            lastResult = SyncResult(SyncStatus.unchanged, heads: heads);
            return true;
          }
          if (head.legacy &&
              config == null &&
              head.legacyVersion! <=
                  (int.tryParse(appdata.settings[46]) ?? 0)) {
            lastResult = SyncResult(SyncStatus.skipped, heads: heads);
            return true;
          }
          await _importRevision(transport, head, preserveSettings: false);
          state['heads'] = [head.id];
          await _saveState(configs, state);
          lastResult = SyncResult(SyncStatus.success, heads: heads);
          return true;
        } catch (e, s) {
          lastResult = const SyncResult(SyncStatus.failed);
          Log.error(
              'Sync', 'Failed to download data.\n${safeNetworkError(e)}\n$s');
          return false;
        } finally {
          transport?.close();
        }
      });

  static Future<void> _importRevision(
      SyncTransport transport, SyncRevision? revision,
      {required bool preserveSettings}) async {
    final work = await io.Directory(App.cachePath).createTemp('sync-download-');
    try {
      final path = '${work.path}/data.picadata';
      await transport.download(revision?.archiveName ?? 'picadata', path);
      if (revision != null &&
          !revision.legacy &&
          await fileDigest(io.File(path)) != revision.sha256) {
        throw const FormatException('Downloaded sync archive hash mismatch');
      }
      final result =
          await importDataResult(path, preserveSettings: preserveSettings);
      if (result != DataImportResult.imported) {
        throw StateError('Sync import failed');
      }
    } finally {
      if (work.existsSync()) work.deleteSync(recursive: true);
    }
  }

  /// Merges all branch collections/progress; settings are explicitly selected.
  /// Null means keep local settings. No archive is selected by wall clock.
  static Future<bool> resolveConflict({String? settingsRevision}) =>
      _enqueueOperation(() async {
        List<String>? config;
        SyncTransport? transport;
        try {
          config = await _config(null);
          if (config == null) return true;
          transport = transportFactory(config);
          final state = await _state(config);
          final heads = revisionHeads(await _revisions(transport));
          if (settingsRevision != null &&
              !heads.any((e) => e.id == settingsRevision)) {
            throw StateError('Selected sync revision is no longer a head');
          }
          // Import collection/progress branches first. If a later branch is
          // unavailable, the selected settings revision must not have been
          // applied yet; otherwise conflict resolution would leave local
          // settings changed without publishing the merged revision.
          final mergeHeads = settingsRevision == null
              ? heads
              : [
                  ...heads.where((head) => head.id != settingsRevision),
                  ...heads.where((head) => head.id == settingsRevision),
                ];
          for (final head in mergeHeads) {
            await _importRevision(transport, head,
                preserveSettings: head.id != settingsRevision);
          }
          state['heads'] = heads.map((e) => e.id).toList();
          await _saveState(config, state);
          // Publish one descendant only after every branch has been merged.
          return await _uploadOnceExclusive(null);
        } catch (e, s) {
          lastResult = const SyncResult(SyncStatus.failed);
          Log.error('Sync', '${safeNetworkError(e)}\n$s');
          return false;
        } finally {
          transport?.close();
        }
      });

  static Future<T> _enqueueOperation<T>(Future<T> Function() operation) =>
      DataMaintenance.run(operation, suppressSync: true);

  static Future<void> waitForIdle() => DataMaintenance.waitForIdle();

  static Future<void> syncData() async {
    List<String>? configs;
    try {
      configs = await _config(null);
    } catch (error, stack) {
      lastResult = const SyncResult(SyncStatus.failed);
      Log.error(
          'Sync',
          'Cannot start WebDAV sync because credentials are unavailable.\n'
              '${safeNetworkError(error)}\n$stack');
      return;
    }
    if (configs == null) {
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
    if (lastResult.status == SyncStatus.conflict) {
      controller.close();
      if (App.globalContext == null) return;
      final choice = await showDialog<String>(
          context: App.globalContext!,
          builder: (context) =>
              SimpleDialog(title: const Text('发现多个设备版本'), children: [
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, ''),
                    child: const Text('保留本机设置，合并收藏和阅读进度')),
                for (final head in lastResult.heads)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, head.id),
                      child: Text(
                          '合并并采用设备 ${head.device.substring(0, min(8, head.device.length))} 的设置')),
              ]));
      if (choice != null) {
        final resolved = await resolveConflict(
            settingsRevision: choice.isEmpty ? null : choice);
        showToast(message: resolved ? '版本合并完成' : '版本合并失败，已保留备份');
      }
      return;
    }
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
