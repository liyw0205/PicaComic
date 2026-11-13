import 'package:flutter_test/flutter_test.dart';

import 'byte_lru_cache_regression.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('byte cache replacement, eviction and owner-safe cleanup',
      verifyByteLruCache);
}
