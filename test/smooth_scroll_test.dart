import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';

void main() {
  Widget view(ScrollController controller) => MaterialApp(
        home: SmoothScrollProvider(
          controller: controller,
          builder: (context, controller, physics) => SingleChildScrollView(
            controller: controller,
            physics: physics,
            child: const SizedBox(width: 400, height: 5000),
          ),
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
}
