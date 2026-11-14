import 'dart:convert';
import 'dart:io' as io;

import 'package:app_links/app_links.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/js_engine.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/foundation/secret_store.dart';
import 'package:pica_comic/foundation/startup.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_proxy.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:pica_comic/tools/app_links.dart';
import 'package:pica_comic/tools/background_service.dart';
import 'package:pica_comic/tools/cache_auto_clear.dart';
import 'package:pica_comic/tools/data_backup.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/legacy_data_migration.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/foundation/settings_schema.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'base.dart';
import 'comic_source/built_in/ehentai.dart';
import 'comic_source/built_in/ht_manga.dart';
import 'comic_source/built_in/jm.dart';
import 'comic_source/built_in/nhentai.dart';
import 'comic_source/built_in/picacg.dart';
import 'foundation/app.dart';
import 'network/nhentai_network/nhentai_main_network.dart';

final _startup = StartupCoordinator([
  const StartupStep('storage paths', App.init),
  StartupStep('secret store', () async {
    SecretStoreRegistry.configure(FlutterSecureSecretStore());
  }),
  StartupStep('data recovery', () async {
    await recoverPendingDataRestore(App.dataPath,
        trustedAllowedRoots: await _startupRestoreRoots());
  }),
  const StartupStep('logging', _initializeLogging, essential: false),
  StartupStep('settings', () async {
    await appdata.readData(throwOnError: true);
  }),
  StartupStep('secret migration', () async {
    await Webdav.migrateLegacyConfig();
  }, essential: false),
  StartupStep('cookies', () async {
    SingleInstanceCookieJar('${App.dataPath}/cookies.db');
  }),
  const StartupStep('download location', checkDownloadPath),
  const StartupStep('legacy migration', _checkOldData, essential: false),
  StartupStep('JavaScript engine', () => JsEngine().init(throwOnError: true)),
  const StartupStep('comic sources', ComicSource.init),
  StartupStep('downloads', downloadManager.init),
  StartupStep('Nhentai', () => NhentaiNetwork().init()),
  StartupStep('JM', () => JmNetwork().init()),
  StartupStep('favorites', () => LocalFavoritesManager().init()),
  StartupStep('history', () => HistoryManager().init()),
  const StartupStep('translations', AppTranslation.init),
  StartupStep('cache budget', () async {
    CacheManager().setLimitSize(appdata.appSettings.cacheLimit);
  }),
  const StartupStep('network proxy', setNetworkProxy, essential: false),
  StartupStep('local proxy', () async {
    await HttpProxyServer.createConfigFile();
    if (appdata.settings[58] == '1') await HttpProxyServer.startServer();
  }, essential: false),
  StartupStep('app links', () async {
    if (!App.isAndroid) return;
    AppLinks().allUriLinkStream.listen((uri) async {
      while (App.mainNavigatorKey == null) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      handleAppLinks(uri);
    });
  }, essential: false),
  StartupStep('background jobs', () async {
    if (App.isMobile) await Workmanager().initialize(onStart);
  }, essential: false),
  const StartupStep('cache cleanup', startClearCache, essential: false),
], onStepFinished: (stage, elapsed, failure) {
  RuntimeMetrics.record(
    'startup.${stage.replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '_')}',
    elapsed: elapsed,
    success: failure == null,
  );
  LogManager.addLog(
    failure == null ? LogLevel.info : LogLevel.error,
    'Startup',
    '$stage: ${elapsed.inMilliseconds} ms'
        '${failure == null ? '' : '\n${safeNetworkError(failure.error)}\n${failure.stackTrace}'}',
  );
});

Future<StartupResult> init() => _startup.run();

/// Reads only the validated download setting needed to authorize recovery of
/// an external download directory. This runs before the normal settings step,
/// so an interrupted restore can still be recovered before databases open.
Future<List<String>> _startupRestoreRoots() async {
  final candidates = [
    io.File('${App.dataPath}/settings'),
    io.File('${App.dataPath}/settings.bak'),
  ];
  final roots = <String>[];
  void addConfiguredRoot(Object? decoded) {
    try {
      final settings =
          SettingsSchema.decode(decoded, appdata.settings, strict: true);
      final configured = settings[22];
      // A relative setting cannot authorize a filesystem boundary. The
      // restore validator also resolves the nearest existing ancestor, so a
      // configured directory may legitimately be missing during recovery.
      if (configured.isNotEmpty && io.File(configured).isAbsolute) {
        if (!roots.contains(configured)) roots.add(configured);
      }
    } catch (_) {
      // The normal settings step reports malformed settings. Keep checking
      // the backup/shared copy so a valid boundary survives a torn write.
    }
  }

  for (final file in candidates) {
    try {
      if (!await file.exists()) continue;
      addConfiguredRoot(jsonDecode(await file.readAsString()));
    } catch (_) {
      // The normal settings step reports malformed settings. Recovery falls
      // back to the other persisted copy or the application-owned default
      // download directory here.
    }
  }

  // SharedPreferences is the final persisted settings source used by
  // Appdata.readSettings when both files are unavailable. Read it here too,
  // before any database or download manager is initialized.
  try {
    final shared = await SharedPreferences.getInstance();
    addConfiguredRoot(shared.getStringList('settings'));
  } catch (_) {
    // Recovery can still proceed for app-owned targets without this source.
  }

  final applicationSupport = await getApplicationSupportDirectory();
  final fallback =
      '${applicationSupport.path}${io.Platform.pathSeparator}download';
  if (!roots.contains(fallback)) roots.add(fallback);
  return roots;
}

