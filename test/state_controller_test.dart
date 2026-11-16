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

  test('putIfNotExists disposes an unused candidate', () {
    final existing = StateController.put(
      _TestController(),
      tag: 'put-if-existing',
    );
    final candidate = _TestController();

    expect(
      StateController.putIfNotExists(candidate, tag: 'put-if-existing'),
      same(existing),
    );
    expect(candidate.isDisposed, isTrue);
    expect(existing.isDisposed, isFalse);
    expect(
      StateController.find<_TestController>(tag: 'put-if-existing'),
      same(existing),
    );

    StateController.remove<_TestController>('put-if-existing');
  });

  test('putIfNotExists keeps an already registered candidate alive', () {
    final candidate = StateController.put(
      _TestController(),
      tag: 'put-if-candidate',
    );
    final existing = StateController.put(
      _TestController(),
      tag: 'put-if-existing-2',
    );

    expect(
      StateController.putIfNotExists(candidate, tag: 'put-if-existing-2'),
      same(existing),
    );
    expect(candidate.isDisposed, isFalse);
    expect(
      StateController.find<_TestController>(tag: 'put-if-candidate'),
      same(candidate),
    );

    StateController.remove<_TestController>('put-if-existing-2');
    StateController.remove<_TestController>('put-if-candidate');
  });

  test('putIfNotExists does not dispose the matching instance itself', () {
    final controller = StateController.put(
      _TestController(),
      tag: 'put-if-self',
    );

    expect(
      StateController.putIfNotExists(controller, tag: 'put-if-self'),
      same(controller),
    );
    expect(controller.isDisposed, isFalse);

    StateController.remove<_TestController>('put-if-self');
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

  testWidgets('StateBuilder removes its own controller for duplicate tags',
      (tester) async {
    final first = _TestController();
    final second = _TestController();

    await tester.pumpWidget(Column(
      children: [
        StateBuilder<_TestController>(
          key: const ValueKey('first'),
          init: first,
          tag: 'duplicate-tag',
          builder: (_) => const SizedBox.shrink(),
        ),
        StateBuilder<_TestController>(
          key: const ValueKey('second'),
          init: second,
          tag: 'duplicate-tag',
          builder: (_) => const SizedBox.shrink(),
        ),
      ],
    ));

    await tester.pumpWidget(Column(
      children: [
        StateBuilder<_TestController>(
          key: const ValueKey('second'),
          init: second,
          tag: 'duplicate-tag',
          builder: (_) => const SizedBox.shrink(),
        ),
      ],
    ));

    expect(first.isDisposed, isTrue);
    expect(second.isDisposed, isFalse);
    expect(StateController.findAll<_TestController>(tag: 'duplicate-tag'),
        [second]);
    StateController.remove<_TestController>('duplicate-tag');
  });

  testWidgets('StateBuilder rebinds when its tag changes', (tester) async {
    final first = _TestController();
    final second = _TestController();

    await tester.pumpWidget(StateBuilder<_TestController>(
      init: first,
      tag: 'first-tag',
      builder: (_) => const SizedBox.shrink(),
    ));

    await tester.pumpWidget(StateBuilder<_TestController>(
      init: second,
      tag: 'second-tag',
      builder: (_) => const SizedBox.shrink(),
    ));

    expect(first.isDisposed, isTrue);
    expect(second.isDisposed, isFalse);
    expect(
      StateController.find<_TestController>(tag: 'second-tag'),
      same(second),
    );
    expect(
        StateController.findOrNull<_TestController>(tag: 'first-tag'), isNull);
    StateController.remove<_TestController>('second-tag');
  });
}
