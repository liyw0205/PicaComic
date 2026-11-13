import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/http_client.dart';
import '../res.dart';
import 'hitomi_main_network.dart';

const _maxFileOffset = 0x7fffffffffffffff;

class HitomiSearch {
  String get baseDomain => HiNetwork().baseDomain;
  var results = <int>[];
  String? tagIndexVersion;
  final Dio dio;
  final Future<Directory> Function() _cacheDirectoryProvider;
  final nozomiExtension = '.nozomi';
  var indexDir = 'galleriesindex';
  var galleriesIndexDir = 'galleriesindex';
  var languagesIndexDir = 'languagesindex';
  var nozomiUrlIndexDir = 'nozomiurlindex';
  final String keyword;

  HitomiSearch(this.keyword,
      {Dio? client, Future<Directory> Function()? cacheDirectoryProvider})
      : dio = client ?? logDio(),
        _cacheDirectoryProvider =
            cacheDirectoryProvider ?? getApplicationCacheDirectory;

  Future<Res<List<int>>> search() async {
    await setNetworkProxy();
    await getTagIndexVersion();
    var terms = keyword.toLowerCase().trim().split(RegExp(r"\s+"));
    var negativeTerms = <String>[];
    var positiveTerms = <String>[];
    var languageTerms = <String>[];
    for (var term in terms.where((term) => term.isNotEmpty)) {
      term = term.replaceAll('_', ' ');
      if (term.startsWith('-')) {
        negativeTerms.add(term.replaceFirst('-', ''));
      } else if (term.startsWith("language:")) {
        languageTerms.add(term);
      } else {
        positiveTerms.add(term);
      }
    }

    if (negativeTerms.isEmpty &&
        languageTerms.length == 1 &&
        positiveTerms.length == 1 &&
        positiveTerms[0].contains(':')) {
      results = await getGalleryIdsForTermAndLanguage(
          positiveTerms[0], languageTerms[0].split(":")[1]);
      return Res(results);
    }
    positiveTerms += languageTerms;

    //first results
    if (positiveTerms.isEmpty) {
      results = await getGalleryIdsFromNozomi(null, 'index', 'all');
    } else {
      final term = positiveTerms.removeAt(0);
      results = await getGalleryIdsForQuery(term);
    }
    //positive results
    for (var term in positiveTerms) {
      var res = await getGalleryIdsForQuery(term);
      var newRes = <int>[];

      int p1 = 0;
      int p2 = 0;
      while (p1 < res.length && p2 < results.length) {
        if (res[p1] > results[p2]) {
          p1++;
        } else if (res[p1] < results[p2]) {
          p2++;
        } else {
          newRes.add(res[p1]);
          p1++;
          p2++;
        }
      }

      results = newRes;
    }
    //negative results
    for (var term in negativeTerms) {
      var res = await getGalleryIdsForQuery(term);
      var newRes = <int>[];

      int p1 = 0;
      int p2 = 0;
      while (p1 < res.length && p2 < results.length) {
        if (res[p1] > results[p2]) {
          p1++;
        } else if (res[p1] < results[p2]) {
          newRes.add(results[p2]);
          p2++;
        } else {
          p1++;
          p2++;
        }
      }
      newRes.addAll(results.skip(p2));
      results = newRes;
    }
    return Res(results);
  }

  Future<void> getTagIndexVersion() async {
    var res = await dio.get(
        "https://ltn.$baseDomain/galleriesindex/version?_=${DateTime.now().millisecondsSinceEpoch ~/ 1000}",
        options: Options(responseType: ResponseType.plain));
    tagIndexVersion = res.data;
  }

  Future<List<int>> getGalleryIdsFromNozomi(
      String? area, String tag, String language) async {
    var url = "https://ltn.$baseDomain/n/$tag-$language$nozomiExtension";
    if (area != null) {
      url = "https://ltn.$baseDomain/n/$area/$tag-$language$nozomiExtension";
    }
    var bytes = (await dio.get<Uint8List>(url,
            options: Options(responseType: ResponseType.bytes)))
        .data;
    if (bytes == null) {
      return [];
    }
    return decodeNozomiData(bytes);
  }

  static List<int> decodeNozomiData(Uint8List bytes) {
    if (bytes.length % 4 != 0) {
      throw const FormatException('Invalid nozomi data length');
    }
    final view = ByteData.sublistView(bytes);
    return List<int>.generate(
      bytes.length ~/ 4,
      (index) => view.getInt32(index * 4, Endian.big),
      growable: false,
    );
  }

