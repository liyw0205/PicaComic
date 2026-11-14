import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';

void main() {
  test('thumbnail decode dimensions follow display size and pixel ratio', () {
    expect(thumbnailCacheDimension(double.infinity, 120, 2), 240);
    expect(thumbnailCacheDimension(double.infinity, 80, 2), 160);
    expect(thumbnailCacheDimension(96, 120, 1.5), 144);
    expect(
        thumbnailCacheDimension(double.infinity, double.infinity, 2), isNull);
    expect(thumbnailCacheDimension(120, 80, double.nan), isNull);
  });
}
