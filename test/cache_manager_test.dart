import 'package:flutter_test/flutter_test.dart';

import 'cache_manager_regression.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cache cleanup, accounting and concurrent writes', verifyCacheManager);
}
