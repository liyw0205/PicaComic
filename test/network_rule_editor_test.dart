import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late File configFile;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-rule-editor-');
    App.dataPath = directory.path;
    configFile = File('${directory.path}/rule.json');
  });

  setUp(() async {
    await configFile.writeAsString(jsonEncode({'port': 7891, 'rule': {}}));
  });

  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  testWidgets('rule editor accepts taps below short input and saves long edits',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const EditRuleView()),
            ),
            child: const Text('Open rules'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('Open rules'));
    for (var frame = 0;
        frame < 20 && find.byType(TextField).evaluate().isEmpty;
        frame++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }

    final field = tester.widget<TextField>(find.byType(TextField));
    await tester.pumpAndSettle();
    final pageBounds = tester.getRect(find.byType(Scaffold).last);
    await tester.tapAt(Offset(pageBounds.center.dx, pageBounds.bottom - 32));
    await tester.pump();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue);

    final edited = const JsonEncoder.withIndent('    ').convert({
      'port': 7891,
      'rule': {
        for (var index = 0; index < 100; index++)
          'host-$index.example': '127.0.0.1',
      },
    });
    await tester.enterText(find.byType(TextField), edited);
    await tester.pumpAndSettle();
    final fieldBounds = tester.getRect(find.byType(TextField));
    expect(fieldBounds.bottom, lessThanOrEqualTo(pageBounds.bottom));
    final scrollable = find.descendant(
      of: find.byType(EditableText),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0));
    final previousOffset = position.pixels;
    await tester.drag(find.byType(TextField), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(previousOffset));
    await tester.runAsync(() async {
      Navigator.of(tester.element(find.byType(EditRuleView))).pop();
    });
    await tester.pumpAndSettle();
    expect(find.byType(EditRuleView), findsNothing);
    expect(() => field.controller!.addListener(() {}), throwsFlutterError);

    String? saved;
    for (var attempt = 0; attempt < 50 && saved != edited; attempt++) {
      saved = await tester.runAsync(configFile.readAsString);
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(saved, edited);
    expect(tester.takeException(), isNull);
  });
}
