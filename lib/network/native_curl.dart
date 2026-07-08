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
    return host == "e-hentai.org" ||
        host == "exhentai.org" ||
        host == "api.e-hentai.org" ||
        host == "forums.e-hentai.org" ||
        host == "nhentai.net" ||
        host == "hitomi.la" ||
        host.startsWith("ltn.");
  }

  static Future<ResponseBody> fetch(
    RequestOptions options,
    Uint8List? body,
  ) async {
    final proxy = _curlProxy(proxyHttpOverrides!.proxyConfig!);
    final timeout = _timeoutMs(options);
    final headers = <String, String>{};
    for (final entry in options.headers.entries) {
      if (entry.value == null) continue;
      headers[entry.key] = entry.value.toString();
    }

    final result = await _channel.invokeMapMethod<String, dynamic>("fetch", {
      "method": options.method,
      "url": options.uri.toString(),
      "proxy": proxy,
      "headers": headers,
      "body": body,
      "timeoutMs": timeout,
      "attempts": 3,
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
    final attempts = result["attempts"];
    LogManager.addLog(
        LogLevel.info,
        "Network",
        "Native curl ${options.method} ${options.uri} ${responseBody.statusCode}"
            "${attempts == null ? "" : " attempts=$attempts"}");
    return responseBody;
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
