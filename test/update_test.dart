import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/update.dart';

class _ReleaseAdapter implements HttpClientAdapter {
  _ReleaseAdapter(this.payload);

  final Map<String, dynamic> payload;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(payload)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('compares numeric version components without dynamic type errors', () {
    expect(compareSemVer('4.2.18', '4.2.17'), isTrue);
    expect(compareSemVer('4.3.0', '4.20.0'), isFalse);
    expect(compareSemVer('4.2.17', '4.2.17'), isFalse);
  });

  test('release versions sort after prereleases and invalid tags are ignored',
      () {
    expect(compareSemVer('4.2.17', '4.2.17-beta.1'), isTrue);
    expect(compareSemVer('4.2.17-beta.1', '4.2.17'), isFalse);
    expect(compareSemVer('not-a-version', '4.2.17'), isFalse);
    expect(compareSemVer('v4.2.18+4218', '4.2.17+4217'), isTrue);
  });

  test('prerelease identifiers use SemVer ordering', () {
    expect(compareSemVer('4.2.17-beta.10', '4.2.17-beta.2'), isTrue);
    expect(compareSemVer('4.2.17-beta.2', '4.2.17-beta.10'), isFalse);
    expect(compareSemVer('4.2.17-1', '4.2.17-alpha'), isFalse);
    expect(compareSemVer('4.2.17-alpha', '4.2.17-1'), isTrue);
    expect(compareSemVer('4.2.17+build.10', '4.2.17+build.2'), isFalse);
    expect(compareSemVer('01.0.0', '1.0.0'), isFalse);
    expect(
      compareSemVer('1.0.0-alpha.999999999999999999999999', '1.0.0-alpha.2'),
      isTrue,
    );
    expect(
      compareSemVer('999999999999999999999.0.0', '1.0.0'),
      isTrue,
    );
    expect(compareSemVer('1.0.0-alpha.01', '1.0.0-alpha.1'), isFalse);
  });

  test('release with a null body remains a valid update response', () async {
    final dio = Dio()
      ..httpClientAdapter = _ReleaseAdapter({
        'tag_name': 'v4.2.18',
        'body': null,
      });
    addTearDown(() => dio.close(force: true));

    expect(await getLatestVersion(client: dio), '4.2.18');
    expect(await getUpdatesInfo(), '');
  });
}
