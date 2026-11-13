import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/image_recombine.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/download_progress.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/file_type.dart';

import '../base.dart';
import '../network/eh_network/eh_main_network.dart';
import '../network/eh_network/image_response_utils.dart';
import '../network/hitomi_network/image.dart';
import '../network/jm_network/headers.dart';
import '../network/res.dart';
import '../network/network_logging.dart';

export 'package:pica_comic/network/download_progress.dart';

class BadRequestException {
  final String message;

  const BadRequestException(this.message);

  @override
  String toString() => message;
}

String? _responseHeader(Map<String, List<String>> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase() &&
        entry.value.isNotEmpty) {
      return entry.value.first;
    }
  }
  return null;
}

class ImageManager {
  static ImageManager? cache;

  ///用于标记正在加载的项目, 避免出现多个异步函数加载同一张图片
  static Map<String, DownloadProgress> loadingItems = {};
  static final Map<String, CancelToken> _cancelTokens = {};
  static final Map<String, Object?> _taskOwners = {};
  static final Object _taskOwnerZoneKey = Object();
  static final Set<Object> _cancelledOwners = {};

  /// Image cache manager for reader and download manager
  factory ImageManager() => cache ??= ImageManager._create();

  static bool get haveTask => loadingItems.isNotEmpty;

  static void clearTasks() {
    for (final token in _cancelTokens.values) {
      token.cancel('Image tasks cleared');
    }
  }

