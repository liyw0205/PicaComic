import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/pages/download_page.dart';

void main() {
  test('font download treats Dio cancellation as a normal result', () async {
    final cancelToken = CancelToken();

    final completed = await runFontDownload((token) async {
      token.cancel('user stopped');
      throw DioException(
        requestOptions: RequestOptions(path: '/font.ttf'),
        type: DioExceptionType.cancel,
      );
    }, cancelToken);

    expect(completed, isFalse);
  });

  test('font download propagates non-cancellation errors', () async {
    final failure = StateError('font server failed');

    await expectLater(
      runFontDownload((_) async => throw failure, CancelToken()),
      throwsA(same(failure)),
    );
  });

  test('font download future waits for the underlying operation', () async {
    final gate = Completer<void>();
    var settled = false;
    final future = runFontDownload((_) => gate.future, CancelToken());
    future.then((_) => settled = true);

    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    gate.complete();
    expect(await future, isTrue);
    expect(settled, isTrue);
  });
}
