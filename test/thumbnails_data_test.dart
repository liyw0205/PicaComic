import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';

void main() {
  test('thumbnail decode dimensions follow display size and pixel ratio', () {
    expect(thumbnailCacheDimension(double.infinity, 120, 2), 240);
    expect(thumbnailCacheDimension(double.infinity, 80, 2), 160);
    expect(thumbnailCacheDimension(96, 120, 1.5), 144);
    expect(
        thumbnailCacheDimension(double.infinity, double.infinity, 2), isNull);
    expect(thumbnailCacheDimension(120, 80, double.nan), isNull);
  });

  test('thumbnail request failure releases the retry guard', () async {
    final requests = <int>[];
    var fail = true;
    final thumbnails = ThumbnailsData([], (page) async {
      requests.add(page);
      if (fail) {
        fail = false;
        throw StateError('temporary failure');
      }
      return const Res(['thumbnail'], subData: 2);
    }, 2);

    await expectLater(thumbnails.get(() {}), throwsStateError);
    expect(thumbnails.isGetting, isFalse);

    await thumbnails.get(() {});
    expect(requests, [2, 2]);
    expect(thumbnails.thumbnails, ['thumbnail']);
    expect(thumbnails.current, 2);
  });
}
