import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';

void main() {
  test('close is safe before the navigator callback is installed', () async {
    final controller = LoadingDialogController();
    var calls = 0;

    controller.close();
    controller.closeDialog = () => calls++;
    await Future<void>.delayed(Duration.zero);

    expect(controller.closed, isTrue);
    expect(calls, 1);
  });

  test('close invokes the navigator callback only once', () {
    final controller = LoadingDialogController();
    var calls = 0;
    controller.closeDialog = () => calls++;

    controller.close();
    controller.close();

    expect(calls, 1);
  });
}
