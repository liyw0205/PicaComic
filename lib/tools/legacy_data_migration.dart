import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:pica_comic/network/cookie_jar.dart';

/// Reads persisted jars without opening PersistCookieJar: opening a corrupt
/// legacy jar can delete its metadata before migration has finished.
Future<void> migrateLegacyCookieDirectories(
    String dataPath, CookieJarSql destination) async {
  final sources = [
    Directory('$dataPath/cookies'),
    Directory('$dataPath/eh_cookies'),
    Directory('$dataPath/comic_source/cookies'),
  ];
  final marker = File('$dataPath/legacy_migration_v1/cookies.completed.json');
  final completed = <String, dynamic>{};
  if (await marker.exists()) {
    final state = _jsonMap(await marker.readAsString());
    if (state['version'] != 1) {
      throw const FormatException('Unknown legacy cookie migration version');
    }
    completed.addAll(_jsonMap(state['sources']));
  }
  final existing = <Directory>[];
  final fingerprints = <String, String>{};
  final cookies = <String, Cookie>{};
  for (final source in sources) {
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('Legacy cookie directory is not a directory');
    }
    existing.add(source);
    final fingerprint = await _cookieSourceFingerprint(source);
    fingerprints[source.path] = fingerprint;
    if (completed[source.path] == fingerprint) continue;
    for (final cookie in await _readLegacyCookieDirectory(source)) {
      final key = '${cookie.name}\u0000${cookie.domain}\u0000${cookie.path}';
      final previous = cookies[key];
      if (previous != null && previous.toString() != cookie.toString()) {
        throw const FormatException('Conflicting legacy cookie records');
      }
      cookies[key] = cookie;
    }
  }
  if (existing.isEmpty) return;
  destination.saveCookies(cookies.values);
  if (cookies.values.any((cookie) => !destination.containsCookie(cookie))) {
    throw StateError('Cookie migration read-back verification failed');
  }
  for (final source in existing) {
    if (await _cookieSourceFingerprint(source) != fingerprints[source.path]) {
      throw StateError('Legacy cookie source changed during migration');
    }
  }
  await _writeMigrationJson(marker, {
    'version': 1,
    'sources': {...completed, ...fingerprints},
  });
  for (final source in existing) {
    // Rename only after the entire batch verifies. Keeping the complete source
    // snapshot also makes a crash between directory moves safe to retry.
    var backupPath = '${source.path}.legacy-v1-backup';
    var suffix = 1;
    while (await FileSystemEntity.type(backupPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      backupPath = '${source.path}.legacy-v1-backup-${suffix++}';
    }
    await source.rename(backupPath);
  }
}

Future<String> _cookieSourceFingerprint(Directory source) async {
  final files = <String, String>{};
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    if (entry is Directory) continue;
    if (entry is! File) {
      throw const FormatException('Unsupported legacy cookie storage entry');
    }
    files[entry.path.substring(source.path.length)] =
        sha256.convert(await entry.readAsBytes()).toString();
  }
  return sha256.convert(utf8.encode(_canonicalJson(files))).toString();
}

Future<List<Cookie>> _readLegacyCookieDirectory(Directory source) async {
  final entries = await source.list(followLinks: false).toList();
  final storageDirectories = <Directory>[];
  var hasRootFiles = false;
  for (final entry in entries) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    if (entry is Directory && RegExp(r'^ie[01]_ps[01]$').hasMatch(name)) {
      storageDirectories.add(entry);
    } else if (entry is File) {
      hasRootFiles = true;
    } else {
      throw const FormatException('Unsupported legacy cookie storage entry');
    }
  }
  storageDirectories.sort((a, b) => a.path.compareTo(b.path));
  if (hasRootFiles) storageDirectories.insert(0, source);
  final result = <Cookie>[];
  for (final storage in storageDirectories) {
    result.addAll(await _readLegacyCookieStorage(storage,
        allowStorageDirectories: storage.path == source.path));
  }
  return result;
}

Future<List<Cookie>> _readLegacyCookieStorage(Directory directory,
    {required bool allowStorageDirectories}) async {
  final files = <String, File>{};
  await for (final entry in directory.list(followLinks: false)) {
    if (allowStorageDirectories && entry is Directory) continue;
    if (entry is! File) {
      throw const FormatException('Unsupported legacy cookie storage entry');
    }
    files[entry.uri.pathSegments.last] = entry;
  }
  if (files.isEmpty) return [];
  final domains = files.remove('.domains');
  final index = files.remove('.index');
  final result = <Cookie>[];
  final domainNames = <String>[];
  if (domains != null) {
    final map = _jsonMap(await domains.readAsString());
    for (final entry in map.entries) {
      final domain = _normalizeLegacyHost(entry.key, shared: true);
      domainNames.add(domain);
      result.addAll(_readCookiePaths(entry.value, domain, shared: true));
    }
  }
  if (index == null) {
    throw const FormatException('Legacy cookie index is missing');
  }
  final indexValue = jsonDecode(await index.readAsString());
  if (indexValue is! List || indexValue.any((host) => host is! String)) {
    throw const FormatException('Invalid legacy cookie index');
  }
  final indexedHosts = <String>{};
  for (final value in indexValue.cast<String>()) {
    final host = _normalizeLegacyHost(value, shared: false);
    indexedHosts.add(host);
    // PersistCookieJar indexes a response host even when it only receives
    // shared-domain cookies and therefore never writes a host cookie file.
    if (!files.containsKey(value) &&
        !domainNames
            .any((domain) => host == domain || host.endsWith('.$domain'))) {
      throw const FormatException('Legacy cookie host file is missing');
    }
  }
  for (final entry in files.entries) {
    final host = _normalizeLegacyHost(entry.key, shared: false);
    if (!indexedHosts.contains(host)) {
      throw const FormatException('Legacy cookie index is incomplete');
    }
    result.addAll(_readCookiePaths(
        jsonDecode(await entry.value.readAsString()), host,
        shared: false));
  }
  return result;
}