  Future<List<int>> getGalleryIdsForQuery(String query) async {
    query = query.replaceAll("_", " ");
    if (query.contains(":")) {
      final sides = query.split(":");
      final ns = sides[0];
      var tag = sides[1];
      String? area = ns;
      var language = 'all';

      if (ns == 'female' || ns == 'male') {
        area = 'tag';
        tag = query;
      } else if (ns == 'language') {
        area = null;
        language = tag;
        tag = 'index';
      }

      return getGalleryIdsFromNozomi(area, tag, language);
    }
    final key = hashTerm(query);
    const field = 'galleries';
    var node = await getNodeAtAddress(field, 0);
    if (node == null) {
      return [];
    } else {
      var data = await bSearch(field, key, node);
      if (data == null) {
        return [];
      } else {
        return getGalleryIdsFromData(data);
      }
    }
  }

  Future<List<int>> getGalleryIdsForTermAndLanguage(
      String term, String language) async {
    final ns = term.split(':')[0];
    var tag = term.split(':')[1];
    String? area = ns;

    if (ns == 'female' || ns == 'male') {
      area = 'tag';
      tag = term;
    }

    return getGalleryIdsFromNozomi(area, tag, language);
  }

  Uint8List hashTerm(String term) {
    List<int> hash = sha256.convert(utf8.encode(term)).bytes;
    return Uint8List.fromList(hash.sublist(0, 4));
  }

  Future<Node?> getNodeAtAddress(String field, int address) async {
    const maxNodeSize = 464;
    if (address < 0 || address > _maxFileOffset - maxNodeSize + 1) {
      return null;
    }
    var url =
        'https://ltn.$baseDomain/$indexDir/$field.${tagIndexVersion!}.index';
    final range = [address, address + maxNodeSize - 1];
    var res = await getUrlAtRange(url, range);
    if (res == null) {
      return null;
    } else {
      final node = await decodeNodeData(res);
      if (node == null) await _deleteUrlRangeCache(url, range);
      return node;
    }
  }

  Future<File> _rangeCacheFile(String url, List<int> range) async {
    final cachePath = await _cacheDirectoryProvider();
    final key = md5.convert(
        const Utf8Encoder().convert('range-v2:$url${range.toString()}'));
    return File(
        '${cachePath.path}${Platform.pathSeparator}hitomi${Platform.pathSeparator}$key');
  }

  Future<void> _deleteUrlRangeCache(String url, List<int> range) async {
    final cacheFile = await _rangeCacheFile(url, range);
    if (cacheFile.existsSync()) cacheFile.deleteSync();
  }

