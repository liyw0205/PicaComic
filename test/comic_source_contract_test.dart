import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';

void main() {
  test('custom source parser rejects oversized source before evaluation',
      () async {
    final source = 'x' * (ComicSourceParser.maxSourceBytes + 1);
    await expectLater(
      ComicSourceParser().parse(source, 'oversized.js'),
      throwsA(isA<ComicSourceParseException>()),
    );
  });
}
