import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';

void main() {
  Widget host(int? initialValue, List<String> values, List<int> changes) =>
      MaterialApp(
        navigatorKey: App.navigatorKey,
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Center(
            child: Select(
              key: const ValueKey('select'),
              initialValue: initialValue,
              values: values,
              onChange: changes.add,
            ),
          ),
        ),
      );

  testWidgets('select follows parent selection changes without callbacks',
      (tester) async {
    final changes = <int>[];
    const values = ['First', 'Second'];
    await tester.pumpWidget(host(0, values, changes));
    expect(find.text('First'), findsOneWidget);

    await tester.pumpWidget(host(1, values, changes));
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('First'), findsNothing);

    await tester.pumpWidget(host(null, values, changes));
    expect(find.text('Second'), findsNothing);
    expect(changes, isEmpty);
  });

  testWidgets('select clears a selection outside a shortened or empty list',
      (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(host(2, ['First', 'Second', 'Third'], changes));
    expect(find.text('Third'), findsOneWidget);

    await tester.pumpWidget(host(2, ['First'], changes));
    expect(tester.takeException(), isNull);
    expect(find.text('Third'), findsNothing);
    expect(find.text('First'), findsNothing);

    await tester.pumpWidget(host(2, [], changes));
    await tester.tap(find.byType(Select));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(PopupMenuItem<int>), findsNothing);
    expect(changes, isEmpty);
  });

  testWidgets('select tolerates invalid initial indexes', (tester) async {
    final changes = <int>[];
    for (final index in [-1, 2]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host(index, ['First', 'Second'], changes));
      expect(tester.takeException(), isNull);
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsNothing);
    }
    expect(changes, isEmpty);
  });

  testWidgets('select keeps user choice until the parent changes selection',
      (tester) async {
    final changes = <int>[];
    const values = ['First', 'Second'];
    await tester.pumpWidget(host(0, values, changes));
    await tester.tap(find.byType(Select));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(changes, [1]);
    expect(find.text('Second'), findsOneWidget);

    await tester.pumpWidget(host(0, values, changes));
    expect(find.text('Second'), findsOneWidget);
    expect(changes, [1]);
  });

  testWidgets('filter chip tolerates an overlay entry before its first layout',
      (tester) async {
    final hiddenEntry = OverlayEntry(
      maintainState: true,
      builder: (_) => Center(
        child: FilterChipFixedWidth(
          label: const Text('Source'),
          selected: false,
          onSelected: (_) {},
        ),
      ),
    );
    final coverEntry = OverlayEntry(
      opaque: true,
      builder: (_) => const SizedBox.expand(),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Overlay(initialEntries: [hiddenEntry, coverEntry]),
    ));
    expect(tester.takeException(), isNull);

    coverEntry.remove();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Source'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final revealedSize = tester.getSize(find.byType(FilterChipFixedWidth));

    hiddenEntry.remove();
    await tester.pumpWidget(const SizedBox.shrink());
    hiddenEntry.dispose();
    coverEntry.dispose();

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Center(
        child: FilterChipFixedWidth(
          label: const Text('Source'),
          selected: false,
          onSelected: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FilterChipFixedWidth)), revealedSize);
  });

  testWidgets('filter chip keeps its size when toggling selection',
      (tester) async {
    var selected = false;
    final changes = <bool>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          body: Wrap(children: [
            FilterChipFixedWidth(
              label: const Text('Source'),
              selected: selected,
              onSelected: (value) {
                changes.add(value);
                setState(() => selected = value);
              },
            ),
          ]),
        );
      }),
    ));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(FilterChipFixedWidth));

    await tester.tap(find.byType(FilterChipFixedWidth));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(changes, [true]);
    expect(tester.getSize(find.byType(FilterChipFixedWidth)), size);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter chip can be removed without ever being laid out',
      (tester) async {
    final hiddenEntry = OverlayEntry(
      maintainState: true,
      builder: (_) => FilterChipFixedWidth(
        label: const Text('Source'),
        selected: true,
        onSelected: (_) {},
      ),
    );
    final coverEntry = OverlayEntry(
      opaque: true,
      builder: (_) => const SizedBox.expand(),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Overlay(initialEntries: [hiddenEntry, coverEntry]),
    ));
    expect(tester.takeException(), isNull);

    hiddenEntry.remove();
    coverEntry.remove();
    await tester.pumpWidget(const SizedBox.shrink());
    hiddenEntry.dispose();
    coverEntry.dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
