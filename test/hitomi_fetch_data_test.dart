import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/hitomi_network/fetch_data.dart';
import 'package:pica_comic/network/http_client.dart';

class _FetchAdapter implements HttpClientAdapter {
  _FetchAdapter(this.statusCode, this.bytes, this.headers);

  final int statusCode;
  final List<int> bytes;
  final Map<String, List<String>> headers;
  String? requestedRange;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    requestedRange = options.headers['Range'] as String?;
    return ResponseBody.fromBytes(bytes, statusCode, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() {
    final settings = List<String>.from(appdata.settings);
    final overrides = HttpOverrides.current;
    final proxy = proxyHttpOverrides;
    appdata.settings[8] = '';
    appdata.settings[58] = '0';
    addTearDown(() {
      appdata.settings = settings;
      HttpOverrides.global = overrides;
      proxyHttpOverrides = proxy;
    });
  });

  test('last range uses inclusive end and parses only aligned partial data',
      () async {
    final adapter = _FetchAdapter(
      HttpStatus.partialContent,
      [0, 0, 0, 7],
      {
        'content-range': ['bytes 8-11/12']
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));

    final result = await fetchComicData(
      'https://example.test/nozomi',
      8,
      maxLength: 12,
      client: dio,
    );

    expect(result.error, isFalse);
    expect(result.data, [7]);
    expect(result.subData, '12');
    expect(adapter.requestedRange, 'bytes=8-11');
  });

  test('full, truncated and misaligned range responses are rejected', () async {
    final adapter = _FetchAdapter(HttpStatus.ok, [0, 0, 0, 7], {});
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));

    final full = await fetchComicData(
      'https://example.test/nozomi',
      0,
      client: dio,
    );
    expect(full.error, isTrue);
    expect(full.errorMessage, 'Invalid ranged response');

    final malformedAdapter = _FetchAdapter(
      HttpStatus.partialContent,
      [0, 0, 0],
      {
        'content-range': ['bytes 0-2/12']
      },
    );
    final malformedDio = Dio()..httpClientAdapter = malformedAdapter;
    addTearDown(() => malformedDio.close(force: true));
    final malformed = await fetchComicData(
      'https://example.test/nozomi',
      0,
      endData: 2,
      client: malformedDio,
    );
    expect(malformed.error, isTrue);
    expect(malformedAdapter.calls, 1);
  });
}
