import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';

import 'http_client.dart';

class NativeCurlHttpClient {
  static const _channel =
      MethodChannel("com.github.pacalini.pica_comic/native_curl");

  static Future<bool>? _availableFuture;

  static Future<bool> get isAvailable {
    if (!App.isAndroid) return Future.value(false);
    return _availableFuture ??= _channel
        .invokeMethod<bool>("available")
        .then((value) => value == true)
        .catchError((_) => false);
  }

  static bool shouldHandle(RequestOptions options) {
    if (!App.isAndroid) return false;
    if (proxyHttpOverrides?.proxyConfig == null) return false;
    final host = options.uri.host.toLowerCase();
    return _hostMatches(host, "e-hentai.org") ||
        _hostMatches(host, "exhentai.org") ||
        _hostMatches(host, "ehgt.org") ||
        _hostMatches(host, "nhentai.net") ||
        _hostMatches(host, "hitomi.la") ||
        _hostMatches(host, "gold-usergeneratedcontent.net") ||
        _isHitomiCdnHost(host);
  }

  static bool _hostMatches(String host, String domain) {
    return host == domain || host.endsWith(".$domain");
  }

  static bool _isHitomiCdnHost(String host) {
    return host.startsWith("ltn.") ||
        host.startsWith("atn.") ||
        host.startsWith("btn.") ||
        host.startsWith("w1.") ||
        host.startsWith("w2.");
  }

  static Future<ResponseBody> fetchUri(
    AppProxyConfig config,
    Uri uri, {
    String method = "GET",
    Map<String, String>? headers,
    Uint8List? body,
    Duration timeout = const Duration(seconds: 15),
    int attempts = 3,
  }) async {
    final options = RequestOptions(
      path: uri.toString(),
      method: method,
      headers: headers,
      connectTimeout: timeout,
      sendTimeout: timeout,
      receiveTimeout: timeout,
    );
    return _fetchWithProxy(
      options,
      body,
      _curlProxy(config),
      attempts: attempts,
    );
  }

  static Future<ResponseBody> fetch(
    RequestOptions options,
    Uint8List? body,
  ) async {
    final proxy = _curlProxy(proxyHttpOverrides!.proxyConfig!);
    return _fetchWithProxy(options, body, proxy);
  }

  static Future<ResponseBody> _fetchWithProxy(
    RequestOptions options,
    Uint8List? body,
    String proxy, {
    int attempts = 3,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>("fetch", {
      "method": options.method,
      "url": options.uri.toString(),
      "proxy": proxy,
      "headers": _headersToStringMap(options.headers),
      "body": body,
      "timeoutMs": _timeoutMs(options),
      "attempts": attempts,
    });

    if (result == null) {
      throw DioException(
        requestOptions: options,
        error: "native curl returned empty result",
        type: DioExceptionType.connectionError,
      );
    }

    final error = result["error"];
    if (error != null) {
      throw DioException(
        requestOptions: options,
        error: error,
        message: error.toString(),
        type: DioExceptionType.connectionError,
      );
    }

    final responseBody = ResponseBody.fromBytes(
      (result["body"] as Uint8List?) ?? Uint8List(0),
      (result["statusCode"] as int?) ?? 0,
      headers: _parseHeaders(result["headers"]),
    );
    final usedAttempts = result["attempts"];
    LogManager.addLog(
        LogLevel.info,
        "Network",
        "Native curl ${options.method} ${options.uri} ${responseBody.statusCode}"
            "${usedAttempts == null ? "" : " attempts=$usedAttempts"}");
    return responseBody;
  }

  static Map<String, String> _headersToStringMap(Map<String, dynamic> raw) {
    final headers = <String, String>{};
    for (final entry in raw.entries) {
      final value = _headerValueToString(entry.value);
      if (value != null && value.isNotEmpty) {
        headers[entry.key] = value;
      }
    }
    return headers;
  }

  static String? _headerValueToString(Object? value) {
    if (value == null) return null;
    if (value is Iterable) {
      return value
          .where((item) => item != null)
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .join(", ");
    }
    return value.toString().trim();
  }

  static Future<Uint8List?> readBody(Stream<Uint8List>? stream) async {
    if (stream == null) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static int _timeoutMs(RequestOptions options) {
    final values = [
      options.connectTimeout,
      options.sendTimeout,
      options.receiveTimeout,
    ].whereType<Duration>().map((duration) => duration.inMilliseconds);
    final max = values.isEmpty
        ? 15000
        : values.reduce((value, element) => value > element ? value : element);
    return max <= 0 ? 15000 : max;
  }

  static String _curlProxy(AppProxyConfig config) {
    final scheme = config.isSocks5 ? "socks5h" : "http";
    final auth = config.hasAuth ? "${config.userInfo}@" : "";
    return "$scheme://$auth${config.hostPort}";
  }

  static Map<String, List<String>> _parseHeaders(Object? raw) {
    final headers = <String, List<String>>{};
    if (raw is! Map) return headers;
    for (final entry in raw.entries) {
      final key = entry.key?.toString().toLowerCase();
      if (key == null || key.isEmpty) continue;
      final value = entry.value;
      if (value is List) {
        headers[key] = value.map((item) => item.toString()).toList();
      } else if (value != null) {
        headers[key] = [value.toString()];
      }
    }
    return headers;
  }
}
