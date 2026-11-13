import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling one owned image stream does not cancel another', () async {
    var firstCancelled = false;
    var secondCancelled = false;
    final first = StreamController<int>(
      onCancel: () => firstCancelled = true,
    );
    final second = StreamController<int>(
      onCancel: () => secondCancelled = true,
    );
    final firstSubscription =
        ImageManager.withTaskOwner(first.stream, Object()).listen((_) {});
    final secondSubscription =
        ImageManager.withTaskOwner(second.stream, Object()).listen((_) {});

    await firstSubscription.cancel();

    expect(firstCancelled, isTrue);
    expect(secondCancelled, isFalse);
    await secondSubscription.cancel();
    expect(secondCancelled, isTrue);
  });
}
