import 'dart:typed_data';
import 'dart:io';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/res.dart';
import 'package:dio/dio.dart';

import '../http_client.dart';

///改写自 hitomi.la 网站上的js脚本
///
/// 接收byte数据, 将每4个byte合成1个int32即为漫画id
///
/// 发送请求时需要在请求头设置开始接收位置和最后接收位置,
///
/// 获取主页时不需要传入end, 因为需要和js脚本保持一致, 设置获取宽度100, 避免出现问题
///
/// 响应头中 Content-Range 指明数据范围, 此函数用subData形式返回此值
Future<Res<List<int>>> fetchComicData(String url, int start,
    {int? maxLength, int? endData, String? ref, Dio? client}) async {
  await setNetworkProxy();
  try {
    if (start < 0 ||
        start % 4 != 0 ||
        start > 0x7fffffffffffffff - 99 ||
        (maxLength != null && maxLength <= start)) {
      return const Res.error('Invalid byte range');
    }
    var end = start + 100 - 1;
    if (endData != null) {
      end = endData;
    }
    if (maxLength != null && maxLength - 1 < end) {
      end = maxLength - 1;
    }
    if (end < start) return const Res.error('Invalid byte range');
    final requestDio = client ??
        logDio(BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ));
    requestDio.options.responseType = ResponseType.bytes;
    requestDio.options.headers = {
      "User-Agent": webUA,
      "Range": "bytes=$start-$end",
      if (ref != null) "Referer": ref
    };
    final res = await requestDio.get<List<int>>(url);
    final bytes = res.data;
    final contentRange = res.headers.value('content-range');
    final match = contentRange == null
        ? null
        : RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$', caseSensitive: false)
            .firstMatch(contentRange.trim());
    final responseStart = int.tryParse(match?.group(1) ?? '');
    final responseEnd = int.tryParse(match?.group(2) ?? '');
    final totalLength = int.tryParse(match?.group(3) ?? '');
    if (res.statusCode != HttpStatus.partialContent ||
        bytes == null ||
        match == null ||
        responseStart == null ||
        responseStart != start ||
        responseEnd == null ||
        totalLength == null ||
        totalLength % 4 != 0 ||
        responseEnd < responseStart ||
        responseEnd > end ||
        totalLength <= responseEnd ||
        (responseEnd < end && responseEnd != totalLength - 1) ||
        bytes.length != responseEnd - responseStart + 1 ||
        bytes.length % 4 != 0) {
      return const Res.error('Invalid ranged response');
    }

    final view = ByteData.sublistView(Uint8List.fromList(bytes));
    final comicIds = List<int>.generate(
      bytes.length ~/ 4,
      (index) => view.getInt32(index * 4, Endian.big),
      growable: false,
    );
    return Res(comicIds, subData: totalLength.toString());
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "Network", "${safeNetworkError(e)}\n$s");
    return Res(null,
        errorMessage: e.toString() == "null" ? "Unknown Error" : e.toString());
  }
}
