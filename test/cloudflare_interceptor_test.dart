import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/cloudflare.dart';

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter({required this.headers});

  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString('blocked', 403, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('Cloudflare challenge errors expose the challenge URL', () async {
    final dio = Dio()
      ..httpClientAdapter = _ResponseAdapter(
        headers: <String, List<String>>{
          'cf-mitigated': <String>['challenge'],
        },
      )
      ..interceptors.add(CloudflareInterceptor());
    addTearDown(() => dio.close(force: true));

    await expectLater(
      dio.get<void>('https://example.org/protected'),
      throwsA(isA<CloudflareException>().having(
        (error) => error.url,
        'url',
        'https://example.org/protected',
      )),
    );
  });

  test('ordinary 403 responses remain Dio errors', () async {
    final dio = Dio()
      ..httpClientAdapter = _ResponseAdapter(headers: <String, List<String>>{})
      ..interceptors.add(CloudflareInterceptor());
    addTearDown(() => dio.close(force: true));

    await expectLater(
      dio.get<void>('https://example.org/protected'),
      throwsA(isA<DioException>()),
    );
  });
}
