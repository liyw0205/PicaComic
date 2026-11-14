import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/state_controller.dart';

class _TestController extends StateController {}

void main() {
  test('subscriptions are removable and idempotent', () {
    final controller = _TestController();
    var calls = 0;
    final first = controller.subscribe(() => calls++);
    final second = controller.subscribe(() => calls++, id: 'second');

    controller.update();
    expect(calls, 2);
    expect(controller.stateUpdaters, hasLength(2));

    first.dispose();
    first.dispose();
    controller.update();
    expect(calls, 3);
    expect(first.isDisposed, isTrue);
    expect(second.isDisposed, isFalse);

    controller.dispose();
    second.dispose();
  });

  test('disposed controllers clear listeners and reject registration', () {
    final controller = _TestController();
    controller.subscribe(() {});

    controller.dispose();
    controller.dispose();

    expect(controller.isDisposed, isTrue);
    expect(controller.stateUpdaters, isEmpty);
    expect(() => controller.subscribe(() {}), throwsStateError);
    expect(() => StateController.put(controller), throwsStateError);
  });

  test('a listener can dispose its own token during update', () {
    final controller = _TestController();
    var calls = 0;
    late StateControllerSubscription subscription;
    subscription = controller.subscribe(() {
      calls++;
      subscription.dispose();
    });
    controller.subscribe(() => calls++);

    controller.update();
    controller.update();

    expect(calls, 3);
    expect(controller.stateUpdaters, hasLength(1));
    controller.dispose();
  });

  test('removing a controller disposes its subscriptions', () {
    final controller = StateController.put(
      _TestController(),
      tag: 'state-controller-test',
    );
    controller.subscribe(() {});

    StateController.remove<_TestController>('state-controller-test');

    expect(controller.isDisposed, isTrue);
    expect(controller.stateUpdaters, isEmpty);
    expect(
        StateController.findOrNull<_TestController>(
            tag: 'state-controller-test'),
        isNull);
  });

  testWidgets('StateBuilder removes its updater when unmounted',
      (tester) async {
    late _TestController controller;
    await tester.pumpWidget(StateBuilder<_TestController>(
      init: _TestController(),
      builder: (value) {
        controller = value;
        return const SizedBox.shrink();
      },
    ));
    expect(controller.stateUpdaters, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());

    expect(controller.isDisposed, isTrue);
    expect(controller.stateUpdaters, isEmpty);
  });
}
