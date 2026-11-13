import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/hitomi_network/search.dart';
import 'package:pica_comic/network/http_client.dart';

class _RangeAdapter implements HttpClientAdapter {
  _RangeAdapter(this.statusCode, this.bytes, this.headers);

  int statusCode;
  List<int> bytes;
  Map<String, List<String>> headers;
  var calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    return ResponseBody.fromBytes(bytes, statusCode, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _nodeBytes({
  List<int> addresses = const [],
  List<List<int>> keys = const [
    [1, 2, 3, 4]
  ],
}) {
  final data = ByteData(4 + keys.length * 8 + 4 + keys.length * 12 + 17 * 8);
  var pos = 0;
  data.setInt32(pos, keys.length, Endian.big);
  pos += 4;
  for (final key in keys) {
    data.setInt32(pos, key.length, Endian.big);
    pos += 4;
    data.buffer.asUint8List().setRange(pos, pos + key.length, key);
    pos += key.length;
  }
  data.setInt32(pos, keys.length, Endian.big);
  pos += 4;
  for (var i = 0; i < keys.length; i++) {
    data.setUint64(pos, 25 + i * 8, Endian.big);
    pos += 8;
    data.setUint32(pos, 8, Endian.big);
    pos += 4;
  }
  for (var i = 0; i < 17; i++) {
    data.setUint64(pos, i < addresses.length ? addresses[i] : 0, Endian.big);
    pos += 8;
  }
  return data.buffer.asUint8List();
}

class _Search extends HitomiSearch {
  _Search(super.keyword, this.ids);

  final Map<String, List<int>> ids;
  String? requestedArea;
  String? requestedTag;
  String? requestedLanguage;

  @override
  Future<void> getTagIndexVersion() async {}

  @override
  Future<List<int>> getGalleryIdsForQuery(String query) async => ids[query]!;

  @override
  Future<List<int>> getGalleryIdsFromNozomi(
      String? area, String tag, String language) async {
    requestedArea = area;
    requestedTag = tag;
    requestedLanguage = language;
    return [10, 5];
  }
}

class _TreeSearch extends HitomiSearch {
  _TreeSearch() : super('');

  int? requestedAddress;
  Node? nextNode;

  @override
  Future<Node?> getNodeAtAddress(String field, int address) async {
    requestedAddress = address;
    return nextNode;
  }
}

class _RangeNodeSearch extends HitomiSearch {
  _RangeNodeSearch(
    Dio client,
    Future<Directory> Function() cacheDirectoryProvider,
  ) : super('', client: client, cacheDirectoryProvider: cacheDirectoryProvider);

  @override
  String get baseDomain => 'example.test';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final settings = List<String>.from(appdata.settings);
    final overrides = HttpOverrides.current;
    final proxy = proxyHttpOverrides;
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    addTearDown(() {
      appdata.settings = settings;
      HttpOverrides.global = overrides;
      proxyHttpOverrides = proxy;
    });
  });

  test('excluding a larger ID does not index beyond the list', () async {
    final search = _Search('title -blocked', {
      'title': [5],
      'blocked': [10],
    });
    expect((await search.search()).data, [5]);
  });

  test('exclusion keeps the remaining positive tail', () async {
    final search = _Search('title -blocked', {
      'title': [10, 5],
      'blocked': [10],
    });
    expect((await search.search()).data, [5]);
  });

  test('exclusion never adds IDs from the excluded list', () async {
    final search = _Search('title -blocked', {
      'title': [10, 9],
      'blocked': [7, 6, 5],
    });
    expect((await search.search()).data, [10, 9]);
  });

  test('language and tag optimization still applies exclusions', () async {
    final search = _Search('female:test language:chinese -blocked', {
      'female:test': [10, 5],
      'language:chinese': [10, 5],
      'blocked': [10],
    });
    expect((await search.search()).data, [5]);
  });

  for (final gender in ['female', 'male']) {
    test('$gender language index retains the whole tag', () async {
      final search = _Search('$gender:test language:chinese', {});
      await search.search();
      expect(search.requestedArea, 'tag');
      expect(search.requestedTag, '$gender:test');
      expect(search.requestedLanguage, 'chinese');
    });
  }

  test('empty exclusion preserves all results', () async {
    final search = _Search('title -blocked', {
      'title': [10, 5],
      'blocked': [],
    });
    expect((await search.search()).data, [10, 5]);
  });

  test('nozomi IDs require complete big-endian 32-bit values', () {
    expect(
      HitomiSearch.decodeNozomiData(Uint8List.fromList([
        0,
        0,
        0,
        7,
        255,
        255,
        255,
        254,
      ])),
      [7, -2],
    );
    expect(
      () => HitomiSearch.decodeNozomiData(Uint8List.fromList([0, 0, 0])),
      throwsFormatException,
    );
  });

