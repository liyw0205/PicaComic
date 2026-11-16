import 'package:flutter_test/flutter_test.dart';

import 'byte_lru_cache_regression.dart';
import 'cache_manager_regression.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cache cleanup, accounting and concurrent writes', verifyCacheManager);
  test('byte cache replacement, eviction and owner-safe cleanup',
      verifyByteLruCache);
}
