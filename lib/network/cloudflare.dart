import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';

import '../components/components.dart';

class CloudflareException implements DioException {
  final String url;

  const CloudflareException(this.url);

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    return CloudflareException(match.group(1)!);
  }

  @override
  DioException copyWith(
      {RequestOptions? requestOptions,
      Response<dynamic>? response,
      DioExceptionType? type,
      Object? error,
      StackTrace? stackTrace,
      String? message}) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;
}

@visibleForTesting
class CloudflareCompletionGate {
  bool _completed = false;

  bool tryComplete() {
    if (_completed) return false;
    _completed = true;
    return true;
  }
}

@visibleForTesting
Future<Map<String, String>?> verifiedCloudflareCookies({
  required Future<Map<String, String>> Function() readCookies,
  required Future<bool> Function() isVerifiedPage,
}) async {
  final cookies = await readCookies();
  if (cookies['cf_clearance']?.trim().isNotEmpty != true) return null;
  if (!await isVerifiedPage()) return null;
  return cookies;
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.headers['cookie'].toString().contains('cf_clearance')) {
      options.headers['user-agent'] = appdata.implicitData[3];
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      return CloudflareException(response.requestOptions.uri.toString());
    }
    return null;
  }
}

Future<void> passCloudflare(
    CloudflareException e, void Function() onFinished) async {
  final url = e.url;
  final uri = Uri.parse(url);
  final verifiedPageScript = 'location.origin === ${jsonEncode(uri.origin)} && '
      "document.readyState !== 'loading' && typeof window._cf_chl_opt === 'undefined'";
  final completionGate = CloudflareCompletionGate();
  var sessionSyncInProgress = false;

  void saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    SingleInstanceCookieJar.instance!.saveFromResponse(
      uri,
      List<io.Cookie>.generate(cookies.length, (index) {
        var cookie = io.Cookie(
            cookies.keys.elementAt(index), cookies.values.elementAt(index));
        cookie.domain = domain;
        return cookie;
      }),
    );
  }

  void logSyncFailure(Object error) {
    Log.warning('Cloudflare',
        'WebView session sync failed: ${safeNetworkError(error)}');
  }

  Future<void> syncSession({
    required Future<Map<String, String>> Function() readCookies,
    required Future<bool> Function() isVerifiedPage,
    required Future<String?> Function() readUserAgent,
    required void Function() close,
  }) async {
    if (completionGate._completed || sessionSyncInProgress) return;
    sessionSyncInProgress = true;
    try {
      final cookies = await verifiedCloudflareCookies(
        readCookies: readCookies,
        isVerifiedPage: isVerifiedPage,
      );
      if (cookies == null || completionGate._completed) return;
      final ua = await readUserAgent();
      if (ua == null || ua.isEmpty || completionGate._completed) return;

      saveCookies(cookies);
      appdata.implicitData[3] = ua;
      unawaited(appdata.writeImplicitData().catchError(logSyncFailure));
    } catch (error) {
      logSyncFailure(error);
      return;
    } finally {
      sessionSyncInProgress = false;
    }
    if (completionGate.tryComplete()) {
      close();
      onFinished();
    }
  }

  if (App.isDesktop && (await DesktopWebview.isAvailable())) {
    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (_, controller) => unawaited(syncSession(
        readCookies: () => controller.getCookies(url),
        isVerifiedPage: () async =>
            await controller.evaluateJavascript(verifiedPageScript) == 'true',
        readUserAgent: () async => controller.userAgent,
        close: controller.close,
      )),
      onClose: completionGate.tryComplete,
    );
    unawaited(webview.open());
  } else if (App.isMobile) {
    await App.globalTo(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onLoadStop: (controller) => unawaited(syncSession(
          readCookies: () async => await controller.getCookies(url) ?? {},
          isVerifiedPage: () async =>
              await controller.evaluateJavascript(source: verifiedPageScript) ==
              true,
          readUserAgent: controller.getUA,
          close: App.globalBack,
        )),
      ),
    );
    completionGate.tryComplete();
  } else {
    showToast(message: "当前设备不支持".tl);
  }
}
