import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/native_curl.dart';
import '../base.dart';

String _networkErrorText(Object? error) {
  var parts = <String>[];
  if (error is DioException) {
    if (error.message != null) parts.add(error.message!);
    if (error.error != null) parts.add(error.error.toString());
  }
  if (error != null) parts.add(error.toString());
  return parts.join("\n");
}

String describeNetworkError(Object? error) {
  var text = _networkErrorText(error);
  if (error is TimeoutException || text.contains("TimeoutException")) {
    return "连接超时";
  }
  if (text.contains("Connection terminated during handshake") ||
      text.contains("HandshakeException")) {
    return "HTTPS 握手失败：代理端口可连接，但 TLS 握手被关闭，请检查代理类型（HTTP/SOCKS5）和代理规则。";
  }
  if (text.contains("Connection reset by peer")) {
    return "连接被重置：代理或远端服务器关闭了连接。";
  }
  if (text.contains("Failed host lookup")) {
    return "域名解析失败，请检查网络或代理规则。";
  }
  if (text.contains("Connection refused")) {
    return "连接被拒绝，请检查代理地址和端口。";
  }
  return error.toString();
}

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    LogManager.addLog(LogLevel.error, "Network",
        "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}");
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
              message: "Invalid Status Code: $statusCode. "
                  "${_getStatusCodeInfo(statusCode)}");
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
            message: "Receive Timeout: "
                "This indicates that the server is too busy to respond");
      case DioExceptionType.sendTimeout:
        err = err.copyWith(message: "Send Timeout");
      case DioExceptionType.connectionError:
        err = err.copyWith(message: describeNetworkError(err));
      case DioExceptionType.badCertificate:
        err = err.copyWith(message: "Bad Certificate");
      case DioExceptionType.cancel:
        err = err.copyWith(message: "Request Cancelled");
      case DioExceptionType.unknown:
        var message = describeNetworkError(err);
        if (message != err.toString()) {
          err = err.copyWith(message: message);
        }
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    var headers = response.headers.map.map((key, value) => MapEntry(
        key.toLowerCase(), value.length == 1 ? value.first : value.toString()));
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    LogManager.addLog(
        (response.statusCode != null && response.statusCode! < 400)
            ? LogLevel.info
            : LogLevel.error,
        "Network",
        "Response ${response.realUri.toString()} ${response.statusCode}\n"
            "headers:\n$headers\n$content");
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppHttpAdapter implements HttpClientAdapter {
  HttpClientAdapter? adapter;
  String? _adapterProxySignature;

  final bool http2;

  AppHttpAdapter(this.http2);

  static String _proxySignature() {
    final overrides = proxyHttpOverrides;
    final config = overrides?.proxyConfig;
    return [
      overrides?.proxy ?? "",
      config?.uriString ?? "",
      config?.useHostRules == true ? "1" : "0",
      appdata.settings[58],
    ].join("|");
  }

  static HttpClientAdapter _createIoAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final overrides = proxyHttpOverrides;
        return overrides?.createHttpClient(null) ?? HttpClient();
      },
    );
  }

  static Future<HttpClientAdapter> createAdapter(bool http2) async {
    final proxyConfig = proxyHttpOverrides?.proxyConfig;
    return http2 && proxyConfig?.isSocks5 != true
        ? Http2Adapter(
            ConnectionManager(
              idleTimeout: const Duration(seconds: 15),
              onClientCreate: (_, config) {
                var proxyUri = proxyConfig?.http2ProxyUri;
                if (proxyUri != null && appdata.settings[58] != "1") {
                  config.proxy = proxyUri;
                }
              },
            ),
          )
        : _createIoAdapter();
  }

  @override
  void close({bool force = false}) {
    adapter?.close(force: force);
  }

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    await setNetworkProxy();
    final proxySignature = _proxySignature();
    if (adapter == null || _adapterProxySignature != proxySignature) {
      adapter?.close(force: true);
      adapter = await createAdapter(http2);
      _adapterProxySignature = proxySignature;
    }
    int retry = 0;
    while (true) {
      try {
        var res = await fetchOnce(o, requestStream, cancelFuture);
        return res;
      } catch (e) {
        if (e is DioException) {
          if (e.response?.statusCode != null) {
            var code = e.response!.statusCode!;
            if (code >= 400 && code < 500) {
              rethrow;
            }
          }
        }
        LogManager.addLog(LogLevel.error, "Network",
            "${o.method} ${o.path}\n$e\nRetrying...");
        retry++;
        if (retry == 2) {
          rethrow;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<ResponseBody> fetchOnce(RequestOptions o,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    var options = o.copyWith();
    LogManager.addLog(LogLevel.info, "Network",
        "${options.method} ${options.path}\nheaders:\n${options.headers.toString()}\ndata:${options.data}");
    if (NativeCurlHttpClient.shouldHandle(options) &&
        await NativeCurlHttpClient.isAvailable) {
      final body = await NativeCurlHttpClient.readBody(requestStream);
      try {
        return checkCookie(await NativeCurlHttpClient.fetch(options, body));
      } catch (e) {
        LogManager.addLog(LogLevel.error, "Network",
            "Native curl failed\n${options.method} ${options.uri}\n$e");
        rethrow;
      }
    }
    return checkCookie(
        await adapter!.fetch(options, requestStream, cancelFuture));
  }

  /// 检查cookie是否合法, 去除无效cookie
  ResponseBody checkCookie(ResponseBody res) {
    if (res.headers["set-cookie"] == null) {
      return res;
    }

    var cookies = <String>[];

    var invalid = <String>[];

    for (var cookie in res.headers["set-cookie"]!) {
      try {
        Cookie.fromSetCookieValue(cookie);
        cookies.add(cookie);
      } catch (e) {
        invalid.add(cookie);
      }
    }

    if (cookies.isNotEmpty) {
      res.headers["set-cookie"] = cookies;
    } else {
      res.headers.remove("set-cookie");
    }

    if (invalid.isNotEmpty) {
      res.headers["invalid-cookie"] = invalid;
    }

    return res;
  }
}

Dio logDio([BaseOptions? options, bool http2 = false]) {
  var dio = Dio(options)..interceptors.add(MyLogInterceptor());
  dio.httpClientAdapter = AppHttpAdapter(http2);
  return dio;
}