Map<String, dynamic> _jsonMap(dynamic value) {
  if (value is String) value = jsonDecode(value);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid legacy migration map');
  }
  return value;
}

String _normalizeLegacyHost(String value, {required bool shared}) {
  var host = value;
  if (shared && host.startsWith('.')) host = host.substring(1);
  if (host.isEmpty ||
      host.trim() != host ||
      host.startsWith('.') ||
      host.endsWith('.') ||
      host.contains('..') ||
      RegExp(r'[\s/\\?#@;\x00]').hasMatch(host)) {
    throw const FormatException('Invalid legacy cookie host');
  }
  return host.toLowerCase();
}

List<Cookie> _readCookiePaths(dynamic value, String host,
    {required bool shared}) {
  final result = <Cookie>[];
  for (final pathEntry in _jsonMap(value).entries) {
    final path = pathEntry.key.isEmpty ? '/' : pathEntry.key;
    if (!path.startsWith('/')) {
      throw const FormatException('Invalid legacy cookie path');
    }
    for (final entry in _jsonMap(pathEntry.value).entries) {
      final serialized = entry.value;
      if (serialized is! String ||
          !RegExp(r';_crt=\d+$').hasMatch(serialized)) {
        throw const FormatException('Invalid legacy cookie record');
      }
      final stored = SerializableCookie.fromJson(serialized);
      final cookie = stored.cookie;
      if (cookie.name != entry.key ||
          (cookie.path != null && cookie.path != pathEntry.key)) {
        throw const FormatException('Inconsistent legacy cookie record');
      }
      if (shared) {
        if (cookie.domain == null ||
            _normalizeLegacyHost(cookie.domain!, shared: true) != host) {
          throw const FormatException('Inconsistent legacy cookie domain');
        }
      } else if (cookie.domain != null) {
        throw const FormatException('Host-only legacy cookie has a domain');
      }
      cookie.domain = shared ? '.$host' : host;
      cookie.path = path;
      if (cookie.maxAge != null) {
        final maxAgeExpiry = DateTime.fromMillisecondsSinceEpoch(
            (stored.createTimeStamp + cookie.maxAge!) * 1000,
            isUtc: true);
        if (cookie.expires == null || maxAgeExpiry.isBefore(cookie.expires!)) {
          cookie.expires = maxAgeExpiry;
        }
        cookie.maxAge = null;
      }
      result.add(cookie);
    }
  }
  return result;
}

/// Commits an account before removing its old lookup key. The backup and
/// completion marker survive a failed preference removal and repeated starts.
Future<Map<String, dynamic>> migrateLegacyAccount({
  required String dataPath,
  required String sourceKey,
  required String destinationKey,
  required Map<String, dynamic> sourceValues,
  required Map<String, dynamic> values,
  required Future<bool> Function() removeSource,
}) async {
  final account = values['account'];
  final primaryValue = sourceValues[sourceKey];
  if (primaryValue is! String ||
      primaryValue.isEmpty ||
      (account is List &&
          (account.length != 2 || account.any((value) => value is! String)))) {
    throw const FormatException('Incomplete legacy account');
  }
  final backupDirectory = Directory('$dataPath/legacy_migration_v1/accounts');
  await backupDirectory.create(recursive: true);
  final destination = File('$dataPath/comic_source/$destinationKey.data');
  final marker = File('${backupDirectory.path}/$sourceKey.completed.json');
  final encodedSource = _canonicalJson(sourceValues);
  if (await marker.exists()) {
    final state = _jsonMap(await marker.readAsString());
    if (state['version'] == 1 &&
        _canonicalJson(state['sourceValues']) == encodedSource) {
      final current = _jsonMap(await destination.readAsString());
      if (!await removeSource()) {
        throw StateError('Failed to remove migrated legacy account entry');
      }
      return current;
    }
  }

  final previous = await destination.exists()
      ? _jsonMap(await destination.readAsString())
      : <String, dynamic>{};
  var backup = File('${backupDirectory.path}/$sourceKey.json');
  var suffix = 1;
  while (await backup.exists()) {
    final saved = _jsonMap(await backup.readAsString());
    if (_canonicalJson(saved['sourceValues']) == encodedSource) break;
    backup = File('${backupDirectory.path}/$sourceKey-${suffix++}.json');
  }
  if (!await backup.exists()) {
    await _writeMigrationJson(backup, {
      'version': 1,
      'sourceKey': sourceKey,
      'sourceValues': sourceValues,
      'destinationKey': destinationKey,
      'destinationBefore': previous,
    });
  }
  final merged = {...previous, ...values};
  await _writeMigrationJson(destination, merged);
  final persisted = _jsonMap(await destination.readAsString());
  if (_canonicalJson(persisted) != _canonicalJson(merged)) {
    throw StateError('Legacy account migration read-back verification failed');
  }
  await _writeMigrationJson(marker, {
    'version': 1,
    'sourceValues': sourceValues,
    'backup': backup.uri.pathSegments.last,
  });
  if (!await removeSource()) {
    throw StateError('Failed to remove migrated legacy account entry');
  }
  return persisted;
}

Future<void> _writeMigrationJson(File file, Map<String, dynamic> data) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.migration-tmp');
  await temporary.writeAsString(jsonEncode(data), flush: true);
  await temporary.rename(file.path);
}

String _canonicalJson(dynamic value) {
  dynamic canonicalize(dynamic item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonicalize(item[key])};
    }
    if (item is List) return item.map(canonicalize).toList();
    return item;
  }

  return jsonEncode(canonicalize(value));
}
