import 'dart:convert';
import 'dart:io' as io;

import 'package:app_links/app_links.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/js_engine.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_proxy.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/tools/app_links.dart';
import 'package:pica_comic/tools/background_service.dart';
import 'package:pica_comic/tools/cache_auto_clear.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
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

Future<void> init() async {
  try {
    await App.init();
    io.File? logFile = io.File("${App.dataPath}/log.txt");
    if (App.isAndroid) {
      var externalDirectory = await getExternalStorageDirectory();
      if (externalDirectory != null) {
        logFile = io.File("${externalDirectory.path}/log.txt");
      }
    }
    if (App.isIOS) {
      logFile = null;
    }
    if (logFile?.existsSync() ?? false) {
      await logFile?.delete();
    }
    LogManager.logFile = logFile;
    LogManager.addLog(LogLevel.info, "App Status", "Start initialization.");
    await appdata.readData();
    SingleInstanceCookieJar("${App.dataPath}/cookies.db");
    HttpProxyServer.createConfigFile();
    if (appdata.settings[58] == "1") {
      HttpProxyServer.startServer();
    }
    startClearCache();
    if (App.isAndroid) {
      final appLinks = AppLinks();
      appLinks.allUriLinkStream.listen((uri) async {
        while (App.mainNavigatorKey == null) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        handleAppLinks(uri);
      });
    }
    if (App.isMobile) {
      Workmanager().initialize(
        onStart,
      );
    }
    await checkDownloadPath();
    await _checkOldData();

    await JsEngine().init();

    await ComicSource.init();

    await Future.wait([
      downloadManager.init(),
      NhentaiNetwork().init(),
      JmNetwork().init(),
      LocalFavoritesManager().init(),
      HistoryManager().init(),
      AppTranslation.init(),
    ]);
    CacheManager().setLimitSize(appdata.appSettings.cacheLimit);
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "Init",
        "App initialization failed!\n${safeNetworkError(e)}\n$s");
  }
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

