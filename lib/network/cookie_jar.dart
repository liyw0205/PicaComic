import 'dart:io';

import 'package:dio/dio.dart';
import 'package:sqlite3/sqlite3.dart';

class CookieJarSql {
  late Database _db;

  final String path;

  CookieJarSql(this.path) {
    init();
  }

  void init() {
    _db = sqlite3.open(path);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cookies (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        domain TEXT NOT NULL,
        path TEXT,
        expires INTEGER,
        secure INTEGER,
        httpOnly INTEGER,
        PRIMARY KEY (name, domain, path)
      );
    ''');
  }

  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    // The SQLite schema uses a bare host for host-only cookies. Preserve the
    // distinction by canonicalizing an explicit Domain attribute to a dot
    // domain before persisting it.
    for (var cookie in cookies) {
      final domain = cookie.domain;
      if (domain != null && domain.isNotEmpty && !domain.startsWith('.')) {
        cookie.domain = '.$domain';
      }
    }
    saveCookies(cookies, defaultDomain: uri.host);
  }

  /// Saves a batch atomically so callers can verify it before discarding a
  /// source copy (for example, during a storage migration).
  void saveCookies(Iterable<Cookie> cookies, {String? defaultDomain}) {
    final pending = cookies.toList(growable: false);
    if (pending.isEmpty) {
      return;
    }

    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var cookie in pending) {
        final domain = _normalizeDomain(cookie.domain ?? defaultDomain);
        if (domain == null || domain.isEmpty) {
          throw ArgumentError('A cookie domain is required');
        }
        _db.execute('''
        INSERT OR REPLACE INTO cookies (name, value, domain, path, expires, secure, httpOnly)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''', [
          cookie.name,
          cookie.value,
          domain,
          _normalizePath(cookie.path),
          cookie.expires?.millisecondsSinceEpoch,
          cookie.secure ? 1 : 0,
          cookie.httpOnly ? 1 : 0
        ]);
      }
      _db.execute('COMMIT;');
    } catch (_) {
      try {
        _db.execute('ROLLBACK;');
      } catch (_) {
        // Preserve the original write error if rollback is unavailable.
      }
      rethrow;
    }
  }

  /// Returns whether the exact persisted representation of [cookie] exists.
  bool containsCookie(Cookie cookie, {String? defaultDomain}) {
    final domain = _normalizeDomain(cookie.domain ?? defaultDomain);
    if (domain == null || domain.isEmpty) {
      return false;
    }
    final rows = _db.select('''
      SELECT value, expires, secure, httpOnly
      FROM cookies
      WHERE name = ? AND domain = ? AND path = ?;
    ''', [cookie.name, domain, _normalizePath(cookie.path)]);
    return rows.any((row) =>
        row["value"] == cookie.value &&
        row["expires"] == cookie.expires?.millisecondsSinceEpoch &&
        row["secure"] == (cookie.secure ? 1 : 0) &&
        row["httpOnly"] == (cookie.httpOnly ? 1 : 0));
  }

  List<Cookie> _loadWithDomain(String domain) {
    var rows = _db.select('''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies
      WHERE domain = ?;
    ''', [domain]);

    return rows
        .map((row) => Cookie(
              row["name"] as String,
              row["value"] as String,
            )
              ..domain = row["domain"] as String
              ..path = row["path"] as String
              ..expires = row["expires"] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(row["expires"] as int)
              ..secure = row["secure"] == 1
              ..httpOnly = row["httpOnly"] == 1)
        .toList();
  }

  List<String> _getAcceptedDomains(String host) {
    final normalizedHost = host.toLowerCase();
    final acceptedDomains = <String>[normalizedHost];
    final hostParts = normalizedHost.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      final suffix = hostParts.sublist(i).join(".");
      acceptedDomains.add(".$suffix");
    }
    return acceptedDomains;
  }

  List<Cookie> loadForRequest(Uri uri) {
    // if uri.host is example.example.com, acceptedDomains will be [".example.example.com", ".example.com", "example.com"]
    var acceptedDomains = _getAcceptedDomains(uri.host);

    var cookies = <Cookie>[];
    for (var domain in acceptedDomains) {
      cookies.addAll(_loadWithDomain(domain));
    }

    // check expires
    var expires = cookies.where((cookie) =>
        cookie.expires != null && cookie.expires!.isBefore(DateTime.now()));
    for (var cookie in expires) {
      _db.execute('''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''', [cookie.name, cookie.domain, cookie.path]);
    }

    return cookies
        .where((element) =>
            !expires.contains(element) &&
            (!element.secure || uri.scheme.toLowerCase() == 'https') &&
            _checkPathMatch(uri, element.path))
        .toList();
  }

  bool _checkPathMatch(Uri uri, String? cookiePath) {
    if (cookiePath == null) {
      return true;
    }

    final requestPath = uri.path.isEmpty ? "/" : uri.path;
    final normalizedCookiePath = cookiePath.isEmpty ? "/" : cookiePath;
    if (normalizedCookiePath == requestPath) {
      return true;
    }

    if (normalizedCookiePath == "/") {
      return true;
    }

    if (!requestPath.startsWith(normalizedCookiePath)) {
      return false;
    }

    return normalizedCookiePath.endsWith("/") ||
        requestPath.length > normalizedCookiePath.length &&
            requestPath[normalizedCookiePath.length] == "/";
  }

  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeader) {
    var cookies = cookieHeader
        .map((header) => Cookie.fromSetCookieValue(header))
        .toList();
    saveFromResponse(uri, cookies);
  }

  String loadForRequestCookieHeader(Uri uri) {
    var cookies = loadForRequest(uri);
    // RFC 6265 recommends longer paths first. Keep same-name cookies from
    // different paths instead of silently dropping one of them.
    cookies.sort((a, b) =>
        _normalizePath(b.path).length.compareTo(_normalizePath(a.path).length));
    return cookies.map((cookie) => "${cookie.name}=${cookie.value}").join("; ");
  }

  String? _normalizeDomain(String? domain) {
    if (domain == null) {
      return null;
    }
    final value = domain.trim().toLowerCase();
    return value.isEmpty ? null : value;
  }

  String _normalizePath(String? path) {
    if (path == null || path.isEmpty || !path.startsWith('/')) {
      return '/';
    }
    return path;
  }

  void delete(Uri uri, String name) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute('''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''', [name, domain, uri.path]);
    }
  }

  void deleteUri(Uri uri) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute('''
        DELETE FROM cookies
        WHERE domain = ?;
      ''', [domain]);
    }
  }

  void deleteAll() {
    _db.execute('''
      DELETE FROM cookies;
    ''');
  }

  void dispose() {
    _db.dispose();
  }
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;
}

class CookieManagerSql extends Interceptor {
  final CookieJarSql cookieJar;

  CookieManagerSql(this.cookieJar);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    var cookies = cookieJar.loadForRequestCookieHeader(options.uri);
    if (cookies.isNotEmpty) {
      options.headers["cookie"] = cookies;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    cookieJar.saveFromResponseCookieHeader(
        response.requestOptions.uri, response.headers["set-cookie"] ?? []);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }
}
