import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';

void main() {
  Widget view(ScrollController? controller,
          {ValueChanged<ScrollController>? onController}) =>
      MaterialApp(
        home: SmoothScrollProvider(
          controller: controller,
          builder: (context, controller, physics) {
            onController?.call(controller);
            return SingleChildScrollView(
              controller: controller,
              physics: physics,
              child: const SizedBox(width: 400, height: 5000),
            );
          },
        ),
      );

  Future<void> wheel(WidgetTester tester, double delta) async {
    await tester.sendEventToBinding(PointerScrollEvent(
      position: tester.getCenter(find.byType(SingleChildScrollView)),
      scrollDelta: Offset(0, delta),
    ));
  }

  testWidgets(
      'wheel uses the current position after a completed scroll and jump',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(view(controller));
    await wheel(tester, 80);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(80, 0.01));

    controller.jumpTo(1000);
    await tester.pump();
    await wheel(tester, 80);
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(1080, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wheel resumes at the touch position without reversing direction',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(view(controller));
    await wheel(tester, 80);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SingleChildScrollView));
    await tester.pump();
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final touchOffset = controller.offset;
    expect(touchOffset, greaterThan(500));

    await wheel(tester, 80);
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(touchOffset + 80, 0.01));
    await wheel(tester, 80);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(touchOffset + 160, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rapid wheel input keeps the newest accumulated target',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(view(controller));
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 16));
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 16));
    await wheel(tester, -40);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(150));
    expect(controller.offset, lessThan(190));

    final previousOffset = controller.offset;
    await wheel(tester, 60);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(previousOffset + 60, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a jump during a wheel animation replaces its stale target',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(view(controller));
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 16));
    controller.jumpTo(1000);
    await wheel(tester, 80);
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(1080, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wheel input is ignored while no scroll view is attached',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: SmoothScrollProvider(
        controller: controller,
        builder: (_, __, ___) => const SizedBox.expand(),
      ),
    ));
    await tester.sendEventToBinding(const PointerScrollEvent(
      position: Offset(100, 100),
      scrollDelta: Offset(0, 80),
    ));
    await tester.pumpAndSettle();

    expect(controller.hasClients, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replacing an external controller reattaches the mounted list',
      (tester) async {
    final first = ScrollController();
    final next = ScrollController();
    addTearDown(first.dispose);
    addTearDown(next.dispose);
    await tester.pumpWidget(view(first));
    final state = tester.state(find.byType(SmoothScrollProvider));
    await wheel(tester, 80);
    await tester.pump(const Duration(milliseconds: 16));

    await tester.pumpWidget(view(next));
    expect(tester.state(find.byType(SmoothScrollProvider)), same(state));
    expect(first.hasClients, isFalse);
    expect(next.hasClients, isTrue);
    final replacedOffset = next.offset;
    await wheel(tester, 80);
    await tester.pumpAndSettle();
    expect(next.offset, closeTo(replacedOffset + 80, 0.01));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view(first));
    first.jumpTo(400);
    expect(first.offset, 400);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an external controller replaces and releases the owned one',
      (tester) async {
    late ScrollController owned;
    final external = ScrollController();
    addTearDown(external.dispose);
    await tester.pumpWidget(view(null, onController: (value) => owned = value));
    owned.jumpTo(400);
    await tester.pump();

    await tester.pumpWidget(view(external));
    expect(owned.hasClients, isFalse);
    expect(external.hasClients, isTrue);
    expect(external.offset, 400);
    expect(() => owned.addListener(() {}), throwsFlutterError);

    await tester.pumpWidget(const SizedBox());
    void listener() {}
    external.addListener(listener);
    external.removeListener(listener);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing an external controller creates an owned replacement',
      (tester) async {
    final external = ScrollController();
    addTearDown(external.dispose);
    await tester.pumpWidget(view(external));
    external.jumpTo(400);
    await tester.pump();

    late ScrollController owned;
    await tester.pumpWidget(view(null, onController: (value) => owned = value));
    expect(owned, isNot(same(external)));
    expect(external.hasClients, isFalse);
    expect(owned.offset, 400);
    owned.jumpTo(1000);
    await wheel(tester, 80);
    await tester.pumpAndSettle();
    expect(owned.offset, closeTo(1080, 0.01));

    await tester.pumpWidget(const SizedBox());
    expect(() => owned.addListener(() {}), throwsFlutterError);
    void listener() {}
    external.addListener(listener);
    external.removeListener(listener);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the owned controller survives rebuilds and is released on exit',
      (tester) async {
    late ScrollController owned;
    await tester.pumpWidget(view(null, onController: (value) => owned = value));
    owned.jumpTo(400);
    await tester.pump();
    late ScrollController rebuilt;
    await tester
        .pumpWidget(view(null, onController: (value) => rebuilt = value));
    expect(rebuilt, same(owned));
    expect(rebuilt.offset, 400);

    await tester.pumpWidget(const SizedBox());
    expect(() => owned.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a caller can take ownership of the current internal controller',
      (tester) async {
    late ScrollController owned;
    await tester.pumpWidget(view(null, onController: (value) => owned = value));
    addTearDown(owned.dispose);
    final position = owned.position;

    await tester.pumpWidget(view(owned));
    expect(owned.position, same(position));
    owned.jumpTo(400);
    await wheel(tester, 80);
    await tester.pumpAndSettle();
    expect(owned.offset, closeTo(480, 0.01));

    await tester.pumpWidget(const SizedBox());
    void listener() {}
    owned.addListener(listener);
    owned.removeListener(listener);
    expect(tester.takeException(), isNull);
  });
}