  Future<Uint8List?> getUrlAtRange(String url, List<int> range) async {
    if (range.length != 2 ||
        range[0] < 0 ||
        range[1] < range[0] ||
        range[1] > _maxFileOffset ||
        range[1] - range[0] >= _maxFileOffset) {
      throw ArgumentError.value(range, 'range', 'Invalid byte range');
    }
    final expectedLength = range[1] - range[0] + 1;
    var cacheFile = await _rangeCacheFile(url, range);
    if (cacheFile.existsSync()) {
      final cached = cacheFile.readAsBytesSync();
      if (cached.length == expectedLength) {
        return Uint8List.fromList(cached);
      }
      cacheFile.deleteSync();
    }
    var res = await dio.get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes, headers: {
          'Range': "bytes=${range[0]}-${range[1]}",
          'User-Agent': webUA,
          'Referer': 'https://hitomi.la/search.html',
          'Origin': "https://hitomi.la"
        }));
    final data = res.data;
    final contentRange = res.headers.value('content-range');
    final match = contentRange == null
        ? null
        : RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$', caseSensitive: false)
            .firstMatch(contentRange.trim());
    final total = match?.group(3);
    final totalLength =
        total == null || total == '*' ? null : int.tryParse(total);
    if (res.statusCode != HttpStatus.partialContent ||
        match == null ||
        int.tryParse(match.group(1)!) != range[0] ||
        int.tryParse(match.group(2)!) != range[1] ||
        (totalLength != null && totalLength <= range[1]) ||
        data == null ||
        data.length != expectedLength) {
      return null;
    }

    final bytes = Uint8List.fromList(data);
    final tempFile =
        File('${cacheFile.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      tempFile.createSync(recursive: true);
      tempFile.writeAsBytesSync(bytes, flush: true);
      tempFile.renameSync(cacheFile.path);
    } finally {
      if (tempFile.existsSync()) tempFile.deleteSync();
    }
    return bytes;
  }

  Future<Node?> decodeNodeData(Uint8List data) async {
    try {
      final view = ByteData.sublistView(data);
      var pos = 0;

      bool hasBytes(int length) =>
          length >= 0 && length <= view.lengthInBytes - pos;

      if (!hasBytes(4)) return null;
      final numberOfKeys = view.getInt32(pos, Endian.big);
      pos += 4;
      if (numberOfKeys < 0 || numberOfKeys > 16) return null;

      final keys = <Uint8List>[];
      for (var i = 0; i < numberOfKeys; i++) {
        if (!hasBytes(4)) return null;
        final keySize = view.getInt32(pos, Endian.big);
        pos += 4;
        if (keySize != 4 || !hasBytes(keySize)) return null;
        final key = Uint8List.fromList(data.sublist(pos, pos + keySize));
        if (keys.isNotEmpty && _compareKeys(keys.last, key) >= 0) return null;
        keys.add(key);
        pos += keySize;
      }

      if (!hasBytes(4)) return null;
      final numberOfDatas = view.getInt32(pos, Endian.big);
      pos += 4;
      if (numberOfDatas != numberOfKeys) return null;

      final datas = <List<int>>[];
      for (var i = 0; i < numberOfDatas; i++) {
        if (!hasBytes(12)) return null;
        final offset = view.getUint64(pos, Endian.big);
        pos += 8;
        final length = view.getUint32(pos, Endian.big);
        pos += 4;
        if (length == 0 || offset < 0 || offset > _maxFileOffset - length + 1) {
          return null;
        }
        datas.add([offset, length]);
      }

      const numberOfSubnodeAddresses = 17;
      if (!hasBytes(numberOfSubnodeAddresses * 8)) return null;
      final subnodeAddresses = List<int>.generate(
        numberOfSubnodeAddresses,
        (_) {
          final address = view.getUint64(pos, Endian.big);
          pos += 8;
          return address;
        },
        growable: false,
      );
      if (subnodeAddresses
          .any((address) => address < 0 || address > _maxFileOffset - 463)) {
        return null;
      }

      return Node(keys, datas, subnodeAddresses);
    } on RangeError {
      return null;
    }
  }

  Future<List<int>?> bSearch(String field, Uint8List key, Node? node) async {
    (bool, int) locateKey(Uint8List key, Node node) {
      var cmpResult = -1;
      int i;
      for (i = 0; i < node.keys.length; i++) {
        cmpResult = _compareKeys(key, node.keys[i]);
        if (cmpResult <= 0) {
          break;
        }
      }
      return (cmpResult == 0, i);
    }

    final visitedAddresses = <int>{};
    for (var depth = 0; depth < 64; depth++) {
      if (node == null ||
          node.keys.isEmpty ||
          node.keys.length != node.data.length ||
          node.subNodeAddresses.length != 17 ||
          key.length != 4) {
        return null;
      }
      final (there, where) = locateKey(key, node);
      if (there) {
        return where < node.data.length ? node.data[where] : null;
      }
      if (where >= node.subNodeAddresses.length) return null;
      final address = node.subNodeAddresses[where];
      if (address <= 0 ||
          address > _maxFileOffset - 463 ||
          !visitedAddresses.add(address)) {
        return null;
      }
      node = await getNodeAtAddress(field, address);
    }
    return null;
  }

  Future<List<int>> getGalleryIdsFromData(List<int>? data) async {
    if (data == null) {
      return [];
    }
    if (data.length != 2) return [];
    var [offset, length] = data;
    if (offset < 0 ||
        offset % 4 != 0 ||
        length > 100000000 ||
        length <= 0 ||
        length % 4 != 0 ||
        offset > _maxFileOffset - length + 1) {
      if (kDebugMode) print("invalid gallery data range: $offset+$length");
      return [];
    }
    var url =
        'https://ltn.$baseDomain/$galleriesIndexDir/galleries.${tagIndexVersion!}.data';
    var inbuf = await getUrlAtRange(url, [offset, offset + length - 1]);
    if (inbuf == null) {
      return [];
    }
    final galleryIds = <int>[];
    var pos = 0;
    if (inbuf.length < 4) {
      await _deleteUrlRangeCache(url, [offset, offset + length - 1]);
      return galleryIds;
    }
    final view = ByteData.sublistView(inbuf);
    final numberOfGalleryIds = view.getInt32(pos);
    pos += 4;
    final expectedLength = numberOfGalleryIds * 4 + 4;
    if (numberOfGalleryIds > 10000000 ||
        numberOfGalleryIds <= 0 ||
        inbuf.length != expectedLength) {
      await _deleteUrlRangeCache(url, [offset, offset + length - 1]);
      return galleryIds;
    }

    for (var i = 0; i < numberOfGalleryIds; i++) {
      galleryIds.add(view.getInt32(pos));
      pos += 4;
    }
    if (galleryIds.any((id) => id <= 0)) {
      await _deleteUrlRangeCache(url, [offset, offset + length - 1]);
      return [];
    }
    return galleryIds;
  }
}

int _compareKeys(Uint8List a, Uint8List b) {
  final top = min(a.length, b.length);
  for (var i = 0; i < top; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

class Node {
  List<Uint8List> keys;

  ///数据, 个体为[offset, length]
  List<List<int>> data;
  List<int> subNodeAddresses;

  Node(this.keys, this.data, this.subNodeAddresses);
}