Future<void> _initializeLogging() async {
  // Finish a queue left by an earlier startup before switching destinations.
  await LogManager.flush();
  LogManager.logFile = LogManager.logFileForDataPath(
    App.dataPath,
    isIOS: App.isIOS,
  );
  LogManager.addLog(LogLevel.info, 'App Status', 'Start initialization.');
  await LogManager.flush();
}

Future<void> _checkOldData() async {
  try {
    if (int.parse(appdata.settings[17]) >= 4) {
      appdata.settings[17] = '0';
    }
    if (int.parse(appdata.settings[40]) > 40) {
      appdata.settings[40] = '40';
    }
    appdata.blockingKeyword.removeWhere((value) => value.isEmpty);

    await migrateLegacyCookies(App.dataPath);

    if (io.File("${App.dataPath}/cache.json").existsSync()) {
      io.File("${App.dataPath}/cache.json").deleteIgnoreError();
    }
    if (io.Directory("${App.cachePath}/imageCache").existsSync()) {
      io.Directory("${App.cachePath}/imageCache")
          .deleteIgnoreError(recursive: true);
    }
    if (io.Directory("${App.cachePath}/cachedNetwork").existsSync()) {
      io.Directory("${App.cachePath}/cachedNetwork")
          .deleteIgnoreError(recursive: true);
    }
    await _checkAccountData();
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "Init",
        "Check old data failed!\n${safeNetworkError(e)}\n$s");
  }
}

/// Migrates complete persisted jars and retains the verified sources as backups.
Future<bool> migrateLegacyCookies(String dataPath,
    {CookieJarSql? destination}) async {
  try {
    final target = destination ?? SingleInstanceCookieJar.instance;
    if (target == null) {
      throw StateError('Cookie jar is not initialized');
    }
    await migrateLegacyCookieDirectories(dataPath, target);
    return true;
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error,
        'Init',
        'Cookie migration failed; legacy files were retained.\n'
            '${safeNetworkError(e)}\n$s');
    return false;
  }
}

Future<void> _checkAccountData() async {
  final s = await SharedPreferences.getInstance();
  Future<void> migrate(ComicSource source, String sourceKey,
      List<String> preferenceKeys, Map<String, dynamic> values) async {
    try {
      source.data = await migrateLegacyAccount(
        dataPath: App.dataPath,
        sourceKey: sourceKey,
        destinationKey: source.key,
        sourceValues: {
          for (final key in preferenceKeys) key: s.get(key),
        },
        values: values,
        removeSource: () => s.remove(sourceKey),
      );
    } catch (e, stack) {
      LogManager.addLog(LogLevel.error, 'Init',
          'Account migration failed; source was retained.\n${safeNetworkError(e)}\n$stack');
    }
  }

  if (s.getString('picacgAccount') != null) {
    await migrate(picacg, 'picacgAccount', const [
      'picacgAccount',
      'picacgPassword',
      'token',
      'userId',
      'userAvatar',
      'userEmail',
      'userExp',
      'userLevel',
      'userName',
      'userTitle',
      'appChannel',
      'image',
    ], {
      'account': [s.getString('picacgAccount'), s.getString('picacgPassword')],
      'token': s.getString('token'),
      'user': Profile(
        s.getString('userId') ?? '',
        s.getString('userAvatar') ?? '',
        s.getString('userEmail') ?? '',
        s.getInt('userExp') ?? 0,
        s.getInt('userLevel') ?? 0,
        s.getString('userName') ?? '',
        s.getString('userTitle') ?? '',
        false,
        '',
        '',
      ).toJson(),
      'appChannel': s.getString('appChannel') ?? '3',
      'imageQuality': s.getString('image') ?? 'original',
    });
  }
  if (s.getString('jmName') != null) {
    await migrate(jm, 'jmName', const [
      'jmName',
      'jmPwd'
    ], {
      'account': [s.getString('jmName'), s.getString('jmPwd')],
      'name': s.getString('jmName'),
    });
  }
  if (s.getString('ehAccount') != null) {
    await migrate(ehentai, 'ehAccount', const [
      'ehAccount'
    ], {
      'account': 'ok',
      'name': s.getString('ehAccount'),
    });
  }
  if (s.getString('htName') != null) {
    await migrate(htManga, 'htName', const [
      'htName',
      'htPwd'
    ], {
      'account': [s.getString('htName'), s.getString('htPwd')],
      'name': s.getString('htName'),
    });
  }
  await NhentaiNetwork().init();
  if (NhentaiNetwork().logged) {
    nhentai.data['account'] = 'ok';
    await nhentai.saveData();
  }
}