  static Stream<T> withTaskOwner<T>(Stream<T> stream, Object owner) {
    return Stream<T>.multi((controller) {
      final subscription = runZoned(
        () => stream.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) =>
              controller.addError(error, stackTrace),
          onDone: () {
            _cancelledOwners.remove(owner);
            controller.close();
          },
        ),
        zoneValues: {_taskOwnerZoneKey: owner},
      );
      controller
        ..onPause = subscription.pause
        ..onResume = subscription.resume
        ..onCancel = () async {
          _cancelledOwners.add(owner);
          cancelTasksForOwner(owner);
          await subscription.cancel();
          for (final entry in _taskOwners.entries.toList()) {
            if (identical(entry.value, owner)) {
              final token = _cancelTokens[entry.key];
              if (token != null) _finishTask(entry.key, token);
            }
          }
          _cancelledOwners.remove(owner);
        };
    });
  }

  static void cancelTasksForOwner(Object owner) {
    for (final entry in _taskOwners.entries.toList()) {
      if (identical(entry.value, owner)) {
        _cancelTokens[entry.key]?.cancel('Image task owner cancelled');
      }
    }
  }

  ImageManager._create();

  final dio = logDio(BaseOptions())
    ..interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));

  int ehgtLoading = 0;

  Future<CancelToken> _startTask(String key) async {
    final owner = Zone.current[_taskOwnerZoneKey] as Object?;
    while (true) {
      if (owner != null && _cancelledOwners.contains(owner)) {
        throw StateError('Image task owner cancelled');
      }
      if (_cancelTokens.containsKey(key) || loadingItems[key] != null) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }

      // Claim the key without an async gap so concurrent waiters cannot both start.
      final token = CancelToken();
      _cancelTokens[key] = token;
      _taskOwners[key] = owner;
      loadingItems[key] = DownloadProgress(0, 1, key, "");
      return token;
    }
  }

  static void _finishTask(String key, CancelToken token) {
    if (identical(_cancelTokens[key], token)) {
      _cancelTokens.remove(key);
      _taskOwners.remove(key);
      loadingItems.remove(key);
    }
  }

  Future<void> _cleanupImageTask(
    String key,
    CancelToken token,
    CachingFile? caching, {
    bool countedEhgtSlot = false,
  }) async {
    try {
      await caching?.cancel();
    } catch (error) {
      LogManager.addLog(LogLevel.error, "Cache",
          "Failed to remove incomplete image cache: ${safeNetworkError(error)}");
    } finally {
      _finishTask(key, token);
      if (countedEhgtSlot) ehgtLoading--;
    }
  }

  /// 获取图片, 适用于没有任何限制的图片链接
  Stream<DownloadProgress> getImage(final String url,
      [Map<String, String>? headers]) async* {
    final cancelToken = await _startTask(url);
    var countedEhgtSlot = false;
    CachingFile? caching;

    try {
      final key = url;
      var cache = await CacheManager().findCache(key);
      if (cache != null) {
        yield DownloadProgress(
            1, 1, url, cache, null, CacheManager().getType(key));
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, url, savePath);
      headers = headers ?? {};
      headers["User-Agent"] ??= webUA;
      headers["Connection"] = "Keep-Alive";
      var realUrl = url;
      if (url.contains("s.exhentai.org")) {
        // s.exhentai.org 有严格的加载限制
        realUrl = url.replaceFirst("s.exhentai.org", "ehgt.org");
      }
      if (realUrl.contains("ehgt.org")) {
        if (ehgtLoading < 3) {
          ehgtLoading++;
          countedEhgtSlot = true;
          await Future.delayed(const Duration(milliseconds: 10));
        } else {
          while (ehgtLoading > 2) {
            if (cancelToken.isCancelled) {
              throw DioException(
                  requestOptions: RequestOptions(path: realUrl),
                  type: DioExceptionType.cancel);
            }
            await Future.delayed(const Duration(milliseconds: 200));
          }
          ehgtLoading++;
          countedEhgtSlot = true;
        }
      }
      var dioRes = await dio.get<ResponseBody>(realUrl,
          cancelToken: cancelToken,
          options:
              Options(responseType: ResponseType.stream, headers: headers));
      if (dioRes.data == null || _isHtmlResponse(dioRes)) {
        throw Exception("Empty Data");
      }
      final imageData = BytesBuilder(copy: false);
      final expectedBytes = int.tryParse(
          _responseHeader(dioRes.data!.headers, "content-length") ?? "");
      var currentBytes = 0;
      await for (var res in dioRes.data!.stream) {
        imageData.add(res);
        await cachingFile.writeBytes(res);
        currentBytes += res.length;
        var progress = DownloadProgress.inProgress(
            currentBytes, expectedBytes, url, savePath);
        yield progress;
        loadingItems[url] = progress;
      }
      if (currentBytes == 0 ||
          (expectedBytes != null && currentBytes != expectedBytes)) {
        throw const FormatException("Incomplete image response");
      }
      await cachingFile.close();
      final bytes = imageData.takeBytes();
      var ext = getExt(dioRes);
      CacheManager().setType(key, ext);
      yield DownloadProgress(
        bytes.length,
        bytes.length,
        url,
        savePath,
        bytes,
        ext,
      );
    } catch (e, s) {
      log("${e.runtimeType}\n$s", "Network", LogLevel.error);
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      await _cleanupImageTask(url, cancelToken, caching,
          countedEhgtSlot: countedEhgtSlot);
    }
  }

  Stream<DownloadProgress> getEhImageNew(
      final Gallery gallery, final int page) async* {
    final galleryLink = gallery.link;
    final cacheKey = "$galleryLink$page";
    final gid = getGalleryId(galleryLink);

    final cancelToken = await _startTask(cacheKey);

    CachingFile? caching;

    try {
      final key = cacheKey;
      var cache = await CacheManager().findCache(key);
      if (cache != null) {
        yield DownloadProgress(
            1, 1, key, cache, null, CacheManager().getType(key));
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, key, savePath);

      final options = BaseOptions(
          followRedirects: true,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 20),
          headers: {"user-agent": webUA, "cookie": EhNetwork().cookiesStr});

      var dio = logDio(options);

      // Get imgKey
      final readerLink = (await EhNetwork()
              .getReaderLink(galleryLink, page, cancelToken: cancelToken))
          .data;

      Future<void> getShowKey() async {
        while (gallery.auth!["showKey"] == "loading") {
          if (cancelToken.isCancelled) {
            throw DioException(
                requestOptions: RequestOptions(path: readerLink),
                type: DioExceptionType.cancel);
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (gallery.auth!["showKey"] != null ||
            gallery.auth!["mpvKey"] != null) {
          return;
        }
        gallery.auth!["showKey"] = "loading";
        try {
          var res =
              await EhNetwork().request(readerLink, cancelToken: cancelToken);

          var html = parse(res.data);
          var script = html
              .querySelectorAll("script")
              .firstWhereOrNull((element) => element.text.contains("showkey"));
          if (script != null) {
            var match = RegExp(r'showkey="(.*?)"').firstMatch(script.text);
            final showKey = match!.group(1)!;
            gallery.auth!["showKey"] = showKey;
          } else {
            final script = html
                .querySelectorAll("script")
                .firstWhereOrNull((element) => element.text.contains("mpvkey"))
                ?.text;
            if (script == null) {
              throw Exception("Failed to get showKey or mpvkey");
            }
            var mpvKey = script
                .split(";")
                .firstWhere((element) => element.contains("mpvkey"));
            gallery.auth!["mpvKey"] = mpvKey.removeAllBlank
                .replaceFirst("varmpvkey=", "")
                .replaceAll('"', "");
            var imageListScript = script
                .split(";")
                .firstWhere((element) => element.contains("imagelist"))
                .removeAllBlank
                .replaceFirst("varimagelist=", "");
            gallery.auth!["imgKey"] =
                jsonDecode(imageListScript).map((e) => e["k"]).join(",");
            gallery.auth!.remove("showKey");
          }
        } catch (e) {
          gallery.auth!.remove("showKey");
          rethrow;
        }
      }

      await getShowKey();
      assert(
          gallery.auth?["showKey"] != null || gallery.auth?["mpvKey"] != null);

      yield DownloadProgress(0, 100, cacheKey, savePath);

      Response<ResponseBody>? res;

      var imgKey = readerLink.split('/')[4];

      int totalBytes = 0;
      Uint8List? imageBytes;

      if (gallery.auth?["mpvKey"] != null) {
        Future<(String image, String nl)> getImageFromApi([String? nl]) async {
          Res<String>? apiRes = await EhNetwork().apiRequest({
            "gid": int.parse(gid),
            "imgkey": gallery.auth!["imgKey"]!.split(',')[page - 1],
            "method": "imagedispatch",
            "page": page,
            "mpvkey": gallery.auth!["mpvKey"],
            if (nl != null) "nl": nl
          }, cancelToken: cancelToken);
          var apiJson = const JsonDecoder().convert(apiRes.data);
          return (apiJson["i"].toString(), apiJson["s"].toString());
        }

        var (image, nl) = await getImageFromApi();
        int retryTimes = 0;
        while (true) {
          try {
            cachingFile.reset();
            imageBytes = null;
            res = null;
            if (image == "") {
              throw "empty url";
            }
            res = await dio.get<ResponseBody>(image,
                cancelToken: cancelToken,
                options: Options(responseType: ResponseType.stream));
            if (res.data == null || _isHtmlResponse(res)) {
              throw ImageExceedError();
            }
            final expectedBytes = int.tryParse(
                _responseHeader(res.data!.headers, "content-length") ?? "");
            await for (final event in readEhImageResponse(
              res.data!.stream,
              expectedBytes: expectedBytes,
              writeChunk: cachingFile.writeBytes,
            )) {
              if (event is EhImageResponseProgress) {
                final progress = DownloadProgress.inProgress(
                    event.receivedBytes,
                    event.expectedBytes,
                    cacheKey,
                    savePath);
                yield progress;
                loadingItems[cacheKey] = progress;
              } else if (event is EhImageResponseComplete) {
                imageBytes = event.bytes;
                totalBytes = event.bytes.length;
              }
            }
            break;
          } catch (e) {
            if (cancelToken.isCancelled) rethrow;
            retryTimes++;
            if (retryTimes == 4) {
              throw "Failed to load image.\nMaximum number of retries reached.";
            }
            (image, nl) = await getImageFromApi(nl);
          }
        }
      } else {
        Future<(String, String, String?)> getImageFromApi() async {
          // get image url through api
          Res<String>? apiRes = await EhNetwork().apiRequest({
            "gid": int.parse(gid),
            "imgkey": imgKey,
            "method": "showpage",
            "page": page,
            "showkey": gallery.auth!["showKey"]
          }, cancelToken: cancelToken);

          if (apiRes.error && apiRes.errorMessage!.contains("handshake")) {
            throw "Failed to make api request.\n"
                "This may be due to too frequent requests.\n"
                "Try to wait for some time and retry.";
          }

          var apiJson = const JsonDecoder().convert(apiRes.data);

          var i6 = apiJson["i6"] as String;

          RegExp regex = RegExp(r"nl\('(.+?)'\)");
          var nl = regex.firstMatch(i6)?.group(1);

          var originImage = i6.split("<a href=\"").last.split("\">").first;

          var image = apiJson["i3"] as String;

          image = image.substring(
              image.indexOf("src=\"") + 5, image.indexOf("\" style"));

          return (image, originImage, nl);
        }

        Future<(String, String, String?)> getImageFromHtml() async {
          var res =
              await EhNetwork().request(readerLink, cancelToken: cancelToken);
          if (res.error) {
            throw res.errorMessage ?? "error";
          } else {
            var document = parse(res.data);
            var image =
                document.querySelector("div#i3 > a > img")?.attributes["src"];
            var nl = document
                .querySelector("div#i6 > div > a#loadfail")
                ?.attributes["onclick"]
                ?.split('\'')
                .firstWhereOrNull((element) => element.contains('-'));
            var originImage = document
                    .querySelectorAll("div#i6 > div > a")
                    .firstWhereOrNull(
                        (element) => element.text.contains("original"))
                    ?.attributes["href"] ??
                "";
            return (image ?? "", originImage, nl);
          }
        }

        String image, originImage;
        String? nl;

        try {
          (image, originImage, nl) = await getImageFromApi();
        } catch (e) {
          (image, originImage, nl) = await getImageFromHtml();
        }

        if (image.contains("509.gif")) {
          throw ImageExceedError();
        }

        if (appdata.settings[29] == "1" && originImage.isURL) {
          image = originImage;
        }

        int retryTimes = 0;

        while (true) {
          try {
            cachingFile.reset();
            imageBytes = null;
            if (image == "") {
              throw "empty url";
            }
            res = await dio.get<ResponseBody>(image,
                cancelToken: cancelToken,
                options: Options(responseType: ResponseType.stream));
            if (res.data == null || _isHtmlResponse(res)) {
              throw ImageExceedError();
            }
            final contentLength =
                _responseHeader(res.data!.headers, "content-length");
            final expectedBytes = int.tryParse(contentLength ?? "");
            await for (final event in readEhImageResponse(
              res.data!.stream,
              expectedBytes: expectedBytes,
              writeChunk: cachingFile.writeBytes,
            )) {
              if (event is EhImageResponseProgress) {
                final progress = DownloadProgress.inProgress(
                    event.receivedBytes,
                    event.expectedBytes,
                    cacheKey,
                    savePath);
                yield progress;
                loadingItems[cacheKey] = progress;
              } else if (event is EhImageResponseComplete) {
                imageBytes = event.bytes;
              }
            }
            totalBytes = imageBytes!.length;
            break;
          } catch (e) {
            if (cancelToken.isCancelled) rethrow;
            retryTimes++;
            if (retryTimes == 4) {
              throw "Failed to load image.\nMaximum number of retries reached.";
            }
            if (nl == null) {
              rethrow;
            }
            var (newImage, newNl) = await EhNetwork().getImageLinkWithNL(
                getGalleryId(galleryLink), imgKey, page, nl,
                cancelToken: cancelToken);
            image = newImage;
            if (kDebugMode) {
              debugPrint(
                  "Get new image: ${safeNetworkUrl(image)}, new nl $newNl");
            }
            if (newNl != null) {
              nl = newNl;
            }
          }
        }
      }

      final completedImage = imageBytes;
      if (completedImage == null || completedImage.isEmpty) {
        throw const FormatException("Empty image response");
      }
      await cachingFile.close();
      var ext = detectFileType(completedImage).ext.replaceFirst(('.'), '');
      CacheManager().setType(key, ext);
      yield DownloadProgress(
        totalBytes,
        totalBytes,
        cacheKey,
        savePath,
        completedImage,
        ext,
        cacheKey,
        true,
      );
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Network", "${e.runtimeType}\n$s");
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      await _cleanupImageTask(cacheKey, cancelToken, caching);
    }
  }

  ///为Hitomi设计的图片加载函数
  ///
  /// 使用hash标识图片
  Stream<DownloadProgress> getHitomiImage(
      HitomiFile image, String galleryId) async* {
    final cancelToken = await _startTask(image.hash);
    CachingFile? caching;

    try {
      final key = image.hash;
      var cache = await CacheManager().findCache(key);
      if (cache != null) {
        yield DownloadProgress(
            1, 1, key, cache, null, CacheManager().getType(key));
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, key, savePath);

      final gg = GG();
      var url = await gg.urlFromUrlFromHash(galleryId, image, 'webp', null);
      int l;
      for (l = url.length - 1; l >= 0; l--) {
        if (url[l] == '.') {
          break;
        }
      }
      var dio = logDio();
      dio.options.headers = {
        "User-Agent": webUA,
        "Referer": "https://hitomi.la/reader/$galleryId.html"
      };

      var res = await dio.get<ResponseBody>(url,
          cancelToken: cancelToken,
          options: Options(responseType: ResponseType.stream));
      if (res.data == null || _isHtmlResponse(res)) {
        throw const FormatException("Invalid image response");
      }
      var stream = res.data!.stream;
      final expectedBytes = int.tryParse(
          _responseHeader(res.data!.headers, "content-length") ?? "");
      var currentBytes = 0;
      final data = BytesBuilder(copy: false);
      await for (var b in stream) {
        data.add(b);
        await cachingFile.writeBytes(b);
        currentBytes += b.length;
        var progress = DownloadProgress.inProgress(
            currentBytes, expectedBytes, url, savePath);
        yield progress;
        loadingItems[image.hash] = progress;
      }
      if (currentBytes == 0 ||
          (expectedBytes != null && currentBytes != expectedBytes)) {
        throw const FormatException("Incomplete image response");
      }
      await cachingFile.close();
      final bytes = data.takeBytes();
      var ext = getExt(res);
      CacheManager().setType(key, ext);
      yield DownloadProgress(
          currentBytes, currentBytes, url, savePath, bytes, ext, key);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      await _cleanupImageTask(image.hash, cancelToken, caching);
    }
  }

  ///获取禁漫图片, 如果缓存中没有, 则尝试下载
  Stream<DownloadProgress> getJmImage(String url, Map<String, String>? headers,
      {required String epsId,
      required String scrambleId,
      required String bookId}) async* {
    bookId = bookId.replaceAll(RegExp(r"\..+"), "");
    final urlWithoutParam = url.replaceAll(RegExp(r"\?.+"), "");
    final cancelToken = await _startTask(urlWithoutParam);
    CachingFile? caching;

    try {
      final key = urlWithoutParam;
      var cache = await CacheManager().findCache(key);
      if (cache != null) {
        yield DownloadProgress(1, 1, url, cache);
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 1, url, savePath);

      var dio = logDio();

      final data = BytesBuilder(copy: false);
      String? ext;
      try {
        var res = await dio.get<ResponseBody>(url,
            cancelToken: cancelToken,
            options: Options(
                responseType: ResponseType.stream, headers: getImgHeaders()));
        if (res.data == null || _isHtmlResponse(res)) {
          throw const FormatException("Invalid image response");
        }
        ext = getExt(res);
        var stream = res.data!.stream;
        await for (var b in stream) {
          //不直接写入文件, 因为需要对图片进行重组, 处理完成后再写入
          data.add(b);
          //构建虚假的进度条, 因为无法获取jm文件大小
          var total = max(1 << 20, data.length + 1);
          var progress =
              DownloadProgress.inProgress(data.length, total, url, savePath);
          yield progress;
          loadingItems[urlWithoutParam] = progress;
        }
      } catch (e) {
        rethrow;
      }
      var bytes = data.takeBytes();
      if (bytes.isEmpty) throw const FormatException("Empty image response");
      var progress = DownloadProgress.inProgress(
          bytes.length, (bytes.length / 0.75).toInt(), url, savePath);
      yield progress;
      loadingItems[urlWithoutParam] = progress;
      if (url.split('.').last != "gif") {
        bytes = await startRecombineAndWriteImage(
            bytes, epsId, scrambleId, bookId, savePath);
      }
      await cachingFile.writeBytes(bytes);
      await cachingFile.close();
      CacheManager().setType(key, ext);
      progress = DownloadProgress(
        bytes.length,
        bytes.length,
        url,
        savePath,
        bytes,
        ext,
        key,
      );
      yield progress;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      await _cleanupImageTask(urlWithoutParam, cancelToken, caching);
    }
  }

  Stream<DownloadProgress> getCustomImage(
      String url, String comicId, String epId, String sourceKey) async* {
    var cacheKey = "$sourceKey$comicId$epId$url";
    final cancelToken = await _startTask(cacheKey);

    CachingFile? caching;

    try {
      var cache = await CacheManager().findCache(cacheKey);
      if (cache != null) {
        yield DownloadProgress(1, 1, cacheKey, cache);
        return;
      }

      var source = ComicSource.find(sourceKey) ??
          (throw "Unknown Comic Source $sourceKey");
      Map<String, dynamic> config;

      if (source.getImageLoadingConfig == null) {
        config = {};
      } else {
        config = source.getImageLoadingConfig!(url, comicId, epId);
      }

      caching = await CacheManager().openWrite(cacheKey);
      final savePath = caching.file.path;

      var res = await dio.request<ResponseBody>(config['url'] ?? url,
          data: config['data'],
          cancelToken: cancelToken,
          options: Options(
              method: config['method'] ?? 'GET',
              headers: config['headers'] ?? {'user-agent': webUA},
              responseType: ResponseType.stream));
      if (res.data == null || _isHtmlResponse(res)) {
        throw const FormatException("Invalid image response");
      }

      final imageData = BytesBuilder(copy: false);

      int? expectedBytes = res.data!.contentLength;
      if (expectedBytes == -1) {
        expectedBytes = null;
      }

      bool shouldModifyData = config['onResponse'] != null;

      await for (var data in res.data!.stream) {
        if (!shouldModifyData) {
          await caching.writeBytes(data);
        }
        imageData.add(data);
        var progress = DownloadProgress.inProgress(
            imageData.length, expectedBytes, url, savePath);
        yield progress;
        loadingItems[cacheKey] = progress;
      }
      final rawData = imageData.takeBytes();
      if (rawData.isEmpty ||
          (expectedBytes != null && rawData.length != expectedBytes)) {
        throw const FormatException("Incomplete image response");
      }

      Uint8List? result;

      if (shouldModifyData) {
        var data = (config['onResponse'] as JSInvokable)(rawData);
        if (data is! Uint8List) {
          throw "Invalid Config: onImageLoad.onResponse return invalid type\n"
              "Expected: Uint8List(ArrayBuffer)\n"
              "Got: ${data.runtimeType}";
        }
        result = data;
        await caching.writeBytes(data);
      }

      var ext = getExt(res);
      CacheManager().setType(cacheKey, ext);
      await caching.close();
      final bytes = result ?? rawData;
      var length = bytes.length;
      yield DownloadProgress(
        length,
        length,
        url,
        savePath,
        bytes,
        ext,
        cacheKey,
      );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      await _cleanupImageTask(cacheKey, cancelToken, caching);
    }
  }

  Future<void> wait(String cacheKey) {
    return Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      return _cancelTokens.containsKey(cacheKey) ||
          loadingItems[cacheKey] != null;
    });
  }

  Stream<DownloadProgress> getCustomThumbnail(String url, String sourceKey,
      [Map<String, String>? headers]) async* {
    var cacheKey = "$sourceKey$url";
    final cancelToken = await _startTask(cacheKey);

    CachingFile? caching;

    try {
      var cache = await CacheManager().findCache(cacheKey);
      if (cache != null) {
        yield DownloadProgress(1, 1, cacheKey, cache);
        return;
      }

      var source = ComicSource.find(sourceKey) ??
          (throw "Unknown Comic Source $sourceKey");
      Map<String, dynamic> config;

      if (source.getThumbnailLoadingConfig == null) {
        config = {};
      } else {
        config = source.getThumbnailLoadingConfig!(url);
      }

      config['headers'] ??= headers;

      caching = await CacheManager().openWrite(cacheKey);
      final savePath = caching.file.path;

      var res = await dio.request<ResponseBody>(config['url'] ?? url,
          data: config['data'],
          cancelToken: cancelToken,
          options: Options(
              method: config['method'] ?? 'GET',
              headers: config['headers'] ?? {'user-agent': webUA},
              responseType: ResponseType.stream));
      if (res.data == null || _isHtmlResponse(res)) {
        throw const FormatException("Invalid thumbnail response");
      }

      final imageData = BytesBuilder(copy: false);

      int? expectedBytes = res.data!.contentLength;
      if (expectedBytes == -1) {
        expectedBytes = null;
      }

      bool shouldModifyData = config['onResponse'] != null;

      await for (var data in res.data!.stream) {
        if (!shouldModifyData) {
          await caching.writeBytes(data);
        }
        imageData.add(data);
        var progress = DownloadProgress.inProgress(
            imageData.length, expectedBytes, url, savePath);
        yield progress;
        loadingItems[cacheKey] = progress;
      }
      final rawData = imageData.takeBytes();
      if (rawData.isEmpty ||
          (expectedBytes != null && rawData.length != expectedBytes)) {
        throw const FormatException("Incomplete thumbnail response");
      }

      Uint8List? result;

      if (shouldModifyData) {
        var data = (config['onResponse'] as JSInvokable)(rawData);
        if (data is! Uint8List) {
          throw "Invalid Config: onImageLoad.onResponse return invalid type\n"
              "Expected: Uint8List(ArrayBuffer)\n"
              "Got: ${data.runtimeType}";
        }
        result = data;
        await caching.writeBytes(data);
      }

      await caching.close();
      yield DownloadProgress(
          1, 1, url, savePath, result ?? rawData, null, cacheKey);
    } catch (e) {
      Log.error("Network",
          "Failed to load an image: ${safeNetworkUrl(url)}\n${e.runtimeType}");
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      await _cleanupImageTask(cacheKey, cancelToken, caching);
    }
  }

  Future<File?> getFile(String key) async {
    var cache = await CacheManager().findCache(key);
    if (cache != null) {
      return File(cache);
    }
    return null;
  }

  Future<void> clear() async {
    await CacheManager().clear();
  }

  Future<bool> find(String key) async {
    return await CacheManager().findCache(key) != null;
  }

  Future<void> delete(String key) async {
    await CacheManager().delete(key);
  }

  String? getExt(Response res) {
    String? ext;
    var url = res.realUri.toString();
    var contentType =
        (res.headers["Content-Type"] ?? res.headers["content-type"])?[0];
    if (contentType != null) {
      ext = switch (contentType) {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        _ => null
      };
    }
    ext ??= url.split('.').last;
    if (!["jpg", "jpeg", "png", "gif", "webp"].contains(ext)) {
      ext = "jpg";
      LogManager.addLog(
          LogLevel.warning,
          "ImageManager",
          "Unknown image extension: \n"
              "Content-Type: $contentType\n"
              "URL: ${safeNetworkUrl(url)}");
    }
    return ext;
  }

  bool _isHtmlResponse(Response<ResponseBody> response) {
    final contentType = response.data == null
        ? ''
        : _responseHeader(response.data!.headers, 'content-type') ?? '';
    return contentType.toLowerCase().startsWith('text/html');
  }
}

class ImageExceedError extends Error {
  @override
  String toString() => "Maximum image loading limit reached.";
}
