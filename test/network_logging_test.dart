import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/network_logging.dart';

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromBytes(
      utf8.encode(body),
      statusCode,
      headers: {
        'content-type': ['application/json'],
        'set-cookie': ['session=private'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('URLs remove credentials and redact secret parameters', () {
    final url = safeNetworkUrl(
        'https://user:password@example.org/path?access_token=private&rkey=private&imgkey=private&showkey=private&mpvkey=private&image_key=private&x-key=private&file_id=private&sid=private&jwt=private&code=private&state=private&nonce=private&csrf_token=private&page=2#private');
    expect(url, isNot(contains('private')));
    expect(url, isNot(contains('password')));
    expect(Uri.parse(url).queryParameters['page'], '2');
  });

  test('app link and proxy log URLs omit credentials', () {
    final appLink = safeNetworkUrl(
      'https://e-hentai.org/g/123/abc/?token=private&page=4#private',
    );
    final proxy = safeNetworkUrl(
      'socks5://proxy-user:proxy-password@proxy.example.org:1080',
    );

    expect(appLink, contains('page=4'));
    expect(appLink, isNot(contains('private')));
    expect(proxy, 'socks5://proxy.example.org:1080');
    expect(proxy, isNot(contains('proxy-password')));
  });

  test('EH image keys in path segments are redacted', () {
    final url = safeNetworkUrl(
      'https://ehgt.org/s/private-img-key/123456-7?nl=public-page-key',
    );

    expect(url, isNot(contains('private-img-key')));
    expect(url, contains('/s/%3Credacted%3E/123456-7'));
    expect(url, contains('nl=public-page-key'));
  });

  test('headers redact request, response and API credentials', () {
    final headers = safeNetworkHeaders({
      'Authorization': 'private',
      'Cookie': 'private',
      'Set-Cookie': ['private'],
      'invalid-cookie': ['private'],
      'X-Api-Key': 'private',
      'X-Auth-Key': 'private',
      'X-Signature': 'private',
      'X-Key': 'private',
      'Location': ['https://example.org/?token=private'],
      'Content-Location': 'https://example.org/?sid=private',
      'X-Request-URI': '/download?jwt=private',
      'Link': '<https://example.org/?code=private>; rel="next"',
      'Content-Type': 'application/json',
    });
    expect(headers.toString(), isNot(contains('private')));
    expect(headers['Content-Type'], 'application/json');
  });

  test('response logs never serialize authentication body values', () {
    LogManager.clear();
    final dio = Dio()
      ..httpClientAdapter =
          _JsonAdapter(200, '{"refresh":"private","value":"private"}')
      ..interceptors.add(MyLogInterceptor());
    addTearDown(() => dio.close(force: true));

    return dio
        .get<Map<String, dynamic>>(
      'https://example.org/auth/refresh',
      options: Options(responseType: ResponseType.json),
    )
        .then((_) {
      expect(LogManager.logs.last.content, isNot(contains('private')));
      LogManager.clear();
    });
  });

  test('error logs omit exception details and redact request secrets',
      () async {
    LogManager.clear();
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter(403, '{"error":"private"}')
      ..interceptors.add(MyLogInterceptor());
    addTearDown(() => dio.close(force: true));

    await expectLater(
      dio.get<Map<String, dynamic>>(
        'https://example.org/image?token=private&rkey=private',
        options: Options(responseType: ResponseType.json),
      ),
      throwsA(isA<DioException>()),
    );

    final content = LogManager.logs.last.content;
    expect(content, contains('https://example.org/image'));
    expect(content, contains('403'));
    expect(content, isNot(contains('private')));
    LogManager.clear();
  });

  test('binary and text payloads only report size', () {
    expect(networkPayloadSummary('private'), '<Text length:7>');
    expect(networkPayloadSummary([1, 2, 3]), '<List length:3>');
    expect(safeNetworkError('private'), 'String(length:7)');
  });

  test('network error summaries omit messages and redact request secrets', () {
    final error = DioException(
      requestOptions: RequestOptions(
        path: 'https://example.org/image?token=private&rkey=private&page=3',
      ),
      message: 'private response body',
      error: 'private transport detail',
      response: Response(
        requestOptions:
            RequestOptions(path: 'https://example.org/image?token=private'),
        statusCode: 403,
      ),
    );

    final summary = safeNetworkError(error);
    expect(summary, contains('GET https://example.org/image'));
    expect(summary, contains('status:403'));
    expect(summary, contains('page=3'));
    expect(summary, isNot(contains('private')));
  });
}