  test('node decoding honors subview offsets and all child slots', () async {
    final nodeBytes = _nodeBytes(addresses: [0, 100, 90]);
    final padded = Uint8List(nodeBytes.length + 2)
      ..setRange(1, nodeBytes.length + 1, nodeBytes);
    final node = await HitomiSearch('').decodeNodeData(
      Uint8List.sublistView(padded, 1, nodeBytes.length + 1),
    );

    expect(node, isNotNull);
    expect(node!.keys.single, [1, 2, 3, 4]);
    expect(node.data.single, [25, 8]);
    expect(node.subNodeAddresses, hasLength(17));
    expect(node.subNodeAddresses.take(3), [0, 100, 90]);
  });

  test('node decoding rejects keys outside the fixed 4-byte format', () async {
    final bytes = _nodeBytes();
    ByteData.sublistView(bytes).setInt32(4, 5, Endian.big);
    expect(await HitomiSearch('').decodeNodeData(bytes), isNull);
  });

  test('B-tree search selects the child slot matching the key position',
      () async {
    final search = _TreeSearch();
    final root = Node(
      [
        Uint8List.fromList([1, 2, 3, 4])
      ],
      [
        <int>[25, 8]
      ],
      [0, 100, 90, ...List<int>.filled(14, 0)],
    );

    expect(
        await search.bSearch(
            'galleries', Uint8List.fromList([2, 0, 0, 0]), root),
        isNull);
    expect(search.requestedAddress, 100);
  });

  test('B-tree search stops when child pointers contain a cycle', () async {
    final search = _TreeSearch();
    final root = Node(
      [
        Uint8List.fromList([1, 2, 3, 4])
      ],
      [
        <int>[25, 8]
      ],
      [0, 100, ...List<int>.filled(15, 0)],
    );
    search.nextNode = root;

    expect(
        await search.bSearch(
            'galleries', Uint8List.fromList([2, 0, 0, 0]), root),
        isNull);
    expect(search.requestedAddress, 100);
  });

  test('B-tree search rejects negative and overflowing child pointers',
      () async {
    final search = _TreeSearch();
    final key = Uint8List.fromList([0, 0, 0, 0]);

    Node rootWithChild(int address) => Node(
          [
            Uint8List.fromList([1, 2, 3, 4])
          ],
          [
            <int>[25, 8]
          ],
          [address, 100, ...List<int>.filled(15, 0)],
        );

    expect(await search.bSearch('galleries', key, rootWithChild(-1)), isNull);
    expect(
      await search.bSearch('galleries', key, rootWithChild(0x7fffffffffffffff)),
      isNull,
    );
    expect(search.requestedAddress, isNull);
  });

  test('malformed and truncated nodes are rejected', () async {
    final badCount = ByteData(4)..setInt32(0, 17, Endian.big);
    expect(
      await HitomiSearch('').decodeNodeData(badCount.buffer.asUint8List()),
      isNull,
    );
    final valid = _nodeBytes();
    expect(
      await HitomiSearch('')
          .decodeNodeData(Uint8List.sublistView(valid, 0, valid.length - 1)),
      isNull,
    );
    final unsorted = _nodeBytes(keys: [
      [255, 2, 3, 4],
      [1, 2, 3, 4],
    ]);
    expect(await HitomiSearch('').decodeNodeData(unsorted), isNull);
  });

  test('invalid gallery data ranges are rejected before network access',
      () async {
    final search = HitomiSearch('');
    expect(await search.getGalleryIdsFromData([1]), isEmpty);
    expect(
      await search.getGalleryIdsFromData([0x7fffffffffffffff, 8]),
      isEmpty,
    );
    expect(await search.getGalleryIdsFromData([2, 8]), isEmpty);
    expect(await search.getGalleryIdsFromData([100, 7]), isEmpty);
  });

  test('valid partial content is cached for the exact requested range',
      () async {
    final dir = await Directory.systemTemp.createTemp('hitomi-range-');
    final adapter = _RangeAdapter(
      HttpStatus.partialContent,
      [1, 2, 3, 4],
      {
        'content-range': ['bytes 10-13/100']
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final search =
        HitomiSearch('', client: dio, cacheDirectoryProvider: () async => dir);
    addTearDown(() async {
      dio.close(force: true);
      await dir.delete(recursive: true);
    });

    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        [1, 2, 3, 4]);
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        [1, 2, 3, 4]);
    expect(adapter.calls, 1);
  });

