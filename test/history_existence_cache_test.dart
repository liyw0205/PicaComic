import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/pages/history_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late HistoryManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pica_history_cache_');
    manager = HistoryManager.create();
    await manager.init(
      databasePath: '${directory.path}/history.db',
      importLegacy: false,
    );
  });

  tearDown(() async {
    manager.close();
    await directory.delete(recursive: true);
  });

  test('lazy existence cache tracks absent, added, and removed targets',
      () async {
    const target = 'cache-target';
    expect(manager.findSync(target), isNull);

    await manager.addHistory(History(
      HistoryType.picacg,
      DateTime.now(),
      'Title',
      '',
      '',
      0,
      0,
      target,
    ));
    expect(manager.findSync(target), isNotNull);

    manager.remove(target);
    await DataMaintenance.waitForIdle();
    expect(manager.findSync(target), isNull);

    await manager.addHistory(History(
      HistoryType.picacg,
      DateTime.now(),
      'Title again',
      '',
      '',
      0,
      0,
      target,
    ));
    expect(manager.findSync(target)?.title, 'Title again');
  });

  testWidgets('history search waits for typing to settle before reloading',
      (tester) async {
    await manager.addHistory(History(
      HistoryType.picacg,
      DateTime.now(),
      'Alpha',
      '',
      '',
      0,
      1,
      'alpha',
    ));
    await manager.addHistory(History(
      HistoryType.picacg,
      DateTime.now().subtract(const Duration(minutes: 1)),
      'Beta',
      '',
      '',
      0,
      1,
      'beta',
    ));

    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(
        tileBuilder: (context, history) => Text(history.title),
      ),
    ));
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    expect(find.text('Beta'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