/// Migrates cookie_jar files into the SQLite jar. Legacy files are removed
/// only after the destination has been written and read back successfully.
/// Returning false leaves every source directory in place for a later retry.
Future<bool> migrateLegacyCookies(String dataPath,
    {CookieJarSql? destination}) async {
  final sourcePaths = [
    '${dataPath}/cookies',
    '${dataPath}/eh_cookies',
    '${dataPath}/comic_source/cookies',
  ];
  final existingPaths = sourcePaths
      .map(io.Directory.new)
      .where((directory) => directory.existsSync())
      .toList(growable: false);
  if (existingPaths.isEmpty) {
    return true;
  }

  try {
    // Only initialize jars for directories that actually exist. FileStorage
    // creates its directory on first read, which would otherwise make a
    // failed migration look successful and erase a newly-created directory.
    final cookies = <io.Cookie>[];
    final nhentaiPath = '${dataPath}/cookies';
    if (io.Directory(nhentaiPath).existsSync()) {
      final jar = PersistCookieJar(storage: FileStorage(nhentaiPath));
      for (var cookie
          in await jar.loadForRequest(Uri.parse('https://nhentai.net'))) {
        cookie.domain ??= '.nhentai.net';
        cookies.add(cookie);
      }
    }

    final ehPath = '${dataPath}/eh_cookies';
    if (io.Directory(ehPath).existsSync()) {
      final jar = PersistCookieJar(storage: FileStorage(ehPath));
      for (var cookie
          in await jar.loadForRequest(Uri.parse('https://e-hentai.org'))) {
        cookie.domain ??= '.e-hentai.org';
        cookies.add(cookie);
      }
      for (var cookie
          in await jar.loadForRequest(Uri.parse('https://exhentai.org'))) {
        cookie.domain ??= '.exhentai.org';
        cookies.add(cookie);
      }
    }

    final comicCookiesPath = '${dataPath}/comic_source/cookies';
    final comicCookiesDirectory = io.Directory(comicCookiesPath);
    if (comicCookiesDirectory.existsSync()) {
      final jar = PersistCookieJar(
          storage:
              FileStorage('$comicCookiesPath${io.Platform.pathSeparator}'));
      final domains = <String>{};
      // cookie_jar v4 stores host files below ie*_ps*/ and keeps domain
      // cookies in .domains. Read both metadata and direct host files so this
      // also handles older layouts where files lived at the root.
      for (var entry in comicCookiesDirectory.listSync(recursive: true)) {
        if (entry is! io.File) {
          continue;
        }
        final name = entry.path.split(io.Platform.pathSeparator).last;
        if (name == '.domains') {
          try {
            final value = jsonDecode(await entry.readAsString());
            if (value is Map) {
              domains.addAll(value.keys.whereType<String>());
            }
          } catch (_) {
            // A corrupt metadata file should not prevent host cookies from
            // being migrated; PersistCookieJar will handle it on load.
          }
          continue;
        }
        if (name == '.index') {
          try {
            final value = jsonDecode(await entry.readAsString());
            if (value is List) {
              domains.addAll(value.whereType<String>());
            }
          } catch (_) {
            // See the .domains handling above.
          }
          continue;
        }
        domains.add(name);
      }
      for (var domain in domains) {
        domain = domain.trim().replaceFirst(RegExp(r'^\.'), '');
        if (domain.isEmpty) {
          continue;
        }
        final uri = Uri.tryParse('https://$domain');
        if (uri == null || uri.host.isEmpty) {
          continue;
        }
        for (var cookie in await jar.loadForRequest(uri)) {
          cookie.domain ??= '.$domain';
          cookies.add(cookie);
        }
      }
    }

    final target = destination ?? SingleInstanceCookieJar.instance;
    if (target == null) {
      throw StateError('Cookie jar is not initialized');
    }

    // SQLite uses (name, domain, path) as the key. Keep the last value from
    // the legacy jars, matching INSERT OR REPLACE semantics.
    final uniqueCookies = <String, io.Cookie>{};
    for (var cookie in cookies) {
      var domain = cookie.domain;
      if (domain == null || domain.isEmpty) {
        throw StateError('Legacy cookie has no domain');
      }
      if (!domain.startsWith('.')) {
        // PersistCookieJar returns null for host-only cookies; all cookies
        // with a domain at this point came from a shared-domain store.
        domain = '.$domain';
        cookie.domain = domain;
      }
      if (cookie.path == null ||
          cookie.path!.isEmpty ||
          !cookie.path!.startsWith('/')) {
        cookie.path = '/';
      }
      final key = '${cookie.name}\u0000$domain\u0000${cookie.path}';
      uniqueCookies[key] = cookie;
    }
    final migratedCookies = uniqueCookies.values.toList(growable: false);
    target.saveCookies(migratedCookies);
    if (migratedCookies.any((cookie) => !target.containsCookie(cookie))) {
      throw StateError('Cookie migration read-back verification failed');
    }

    for (var directory in existingPaths) {
      await directory.delete(recursive: true);
    }
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
  var s = await SharedPreferences.getInstance();
  if (s.getString('picacgAccount') != null) {
    var account = s.getString('picacgAccount');
    var pwd = s.getString('picacgPassword');
    var token = s.getString('token');
    picacg.data['account'] = [account, pwd];
    picacg.data['token'] = token;
    picacg.data['user'] = Profile(
      s.getString("userId") ?? "",
      s.getString("userAvatar") ?? '',
      s.getString("userEmail") ?? "",
      s.getInt("userExp") ?? 0,
      s.getInt("userLevel") ?? 0,
      s.getString("userName") ?? "",
      s.getString("userTitle") ?? "",
      false,
      '',
      '',
    ).toJson();
    picacg.data['appChannel'] = s.getString("appChannel") ?? "3";
    picacg.data['imageQuality'] = s.getString('image') ?? "original";
    await picacg.saveData();
    await s.remove('picacgAccount');
  }
  if (s.getString("jmName") != null) {
    var account = s.getString('jmName');
    var pwd = s.getString('jmPwd');
    jm.data['account'] = [account, pwd];
    jm.data['name'] = account;
    await s.remove("jmName");
    await jm.saveData();
  }
  if (s.getString("ehAccount") != null) {
    ehentai.data['account'] = 'ok';
    ehentai.data['name'] = s.getString("ehAccount")!;
    await s.remove("ehAccount");
    await ehentai.saveData();
  }
  if (s.getString('htName') != null) {
    var account = s.getString('htName');
    var pwd = s.getString('htPwd');
    htManga.data['account'] = [account, pwd];
    htManga.data['name'] = account;
    await s.remove('htName');
    await htManga.saveData();
  }
  NhentaiNetwork().init();
  if (NhentaiNetwork().logged) {
    nhentai.data['account'] = 'ok';
    await nhentai.saveData();
  }
}