  test('structurally invalid node ranges are evicted before the next request',
      () async {
    final dir = await Directory.systemTemp.createTemp('hitomi-node-range-');
    final invalid = Uint8List(464);
    ByteData.sublistView(invalid).setInt32(0, 17, Endian.big);
    final validNode = _nodeBytes();
    final valid = Uint8List(464)..setRange(0, validNode.length, validNode);
    final adapter = _RangeAdapter(
      HttpStatus.partialContent,
      invalid,
      {
        'content-range': ['bytes 10-473/1000']
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final search = _RangeNodeSearch(dio, () async => dir)
      ..tagIndexVersion = 'test';
    addTearDown(() async {
      dio.close(force: true);
      await dir.delete(recursive: true);
    });

    expect(await search.getNodeAtAddress('galleries', 10), isNull);
    adapter.bytes = valid;
    expect(await search.getNodeAtAddress('galleries', 10), isNotNull);
    expect(adapter.calls, 2);
  });

  test('structurally invalid gallery ranges are evicted before retry',
      () async {
    final dir = await Directory.systemTemp.createTemp('hitomi-data-range-');
    final invalid = Uint8List(8);
    final validData = ByteData(8)
      ..setInt32(0, 1, Endian.big)
      ..setInt32(4, 42, Endian.big);
    final adapter = _RangeAdapter(
      HttpStatus.partialContent,
      invalid,
      {
        'content-range': ['bytes 100-107/1000']
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final search = _RangeNodeSearch(dio, () async => dir)
      ..tagIndexVersion = 'test';
    addTearDown(() async {
      dio.close(force: true);
      await dir.delete(recursive: true);
    });

    expect(await search.getGalleryIdsFromData([100, 8]), isEmpty);
    adapter.bytes = validData.buffer.asUint8List();
    expect(await search.getGalleryIdsFromData([100, 8]), [42]);
    expect(adapter.calls, 2);
  });

  test('non-positive gallery IDs are rejected and their range is evicted',
      () async {
    final dir = await Directory.systemTemp.createTemp('hitomi-invalid-id-');
    final invalidData = ByteData(8)
      ..setInt32(0, 1, Endian.big)
      ..setInt32(4, 0, Endian.big);
    final validData = ByteData(8)
      ..setInt32(0, 1, Endian.big)
      ..setInt32(4, 42, Endian.big);
    final adapter = _RangeAdapter(
      HttpStatus.partialContent,
      invalidData.buffer.asUint8List(),
      {
        'content-range': ['bytes 100-107/1000']
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final search = _RangeNodeSearch(dio, () async => dir)
      ..tagIndexVersion = 'test';
    addTearDown(() async {
      dio.close(force: true);
      await dir.delete(recursive: true);
    });

    expect(await search.getGalleryIdsFromData([100, 8]), isEmpty);
    adapter.bytes = validData.buffer.asUint8List();
    expect(await search.getGalleryIdsFromData([100, 8]), [42]);
    expect(adapter.calls, 2);
  });

  test('full responses and short ranges are rejected without caching',
      () async {
    final dir = await Directory.systemTemp.createTemp('hitomi-range-');
    final adapter = _RangeAdapter(200, [1, 2, 3, 4], {});
    final dio = Dio()..httpClientAdapter = adapter;
    final search =
        HitomiSearch('', client: dio, cacheDirectoryProvider: () async => dir);
    addTearDown(() async {
      dio.close(force: true);
      await dir.delete(recursive: true);
    });

    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(adapter.calls, 2);

    adapter
      ..statusCode = HttpStatus.partialContent
      ..bytes = [1, 2, 3, 4]
      ..headers = {
        'content-range': ['bytes 11-14/100']
      };
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(adapter.calls, 4);

    adapter
      ..bytes = [1, 2, 3]
      ..headers = {
        'content-range': ['bytes 10-13/100']
      };
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(adapter.calls, 5);

    adapter
      ..bytes = [1, 2, 3, 4]
      ..headers = {
        'content-range': ['bytes 10-13/12']
      };
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(await search.getUrlAtRange('https://example.test/index', [10, 13]),
        isNull);
    expect(adapter.calls, 7);
  });

  test('range endpoints above the signed offset limit fail before request',
      () async {
    final adapter = _RangeAdapter(HttpStatus.partialContent, [], {});
    final dio = Dio()..httpClientAdapter = adapter;
    final search = HitomiSearch('', client: dio);
    addTearDown(() => dio.close(force: true));

    await expectLater(
      search.getUrlAtRange('https://example.test/index',
          [0x7ffffffffffffffe, 0x8000000000000000]),
      throwsArgumentError,
    );
    expect(adapter.calls, 0);
  });
}
